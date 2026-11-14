import SwiftUI
import Supabase

/// The call I'm in. `connected` and `ringing` never include me.
struct CallState: Equatable {
    var room: String
    var connected: Set<UUID> = []
    var ringing: Set<UUID> = []
    /// Still joining the audio room.
    var isConnecting = true
}

struct IncomingCall: Equatable {
    let from: UUID
    let fromName: String
    let room: String
}

/// Sent between teammates over the team channel to ring, cancel and decline.
struct CallSignal: Codable {
    enum Kind: String, Codable { case ring, cancel, decline, busy }
    let kind: Kind
    let from: UUID
    let to: UUID
    let room: String
    let name: String
}

/// What the `livekit-token` function returns.
private struct CallPass: Decodable {
    let token: String
    let url: String
}

enum Phase: Equatable {
    case needsConfig
    case loading
    /// No team yet: ask for a name and whether to start or join a team.
    case welcome
    case inTeam
}

@MainActor
final class TeamStore: ObservableObject {
    // Account
    @Published var phase: Phase = .loading
    @Published var me: Teammate?
    @Published var teammates: [Teammate] = []
    @Published var teamCode: String?
    @Published var errorMessage: String?

    // Calls
    @Published var call: CallState?
    @Published var incoming: IncomingCall?
    /// A short neutral message such as "Maya declined".
    @Published var notice: String?
    @Published var doNotDisturb = false
    @Published var isMuted = false
    /// Walkie-talkie target (still simulated).
    @Published var talkingTo: UUID?

    /// Lets the app delegate open the panel when a call comes in.
    var onIncomingCall: (() -> Void)?

    private let client: SupabaseClient?
    private var teamID: UUID?
    private var onlineIDs: Set<UUID> = []
    private var presenceChannel: RealtimeChannelV2?
    private var presenceTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private let engine = CallEngine()
    private var ringTimer: Timer?

    init() {
        guard let config = AppConfig.load() else {
            client = nil
            phase = .needsConfig
            return
        }
        let client = makeSupabaseClient(config)
        self.client = client

        engine.onParticipantsChanged = { [weak self] ids in
            guard let self, self.call != nil else { return }
            self.call?.connected = ids
            self.call?.ringing.subtract(ids)
            self.endCallIfAlone()
        }
        engine.onDisconnected = { [weak self] in
            guard let self, self.call != nil else { return }
            self.call = nil
            self.isMuted = false
            self.notice = "The call was disconnected."
        }

        Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession:
                    if session != nil {
                        await self.enterTeamIfMember()
                    } else {
                        self.phase = .welcome
                    }
                case .signedOut:
                    await self.resetToWelcome()
                default:
                    break
                }
            }
        }
    }

    // MARK: Joining

    /// Starts a new team with me as its first member.
    func startTeam(name: String) async {
        await onboard {
            try await $0.rpc("create_team", params: ["my_name": name]).execute()
        }
    }

    /// Joins an existing team using its code.
    func joinTeam(name: String, code: String) async {
        await onboard {
            try await $0.rpc("join_team", params: ["my_name": name, "team_code": code]).execute()
        }
    }

    private func onboard(_ action: (SupabaseClient) async throws -> Void) async {
        guard let client else { return }
        errorMessage = nil
        do {
            // Each Mac gets a silent anonymous account; there is nothing to sign in to.
            if client.auth.currentSession == nil {
                _ = try await client.auth.signInAnonymously()
            }
            try await action(client)
            await enterTeamIfMember()
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    private func enterTeamIfMember() async {
        await reloadTeam()
        if phase == .inTeam {
            await joinPresence()
        }
    }

    private func resetToWelcome() async {
        await leavePresence()
        me = nil
        teammates = []
        teamCode = nil
        teamID = nil
        hangUp()
        dismissIncoming()
        phase = .welcome
    }

    // MARK: Team

    /// Loads my profile, my teammates and the team code, and sets the phase.
    /// Row-level security limits the rows to my own team.
    func reloadTeam() async {
        guard let client, let userID = client.auth.currentSession?.user.id else {
            phase = .welcome
            return
        }
        do {
            let profiles: [ProfileRow] = try await client.from("profiles").select().execute().value

            guard let mine = profiles.first(where: { $0.id == userID }), let team = mine.teamID else {
                // No profile yet, or I was removed from the team.
                if phase == .inTeam { await resetToWelcome() } else { phase = .welcome }
                return
            }
            let teams: [TeamRow] = try await client.from("teams").select("code").execute().value

            teamID = team
            teamCode = teams.first?.code
            me = Teammate(mine, isOnline: true)
            teammates = profiles
                .filter { $0.id != userID }
                .map { Teammate($0, isOnline: onlineIDs.contains($0.id)) }
            phase = .inTeam
        } catch {
            errorMessage = friendlyMessage(error)
            if phase == .loading { phase = .welcome }
        }
    }

    func rename(to name: String) async {
        await run { try await $0.rpc("set_my_name", params: ["new_name": name]).execute() }
    }

    func remove(_ teammate: Teammate) async {
        await run {
            try await $0.rpc("remove_from_team", params: ["member": teammate.id.uuidString]).execute()
        }
    }

    func leaveTeam() async {
        guard let id = me?.id else { return }
        await run { try await $0.rpc("remove_from_team", params: ["member": id.uuidString]).execute() }
    }

    /// Replaces the team code so the old one stops working.
    func regenerateCode() async {
        await run { try await $0.rpc("regenerate_team_code").execute() }
    }

    func copyTeamCode() {
        guard let teamCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(teamCode, forType: .string)
    }

    private func run(_ action: (SupabaseClient) async throws -> Void) async {
        guard let client else { return }
        errorMessage = nil
        do {
            try await action(client)
            await reloadTeam()
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    // MARK: Presence

    private func joinPresence() async {
        guard let client, let teamID, let userID = me?.id else { return }
        guard presenceChannel == nil else { return }

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

        let signals = channel.broadcastStream(event: "call")
        signalTask = Task { [weak self] in
            for await message in signals {
                guard let payload = message["payload"]?.objectValue,
                      let signal = try? payload.decode(as: CallSignal.self)
                else { continue }
                await self?.receive(signal)
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
        signalTask?.cancel()
        signalTask = nil
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
        // Someone I was ringing went offline: stop waiting for them.
        if let ringing = call?.ringing, !ringing.isSubset(of: onlineIDs) {
            call?.ringing.formIntersection(onlineIDs)
            endCallIfAlone()
        }
        if let incoming, !onlineIDs.contains(incoming.from) {
            dismissIncoming()
        }
    }

    // MARK: Calls

    /// SF Symbol for the menu bar while something is happening; nil means show the ✦✦ mark.
    /// Being on a call deliberately keeps the ✦✦ mark.
    var menuBarSymbol: String? {
        if incoming != nil { return "phone.arrow.down.left.fill" }
        if talkingTo != nil { return "dot.radiowaves.left.and.right" }
        return doNotDisturb ? "moon.fill" : nil
    }

    var sortedTeammates: [Teammate] {
        teammates.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Everyone in the call or being rung.
    var callMembers: [Teammate] {
        guard let call else { return [] }
        return teammates.filter { call.connected.contains($0.id) || call.ringing.contains($0.id) }
    }

    func isInCall(_ teammate: Teammate) -> Bool {
        call?.connected.contains(teammate.id) ?? false
    }

    func isRinging(_ teammate: Teammate) -> Bool {
        call?.ringing.contains(teammate.id) ?? false
    }

    /// Rings a teammate: starts a call, or adds them to the current one (group calls).
    func call(_ teammate: Teammate) {
        guard teammate.isOnline, incoming == nil else { return }
        guard !isInCall(teammate), !isRinging(teammate) else { return }
        Task { await ring(teammate) }
    }

    private func ring(_ teammate: Teammate) async {
        notice = nil
        errorMessage = nil

        if let current = call {
            call?.ringing.insert(teammate.id)
            await send(.ring, to: teammate.id, room: current.room)
            scheduleRingTimeout(for: teammate, room: current.room)
            return
        }

        guard let teamID else { return }
        let room = "\(teamID.uuidString.lowercased()):\(UUID().uuidString.lowercased())"
        call = CallState(room: room, ringing: [teammate.id])
        guard await joinAudio(room: room) else { return }
        await send(.ring, to: teammate.id, room: room)
        scheduleRingTimeout(for: teammate, room: room)
    }

    /// Gets a call pass from the server and connects the microphone. False if it failed
    /// or the call was hung up while connecting.
    private func joinAudio(room: String) async -> Bool {
        guard let client else { return false }
        guard await CallEngine.requestMicrophone() else {
            call = nil
            errorMessage = "Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone."
            return false
        }
        do {
            let pass: CallPass = try await client.functions.invoke(
                "livekit-token", options: .init(body: ["room": room])
            )
            try await engine.connect(url: pass.url, token: pass.token)
        } catch {
            await engine.disconnect()
            if call?.room == room { call = nil }
            errorMessage = "Couldn't start the call: \(friendlyMessage(error))"
            return false
        }
        guard call?.room == room else {
            // Hung up while we were connecting.
            await engine.disconnect()
            return false
        }
        call?.isConnecting = false
        return true
    }

    private func scheduleRingTimeout(for teammate: Teammate, room: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.call?.room == room, self.call?.ringing.contains(teammate.id) == true else { return }
            self.call?.ringing.remove(teammate.id)
            await self.send(.cancel, to: teammate.id, room: room)
            self.notice = "\(teammate.name) didn't answer."
            self.endCallIfAlone()
        }
    }

    /// A call with nobody connected and nobody ringing is over.
    private func endCallIfAlone() {
        guard let call, !call.isConnecting, call.connected.isEmpty, call.ringing.isEmpty else { return }
        hangUp()
    }

    func hangUp() {
        guard let current = call else { return }
        call = nil
        isMuted = false
        Task {
            for id in current.ringing {
                await send(.cancel, to: id, room: current.room)
            }
            await engine.disconnect()
        }
    }

    func toggleMute() {
        isMuted.toggle()
        let muted = isMuted
        Task { await engine.setMuted(muted) }
    }

    // MARK: Incoming calls

    func acceptIncoming() {
        guard let accepted = incoming else { return }
        dismissIncoming()
        notice = nil
        errorMessage = nil
        call = CallState(room: accepted.room)
        Task {
            guard await joinAudio(room: accepted.room) else { return }
            // Give the room a moment to list who is there; if the caller already left, end.
            try? await Task.sleep(for: .seconds(2))
            if call?.room == accepted.room { endCallIfAlone() }
        }
    }

    func declineIncoming() {
        guard let declined = incoming else { return }
        dismissIncoming()
        Task { await send(.decline, to: declined.from, room: declined.room) }
    }

    private func dismissIncoming() {
        incoming = nil
        ringTimer?.invalidate()
        ringTimer = nil
    }

    private func receive(_ signal: CallSignal) async {
        guard signal.to == me?.id else { return }
        let name = teammates.first { $0.id == signal.from }?.name ?? signal.name

        switch signal.kind {
        case .ring:
            if call?.room == signal.room || incoming?.room == signal.room { return }
            if doNotDisturb || call != nil || incoming != nil {
                await send(.busy, to: signal.from, room: signal.room)
                return
            }
            incoming = IncomingCall(from: signal.from, fromName: name, room: signal.room)
            startRingSound()
            onIncomingCall?()
            // Stop ringing by ourselves if the caller's cancel never arrives.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(40))
                guard let self, self.incoming?.room == signal.room else { return }
                self.dismissIncoming()
                self.notice = "Missed call from \(name)."
            }

        case .cancel:
            if incoming?.room == signal.room, incoming?.from == signal.from {
                dismissIncoming()
                notice = "Missed call from \(name)."
            }

        case .decline, .busy:
            guard call?.room == signal.room, call?.ringing.contains(signal.from) == true else { return }
            call?.ringing.remove(signal.from)
            notice = signal.kind == .busy ? "\(name) is busy." : "\(name) declined."
            endCallIfAlone()
        }
    }

    private func send(_ kind: CallSignal.Kind, to id: UUID, room: String) async {
        guard let me, let channel = presenceChannel else { return }
        let signal = CallSignal(kind: kind, from: me.id, to: id, room: room, name: me.name)
        try? await channel.broadcast(event: "call", message: signal)
    }

    private func startRingSound() {
        ringTimer?.invalidate()
        NSSound(named: "Glass")?.play()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            NSSound(named: "Glass")?.play()
        }
    }

    // MARK: Walkie-talkie (simulated)

    func setTalking(_ talking: Bool, to teammate: Teammate) {
        guard teammate.isOnline else { return }
        talkingTo = talking ? teammate.id : nil
    }
}

extension Teammate {
    init(_ row: ProfileRow, isOnline: Bool) {
        self.init(
            id: row.id,
            name: row.name.isEmpty ? "Teammate" : row.name,
            isOnline: isOnline,
            colorIndex: row.colorIndex
        )
    }
}
