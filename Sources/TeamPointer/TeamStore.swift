import SwiftUI
import Supabase

/// The team's voice rooms. Everyone sees who is in which; joining needs no ringing.
enum Rooms {
    static let numbers = [1, 2, 3]
    static func name(_ number: Int) -> String { "Room \(number)" }
}

/// My connection to one room. `connected` never includes me.
struct CallState: Equatable {
    var room: String
    var number: Int
    var connected: Set<UUID> = []
    /// Still joining the audio room.
    var isConnecting = true
}

/// A teammate is ringing me: into their room, or just to get my attention.
struct IncomingRing: Equatable {
    let from: UUID
    let fromName: String
    /// The room they want me in; nil when they only want my attention.
    let roomNumber: Int?
}

/// Sent between teammates over the team channel. Kinds this build doesn't know
/// (from older builds) fail to decode and are skipped.
struct CallSignal: Codable {
    enum Kind: String, Codable {
        /// "Come here" (with a room number) or "look at me" (without).
        case ring
        /// Replies to a ring: "seen / not now" and "on Do Not Disturb".
        case decline, busy
    }
    let kind: Kind
    let from: UUID
    let to: UUID
    let room: String
    let name: String
    var roomNumber: Int?
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

    // Rooms
    /// Set while I'm in a room.
    @Published var call: CallState?
    /// Which room each teammate is in, from presence (known even when I'm in none).
    @Published var roomMembers: [UUID: Int] = [:]
    /// Teammates I've rung who haven't arrived or answered yet.
    @Published var ringingTeammates: Set<UUID> = []
    /// Someone is ringing me.
    @Published var incomingRing: IncomingRing?
    /// Lets the app delegate open the panel when someone rings me.
    var onRing: (() -> Void)?
    /// A short neutral message such as "Maya can't join right now."
    @Published var notice: String?
    @Published var doNotDisturb = false
    @Published var isMuted = false
    @Published var isSharingScreen = false
    /// Teammates whose screen I can currently watch.
    @Published var sharingTeammates: Set<UUID> = []
    /// Drawing on my own shared screen is switched on.
    @Published var isDrawingOnOwnScreen = false
    /// Who is audibly speaking in my room right now.
    @Published var speaking: Set<UUID> = []

    private let client: SupabaseClient?
    private var teamID: UUID?
    private var onlineIDs: Set<UUID> = []
    private var presenceChannel: RealtimeChannelV2?
    private var presenceTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private let engine = CallEngine()

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
            self.ringingTeammates.subtract(ids)
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

        engine.onDisconnected = { [weak self] in
            guard let self, self.call != nil else { return }
            self.call = nil
            self.isMuted = false
            self.notice = "You were disconnected from the room."
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
        incomingRing = nil
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
                        UUID(uuidString: state.userID).map { ($0, state.room) }
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
            try await channel.track(PresenceState(userID: userID.uuidString.lowercased(), room: nil))
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
        roomMembers = [:]
    }

    /// Tells the team which room I'm in, so they see it without being in it.
    private func updatePresence() async {
        guard let channel = presenceChannel, let me else { return }
        let room = call?.isConnecting == false ? call?.number : nil
        try? await channel.track(PresenceState(userID: me.id.uuidString.lowercased(), room: room))
    }

    private func applyPresence(joined: [(id: UUID, room: Int?)], left: [UUID]) async {
        // An update arrives as "left" (old state) plus "joined" (new state) for the same person.
        onlineIDs.subtract(left)
        for id in left { roomMembers[id] = nil }
        onlineIDs.formUnion(joined.map(\.id))
        for entry in joined {
            if let room = entry.room, Rooms.numbers.contains(room) { roomMembers[entry.id] = room }
        }
        if let myID = me?.id { roomMembers[myID] = nil }
        if let mine = call?.number {
            ringingTeammates = ringingTeammates.filter { roomMembers[$0] != mine }
        }
        // Whoever rang me into their room has left it or gone offline.
        if let ring = incomingRing, let number = ring.roomNumber, roomMembers[ring.from] != number {
            incomingRing = nil
        }

        // Someone we don't know yet came online: a new teammate just joined.
        let known = Set(teammates.map(\.id)).union([me?.id].compactMap { $0 })
        if !Set(joined.map(\.id)).isSubset(of: known) {
            await reloadTeam()
        }
        for index in teammates.indices {
            teammates[index].isOnline = onlineIDs.contains(teammates[index].id)
        }

        // The test teammate follows people into whichever room is busy, and leaves when alone.
        if TestTeammate.isActive {
            let busy = Rooms.numbers.first { number in roomMembers.values.contains(number) }
            if call == nil, let busy {
                joinRoom(busy)
            } else if let mine = call?.number, call?.isConnecting == false,
                      !roomMembers.values.contains(mine)
            {
                leaveRoom()
            }
        }
    }

    // MARK: Rooms
    //
    // Three always-open voice rooms, like voice channels. You join one, teammates see
    // where you are, and they drop in when they want. Ringing only gets attention.

    var sortedTeammates: [Teammate] {
        teammates.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var isInRoom: Bool { call != nil }

    /// The room a teammate is in: heard directly when they're in mine, otherwise from presence.
    func room(of teammate: Teammate) -> Int? {
        if let call, !call.isConnecting, call.connected.contains(teammate.id) { return call.number }
        return roomMembers[teammate.id]
    }

    func isInMyRoom(_ teammate: Teammate) -> Bool {
        call != nil && room(of: teammate) == call?.number
    }

    /// Teammates in a room, not counting me.
    func teammates(in number: Int) -> [Teammate] {
        teammates.filter { room(of: $0) == number }
    }

    /// Joins a room, leaving the one I'm in first.
    func joinRoom(_ number: Int) {
        guard let teamID, Rooms.numbers.contains(number), call?.number != number else { return }
        let switching = call != nil
        if incomingRing?.roomNumber == number { incomingRing = nil }
        notice = nil
        errorMessage = nil
        ringingTeammates = []
        isSharingScreen = false
        isDrawingOnOwnScreen = false
        let room = "\(teamID.uuidString.lowercased()):room\(number)"
        call = CallState(room: room, number: number)
        Task {
            if switching { await engine.disconnect() }
            guard await joinAudio(room: room) else { return }
            // Two copies on one Mac share a microphone and speakers; muting one avoids a feedback howl.
            if TestTeammate.isActive, !isMuted { toggleMute() }
            if !TestTeammate.isActive, isMuted { await engine.setMuted(true) }
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
            guard call?.room == room else { return false }
            try await engine.connect(url: pass.url, token: pass.token)
        } catch {
            await engine.disconnect()
            if call?.room == room { call = nil }
            errorMessage = "Couldn't join the room: \(friendlyMessage(error))"
            return false
        }
        guard call?.room == room else {
            // Left or switched rooms while we were connecting.
            return false
        }
        call?.isConnecting = false
        return true
    }

    func leaveRoom() {
        guard call != nil else { return }
        call = nil
        ringingTeammates = []
        isMuted = false
        isSharingScreen = false
        isDrawingOnOwnScreen = false
        Task {
            await engine.disconnect()
            await updatePresence()
        }
    }

    // MARK: Ringing

    /// Rings a teammate: into my room if I'm in one, otherwise just to get their attention.
    func ring(_ teammate: Teammate) {
        guard teammate.isOnline, !isInMyRoom(teammate), !ringingTeammates.contains(teammate.id),
              let teamID
        else { return }
        ringingTeammates.insert(teammate.id)
        notice = nil
        let number = call?.number
        let room = number.map { "\(teamID.uuidString.lowercased()):room\($0)" } ?? ""
        Task {
            await send(.ring, to: teammate.id, room: room, roomNumber: number)
            try? await Task.sleep(for: .seconds(30))
            guard ringingTeammates.contains(teammate.id) else { return }
            ringingTeammates.remove(teammate.id)
            notice = number == nil ? "\(teammate.name) didn't respond." : "\(teammate.name) didn't join."
        }
    }

    /// Join the room I was rung into.
    func acceptRing() {
        guard let ring = incomingRing else { return }
        incomingRing = nil
        if let number = ring.roomNumber { joinRoom(number) }
    }

    /// "Not now" for a room ring, "OK" for an attention ring. Either way the ringer is told.
    func dismissRing() {
        guard let ring = incomingRing else { return }
        incomingRing = nil
        Task { await send(.decline, to: ring.from, room: "", roomNumber: ring.roomNumber) }
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
        case .ring:
            let number = signal.roomNumber.flatMap { Rooms.numbers.contains($0) ? $0 : nil }
            // Already in the room they want me in.
            if let number, call?.number == number { return }
            if doNotDisturb {
                await send(.busy, to: signal.from, room: "", roomNumber: number)
                return
            }
            if TestTeammate.isActive {
                if let number {
                    joinRoom(number)
                } else {
                    await send(.decline, to: signal.from, room: "", roomNumber: nil)
                }
                return
            }
            incomingRing = IncomingRing(from: signal.from, fromName: name, roomNumber: number)
            playRingSound()
            onRing?()
            // Clear the ring by itself if it's ignored.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard let self, self.incomingRing?.from == signal.from else { return }
                self.incomingRing = nil
            }

        case .decline, .busy:
            guard ringingTeammates.contains(signal.from) else { return }
            ringingTeammates.remove(signal.from)
            if signal.kind == .busy {
                notice = "\(name) is on Do Not Disturb."
            } else {
                notice = signal.roomNumber == nil ? "\(name) saw your ring." : "\(name) can't join right now."
            }
        }
    }

    private func send(_ kind: CallSignal.Kind, to id: UUID, room: String, roomNumber: Int?) async {
        guard let me, let channel = presenceChannel else { return }
        let signal = CallSignal(kind: kind, from: me.id, to: id, room: room, name: me.name, roomNumber: roomNumber)
        try? await channel.broadcast(event: "call", message: signal)
    }

    /// Two short chimes: enough to notice, not a ringing phone.
    private func playRingSound() {
        NSSound(named: "Glass")?.play()
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            NSSound(named: "Glass")?.play()
        }
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
