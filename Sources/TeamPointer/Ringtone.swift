import AppKit

/// The sound for an incoming call, generated in code so the app ships no audio
/// files. Each person picks their own in Settings → Ringtone.
@MainActor
enum Ringtone {
    enum Style: String, CaseIterable, Identifiable {
        case classic, marimba, chime, digital, gentle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classic: "Classic Phone"
            case .marimba: "Marimba"
            case .chime: "Chime"
            case .digital: "Digital"
            case .gentle: "Gentle"
            }
        }
    }

    static let styleKey = "ringtone"

    static var style: Style {
        get { Style(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .classic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    private static var sound: NSSound?
    private static var preview: NSSound?

    static func start() {
        stop()
        guard let sound = NSSound(data: makeWAV(style)) else { return }
        sound.loops = true
        sound.volume = 0.8
        sound.play()
        self.sound = sound
    }

    static func stop() {
        sound?.stop()
        sound = nil
    }

    /// Plays one cycle of a ringtone, for choosing one in Settings.
    static func playPreview(_ style: Style) {
        preview?.stop()
        guard sound == nil, let sound = NSSound(data: makeWAV(style)) else { return }
        sound.volume = 0.8
        sound.play()
        preview = sound
    }

    // MARK: sounds

    private static let rate = 22_050

    /// One cycle of the ringtone; it loops.
    static func makeWAV(_ style: Style) -> Data {
        var mix: [Double]
        switch style {
        case .classic:
            // Landline ring: 400 + 450 Hz, 0.4 s on, 0.2 s off, 0.4 s on, 2 s off.
            mix = silence(3.0)
            for start in [0.0, 0.6] {
                add(&mix, at: start, length: 0.4) { t in
                    (sin(2 * .pi * 400 * t) + sin(2 * .pi * 450 * t)) * 0.3
                }
            }
        case .marimba:
            // A rising marimba phrase, twice, then a pause.
            mix = silence(3.0)
            let phrase = [523.25, 659.25, 783.99, 1046.5, 783.99, 1046.5]
            for (n, f) in phrase.enumerated() {
                mallet(&mix, at: Double(n) * 0.13, frequency: f, decay: 7, level: 0.42)
            }
            for (n, f) in phrase.enumerated() {
                mallet(&mix, at: 0.95 + Double(n) * 0.13, frequency: f, decay: 7, level: 0.42)
            }
        case .chime:
            // Bright bells, like a doorbell: high-low, high-low.
            mix = silence(3.2)
            for (n, f) in [1318.5, 1046.5, 1318.5, 1046.5].enumerated() {
                mallet(&mix, at: Double(n) * 0.38, frequency: f, decay: 3.2, level: 0.32)
            }
        case .digital:
            // Short electronic beeps: three quick pairs.
            mix = silence(2.6)
            for n in 0..<3 {
                for k in 0..<2 {
                    add(&mix, at: Double(n) * 0.36 + Double(k) * 0.12, length: 0.08) { t in
                        sin(2 * .pi * 1400 * t) * 0.25
                    }
                }
            }
        case .gentle:
            // A slow, soft rise and fall, for quiet offices.
            mix = silence(3.6)
            for (n, f) in [587.33, 739.99, 880.0, 739.99].enumerated() {
                mallet(&mix, at: Double(n) * 0.42, frequency: f, decay: 2.4, level: 0.26)
            }
        }
        let samples = mix.map { Int16(max(-1, min(1, $0)) * Double(Int16.max)) }
        return Sounds.wav(samples, rate: rate)
    }

    private static func silence(_ seconds: Double) -> [Double] {
        [Double](repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// Adds a tone with 10 ms fades at both ends (no clicks).
    private static func add(_ mix: inout [Double], at start: Double, length: Double, wave: (Double) -> Double) {
        let first = Int(start * Double(rate)), count = Int(length * Double(rate))
        let fade = Double(rate) * 0.01
        for i in 0..<count where first + i < mix.count {
            let envelope = min(1, Double(min(i, count - 1 - i)) / fade)
            mix[first + i] += wave(Double(i) / Double(rate)) * envelope
        }
    }

    /// A struck note: instant attack, exponential decay, a little overtone.
    private static func mallet(_ mix: inout [Double], at start: Double, frequency: Double, decay: Double, level: Double) {
        let length = min(1.2, 5 / decay)
        add(&mix, at: start, length: length) { t in
            let tone = sin(2 * .pi * frequency * t) + 0.3 * sin(2 * .pi * frequency * 4 * t) * exp(-t * 20)
            return tone * exp(-t * decay) * level * min(1, t / 0.003)
        }
    }
}
