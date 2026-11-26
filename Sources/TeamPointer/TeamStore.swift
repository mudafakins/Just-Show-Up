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

/// A teammate is calling me to a room.
struct IncomingRing: Equatable {
    let from: UUID
    let fromName: String
    let roomNumber: Int
    /// Identifies this call, so the caller's repeats don't ring twice (nil from older builds).
    var callID: String?
}

/// Sent between teammates over the team channel. Kinds this build doesn't know
/// (from older builds) fail to decode and are skipped.
struct CallSignal: Codable {
    enum Kind: String, Codable {
        /// "Come to this room" (with a room number).
        case ring
        /// The caller stopped calling.
        case cancel
        /// Replies to a call: declined, and "on Do Not Disturb".
        case decline, busy
        /// "Your call reached me and I'm ringing" (sent for every ring, repeats too).
        case ringing
    }
    let kind: Kind
    let from: UUID
    let to: UUID
    let room: String
    let name: String
    var roomNumber: Int?
    /// One id per call. The caller repeats the ring until it hears "ringing", so a
    /// message lost on a stale connection doesn't leave the other side silent.
    var callID: String?
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
    /// The ringtone list is showing in place of the rooms and teammates.
    @Published var isChoosingRingtone = false
    /// The soundboard grid is open.
    @Published var isShowingSoundboard = false

    // Rooms
    /// Set while I'm in a room.
    @Published var call: CallState?
    /// When I last finished joining a room (for the teammate chimes).
    private var joinedAt = Date.distantPast
    /// Which room each teammate is in, from presence (known even when I'm in none).
    @Published var roomMembers: [UUID: Int] = [:]
    /// Teammates I'm calling, and the room I'm calling each of them to.
    @Published var ringingTeammates: [UUID: Int] = [:]
    /// Someone is calling me.
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
    /// Every live connection each person has on the team channel (by its server
    /// reference), with the room it reports. Someone who reconnects briefly has two;
    /// when the old one times out they must stay online.
    private var connections: [UUID: [String: Int?]] = [:]
    private var presenceChannel: RealtimeChannelV2?
    private var presenceTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    /// The call id of each call I'm making, by teammate.
    private var outgoingCalls: [UUID: String] = [:]
    /// My calls whose ring reached the other side.
    private var acknowledgedCalls: Set<String> = []
    /// Calls to me that are over (answered, declined, cancelled, missed): a late
    /// repeat of their ring must not ring again.
    private var endedCalls: Set<String> = []
    /// Waits to see whether the person calling me is really gone, not just reconnecting.
    private var callerGoneCheck: Task<Void, Never>?
    private let engine = CallEngine()

    init() {
        guard let config = AppConfig.load() else {
            client = nil
            phase = .needsConfig
            return
        }
        let client = makeSupabaseClient(config)
        self.client = client

        engine.onSoundboard = { id in
            if id == "stop" { return Soundboard.stop() }
            // Each person can silence these with Settings → Sounds.
            if Sounds.isEnabled { Soundboard.play(id) }
        }
        engine.onParticipantsChanged = { [weak self] ids in
            guard let self, let call = self.call else { return }
            // Chime when someone joins or leaves my room (not for the people
            // already there when I arrive).
            if !call.isConnecting, Date().timeIntervalSince(self.joinedAt) > 1.5 {
                if !ids.subtracting(call.connected).isEmpty {
                    Sounds.play(.teammateJoined)
                } else if !call.connected.subtracting(ids).isEmpty {
                    Sounds.play(.teammateLeft)
                }
            }
            self.call?.connected = ids
            for id in ids { self.ringingTeammates[id] = nil }
            self.refreshOnline()
        }
        engine.onRemoteSharesChanged = { [weak self] ids in
            guard let self else { return }
            // Chime when a teammate in my room starts or stops sharing (not for a
            // share that was already on when I joined).
            if self.call != nil, Date().timeIntervalSince(self.joinedAt) > 1.5 {
                if !ids.subtracting(self.sharingTeammates).isEmpty {
                    Sounds.play(.teammateShareStarted)
                } else if !self.sharingTeammates.subtracting(ids).isEmpty {
                    Sounds.play(.teammateShareStopped)
                }
            }
            self.sharingTeammates = ids
        }
        engine.onLocalShareStopped = { [weak self] in
            if self?.isSharingScreen == true, self?.call != nil { Sounds.play(.shareStopped) }
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
            Sounds.play(.leave)
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
        leaveRoom()
        stopIncomingRing()
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
                .map { Teammate($0, isOnline: isLive($0.id)) }
            phase = .inTeam
        } catch {
            errorMessage = friendlyMessage(error)
            if phase == .loading { phase = .welcome }
        }
    }

    func rename(to name: String) async {
        await run { try await $0.rpc("set_my_name", params: ["new_name": name]).execute() }
    }

    // MARK: Profile photo

    /// Lets me pick a photo, shrinks it to a 256-pixel square and uploads it.
    func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Profile Photo"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url), let jpeg = Self.avatarJPEG(from: image) else {
            errorMessage = "That file isn't a photo the app can read."
            return
        }
        Task { await uploadPhoto(jpeg) }
    }

    private func uploadPhoto(_ jpeg: Data) async {
        guard let client, let me else { return }
        let old = me.avatarPath
        let path = "\(me.id.uuidString.lowercased())/\(Int(Date().timeIntervalSince1970)).jpg"
        await run {
            try await $0.storage.from("avatars").upload(
                path, data: jpeg,
                options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: true)
            )
            try await $0.rpc("set_my_avatar", params: ["path": path]).execute()
        }
        if errorMessage == nil, let old { _ = try? await client.storage.from("avatars").remove(paths: [old]) }
    }

    func removePhoto() async {
        guard let client, let old = me?.avatarPath else { return }
        await run { try await $0.rpc("set_my_avatar", params: ["path": AnyJSON.null]).execute() }
        if errorMessage == nil { _ = try? await client.storage.from("avatars").remove(paths: [old]) }
    }

    /// The middle square of the image, 256x256, as a JPEG.
    static func avatarJPEG(from image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let square = cg.cropping(to: crop) else { return nil }
        let size = 256
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
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
                await self?.applyPresence(change.rawMessage)
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
        connections = [:]
        roomMembers = [:]
    }

    /// Tells the team which room I'm in, so they see it without being in it.
    private func updatePresence() async {
        guard let channel = presenceChannel, let me else { return }
        let room = call?.isConnecting == false ? call?.number : nil
        try? await channel.track(PresenceState(userID: me.id.uuidString.lowercased(), room: room))
    }

    /// Reads the server's presence messages directly: the SDK's summary keeps only one
    /// connection per person, which marked people offline when a stale connection of
    /// theirs timed out while their current one was fine.
    private func applyPresence(_ message: RealtimeMessageV2) async {
        func entries(_ json: JSONObject?) -> [(id: UUID, ref: String, room: Int?)] {
            var found: [(UUID, String, Int?)] = []
            for value in (json ?? [:]).values {
                for meta in value.objectValue?["metas"]?.arrayValue ?? [] {
                    guard let meta = meta.objectValue,
                          let ref = meta["phx_ref"]?.stringValue,
                          let id = meta["user_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                    else { continue }
                    let room = meta["room"]?.intValue ?? meta["room"]?.doubleValue.map { Int($0) }
                    found.append((id, ref, room))
                }
            }
            return found
        }

        let joined: [(id: UUID, ref: String, room: Int?)]
        if message.event == "presence_state" {
            // The full list, sent when (re)joining the channel.
            connections = [:]
            joined = entries(message.payload)
        } else {
            for entry in entries(message.payload["leaves"]?.objectValue) {
                connections[entry.id]?[entry.ref] = nil
                if connections[entry.id]?.isEmpty == true { connections[entry.id] = nil }
            }
            joined = entries(message.payload["joins"]?.objectValue)
        }
        for entry in joined {
            connections[entry.id, default: [:]][entry.ref] = .some(entry.room)
        }

        onlineIDs = Set(connections.keys)
        var rooms: [UUID: Int] = [:]
        for (id, refs) in connections {
            // If any of their connections says it is in a room, show them there.
            if let room = refs.sorted(by: { $0.key < $1.key }).compactMap({ $0.value }).last,
               Rooms.numbers.contains(room) {
                rooms[id] = room
            }
        }
        if let myID = me?.id { rooms[myID] = nil }
        roomMembers = rooms
        // Someone I'm calling arrived in the room I called them to.
        ringingTeammates = ringingTeammates.filter { roomMembers[$0.key] != $0.value }
        // Whoever is calling me went offline.
        // Only once they've been gone a few seconds: calling me moves them into a room,
        // which briefly swaps their connection and must not silence my ring.
        if let ring = incomingRing, !onlineIDs.contains(ring.from), callerGoneCheck == nil {
            callerGoneCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.callerGoneCheck = nil
                if self.incomingRing == ring, !self.onlineIDs.contains(ring.from) {
                    self.stopIncomingRing()
                }
            }
        }

        // Someone we don't know yet came online: a new teammate just joined.
        let known = Set(teammates.map(\.id)).union([me?.id].compactMap { $0 })
        if !Set(joined.map(\.id)).isSubset(of: known) {
            await reloadTeam()
        }
        refreshOnline()
    }

    /// Online means on the team channel, or (whatever the channel says) right here in
    /// my room: someone talking to me is plainly online.
    private func isLive(_ id: UUID) -> Bool {
        onlineIDs.contains(id) || (call?.connected.contains(id) ?? false)
    }

    private func refreshOnline() {
        for index in teammates.indices {
            let live = isLive(teammates[index].id)
            if teammates[index].isOnline != live { teammates[index].isOnline = live }
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
        if incomingRing != nil { stopIncomingRing() }
        notice = nil
        errorMessage = nil
        // Moving rooms ends any calls I was making to the old one.
        cancelAllCalls()
        isSharingScreen = false
        isDrawingOnOwnScreen = false
        let room = "\(teamID.uuidString.lowercased()):room\(number)"
        call = CallState(room: room, number: number)
        Task {
            if switching { await engine.disconnect() }
            guard await joinAudio(room: room) else { return }
            // Keep my mute setting when moving between rooms.
            if isMuted { await engine.setMuted(true) }
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
        joinedAt = Date()
        Sounds.play(.join)
        return true
    }

    func leaveRoom() {
        guard call != nil else { return }
        call = nil
        Sounds.play(.leave)
        cancelAllCalls()
        isMuted = false
        isSharingScreen = false
        isDrawingOnOwnScreen = false
        Task {
            await engine.disconnect()
            await updatePresence()
        }
    }

    // MARK: Calling a teammate to a room
    //
    // Pick a room from the bell menu: I go to that room and their Mac rings like a phone
    // until they accept, decline, I stop calling, or 30 seconds pass.

    /// Calls a teammate to a room, moving me there first if I'm elsewhere.
    ///
    /// The ring is repeated every few seconds until their app says it's ringing: a
    /// single message can be lost on a connection that went stale (after sleep or a
    /// network change) while I'd still be shown as calling. With no answer at all
    /// in 8 seconds I stop and say they couldn't be reached.
    func ring(_ teammate: Teammate, to number: Int) {
        guard teammate.isOnline, Rooms.numbers.contains(number), room(of: teammate) != number else { return }
        if call?.number != number { joinRoom(number) }
        let callID = UUID().uuidString
        ringingTeammates[teammate.id] = number
        outgoingCalls[teammate.id] = callID
        notice = nil
        Task {
            let started = Date()
            var lastSent = Date.distantPast
            while ringingTeammates[teammate.id] == number, outgoingCalls[teammate.id] == callID {
                let elapsed = Date().timeIntervalSince(started)
                let reached = acknowledgedCalls.contains(callID)
                if elapsed >= Self.unansweredAfter || (!reached && elapsed >= Self.unreachedAfter) {
                    ringingTeammates[teammate.id] = nil
                    endOutgoingCall(to: teammate.id, callID: callID)
                    await send(.cancel, to: teammate.id, roomNumber: number, callID: callID)
                    notice = reached
                        ? "\(teammate.name) didn't answer."
                        : "Couldn't reach \(teammate.name). They may be offline or asleep."
                    return
                }
                if !reached, Date().timeIntervalSince(lastSent) >= Self.ringRepeat {
                    lastSent = Date()
                    await send(.ring, to: teammate.id, roomNumber: number, callID: callID)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            endOutgoingCall(to: teammate.id, callID: callID)
        }
    }

    static let ringRepeat: TimeInterval = 3
    static let unreachedAfter: TimeInterval = 8
    static let unansweredAfter: TimeInterval = 30

    private func endOutgoingCall(to id: UUID, callID: String) {
        if outgoingCalls[id] == callID { outgoingCalls[id] = nil }
        acknowledgedCalls.remove(callID)
    }

    /// Stops calling a teammate; their phone stops ringing.
    func stopCalling(_ teammate: Teammate) {
        guard let number = ringingTeammates.removeValue(forKey: teammate.id) else { return }
        let callID = outgoingCalls.removeValue(forKey: teammate.id)
        Task { await send(.cancel, to: teammate.id, roomNumber: number, callID: callID) }
    }

    private func cancelAllCalls() {
        let calls = ringingTeammates
        let ids = outgoingCalls
        ringingTeammates = [:]
        outgoingCalls = [:]
        Task {
            for (id, number) in calls { await send(.cancel, to: id, roomNumber: number, callID: ids[id]) }
        }
    }

    /// Accept: join the room I'm being called to.
    func acceptRing() {
        guard let ring = incomingRing else { return }
        stopIncomingRing()
        joinRoom(ring.roomNumber)
    }

    /// Decline: the caller is told.
    func declineRing() {
        guard let ring = incomingRing else { return }
        stopIncomingRing()
        Task { await send(.decline, to: ring.from, roomNumber: ring.roomNumber, callID: ring.callID) }
    }

    private func stopIncomingRing() {
        if let id = incomingRing?.callID { endedCalls.insert(id) }
        incomingRing = nil
        callerGoneCheck?.cancel()
        callerGoneCheck = nil
        Ringtone.stop()
    }

    /// Plays a soundboard clip here and, when I'm in a room, for everyone in it.
    func playSoundboard(_ id: String) {
        Soundboard.play(id)
        if call != nil { engine.sendSoundboard(id) }
    }

    /// Stops the soundboard clip here and, when I'm in a room, for everyone in it.
    func stopSoundboard() {
        Soundboard.stop()
        if call != nil { engine.sendSoundboard("stop") }
    }

    func toggleMute() {
        isMuted.toggle()
        let muted = isMuted
        Sounds.play(muted ? .muted : .unmuted)
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
                Sounds.play(.shareStarted)
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
            guard let number = signal.roomNumber, Rooms.numbers.contains(number) else { return }
            // Already in the room they're calling me to.
            if call?.number == number { return }
            // A late repeat of a call that's already over.
            if let id = signal.callID, endedCalls.contains(id) { return }
            if doNotDisturb {
                await send(.busy, to: signal.from, roomNumber: number, callID: signal.callID)
                return
            }
            // A repeat of the call that's ringing now: just say it's ringing.
            if let ring = incomingRing, ring.from == signal.from, ring.roomNumber == number,
               ring.callID == signal.callID {
                await send(.ringing, to: signal.from, roomNumber: number, callID: signal.callID)
                return
            }
            if let current = incomingRing?.callID { endedCalls.insert(current) }
            callerGoneCheck?.cancel()
            callerGoneCheck = nil
            let ring = IncomingRing(from: signal.from, fromName: name, roomNumber: number, callID: signal.callID)
            incomingRing = ring
            Ringtone.start()
            onRing?()
            await send(.ringing, to: signal.from, roomNumber: number, callID: signal.callID)
            // Stop by itself if the caller's cancel never arrives.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(40))
                guard let self, self.incomingRing == ring else { return }
                self.stopIncomingRing()
                self.notice = "Missed call from \(name)."
            }

        case .cancel:
            if let id = signal.callID { endedCalls.insert(id) }
            guard let ring = incomingRing, ring.from == signal.from,
                  signal.callID == nil || ring.callID == nil || ring.callID == signal.callID
            else { return }
            stopIncomingRing()
            notice = "Missed call from \(name)."

        case .ringing:
            guard let id = signal.callID, outgoingCalls[signal.from] == id else { return }
            acknowledgedCalls.insert(id)

        case .decline, .busy:
            guard ringingTeammates[signal.from] != nil else { return }
            if let id = signal.callID, let mine = outgoingCalls[signal.from], id != mine { return }
            ringingTeammates[signal.from] = nil
            outgoingCalls[signal.from] = nil
            notice = signal.kind == .busy ? "\(name) is on Do Not Disturb." : "\(name) declined."
        }
    }

    private func send(_ kind: CallSignal.Kind, to id: UUID, roomNumber: Int?, callID: String? = nil) async {
        guard let me, let channel = presenceChannel else { return }
        let signal = CallSignal(kind: kind, from: me.id, to: id, room: "", name: me.name,
                                roomNumber: roomNumber, callID: callID)
        try? await channel.broadcast(event: "call", message: signal)
    }
}

extension Teammate {
    init(_ row: ProfileRow, isOnline: Bool) {
        self.init(
            id: row.id,
            name: row.name.isEmpty ? "Teammate" : row.name,
            isOnline: isOnline,
            colorIndex: row.colorIndex,
            avatarPath: row.avatarPath
        )
    }
}

#if DEBUG
extension TeamStore {
    /// For RingSelfTest: the team channel's name.
    var debugTeamTopic: String? { teamID.map { "team:\($0.uuidString.lowercased())" } }
}
#endif
