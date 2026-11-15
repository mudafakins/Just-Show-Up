import AppKit

/// A classic telephone ring ("ring-ring … ring-ring"), generated in code so the app
/// ships no audio files. Two mixed tones at 400 Hz and 450 Hz, the pattern landline
/// phones use: 0.4 s on, 0.2 s off, 0.4 s on, 2 s off.
@MainActor
enum Ringtone {
    private static var sound: NSSound?

    static func start() {
        stop()
        guard let sound = NSSound(data: makeWAV()) else { return }
        sound.loops = true
        sound.volume = 0.8
        sound.play()
        self.sound = sound
    }

    static func stop() {
        sound?.stop()
        sound = nil
    }

    private static func makeWAV() -> Data {
        let rate = 22_050
        // (seconds, ringing?) for one cycle; the sound loops this cycle.
        let pattern: [(Double, Bool)] = [(0.4, true), (0.2, false), (0.4, true), (2.0, false)]

        var samples: [Int16] = []
        for (duration, ringing) in pattern {
            let count = Int(duration * Double(rate))
            let fade = Int(0.01 * Double(rate)) // 10 ms ramps avoid clicks
            for i in 0..<count {
                guard ringing else {
                    samples.append(0)
                    continue
                }
                let t = Double(i) / Double(rate)
                let envelope = min(1, Double(min(i, count - 1 - i)) / Double(fade))
                let value = (sin(2 * .pi * 400 * t) + sin(2 * .pi * 450 * t)) * 0.3 * envelope
                samples.append(Int16(value * Double(Int16.max)))
            }
        }

        // Minimal 16-bit mono PCM WAV file.
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                  // PCM, mono
        append(UInt32(rate)); append(UInt32(rate * 2))        // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16))                 // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }
}
