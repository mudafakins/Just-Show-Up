import AppKit
import CryptoKit
import LiveKitWebRTC

// Sending files straight to a teammate, computer to computer (like Blip).
//
//   1. The sender offers a file over the team channel ("file" broadcasts):
//      its name and size. Nothing else leaves the computer yet.
//   2. The receiver sees Save / Decline. Save replies "accept".
//   3. The sender opens a WebRTC connection; the two apps swap connection details
//      ("sdp", "ice") over the team channel and connect directly. A relay (TURN) is
//      used only when a direct path is impossible, and only if one is configured.
//   4. The file streams over a data channel in 64 KB pieces, then a fingerprint
//      (SHA-256). The receiver checks it, keeps the file in Downloads/Just Show Up,
//      and says "ok".
//
// The Windows app speaks the same protocol (windows/src/files.ts).

/// A message about a file transfer, sent over the team channel.
struct FileSignal: Codable {
    enum Kind: String, Codable {
        case offer, accept, decline, cancel, sdp, ice
    }

    struct Ice: Codable {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: Int32
    }

    let kind: Kind
    /// The transfer (lowercase UUID).
    let id: String
    let from: UUID
    let to: UUID
    /// The sender's display name.
    var name: String?
    var fileName: String?
    var size: Int64?
    /// "offer" or "answer", with the SDP.
    var sdpType: String?
    var sdp: String?
    var ice: Ice?
    /// Why it was declined or cancelled, for the other side's message.
    var reason: String?
}

/// One transfer, as the panel shows it.
struct FileTransfer: Identifiable, Equatable {
    enum Direction { case sending, receiving }
    enum Stage: Equatable {
        /// Sender: waiting for them to accept. Receiver: waiting for me to choose.
        case waiting
        case connecting
        case transferring
        case checking
    }

    let id: String
    let teammate: UUID
    let teammateName: String
    let direction: Direction
    let fileName: String
    let size: Int64
    var stage: Stage = .waiting
    var sent: Int64 = 0
    /// Bytes per second, smoothed.
    var speed: Double = 0

    var fraction: Double { size > 0 ? min(1, Double(sent) / Double(size)) : 0 }
}

@MainActor
final class FileTransfers: ObservableObject {
    /// Transfers in progress (and offers waiting for an answer).
    @Published private(set) var active: [FileTransfer] = []
    /// The last file I received, for "Show in Finder".
    @Published var lastSaved: URL?

    /// Sends a signal over the team channel.
    var sendSignal: (FileSignal) async -> Void = { _ in }
    /// Me, and my display name.
    var myID: () -> UUID? = { nil }
    var myName: () -> String = { "" }
    /// Whether incoming files should be turned away (Do Not Disturb).
    var isBusy: () -> Bool = { false }
    /// Short messages for the panel.
    var onMessage: (String) -> Void = { _ in }
    /// Ways to reach the other computer: STUN, plus a relay when one is set up.
    var iceServers: () async -> [IceServer] = { IceServer.defaults }

    private var links: [String: PeerLink] = [:]
    /// Connection details that arrived before their connection existed.
    private var earlyIce: [String: [FileSignal.Ice]] = [:]
    private var outgoingFiles: [String: URL] = [:]
    private var expiry: [String: Task<Void, Never>] = [:]

    var incoming: [FileTransfer] { active.filter { $0.direction == .receiving && $0.stage == .waiting } }

    func transfer(with teammate: UUID) -> FileTransfer? {
        active.first { $0.teammate == teammate && !($0.direction == .receiving && $0.stage == .waiting) }
    }

    // MARK: sending

    /// Offers files to a teammate. Several files, or a folder, go as one zip.
    func send(_ urls: [URL], to teammate: Teammate) {
        guard let me = myID(), !urls.isEmpty else { return }
        guard transfer(with: teammate.id) == nil else {
            onMessage("Already sending to \(teammate.name). Wait for it to finish.")
            return
        }
        let id = UUID().uuidString.lowercased()
        Task {
            let file: URL
            do {
                file = try await Self.packaged(urls, senderName: myName())
            } catch {
                onMessage("Couldn't prepare the file: \(error.localizedDescription)")
                return
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            outgoingFiles[id] = file
            active.append(FileTransfer(id: id, teammate: teammate.id, teammateName: teammate.name,
                                       direction: .sending, fileName: file.lastPathComponent, size: size))
            await sendSignal(FileSignal(kind: .offer, id: id, from: me, to: teammate.id, name: myName(),
                                        fileName: file.lastPathComponent, size: size))
            // Give up if they never answer.
            expire(id, after: 90, message: "\(teammate.name) didn't answer. The file wasn't sent.")
        }
    }

    /// Stops a transfer (either direction) and tells the other side.
    func cancel(_ id: String) {
        guard let transfer = active.first(where: { $0.id == id }), let me = myID() else { return }
        Task { await sendSignal(FileSignal(kind: .cancel, id: id, from: me, to: transfer.teammate)) }
        finish(id)
    }

    // MARK: receiving

    func accept(_ id: String) {
        guard let index = active.firstIndex(where: { $0.id == id }), let me = myID() else { return }
        active[index].stage = .connecting
        let transfer = active[index]
        expire(id, after: 60, message: "Couldn't connect to \(transfer.teammateName). The file wasn't received.")
        Task { await sendSignal(FileSignal(kind: .accept, id: id, from: me, to: transfer.teammate)) }
    }

    func decline(_ id: String) {
        guard let transfer = active.first(where: { $0.id == id }), let me = myID() else { return }
        Task { await sendSignal(FileSignal(kind: .decline, id: id, from: me, to: transfer.teammate)) }
        finish(id)
    }

    // MARK: signals

    func receive(_ signal: FileSignal) {
        guard let me = myID(), signal.to == me else { return }
        let transfer = active.first { $0.id == signal.id }
        // Only the person on the other end of this transfer may steer it.
        if let transfer, transfer.teammate != signal.from { return }

        switch signal.kind {
        case .offer:
            guard transfer == nil, let fileName = signal.fileName, let size = signal.size else { return }
            if isBusy() {
                Task { await sendSignal(FileSignal(kind: .decline, id: signal.id, from: me, to: signal.from, reason: "busy")) }
                return
            }
            let safeName = Self.safeFileName(fileName)
            active.append(FileTransfer(id: signal.id, teammate: signal.from, teammateName: signal.name ?? "A teammate",
                                       direction: .receiving, fileName: safeName, size: size))
            Sounds.play(.teammateJoined)
            // The offer lapses if I don't answer.
            expire(signal.id, after: 90, message: nil)

        case .accept:
            guard let transfer, transfer.direction == .sending, transfer.stage == .waiting,
                  let file = outgoingFiles[signal.id] else { return }
            update(signal.id) { $0.stage = .connecting }
            expire(signal.id, after: 45,
                   message: "Couldn't connect to \(transfer.teammateName) directly. Try again, or from another network.")
            Task { await startSending(file, transfer: transfer) }

        case .decline:
            guard let transfer else { return }
            onMessage(signal.reason == "busy"
                      ? "\(transfer.teammateName) is on Do Not Disturb. The file wasn't sent."
                      : "\(transfer.teammateName) declined \(transfer.fileName).")
            finish(signal.id)

        case .cancel:
            guard let transfer else { return }
            onMessage(transfer.direction == .receiving
                      ? "\(transfer.teammateName) stopped sending \(transfer.fileName)."
                      : "\(transfer.teammateName) stopped receiving \(transfer.fileName).")
            finish(signal.id)

        case .sdp:
            guard let transfer, let sdp = signal.sdp else { return }
            if signal.sdpType == "offer", transfer.direction == .receiving, transfer.stage == .connecting {
                Task { await startReceiving(transfer, offer: sdp) }
            } else if signal.sdpType == "answer" {
                links[signal.id]?.setAnswer(sdp)
            }

        case .ice:
            guard transfer != nil, let ice = signal.ice else { return }
            if let link = links[signal.id] { link.add(ice) } else { earlyIce[signal.id, default: []].append(ice) }
        }
    }

    // MARK: connections

    private func startSending(_ file: URL, transfer: FileTransfer) async {
        guard let me = myID() else { return }
        let link = PeerLink(id: transfer.id, servers: await iceServers())
        links[transfer.id] = link
        wire(link, transfer: transfer, me: me)
        earlyIce.removeValue(forKey: transfer.id)?.forEach(link.add)
        link.sendFile(file, onProgress: { [weak self] sent in
            Task { @MainActor in self?.progress(transfer.id, sent) }
        }, onDone: { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                self.onMessage(ok ? "Sent \(transfer.fileName) to \(transfer.teammateName)."
                                  : "\(transfer.fileName) didn't arrive intact. Try sending it again.")
                self.finish(transfer.id)
            }
        })
        link.makeOffer { [weak self] sdp in
            Task { await self?.sendSignal(FileSignal(kind: .sdp, id: transfer.id, from: me, to: transfer.teammate,
                                                     sdpType: "offer", sdp: sdp)) }
        }
    }

    private func startReceiving(_ transfer: FileTransfer, offer: String) async {
        guard let me = myID(), links[transfer.id] == nil else { return }
        let destination: URL
        do {
            destination = try Self.downloadsFolder()
        } catch {
            onMessage("Couldn't save to Downloads: \(error.localizedDescription)")
            cancel(transfer.id)
            return
        }
        let link = PeerLink(id: transfer.id, servers: await iceServers())
        links[transfer.id] = link
        wire(link, transfer: transfer, me: me)
        earlyIce.removeValue(forKey: transfer.id)?.forEach(link.add)
        link.receiveFile(named: transfer.fileName, size: transfer.size, into: destination, onProgress: { [weak self] got in
            Task { @MainActor in self?.progress(transfer.id, got) }
        }, onChecking: { [weak self] in
            Task { @MainActor in self?.update(transfer.id) { $0.stage = .checking } }
        }, onDone: { [weak self] saved in
            Task { @MainActor in
                guard let self else { return }
                if let saved {
                    self.lastSaved = saved
                    Sounds.play(.join)
                    self.onMessage("Saved \(saved.lastPathComponent) from \(transfer.teammateName).")
                } else {
                    self.onMessage("\(transfer.fileName) from \(transfer.teammateName) didn't arrive intact. Ask them to send it again.")
                }
                self.finish(transfer.id)
            }
        })
        link.answer(offer) { [weak self] sdp in
            Task { await self?.sendSignal(FileSignal(kind: .sdp, id: transfer.id, from: me, to: transfer.teammate,
                                                     sdpType: "answer", sdp: sdp)) }
        }
    }

    /// Candidates go to the other side; a dropped connection ends the transfer.
    private func wire(_ link: PeerLink, transfer: FileTransfer, me: UUID) {
        link.onCandidate = { [weak self] ice in
            Task { await self?.sendSignal(FileSignal(kind: .ice, id: transfer.id, from: me, to: transfer.teammate, ice: ice)) }
        }
        link.onOpen = { [weak self] in
            Task { @MainActor in
                self?.expiry[transfer.id]?.cancel()
                self?.update(transfer.id) { $0.stage = .transferring }
            }
        }
        link.onFailed = { [weak self] in
            Task { @MainActor in
                guard let self, self.active.contains(where: { $0.id == transfer.id }) else { return }
                self.onMessage("Lost the connection to \(transfer.teammateName). \(transfer.fileName) wasn't finished.")
                self.cancel(transfer.id)
            }
        }
    }

    // MARK: bookkeeping

    private var lastSample: [String: (time: Date, bytes: Int64)] = [:]

    private func progress(_ id: String, _ bytes: Int64) {
        let now = Date()
        update(id) { transfer in
            if let last = lastSample[id], now.timeIntervalSince(last.time) > 0.3 {
                let rate = Double(bytes - last.bytes) / now.timeIntervalSince(last.time)
                transfer.speed = transfer.speed == 0 ? rate : transfer.speed * 0.6 + rate * 0.4
                lastSample[id] = (now, bytes)
            } else if lastSample[id] == nil {
                lastSample[id] = (now, bytes)
            }
            transfer.sent = bytes
        }
    }

    private func update(_ id: String, _ change: (inout FileTransfer) -> Void) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        change(&active[index])
    }

    private func expire(_ id: String, after seconds: Double, message: String?) {
        expiry[id]?.cancel()
        expiry[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.active.contains(where: { $0.id == id }) else { return }
            if let message { self.onMessage(message) }
            self.cancel(id)
        }
    }

    private func finish(_ id: String) {
        expiry[id]?.cancel()
        expiry[id] = nil
        links.removeValue(forKey: id)?.close()
        if let file = outgoingFiles.removeValue(forKey: id), file.path.contains("/JustShowUpOutgoing-") {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        lastSample[id] = nil
        earlyIce[id] = nil
        active.removeAll { $0.id == id }
    }

    // MARK: files

    /// One file as it is; a folder or several files zipped into one.
    nonisolated static func packaged(_ urls: [URL], senderName: String) async throws -> URL {
        var isFolder: ObjCBool = false
        if urls.count == 1, FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isFolder), !isFolder.boolValue {
            return urls[0]
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("JustShowUpOutgoing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let source: URL
        let zipName: String
        if urls.count == 1 {
            source = urls[0]
            zipName = urls[0].lastPathComponent + ".zip"
        } else {
            // Several files: gather them in one folder, then zip that.
            let first = senderName.components(separatedBy: " ").first ?? ""
            let folderName = first.isEmpty ? "\(urls.count) files" : "\(urls.count) files from \(first)"
            source = work.appendingPathComponent(folderName)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for url in urls {
                try FileManager.default.copyItem(at: url, to: source.appendingPathComponent(url.lastPathComponent))
            }
            zipName = folderName + ".zip"
        }
        let zip = work.appendingPathComponent(zipName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "JustShowUp", code: 1, userInfo: [NSLocalizedDescriptionKey: "zipping failed"])
        }
        return zip
    }

    /// Downloads/Just Show Up.
    nonisolated static func downloadsFolder() throws -> URL {
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = downloads.appendingPathComponent("Just Show Up", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A name that can't climb out of the folder or hide itself.
    nonisolated static func safeFileName(_ name: String) -> String {
        var cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "file" : cleaned).prefix(200))
    }

    /// "name.ext", or "name 2.ext" if that's taken.
    nonisolated static func unusedURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A STUN or TURN server.
struct IceServer: Decodable {
    let urls: [String]
    var username: String?
    var credential: String?

    static let defaults = [
        IceServer(urls: ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"]),
    ]
}

// MARK: - The WebRTC connection for one transfer

/// One direct connection and its data channel. WebRTC calls back on its own
/// threads; file reading and writing happen on `queue`.
private final class PeerLink: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate, @unchecked Sendable {
    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory()
    }()

    /// 64 KB pieces; keep at most 4 MB queued so a slow receiver isn't flooded.
    private static let chunk = 64 * 1024
    private static let highWater: UInt64 = 4 << 20

    let id: String
    private var connection: LKRTCPeerConnection?
    private var channel: LKRTCDataChannel?
    private let queue: DispatchQueue
    private let room = DispatchSemaphore(value: 0)
    private var closed = false
    /// Candidates wait here until the other side's description is set.
    private let iceLock = NSLock()
    private var hasRemote = false
    private var heldIce: [FileSignal.Ice] = []

    var onCandidate: (FileSignal.Ice) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onFailed: () -> Void = {}

    // Sending
    private var fileToSend: URL?
    private var onSendProgress: (Int64) -> Void = { _ in }
    private var onSendDone: (Bool) -> Void = { _ in }

    // Receiving
    private var folder: URL?
    private var fileName = ""
    private var expected: Int64 = 0
    private var partial: URL?
    private var writer: FileHandle?
    private var received: Int64 = 0
    private var onReceiveProgress: (Int64) -> Void = { _ in }
    private var onChecking: () -> Void = {}
    private var onReceiveDone: (URL?) -> Void = { _ in }

    init(id: String, servers: [IceServer]) {
        self.id = id
        queue = DispatchQueue(label: "files.\(id)")
        super.init()
        let config = LKRTCConfiguration()
        config.iceServers = servers.map { server in
            LKRTCIceServer(urlStrings: server.urls, username: server.username, credential: server.credential)
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }

    // MARK: offer / answer

    func makeOffer(_ send: @escaping (String) -> Void) {
        guard let connection else { return }
        let config = LKRTCDataChannelConfiguration()
        config.isOrdered = true
        channel = connection.dataChannel(forLabel: "file", configuration: config)
        channel?.delegate = self
        connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, _ in
            guard let self, let sdp else { return self?.onFailed() ?? () }
            self.connection?.setLocalDescription(sdp) { error in
                if error == nil { send(sdp.sdp) } else { self.onFailed() }
            }
        }
    }

    func answer(_ offer: String, _ send: @escaping (String) -> Void) {
        guard let connection else { return }
        connection.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offer)) { [weak self] error in
            guard let self, error == nil else { self?.onFailed(); return }
            self.remoteIsSet()
            connection.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, _ in
                guard let sdp else { return self.onFailed() }
                connection.setLocalDescription(sdp) { error in
                    if error == nil { send(sdp.sdp) } else { self.onFailed() }
                }
            }
        }
    }

    func setAnswer(_ sdp: String) {
        connection?.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
            if error != nil { self?.onFailed() } else { self?.remoteIsSet() }
        }
    }

    func add(_ ice: FileSignal.Ice) {
        iceLock.lock()
        guard hasRemote else {
            heldIce.append(ice)
            iceLock.unlock()
            return
        }
        iceLock.unlock()
        connection?.add(LKRTCIceCandidate(sdp: ice.candidate, sdpMLineIndex: ice.sdpMLineIndex, sdpMid: ice.sdpMid)) { _ in }
    }

    private func remoteIsSet() {
        iceLock.lock()
        hasRemote = true
        let held = heldIce
        heldIce = []
        iceLock.unlock()
        held.forEach(add)
    }

    func close() {
        queue.async { [self] in
            closed = true
            room.signal()
            try? writer?.close()
            writer = nil
            if let partial { try? FileManager.default.removeItem(at: partial) }
            partial = nil
        }
        channel?.close()
        connection?.close()
    }

    // MARK: sending

    func sendFile(_ url: URL, onProgress: @escaping (Int64) -> Void, onDone: @escaping (Bool) -> Void) {
        fileToSend = url
        onSendProgress = onProgress
        onSendDone = onDone
    }

    private func pump() {
        queue.async { [self] in
            guard let url = fileToSend, let channel, let handle = try? FileHandle(forReadingFrom: url) else {
                return onFailed()
            }
            defer { try? handle.close() }
            var sent: Int64 = 0
            var lastReport = Date.distantPast
            while !closed, let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty {
                while !closed, channel.bufferedAmount > Self.highWater {
                    _ = room.wait(timeout: .now() + 0.05)
                }
                guard !closed, channel.sendData(LKRTCDataBuffer(data: data, isBinary: true)) else { return }
                sent += Int64(data.count)
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    onSendProgress(sent)
                }
            }
            guard !closed else { return }
            onSendProgress(sent)
            let hash = FileTransfers.sha256(of: url) ?? ""
            sendControl(["t": "end", "size": sent, "sha256": hash])
        }
    }

    private func sendControl(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        _ = channel?.sendData(LKRTCDataBuffer(data: data, isBinary: false))
    }

    // MARK: receiving

    func receiveFile(named name: String, size: Int64, into folder: URL,
                     onProgress: @escaping (Int64) -> Void, onChecking: @escaping () -> Void,
                     onDone: @escaping (URL?) -> Void) {
        self.folder = folder
        fileName = name
        expected = size
        onReceiveProgress = onProgress
        self.onChecking = onChecking
        onReceiveDone = onDone
        queue.async { [self] in
            let part = folder.appendingPathComponent(".\(id).part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            partial = part
            writer = try? FileHandle(forWritingTo: part)
        }
    }

    private func received(_ data: Data) {
        queue.async { [self] in
            guard !closed, let writer else { return }
            do { try writer.write(contentsOf: data) } catch { return onFailed() }
            received += Int64(data.count)
            onReceiveProgress(received)
        }
    }

    private func receivedControl(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["t"] as? String else { return }
        switch type {
        case "end":
            let hash = message["sha256"] as? String ?? ""
            queue.async { [self] in
                guard !closed, let partial, let folder else { return }
                try? writer?.close()
                writer = nil
                onChecking()
                let ok = received == expected && FileTransfers.sha256(of: partial) == hash
                var saved: URL?
                if ok {
                    let final = FileTransfers.unusedURL(in: folder, name: fileName)
                    if (try? FileManager.default.moveItem(at: partial, to: final)) != nil {
                        saved = final
                        self.partial = nil
                    }
                }
                sendControl(["t": saved != nil ? "ok" : "bad"])
                onReceiveDone(saved)
            }
        case "ok", "bad":
            onSendDone(type == "ok")
        default:
            break
        }
    }

    // MARK: LKRTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            onOpen()
            if fileToSend != nil { pump() }
        case .closed:
            if !closed { onFailed() }
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        if buffer.isBinary { received(buffer.data) } else { receivedControl(buffer.data) }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        room.signal()
    }

    // MARK: LKRTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        channel = dataChannel
        dataChannel.delegate = self
        if dataChannel.readyState == .open { onOpen() }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        onCandidate(FileSignal.Ice(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        if newState == .failed { onFailed() }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
}
