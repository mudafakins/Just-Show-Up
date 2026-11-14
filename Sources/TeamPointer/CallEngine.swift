import AVFoundation
import Foundation
import LiveKit

/// The audio side of a call: one LiveKit room, microphone on, no video.
/// TeamStore decides who is in the call; this only carries the sound.
@MainActor
final class CallEngine {
    /// Teammates currently connected to the room (by user id), not counting me.
    var onParticipantsChanged: ((Set<UUID>) -> Void)?
    /// The room dropped without us hanging up.
    var onDisconnected: (() -> Void)?

    private var room: Room?
    private var relay: Relay?

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
        await old?.disconnect()
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
        Task { @MainActor [engine] in engine?.reportParticipants() }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [engine] in engine?.roomDidDisconnect(room) }
    }
}
