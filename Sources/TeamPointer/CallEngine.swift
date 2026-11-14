import AppKit
import AVFoundation
import LiveKit

/// Something that can be shared: a whole display or one window.
struct ShareSource: Identifiable {
    let id: String
    let title: String
    let isDisplay: Bool
    /// Size in pixels to capture at.
    fileprivate let dimensions: Dimensions
    fileprivate let source: MacOSScreenCaptureSource
}

/// The audio side of a call: one LiveKit room, microphone on, no video.
/// TeamStore decides who is in the call; this only carries the sound.
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
    /// Used for the viewer window's title.
    var nameForUser: (UUID) -> String = { _ in "Teammate" }

    private var room: Room?
    private var relay: Relay?
    private var sharePublication: LocalTrackPublication?
    private var viewers: [UUID: ShareViewer] = [:]

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func connect(url: String, token: String) async throws {
        let relay = Relay(engine: self)
        let room = Room(delegate: relay)
        self.relay = relay
        self.room = room
        try await room.connect(url: url, token: token)
        try await room.localParticipant.setMicrophone(enabled: true)
        reportParticipants()
    }

    func setMuted(_ muted: Bool) async {
        _ = try? await room?.localParticipant.setMicrophone(enabled: !muted)
    }

    func disconnect() async {
        let old = room
        room = nil
        relay = nil
        cleanUpSharing()
        await old?.disconnect()
    }

    private func cleanUpSharing() {
        if sharePublication != nil {
            sharePublication = nil
            onLocalShareStopped?()
        }
        viewers.values.forEach { $0.close() }
        viewers = [:]
        onRemoteSharesChanged?([])
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
                source: display
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
                source: window
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
        let track = await LocalVideoTrack.createMacOSScreenShareTrack(
            source: share.source,
            // 15 fps is plenty for screens and keeps text sharp at a modest bitrate.
            options: ScreenShareCaptureOptions(dimensions: share.dimensions, fps: 15, showCursor: true)
        )
        sharePublication = try await room.localParticipant.publish(
            videoTrack: track,
            options: VideoPublishOptions(
                screenShareEncoding: VideoEncoding(maxBitrate: 3_000_000, maxFps: 15),
                simulcast: false
            )
        )
    }

    func stopSharing() async {
        guard let publication = sharePublication else { return }
        sharePublication = nil
        try? await room?.localParticipant.unpublish(publication: publication)
        onLocalShareStopped?()
    }

    // MARK: Watching a teammate's screen

    /// Brings a teammate's shared screen back if its window was closed.
    func showViewer(for user: UUID) {
        viewers[user]?.show()
    }

    fileprivate func remoteShareStarted(by user: UUID, track: VideoTrack) {
        viewers[user]?.close()
        let viewer = ShareViewer(title: "\(nameForUser(user))’s Screen", track: track)
        viewers[user] = viewer
        viewer.show()
        onRemoteSharesChanged?(Set(viewers.keys))
    }

    fileprivate func remoteShareStopped(by user: UUID) {
        guard let viewer = viewers.removeValue(forKey: user) else { return }
        viewer.close()
        onRemoteSharesChanged?(Set(viewers.keys))
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
            if let user { engine?.remoteShareStopped(by: user) }
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

/// A resizable window showing one teammate's shared screen.
@MainActor
private final class ShareViewer {
    private let window: NSWindow

    init(title: String, track: VideoTrack) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1100, screen.width * 0.7)
        let size = NSSize(width: width, height: width * 10 / 16)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.minSize = NSSize(width: 480, height: 300)
        window.center()

        let video = VideoView(frame: NSRect(origin: .zero, size: size))
        video.layoutMode = .fit
        video.track = track
        video.autoresizingMask = [.width, .height]
        window.contentView = video
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
