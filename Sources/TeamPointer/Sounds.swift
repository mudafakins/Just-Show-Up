import AppKit

/// Small, soft chimes for room events, generated in code (no audio files).
/// Rising notes for a join, falling notes for a leave; a quick, brighter three-note
/// run for screen sharing starting or stopping; quieter when it's a teammate.
@MainActor
enum Sounds {
    enum Cue {
        case join, leave, teammateJoined, teammateLeft
        case shareStarted, shareStopped, teammateShareStarted, teammateShareStopped
        /// My own mic: a quick soft tick, up for unmute, down for mute.
        case muted, unmuted
    }

    static let enabledKey = "playSounds"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static var cache: [Cue: Data] = [:]
    private static var playing: [NSSound] = []

    static func play(_ cue: Cue) {
        guard isEnabled else { return }
        let data = cache[cue] ?? make(cue)
        cache[cue] = data
        guard let sound = NSSound(data: data) else { return }
        switch cue {
        case .join, .leave, .shareStarted, .shareStopped: sound.volume = 0.5
        case .teammateJoined, .teammateLeft, .teammateShareStarted, .teammateShareStopped: sound.volume = 0.3
        case .muted, .unmuted: sound.volume = 0.4
        }
        // Keep a reference until it finishes, or it stops early.
        playing.removeAll { !$0.isPlaying }
        playing.append(sound)
        sound.play()
    }

    private static func make(_ cue: Cue) -> Data {
        // G5 and C6: a gentle major fourth.
        let low = 783.99, high = 1046.5
        switch cue {
        case .join, .teammateJoined: return tones([low, high])
        case .leave, .teammateLeft: return tones([high, low])
        // E6, G#6, B6: a bright major arpeggio, quicker than the room chimes.
        case .shareStarted, .teammateShareStarted: return tones([1318.5, 1661.2, 1975.5], step: 0.065, ring: 0.24)
        case .shareStopped, .teammateShareStopped: return tones([1975.5, 1661.2, 1318.5], step: 0.065, ring: 0.24)
        // A5 and E6, short and close together, so it reads as a click of a switch.
        case .unmuted: return tones([880, 1318.5], step: 0.05, ring: 0.12)
        case .muted: return tones([1318.5, 880], step: 0.05, ring: 0.12)
        }
    }

    /// Notes one after another, each a soft bell (quick attack, smooth decay).
    static func tones(_ notes: [Double], step: Double = 0.11, ring: Double = 0.32, level: Double = 0.28) -> Data {
        let rate = 44_100
        let total = Int((step * Double(notes.count - 1) + ring) * Double(rate))
        var mix = [Double](repeating: 0, count: total)
        for (n, frequency) in notes.enumerated() {
            let start = Int(step * Double(n) * Double(rate))
            let length = Int(ring * Double(rate))
            for i in 0..<length where start + i < total {
                let t = Double(i) / Double(rate)
                let attack = min(1, t / 0.006)
                let decay = exp(-t * 11)
                // A touch of the octave makes it bell-like rather than a beep.
                let wave = sin(2 * .pi * frequency * t) + 0.25 * sin(4 * .pi * frequency * t)
                mix[start + i] += wave * attack * decay * level
            }
        }
        let samples = mix.map { Int16(max(-1, min(1, $0)) * Double(Int16.max)) }
        return wav(samples, rate: rate)
    }

    static func wav(_ samples: [Int16], rate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }
}
