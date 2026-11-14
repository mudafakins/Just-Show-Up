import SwiftUI
import Supabase

/// My connection to the team room. `connected` never includes me.
struct CallState: Equatable {
    var room: String
    var connected: Set<UUID> = []
    /// Still joining the audio room.
    var isConnecting = true
}

/// Sent between teammates over the team channel for the walkie-talkie.
/// (The ring/cancel/decline/busy kinds belong to older builds and are ignored.)
struct CallSignal: Codable {
    enum Kind: String, Codable {
        case ring, cancel, decline, busy
        /// "I'm about to talk to you" and "I can't listen right now".
        case talk, talkBusy
    }
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
    /// The "change my name" field is showing in the panel.
    @Published var isEditingName = false

    // Calls
    /// Set while I'm in the team room.
    @Published var call: CallState?
    /// Teammates who are in the team room right now (known even when I'm not in it).
    @Published var roomMembers: Set<UUID> = []
    /// A short neutral message such as "Maya declined".
    @Published var notice: String?
    @Published var doNotDisturb = false
    @Published var isMuted = false
    @Published var isSharingScreen = false
    /// Teammates whose screen I can currently watch.
    @Published var sharingTeammates: Set<UUID> = []
    /// Drawing on my own shared screen is switched on.
    @Published var isDrawingOnOwnScreen = false

    // Walkie-talkie
    /// The teammate I'm holding the talk button for.
    @Published var talkingTo: UUID?
    /// The teammate I have an open walkie-talkie line with.
    @Published var walkiePeer: UUID?
    /// The line is connected and the other side is listening.
    @Published var walkieReady = false
    /// Who is audibly speaking right now.
    @Published var speaking: Set<UUID> = []


    private let client: SupabaseClient?
    private var teamID: UUID?
    private var onlineIDs: Set<UUID> = []
    private var presenceChannel: RealtimeChannelV2?
    private var presenceTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private let engine = CallEngine()
    /// A second, separate audio line used only for walkie-talkie.
    private let walkie = CallEngine()
    private var walkieIdle: Task<Void, Never>?
    private var talkLimit: Task<Void, Never>?

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
        }
        engine.onRemoteSharesChanged = { [weak self] ids in self?.sharingTeammates = ids }
        engine.onLocalShareStopped = { [weak self] in
            self?.isSharingScreen = false
            self?.isDrawingOnOwnScreen = false
        }
        engine.onDrawModeExited = { [weak self] in self?.isDrawingOnOwnScreen = false }
        engine.onSpeakersChanged = { [weak self] ids in self?.speaking = ids }
        engine.colorForUser = { [weak self] id in
            guard let self else { return .systemPink }
            let person = self.me?.id == id ? self.me : self.teammates.first { $0.id == id }
            return NSColor(person?.color ?? .pink)
        }
        engine.nameForUser = { [weak self] id in
            guard let self else { return "Teammate" }
            if self.me?.id == id { return self.me?.name ?? "Me" }
            return self.teammates.first { $0.id == id }?.name ?? "Teammate"
        }

        walkie.onParticipantsChanged = { [weak self] ids in self?.walkieParticipantsChanged(ids) }
        walkie.onSpeakersChanged = { [weak self] ids in self?.speaking = ids }
        walkie.onDisconnected = { [weak self] in
            guard let self else { return }
            self.walkiePeer = nil
            self.walkieReady = false
            self.talkingTo = nil
            self.speaking = []
        }
        engine.onDisconnected = { [weak self] in
            guard let self, self.call != nil else { return }
            self.call = nil
            self.isMuted = false
            self.notice = "You were disconnected from the team room."
            Task { await self.updatePresence() }
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
                    await self.joinAsTestTeammateIfNeeded()
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

    /// In test-teammate mode, join (or move to) the team whose code was passed at launch.
    private func joinAsTestTeammateIfNeeded() async {
        guard TestTeammate.isActive, let code = TestTeammate.joinCode else { return }
        if phase == .inTeam, teamCode == code { return }
        await joinTeam(name: TestTeammate.name, code: code)
    }

    /// Opens a second copy of the app as "Test Buddy" on this Mac.
    func openTestTeammate() {
        guard let teamCode else { return }
        let copies = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        if copies.count > 1 {
            notice = "The test teammate is already running (look for ✦T in the menu bar)."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = ["--dummy", "--join", teamCode]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        notice = "Starting the test teammate…"
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
        leaveRoom()
        await closeWalkie()
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
                    joined: joined.compactMap { state in
                        UUID(uuidString: state.userID).map { ($0, state.inRoom ?? false) }
                    },
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
            try await channel.track(PresenceState(userID: userID.uuidString.lowercased(), inRoom: false))
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
        roomMembers = []
    }

    /// Tells the team whether I'm in the team room, so they see it without being in it.
    private func updatePresence() async {
        guard let channel = presenceChannel, let me else { return }
        let inRoom = call != nil && call?.isConnecting == false
        try? await channel.track(PresenceState(userID: me.id.uuidString.lowercased(), inRoom: inRoom))
    }

    private func applyPresence(joined: [(id: UUID, inRoom: Bool)], left: [UUID]) async {
        // An update arrives as "left" (old state) plus "joined" (new state) for the same person.
        onlineIDs.subtract(left)
        roomMembers.subtract(left)
        onlineIDs.formUnion(joined.map(\.id))
        roomMembers.formUnion(joined.filter(\.inRoom).map(\.id))
        if let myID = me?.id { roomMembers.remove(myID) }

        // Someone we don't know yet came online: a new teammate just joined.
        let known = Set(teammates.map(\.id)).union([me?.id].compactMap { $0 })
        if !Set(joined.map(\.id)).isSubset(of: known) {
            await reloadTeam()
        }
        for index in teammates.indices {
            teammates[index].isOnline = onlineIDs.contains(teammates[index].id)
        }

        // The test teammate follows people in and out of the room by itself.
        if TestTeammate.isActive {
            if call == nil, !roomMembers.isEmpty {
                joinRoom()
            } else if call?.isConnecting == false, roomMembers.isEmpty {
                leaveRoom()
            }
        }
    }

    // MARK: Team room
    //
    // One always-open voice room per team, like a voice channel. Nobody rings anybody:
    // you join, teammates see that you're inside, and they drop in when they want.

    /// SF Symbol for the menu bar while something is happening; nil means show the ✦✦ mark.
    /// Being in the room deliberately keeps the ✦✦ mark.
    var menuBarSymbol: String? {
        if talkingTo != nil { return "dot.radiowaves.left.and.right" }
        // Someone is talking to me over the walkie-talkie.
        if let walkiePeer, speaking.contains(walkiePeer) { return "dot.radiowaves.left.and.right" }
        return doNotDisturb ? "moon.fill" : nil
    }

    var sortedTeammates: [Teammate] {
        teammates.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var isInRoom: Bool { call != nil }

    /// Whether a teammate is in the team room (heard directly once I'm connected, otherwise from presence).
    func isInRoom(_ teammate: Teammate) -> Bool {
        if let call, !call.isConnecting { return call.connected.contains(teammate.id) }
        return roomMembers.contains(teammate.id)
    }

    /// Teammates currently in the room, not counting me.
    var roomTeammates: [Teammate] {
        teammates.filter { isInRoom($0) }
    }

    func joinRoom() {
        guard call == nil, let teamID else { return }
        notice = nil
        errorMessage = nil
        let room = "\(teamID.uuidString.lowercased()):room"
        call = CallState(room: room)
        Task {
            await closeWalkie()
            guard await joinAudio(room: room) else { return }
            // Two copies on one Mac share a microphone and speakers; muting one avoids a feedback howl.
            if TestTeammate.isActive, !isMuted { toggleMute() }
            await updatePresence()
        }
    }

    /// Gets a pass from the server and connects the microphone. False if it failed
    /// or I left while connecting.
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
            errorMessage = "Couldn't join the room: \(friendlyMessage(error))"
            return false
        }
        guard call?.room == room else {
            // Left while we were connecting.
            await engine.disconnect()
            return false
        }
        call?.isConnecting = false
        return true
    }

    func leaveRoom() {
        guard call != nil else { return }
        call = nil
        isMuted = false
        isSharingScreen = false
        Task {
            await engine.disconnect()
            await updatePresence()
        }
    }

    func toggleMute() {
        isMuted.toggle()
        let muted = isMuted
        Task { await engine.setMuted(muted) }
    }

    // MARK: Screen sharing

    var hasScreenRecordingPermission: Bool { CallEngine.hasScreenRecordingPermission }

    func requestScreenRecordingPermission() {
        CallEngine.requestScreenRecordingPermission()
    }

    /// Quits and reopens the app. macOS only applies a newly granted Screen Recording
    /// permission at launch, so this saves a trip to the gear menu and Finder.
    func restartApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = Array(CommandLine.arguments.dropFirst())
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func shareSources() async -> [ShareSource] {
        await engine.shareSources()
    }

    func startSharing(_ source: ShareSource) {
        guard call != nil else { return }
        errorMessage = nil
        Task {
            do {
                try await engine.startSharing(source)
                isSharingScreen = true
            } catch {
                isSharingScreen = false
                errorMessage = "Couldn't share the screen: \(friendlyMessage(error))"
            }
        }
    }

    func stopSharing() {
        Task { await engine.stopSharing() }
    }

    /// Lets me draw on my own shared screen; Esc or the same button switches it off.
    func toggleDrawMode() {
        guard isSharingScreen else { return }
        isDrawingOnOwnScreen.toggle()
        engine.setDrawMode(isDrawingOnOwnScreen)
    }

    /// Clears everyone's drawings on my shared screen.
    func clearDrawings() {
        engine.clearMyBoard()
    }

    /// Reopens a teammate's shared screen if its window was closed.
    func showSharedScreen(of teammate: Teammate) {
        engine.showViewer(for: teammate.id)
    }

    // MARK: Signals

    private func receive(_ signal: CallSignal) async {
        guard signal.to == me?.id else { return }
        let name = teammates.first { $0.id == signal.from }?.name ?? signal.name

        switch signal.kind {
        case .talk:
            // Walkie-talkie: open the line and play their voice straight away.
            let busyWithSomeoneElse = walkiePeer != nil && walkiePeer != signal.from && talkingTo != nil
            if doNotDisturb || call != nil || busyWithSomeoneElse {
                await send(.talkBusy, to: signal.from, room: signal.room)
                return
            }
            notice = nil
            await openWalkie(with: signal.from)
            scheduleWalkieIdle()

        case .talkBusy:
            guard walkiePeer == signal.from else { return }
            await closeWalkie()
            notice = "\(name) can't listen right now."

        case .ring, .cancel, .decline, .busy:
            // From an older build that still rings; this build has the open room instead.
            break
        }
    }

    private func send(_ kind: CallSignal.Kind, to id: UUID, room: String) async {
        guard let me, let channel = presenceChannel else { return }
        let signal = CallSignal(kind: kind, from: me.id, to: id, room: room, name: me.name)
        try? await channel.broadcast(event: "call", message: signal)
    }

    // MARK: Walkie-talkie
    //
    // Click to talk, click again to stop: the first click opens a private audio line to that
    // teammate (about a second), a short chirp says they can hear you, and the line stays
    // open for a while so replies are instant. Nobody has to accept anything.

    /// The private line's room name; both sides derive the same one.
    private func walkieRoom(with peer: UUID) -> String? {
        guard let teamID, let me else { return nil }
        let pair = [me.id.uuidString.lowercased(), peer.uuidString.lowercased()].sorted()
        return "\(teamID.uuidString.lowercased()):talk:\(pair[0])-\(pair[1])"
    }

    /// Click to start talking to a teammate, click again to stop.
    func toggleTalking(to teammate: Teammate) {
        if talkingTo == teammate.id {
            setTalking(false, to: teammate)
        } else {
            stopTalking()
            setTalking(true, to: teammate)
        }
    }

    private func setTalking(_ talking: Bool, to teammate: Teammate) {
        if talking {
            guard teammate.isOnline, call == nil, talkingTo == nil else { return }
            guard let room = walkieRoom(with: teammate.id) else { return }
            talkingTo = teammate.id
            notice = nil
            errorMessage = nil
            // The microphone stays on until the second click, so cap it in case it's forgotten.
            talkLimit?.cancel()
            talkLimit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard let self, !Task.isCancelled, self.talkingTo == teammate.id else { return }
                self.setTalking(false, to: teammate)
                self.notice = "Walkie-talkie switched off after 3 minutes."
            }
            Task {
                guard await CallEngine.requestMicrophone() else {
                    talkingTo = nil
                    errorMessage = "Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone."
                    return
                }
                // Each press also tells the other side to open (or keep open) the line.
                await send(.talk, to: teammate.id, room: room)
                await openWalkie(with: teammate.id)
                if talkingTo == teammate.id, walkieReady {
                    await startTransmitting()
                }
            }
        } else {
            guard talkingTo == teammate.id else { return }
            talkingTo = nil
            talkLimit?.cancel()
            talkLimit = nil
            Task { await walkie.setMuted(true) }
            scheduleWalkieIdle()
        }
    }

    /// Stops talking to whoever the walkie-talkie is on for.
    func stopTalking() {
        guard let id = talkingTo, let teammate = teammates.first(where: { $0.id == id }) else { return }
        setTalking(false, to: teammate)
    }

    private func openWalkie(with peer: UUID) async {
        if walkiePeer == peer, walkie.isConnected { return }
        if walkiePeer != nil, walkiePeer != peer { await closeWalkie(keepTalking: true) }
        guard let client, let room = walkieRoom(with: peer) else { return }
        walkiePeer = peer
        walkieReady = false
        do {
            let pass: CallPass = try await client.functions.invoke(
                "livekit-token", options: .init(body: ["room": room])
            )
            // Still wanted? (The press may have ended and the line been closed meanwhile.)
            guard walkiePeer == peer else { return }
            try await walkie.connect(url: pass.url, token: pass.token, microphone: false)
        } catch {
            await closeWalkie()
            errorMessage = "Couldn't open the walkie-talkie: \(friendlyMessage(error))"
        }
    }

    private func walkieParticipantsChanged(_ ids: Set<UUID>) {
        guard let peer = walkiePeer else { return }
        let ready = ids.contains(peer)
        if ready, !walkieReady {
            walkieReady = true
            if talkingTo == peer {
                Task { await startTransmitting() }
            }
        } else if !ready, walkieReady {
            // The other side closed the line.
            Task { await closeWalkie() }
        }
    }

    private func startTransmitting() async {
        // The chirp means "they can hear you now".
        NSSound(named: "Tink")?.play()
        await walkie.setMuted(false)
        // Released during the chirp: don't leave the microphone open.
        if talkingTo == nil { await walkie.setMuted(true) }
    }

    /// Closes the line after a quiet spell.
    private func scheduleWalkieIdle() {
        walkieIdle?.cancel()
        walkieIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, !Task.isCancelled else { return }
            if self.talkingTo == nil, self.speaking.isEmpty {
                await self.closeWalkie()
            } else {
                self.scheduleWalkieIdle()
            }
        }
    }

    private func closeWalkie(keepTalking: Bool = false) async {
        walkieIdle?.cancel()
        walkieIdle = nil
        guard walkiePeer != nil || walkie.isConnected else { return }
        walkiePeer = nil
        walkieReady = false
        if !keepTalking { talkingTo = nil }
        speaking = []
        await walkie.disconnect()
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
