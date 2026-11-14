import SwiftUI
import Supabase

/// What the app is doing right now. Calls are still simulated;
/// real audio arrives with LiveKit in step 3.
enum Activity: Equatable {
    case idle
    case inCall(with: Set<UUID>)
}

enum Phase: Equatable {
    case needsConfig
    case loading
    case signedOut
    case signedIn
}

@MainActor
final class TeamStore: ObservableObject {
    // Account
    @Published var phase: Phase = .loading
    @Published var me: Teammate?
    @Published var teammates: [Teammate] = []
    @Published var pendingInvites: [String] = []
    @Published var errorMessage: String?

    // Call state (simulated until step 3)
    @Published var activity: Activity = .idle
    @Published var doNotDisturb = false
    @Published var isMuted = false
    @Published var isSharingScreen = false
    @Published var talkingTo: UUID?

    private let client: SupabaseClient?
    private var teamID: UUID?
    private var onlineIDs: Set<UUID> = []
    private var presenceChannel: RealtimeChannelV2?
    private var presenceTask: Task<Void, Never>?

    init() {
        guard let config = AppConfig.load() else {
            client = nil
            phase = .needsConfig
            return
        }
        let client = makeSupabaseClient(config)
        self.client = client

        Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession, .signedIn:
                    if session != nil, self.phase != .signedIn {
                        await self.didSignIn()
                    } else if session == nil {
                        self.phase = .signedOut
                    }
                case .signedOut:
                    await self.didSignOut()
                default:
                    break
                }
            }
        }
    }

    // MARK: Sign-in

    /// Emails a one-time code to the address.
    func sendCode(to email: String) async -> Bool {
        guard let client else { return false }
        errorMessage = nil
        do {
            try await client.auth.signInWithOTP(email: email)
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    func verify(code: String, for email: String) async {
        guard let client else { return }
        errorMessage = nil
        do {
            try await client.auth.verifyOTP(email: email, token: code, type: .email)
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func signOut() async {
        guard let client else { return }
        await leavePresence()
        try? await client.auth.signOut(scope: .local)
        await didSignOut()
    }

    private func didSignIn() async {
        errorMessage = nil
        await reloadTeam()
        guard me != nil else {
            // Signed in but the profile could not be read (schema missing or session invalid).
            phase = .signedOut
            return
        }
        phase = .signedIn
        await joinPresence()
    }

    private func didSignOut() async {
        await leavePresence()
        me = nil
        teammates = []
        pendingInvites = []
        teamID = nil
        activity = .idle
        phase = .signedOut
    }

    // MARK: Team

    /// Loads my profile, my teammates and pending invites.
    /// Row-level security limits the rows to my own team.
    func reloadTeam() async {
        guard let client, let userID = client.auth.currentSession?.user.id else { return }
        do {
            let profiles: [ProfileRow] = try await client.from("profiles").select().execute().value
            let invites: [InviteRow] = try await client.from("invites").select("email")
                .order("created_at").execute().value

            guard let mine = profiles.first(where: { $0.id == userID }) else {
                errorMessage = "Your profile was not found. Has the database schema been set up?"
                return
            }
            teamID = mine.teamID
            me = Teammate(mine, isOnline: true)
            teammates = profiles
                .filter { $0.id != userID }
                .map { Teammate($0, isOnline: onlineIDs.contains($0.id)) }
            pendingInvites = invites.map(\.email)
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func invite(email: String) async -> Bool {
        guard let client else { return false }
        errorMessage = nil
        do {
            let _: String = try await client
                .rpc("invite_teammate", params: ["invite_email": email])
                .execute().value
            await reloadTeam()
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    func cancelInvite(email: String) async {
        guard let client else { return }
        do {
            try await client.rpc("cancel_invite", params: ["invite_email": email]).execute()
            await reloadTeam()
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Opens the user's mail app with a ready-to-send invitation.
    func composeInviteEmail(to email: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Join me on \(AppInfo.name)"),
            URLQueryItem(
                name: "body",
                value: "I've added you to my team on \(AppInfo.name). "
                    + "Open the app and sign in with this email address (\(email)) "
                    + "and you'll land in the team automatically."
            ),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Presence

    private func joinPresence() async {
        guard let client, let teamID, let userID = me?.id else { return }
        await leavePresence()

        let channel = client.realtimeV2.channel("team:\(teamID.uuidString.lowercased())") {
            $0.presence.key = userID.uuidString.lowercased()
        }
        presenceChannel = channel

        // Listen before subscribing so the first full sync is not missed.
        let changes = channel.presenceChange()
        presenceTask = Task { [weak self] in
            for await change in changes {
                let left = (try? change.decodeLeaves(as: PresenceState.self)) ?? []
                let joined = (try? change.decodeJoins(as: PresenceState.self)) ?? []
                await self?.applyPresence(
                    joined: joined.compactMap { UUID(uuidString: $0.userID) },
                    left: left.compactMap { UUID(uuidString: $0.userID) }
                )
            }
        }

        do {
            try await channel.subscribeWithError()
            try await channel.track(PresenceState(userID: userID.uuidString.lowercased()))
        } catch {
            errorMessage = "Couldn't connect for live presence: \(friendlyMessage(error))"
        }
    }

    private func leavePresence() async {
        presenceTask?.cancel()
        presenceTask = nil
        if let channel = presenceChannel {
            await channel.untrack()
            await client?.realtimeV2.removeChannel(channel)
        }
        presenceChannel = nil
        onlineIDs = []
    }

    private func applyPresence(joined: [UUID], left: [UUID]) async {
        onlineIDs.subtract(left)
        onlineIDs.formUnion(joined)

        // Someone we don't know yet came online: a new teammate just joined.
        let known = Set(teammates.map(\.id)).union([me?.id].compactMap { $0 })
        if !Set(joined).isSubset(of: known) {
            await reloadTeam()
        }
        for index in teammates.indices {
            teammates[index].isOnline = onlineIDs.contains(teammates[index].id)
        }
        // Drop anyone who went offline from the simulated call.
        if case .inCall(let ids) = activity {
            let remaining = ids.intersection(onlineIDs)
            activity = remaining.isEmpty ? .idle : .inCall(with: remaining)
        }
    }

    // MARK: Calls (simulated)

    var menuBarSymbol: String {
        if talkingTo != nil { return "dot.radiowaves.left.and.right" }
        if case .inCall = activity { return "phone.fill" }
        return doNotDisturb ? "moon.fill" : "hand.point.up.left.fill"
    }

    var sortedTeammates: [Teammate] {
        teammates.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var callMembers: [Teammate] {
        guard case .inCall(let ids) = activity else { return [] }
        return teammates.filter { ids.contains($0.id) }
    }

    func isInCall(_ teammate: Teammate) -> Bool {
        guard case .inCall(let ids) = activity else { return false }
        return ids.contains(teammate.id)
    }

    /// Starts a call, or adds the teammate to the current one (group calls).
    func call(_ teammate: Teammate) {
        guard teammate.isOnline else { return }
        if case .inCall(var ids) = activity {
            ids.insert(teammate.id)
            activity = .inCall(with: ids)
        } else {
            activity = .inCall(with: [teammate.id])
        }
    }

    func hangUp() {
        activity = .idle
        isMuted = false
        isSharingScreen = false
    }

    func setTalking(_ talking: Bool, to teammate: Teammate) {
        guard teammate.isOnline else { return }
        talkingTo = talking ? teammate.id : nil
    }
}

extension Teammate {
    init(_ row: ProfileRow, isOnline: Bool) {
        self.init(
            id: row.id,
            name: row.name.isEmpty ? row.email : row.name,
            email: row.email,
            isOnline: isOnline,
            colorIndex: row.colorIndex
        )
    }
}
