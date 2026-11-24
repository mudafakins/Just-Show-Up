import AVFoundation
import CoreAudio
import LiveKit

/// The computer's sound during a screen share, without echo when not wearing headphones.
///
/// The problem: other apps (a YouTube video, say) play straight to the speakers, the
/// microphone hears them, and teammates get the sound twice. The Mac's echo remover only
/// knows about sound the call itself plays.
///
/// So while sharing (macOS 14.2+), a Core Audio process tap takes over every other app's
/// sound ("muted when tapped": it stops going to the speakers directly). We then
///   • send it to teammates (mixed into the microphone channel), and
///   • play it on this Mac through the call's own audio engine,
/// so it sounds the same here, and the echo remover knows it and removes it from the mic.
///
/// macOS asks for "System Audio Recording" permission the first time. Until it has been
/// seen working, the tap starts unmuted (nothing goes silent if permission is refused) and
/// switches to muted once real sound arrives.
@available(macOS 14.2, *)
final class SharedSound: @unchecked Sendable {
    static let shared = SharedSound()

    /// Set once sound has come through a tap, i.e. the permission is granted.
    private static let provenKey = "systemAudioTapWorks"

    private let queue = DispatchQueue(label: "shared-sound")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var muted = false
    private var running = false
    private var switching = false
    /// For the self-test: blocks received, and blocks that had sound in them.
    private(set) var blocks = 0
    private(set) var loudBlocks = 0
    var isTakingOver: Bool { queue.sync { muted } }
    /// For the echo self-test: play locally but don't send, to measure the mic alone.
    var sendsToRoom = true
    private var outputListener: AudioObjectPropertyListenerBlock?

    // MARK: start / stop

    /// Starts capturing (and, once permitted, taking over) other apps' sound.
    /// Returns false if it couldn't, so the caller can fall back to plain app audio.
    func start() -> Bool {
        queue.sync {
            guard !running else { return true }
            running = true
            let ok = build(muted: UserDefaults.standard.bool(forKey: Self.provenKey))
            if ok { watchOutputDevice() } else { running = false }
            return ok
        }
    }

    func stop() {
        queue.sync {
            running = false
            unwatchOutputDevice()
            teardown()
        }
        Playout.shared.stop()
    }

    // MARK: the tap

    private func build(muted: Bool) -> Bool {
        teardown()
        self.muted = muted

        // Everything except this app (the call's own sound must not be sent back).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [Self.ownProcessObject()].compactMap { $0 })
        description.uuid = UUID()
        description.name = "Just Show Up! shared sound"
        description.isPrivate = true
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return false }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr,
              let format = AVAudioFormat(streamDescription: &asbd) else { teardown(); return false }
        tapFormat = format

        // A private aggregate device clocked by the current output, reading the tap.
        guard let outputUID = Self.defaultOutputUID() else { teardown(); return false }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Just Show Up! shared sound",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr else { teardown(); return false }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, input, _, _, _ in
            self?.received(input)
        }
        guard status == noErr, let proc else { teardown(); return false }
        procID = proc
        guard AudioDeviceStart(aggregate, proc) == noErr else { teardown(); return false }

        if muted { Playout.shared.start(format: format) }
        return true
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Runs on `queue` with each block of tapped sound.
    private func received(_ input: UnsafePointer<AudioBufferList>) {
        guard running, let format = tapFormat else { return }
        let frames = Self.frameCount(input, format: format)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let target = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }

        blocks += 1
        if Self.hasSound(buffer) { loudBlocks += 1 }
        if !muted {
            // Permission is clearly granted once real sound comes through: take over.
            if Self.hasSound(buffer), !switching {
                UserDefaults.standard.set(true, forKey: Self.provenKey)
                // Rebuild after this callback returns, never from inside it.
                switching = true
                queue.async { [self] in
                    if running { _ = build(muted: true) }
                    switching = false
                }
            }
        } else {
            Playout.shared.play(buffer)
        }
        // To teammates, in the microphone channel.
        if sendsToRoom { AudioManager.shared.mixer.capture(appAudio: buffer) }
    }

    // MARK: output device changes (headphones in or out)

    private func watchOutputDevice() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            _ = self.build(muted: self.muted)
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }

    private func unwatchOutputDevice() {
        guard let listener = outputListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        outputListener = nil
    }

    // MARK: helpers

    private static func frameCount(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioFrameCount {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first else { return 0 }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        return bytesPerFrame > 0 ? first.mDataByteSize / bytesPerFrame : 0
    }

    private static func hasSound(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        for c in 0..<Int(buffer.format.channelCount) {
            for i in stride(from: 0, to: Int(buffer.frameLength), by: 16) where abs(channels[c][i]) > 0.0005 {
                return true
            }
        }
        return false
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// Plays the shared sound on this Mac through the call's own audio engine, so the echo
/// remover treats it like the call and keeps it out of my microphone. Hooked into
/// LiveKit's engine as an observer (see `CallEngine`).
final class Playout: AudioEngineObserver, @unchecked Sendable {
    static let shared = Playout()

    var next: (any AudioEngineObserver)?

    private let lock = NSLock()
    private let player = AVAudioPlayerNode()
    private weak var engine: AVAudioEngine?
    private var connectedFormat: AVAudioFormat?
    private var active = false

    func engineWillConnectOutput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode?,
                                 format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        lock.lock()
        if player.engine !== engine {
            if let old = player.engine { old.detach(player) }
            engine.attach(player)
            connectedFormat = nil
        }
        self.engine = engine
        lock.unlock()
        return next?.engineWillConnectOutput(engine, src: src, dst: dst, format: format, context: context) ?? 0
    }

    func engineWillRelease(_ engine: AVAudioEngine) -> Int {
        lock.lock()
        if player.engine === engine {
            player.stop()
            engine.detach(player)
            connectedFormat = nil
        }
        lock.unlock()
        return next?.engineWillRelease(engine) ?? 0
    }

    /// The player's own format: the mixer only takes standard (non-interleaved float)
    /// audio, so tapped sound is converted to this first.
    private var playFormat: AVAudioFormat?
    /// For the self-test: blocks played on this Mac.
    private(set) var played = 0
    private var converter: AVAudioConverter?

    /// Prepares to play sound arriving in `format` (the tap's).
    func start(format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        active = true
        prepare(for: format)
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard active, let engine, engine.isRunning, player.engine === engine else { return }
        prepare(for: buffer.format)
        guard let playFormat, let converted = convert(buffer, to: playFormat) else { return }
        player.scheduleBuffer(converted, completionHandler: nil)
        played += 1
        if !player.isPlaying { player.play() }
    }

    /// Connects the player in the standard format for `source`'s sample rate. Lock held.
    private func prepare(for source: AVAudioFormat) {
        guard let engine, player.engine === engine,
              let standard = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate,
                                           channels: min(2, max(1, source.channelCount)))
        else { return }
        if connectedFormat != standard {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: standard)
            connectedFormat = standard
        }
        if playFormat != standard || converter?.inputFormat != source {
            playFormat = standard
            converter = source == standard ? nil : AVAudioConverter(from: source, to: standard)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer.format == format ? buffer : nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        do { try converter.convert(to: out, from: buffer) } catch { return nil }
        return out
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false
        player.stop()
    }
}

#if DEBUG
// Development-only self-tests (not in release builds, which teammates get).

/// `TeamPointer --sound-selftest`: starts the tap, plays a system sound from another
/// process, and reports whether the tap heard it and took over. No call needed.
@MainActor
enum SharedSoundSelfTest {
    static func runIfAsked() {
        guard CommandLine.arguments.contains("--sound-selftest") else { return }
        guard #available(macOS 14.2, *) else { print("needs macOS 14.2"); exit(2) }
        let started = SharedSound.shared.start()
        print("tap started:", started, "taking over:", SharedSound.shared.isTakingOver)
        Task {
            for round in 1...6 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                p.arguments = ["/System/Library/Sounds/Submarine.aiff"]
                try? p.run()
                try? await Task.sleep(for: .seconds(1.5))
                print("after sound \(round): blocks \(SharedSound.shared.blocks), with sound \(SharedSound.shared.loudBlocks), taking over \(SharedSound.shared.isTakingOver)")
            }
            SharedSound.shared.stop()
            exit(0)
        }
    }
}

/// `TeamPointer --echo-selftest`: joins Room 3 alone, then plays a system sound out loud
/// with and without the shared-sound takeover, measuring what the microphone sends.
/// With the takeover, the echo remover should take the sound out.
@MainActor
enum EchoSelfTest {
    final class Meter: AudioRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private var sum: Double = 0
        private var count = 0
        private(set) var rate: Double = 48000
        private var recording: [Float] = []
        private var isRecording = false
        func startRecording() { lock.lock(); recording = []; isRecording = true; lock.unlock() }
        func stopRecording() -> [Float] { lock.lock(); defer { lock.unlock() }; isRecording = false; return recording }
        func render(pcmBuffer: AVAudioPCMBuffer) {
            guard let data = pcmBuffer.floatChannelData else {
                if let ints = pcmBuffer.int16ChannelData {
                    lock.lock(); defer { lock.unlock() }
                    rate = pcmBuffer.format.sampleRate
                    if isRecording { for i in 0..<Int(pcmBuffer.frameLength) { recording.append(Float(ints[0][i]) / 32768) } }
                    for i in 0..<Int(pcmBuffer.frameLength) { let v = Double(ints[0][i]) / 32768; sum += v * v }
                    count += Int(pcmBuffer.frameLength)
                }
                return
            }
            lock.lock(); defer { lock.unlock() }
            rate = pcmBuffer.format.sampleRate
            if isRecording { recording.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(pcmBuffer.frameLength))) }
            for i in 0..<Int(pcmBuffer.frameLength) { let v = Double(data[0][i]); sum += v * v }
            count += Int(pcmBuffer.frameLength)
        }
        func take() -> Double {
            lock.lock(); defer { lock.unlock() }
            let rms = count > 0 ? sqrt(sum / Double(count)) : 0
            sum = 0; count = 0
            return 20 * log10(rms + 1e-9)
        }
    }

    static func runIfAsked(team: TeamStore) {
        guard CommandLine.arguments.contains("--echo-selftest") else { return }
        guard #available(macOS 14.2, *) else { print("needs macOS 14.2"); exit(2) }
        Task {
            func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            var tries = 0
            while team.phase != .inTeam, tries < 100 { await wait(0.2); tries += 1 }
            team.joinRoom(3)
            tries = 0
            while team.call == nil || team.call?.isConnecting == true, tries < 100 { await wait(0.2); tries += 1 }
            print("in room:", team.call?.number ?? -1, "connecting:", team.call?.isConnecting ?? true,
                  "phase:", team.phase, "error:", team.errorMessage ?? "-", "notice:", team.notice ?? "-")
            if team.isMuted { team.toggleMute() }
            await wait(1)
            print("ECHO STATE:", AudioManager.shared.audioProcessingState.echoCancellation)
            print("PLATFORM VP enabled:", AudioManager.shared.isVoiceProcessingEnabled, "bypassed:", AudioManager.shared.isVoiceProcessingBypassed)
            print("PLATFORM STATE:", AudioManager.shared.platformVoiceProcessingState)
            let meter = Meter()
            AudioManager.shared.add(localAudioRenderer: meter)
            await wait(2)
            let tone = CommandLine.arguments.last ?? ""
            let outDir = (tone as NSString).deletingLastPathComponent
            var trialNumber = 0
            func writeWAV(_ x: [Float], rate: Double, to path: String) {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count)),
                      let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings) else { return }
                buffer.frameLength = AVAudioFrameCount(x.count)
                x.withUnsafeBufferPointer { memcpy(buffer.floatChannelData![0], $0.baseAddress!, x.count * 4) }
                try? file.write(from: buffer)
            }
            /// Mic level while the tone plays, minus the level just before it.
            func trial() async -> (Double, Double) {
                _ = meter.take(); await wait(1)
                let before = meter.take()
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                p.arguments = [tone]
                try? p.run()
                meter.startRecording()
                await wait(0.4); _ = meter.take(); await wait(2.4)
                let during = meter.take()
                await wait(0.6)
                let samples = meter.stopRecording()
                trialNumber += 1
                writeWAV(samples, rate: meter.rate, to: "\(outDir)/trial\(trialNumber).wav")
                await wait(0.5)
                return (before, during)
            }
            if CommandLine.arguments.contains("--state-only") { team.leaveRoom(); await wait(1); exit(0) }
            var plain: [Double] = [], fixed: [Double] = []
            for _ in 1...4 { let (b, d) = await trial(); plain.append(d - b); print(String(format: "without fix: quiet %.1f dB, tone %.1f dB, rise %+.1f dB", b, d, d - b)) }
            SharedSound.shared.sendsToRoom = false
            print("takeover started:", SharedSound.shared.start(), "taking over:", SharedSound.shared.isTakingOver)
            await wait(1.5)
            for _ in 1...4 { let (b, d) = await trial(); fixed.append(d - b); print(String(format: "with fix:    quiet %.1f dB, tone %.1f dB, rise %+.1f dB", b, d, d - b)) }
            print(String(format: "AVERAGE rise without fix %+.1f dB, with fix %+.1f dB; blocks played here: %d",
                         plain.reduce(0, +) / 4, fixed.reduce(0, +) / 4, Playout.shared.played))
            SharedSound.shared.stop()
            AudioManager.shared.remove(localAudioRenderer: meter)
            team.leaveRoom()
            await wait(1.5)
            exit(0)
        }
    }
}
#endif
