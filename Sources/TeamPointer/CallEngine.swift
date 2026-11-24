import AppKit
import AVFoundation
import LiveKit
import SwiftUI

/// Something that can be shared: a whole display or one window.
struct ShareSource: Identifiable {
    let id: String
    let title: String
    let isDisplay: Bool
    /// Size in pixels to capture at.
    fileprivate let dimensions: Dimensions
    fileprivate let source: MacOSScreenCaptureSource
    /// Where the drawing overlay goes on my own screen.
    fileprivate let overlayTarget: SharerOverlay.Target
}

/// One LiveKit room: audio, screen sharing and drawing. No camera video.
/// TeamStore decides who is in the call; this carries the media.
@MainActor
final class CallEngine {
    /// Teammates currently connected to the room (by user id), not counting me.
    var onParticipantsChanged: ((Set<UUID>) -> Void)?
    /// The room dropped without us hanging up.
    var onDisconnected: (() -> Void)?
    /// Teammates currently sharing their screen with me.
    var onRemoteSharesChanged: ((Set<UUID>) -> Void)?
    /// My own share stopped (by me, or because the call ended).
    var onLocalShareStopped: (() -> Void)?
    /// Used for the viewer window's title and cursor labels.
    var nameForUser: (UUID) -> String = { _ in "Teammate" }
    /// Each person's ink and cursor colour.
    var colorForUser: (UUID) -> NSColor = { _ in .systemPink }
    /// Draw-on-my-own-screen mode was switched off with Esc.
    var onDrawModeExited: (() -> Void)?
    /// Who is audibly speaking right now (not counting me).
    var onSpeakersChanged: ((Set<UUID>) -> Void)?
    /// A teammate in the room played a soundboard clip (its ringtone id), or "stop".
    var onSoundboard: ((String) -> Void)?

    private var room: Room?
    private var relay: Relay?
    private var sharePublication: LocalTrackPublication?
    private var viewers: [UUID: ShareViewer] = [:]
    private var myID: UUID?
    /// One drawing board per shared screen, keyed by the sharer.
    private var boards: [UUID: InkBoard] = [:]
    private var overlay: SharerOverlay?
    private var infoTimer: Timer?

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Lets the shared screen's sound play through the call's audio engine (see SharedSound).
    private static let installPlayout: Void = {
        AudioManager.shared.set(engineObservers: [Playout.shared, AudioManager.shared.mixer])
    }()

    func connect(url: String, token: String) async throws {
        _ = Self.installPlayout
        let relay = Relay(engine: self)
        let room = Room(delegate: relay, roomOptions: RoomOptions(
            // Echo cancellation, noise suppression and automatic gain run through macOS's own
            // voice processing, which also lets each person pick Voice Isolation in Control Center.
            defaultAudioCaptureOptions: AudioCaptureOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true,
                highpassFilter: true
            ),
            // 48 kbps is double the SDK's speech default: noticeably clearer voice for little data.
            // `red` repeats audio packets so short network hiccups don't sound choppy;
            // `dtx` sends almost nothing during silence.
            defaultAudioPublishOptions: AudioPublishOptions(
                encoding: AudioEncoding(maxBitrate: 48_000),
                dtx: true,
                red: true
            )
        ))
        self.relay = relay
        self.room = room
        try await room.connect(url: url, token: token)
        myID = room.localParticipant.identity.flatMap { UUID(uuidString: $0.stringValue) }
        try await room.localParticipant.setMicrophone(enabled: true)
        reportParticipants()
    }


    /// Whether I'm muted. While I share my screen, my computer's sound travels in the
    /// microphone channel, so muting then turns down only my voice, not the channel.
    private var isMuted = false

    func setMuted(_ muted: Bool) async {
        isMuted = muted
        if sharePublication != nil {
            AudioManager.shared.mixer.micVolume = muted ? 0 : 1
            _ = try? await room?.localParticipant.setMicrophone(enabled: true)
        } else {
            AudioManager.shared.mixer.micVolume = 1
            _ = try? await room?.localParticipant.setMicrophone(enabled: !muted)
        }
    }

    func disconnect() async {
        let old = room
        room = nil
        // A new room starts unmuted (the panel re-applies mute if I joined muted).
        isMuted = false
        AudioManager.shared.mixer.micVolume = 1
        relay = nil
        cleanUpSharing()
        await old?.disconnect()
    }

    private func cleanUpSharing() {
        if #available(macOS 14.2, *) { SharedSound.shared.stop() }
        if sharePublication != nil {
            sharePublication = nil
            onLocalShareStopped?()
        }
        closeOverlay()
        viewers.values.forEach { $0.close() }
        viewers = [:]
        boards = [:]
        onRemoteSharesChanged?([])
    }

    private func closeOverlay() {
        infoTimer?.invalidate()
        infoTimer = nil
        overlay?.close()
        overlay = nil
        if let myID { boards[myID]?.reset() }
    }

    // MARK: Drawing

    private var people: InkPeople {
        InkPeople(me: myID ?? UUID(), color: colorForUser, name: nameForUser)
    }

    private func board(for sharer: UUID) -> InkBoard {
        if let board = boards[sharer] { return board }
        let board = InkBoard()
        boards[sharer] = board
        return board
    }

    /// Applies my own drawing immediately, then sends it to everyone in the call.
    fileprivate func sendInk(_ message: InkMessage) {
        guard let room, let myID else { return }
        board(for: message.board).apply(message, from: myID)
        guard let data = try? JSONEncoder().encode(message) else { return }
        // Strokes must all arrive; pointer positions can be dropped if the network is busy.
        let reliable = ![.cursor, .leave, .info].contains(message.kind)
        Task {
            try? await room.localParticipant.publish(
                data: data, options: DataPublishOptions(topic: "ink", reliable: reliable)
            )
        }
    }

    /// Asks everyone else in the room to play a soundboard clip.
    func sendSoundboard(_ id: String) {
        guard let room else { return }
        Task {
            try? await room.localParticipant.publish(
                data: Data(id.utf8), options: DataPublishOptions(topic: "soundboard", reliable: true)
            )
        }
    }

    fileprivate func receiveInk(_ data: Data, from user: UUID) {
        guard let message = try? JSONDecoder().decode(InkMessage.self, from: data) else { return }
        board(for: message.board).apply(message, from: user)
    }

    /// Lets me draw on my own shared screen (otherwise clicks pass through the overlay).
    func setDrawMode(_ on: Bool) {
        overlay?.setDrawMode(on)
    }

    /// Clears everyone's drawings on my shared screen.
    func clearMyBoard() {
        guard let myID else { return }
        sendInk(InkMessage(kind: .clear, board: myID))
    }

    private func sendShareInfo() {
        guard let myID, let aspect = overlay?.aspect else { return }
        var message = InkMessage(kind: .info, board: myID)
        message.aspect = aspect
        sendInk(message)
    }

    // MARK: Sharing my screen

    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user must use System Settings.
    static func requestScreenRecordingPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }

    /// Displays first, then ordinary on-screen windows of other apps.
    func shareSources() async -> [ShareSource] {
        guard Self.hasScreenRecordingPermission else { return [] }
        var result: [ShareSource] = []

        let displays = (try? await MacOSScreenCapturer.displaySources()) ?? []
        for (index, display) in displays.enumerated() {
            result.append(ShareSource(
                id: "display-\(display.displayID)",
                title: displays.count == 1 ? "Entire Screen" : "Screen \(index + 1)",
                isDisplay: true,
                dimensions: Self.captureSize(width: display.width, height: display.height),
                source: display,
                overlayTarget: .display(display.displayID)
            ))
        }

        let windows = (try? await MacOSScreenCapturer.windowSources()) ?? []
        for window in windows {
            guard window.windowLayer == 0, window.isOnScreen,
                  window.frame.width >= 200, window.frame.height >= 150,
                  let app = window.owningApplication?.applicationName, !app.isEmpty,
                  let title = window.title, !title.isEmpty
            else { continue }
            let label = title == app ? app : "\(app) — \(title)"
            result.append(ShareSource(
                id: "window-\(window.windowID)",
                title: label.count > 48 ? String(label.prefix(47)) + "…" : label,
                isDisplay: false,
                // Windows report points; capture at 2x for sharp text.
                dimensions: Self.captureSize(width: Int(window.frame.width * 2), height: Int(window.frame.height * 2)),
                source: window,
                overlayTarget: .window(window.windowID)
            ))
            if result.count >= displays.count + 15 { break }
        }
        return result
    }

    /// Keeps the aspect ratio, caps the long side so the stream stays light, and rounds to even.
    private static func captureSize(width: Int, height: Int) -> Dimensions {
        let longest = max(width, height, 1)
        let scale = min(1, 2560.0 / Double(longest))
        let w = max(2, Int(Double(width) * scale) / 2 * 2)
        let h = max(2, Int(Double(height) * scale) / 2 * 2)
        return Dimensions(width: Int32(w), height: Int32(h))
    }

    func startSharing(_ share: ShareSource) async throws {
        guard let room else { return }
        await stopSharing()
        // The computer's sound: through a process tap where possible (no echo without
        // headphones), otherwise ScreenCaptureKit's app audio.
        var tapping = false
        if #available(macOS 14.2, *) { tapping = SharedSound.shared.start() }
        let track = await LocalVideoTrack.createMacOSScreenShareTrack(
            source: share.source,
            // 15 fps is plenty for screens and keeps text sharp at a modest bitrate.
            // appAudio: what's playing on my computer goes along with the screen (this
            // app's own sound, i.e. the call, is left out so nobody hears an echo).
            options: ScreenShareCaptureOptions(dimensions: share.dimensions, fps: 15, showCursor: true, appAudio: !tapping)
        )
        sharePublication = try await room.localParticipant.publish(
            videoTrack: track,
            options: VideoPublishOptions(
                // Up to 6 Mbps keeps small text readable on Retina screens.
                screenShareEncoding: VideoEncoding(maxBitrate: 6_000_000, maxFps: 15),
                simulcast: false,
                // H.264 is encoded by the Mac's video chip: less delay and far less CPU.
                preferredCodec: .h264,
                // When bandwidth is tight, drop frames rather than blur the text.
                degradationPreference: .maintainResolution
            )
        )
        // The computer's sound rides in the microphone channel: keep it open while
        // sharing, and if I'm muted, silence only my voice.
        await setMuted(isMuted)

        // The see-through layer on my own screen where teammates' ink and cursors appear.
        if let myID {
            let overlay = SharerOverlay(
                board: board(for: myID), boardID: myID, people: people, target: share.overlayTarget
            ) { [weak self] in self?.sendInk($0) }
            overlay.onExitDrawMode = { [weak self] in
                self?.setDrawMode(false)
                self?.onDrawModeExited?()
            }
            self.overlay = overlay
            // Tell viewers the shape of what I'm sharing, and keep telling late joiners.
            sendShareInfo()
            infoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendShareInfo() }
            }
        }
    }

    func stopSharing() async {
        guard let publication = sharePublication else { return }
        sharePublication = nil
        closeOverlay()
        if #available(macOS 14.2, *) { SharedSound.shared.stop() }
        try? await room?.localParticipant.unpublish(publication: publication)
        // Back to a normal mute now the computer's sound isn't being shared.
        await setMuted(isMuted)
        onLocalShareStopped?()
    }

    // MARK: Watching a teammate's screen

    /// Brings a teammate's shared screen back if its window was closed.
    func showViewer(for user: UUID) {
        viewers[user]?.show()
    }

    fileprivate func remoteShareStarted(by user: UUID, track: VideoTrack) {
        viewers[user]?.close()
        let board = board(for: user)
        board.reset()
        let viewer = ShareViewer(
            title: "\(nameForUser(user))’s Screen — drag to draw",
            track: track, board: board, boardID: user, people: people
        ) { [weak self] in self?.sendInk($0) }
        viewers[user] = viewer
        viewer.show()
        onRemoteSharesChanged?(Set(viewers.keys))
    }

    fileprivate func remoteShareStopped(by user: UUID) {
        boards[user]?.removeUser(user)
        guard let viewer = viewers.removeValue(forKey: user) else { return }
        viewer.close()
        boards[user] = nil
        onRemoteSharesChanged?(Set(viewers.keys))
    }

    fileprivate func participantLeft(_ user: UUID) {
        boards.values.forEach { $0.removeUser(user) }
        remoteShareStopped(by: user)
    }

    fileprivate func reportSpeakers(_ ids: Set<UUID>) {
        onSpeakersChanged?(ids.subtracting([myID].compactMap { $0 }))
    }

    fileprivate func reportParticipants() {
        guard let room else { return }
        let ids = room.remoteParticipants.keys.compactMap { UUID(uuidString: $0.stringValue) }
        onParticipantsChanged?(Set(ids))
    }

    fileprivate func roomDidDisconnect(_ disconnected: Room) {
        // Ignore the echo of our own disconnect().
        guard disconnected === room else { return }
        room = nil
        relay = nil
        cleanUpSharing()
        onDisconnected?()
    }
}

/// LiveKit calls its delegate on background threads; this hops back to the main actor.
private final class Relay: RoomDelegate, @unchecked Sendable {
    private weak var engine: CallEngine?

    init(engine: CallEngine) {
        self.engine = engine
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [engine] in engine?.reportParticipants() }
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let user = participant.identity.flatMap { UUID(uuidString: $0.stringValue) }
        Task { @MainActor [engine] in
            if let user { engine?.participantLeft(user) }
            engine?.reportParticipants()
        }
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard publication.source == .screenShareVideo,
              let track = publication.track as? VideoTrack,
              let user = participant.identity.flatMap({ UUID(uuidString: $0.stringValue) })
        else { return }
        Task { @MainActor [engine] in engine?.remoteShareStarted(by: user, track: track) }
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        if topic == "soundboard", participant != nil {
            let id = String(decoding: data.prefix(200), as: UTF8.self)
            Task { @MainActor [engine] in engine?.onSoundboard?(id) }
            return
        }
        guard topic == "ink", let user = participant?.identity.flatMap({ UUID(uuidString: $0.stringValue) }) else { return }
        Task { @MainActor [engine] in engine?.receiveInk(data, from: user) }
    }

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let ids = Set(participants.compactMap { $0.identity.flatMap { UUID(uuidString: $0.stringValue) } })
        Task { @MainActor [engine] in engine?.reportSpeakers(ids) }
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard publication.source == .screenShareVideo,
              let user = participant.identity.flatMap({ UUID(uuidString: $0.stringValue) })
        else { return }
        Task { @MainActor [engine] in engine?.remoteShareStopped(by: user) }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [engine] in engine?.roomDidDisconnect(room) }
    }
}

/// A resizable window showing one teammate's shared screen, with a drawing layer on top.
@MainActor
private final class ShareViewer {
    private let window: NSWindow

    init(
        title: String, track: VideoTrack, board: InkBoard, boardID: UUID,
        people: InkPeople, send: @escaping (InkMessage) -> Void
    ) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1100, screen.width * 0.7)
        let size = NSSize(width: width, height: width * 10 / 16)
        let frame = NSRect(origin: .zero, size: size)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.minSize = NSSize(width: 480, height: 300)
        window.acceptsMouseMovedEvents = true
        window.center()

        let container = NSView(frame: frame)

        let video = VideoView(frame: frame)
        video.layoutMode = .fit
        video.track = track
        video.autoresizingMask = [.width, .height]
        container.addSubview(video)

        // Ink sits above the video and follows the same letterboxed rectangle.
        let ink = InkView(board: board, people: people, fitsAspect: true, send: send)
        ink.boardID = boardID
        ink.frame = frame
        ink.autoresizingMask = [.width, .height]
        ink.isInteractive = true
        if let dimensions = track.dimensions, dimensions.height > 0 {
            ink.fallbackAspect = Double(dimensions.width) / Double(dimensions.height)
        }
        container.addSubview(ink)

        let controls = NSHostingView(rootView: InkControls {
            send(InkMessage(kind: .clear, board: boardID))
        })
        let controlsSize = controls.fittingSize
        controls.frame = NSRect(
            x: frame.width - controlsSize.width, y: frame.height - controlsSize.height,
            width: controlsSize.width, height: controlsSize.height
        )
        controls.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(controls)

        window.contentView = container
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
