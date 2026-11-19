import AppKit

/// The sound for an incoming call. Each person picks their own in Settings →
/// Ringtone: one of the sound clips that ship with the app (Ringtones/), or one of
/// the simple tones generated in code.
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

    /// One entry in the ringtone list.
    struct Choice: Identifiable, Hashable {
        enum Source: Hashable { case clip(URL), generated(Style) }
        let id: String
        let title: String
        let source: Source
    }

    static let styleKey = "ringtone"

    /// The bundled clips, in file-name order ("01 - Title.mp3" shows as "Title").
    static let clips: [Choice] = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Ringtones"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { ["mp3", "m4a", "wav"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                let title = name.replacingOccurrences(of: #"^\d+\s*-\s*"#, with: "", options: .regularExpression)
                return Choice(id: "clip:" + name, title: title, source: .clip(url))
            }
    }()

    static let tones: [Choice] = Style.allCases.map { Choice(id: $0.rawValue, title: $0.title, source: .generated($0)) }

    static var all: [Choice] { clips + tones }

    /// The first clip, unless the app was built without them.
    static var defaultID: String { clips.first?.id ?? Style.classic.rawValue }

    static var current: Choice {
        let saved = UserDefaults.standard.string(forKey: styleKey) ?? defaultID
        return all.first { $0.id == saved } ?? all.first { $0.id == defaultID } ?? tones[0]
    }

    private static var sound: NSSound?
    private static var repeatTimer: Timer?
    private static var preview: NSSound?

    static func start() {
        stop()
        stopPreview()
        let choice = current
        guard let sound = makeSound(choice) else { return }
        sound.volume = 0.8
        switch choice.source {
        case .generated:
            sound.loops = true
            sound.play()
        case .clip:
            // Play the clip, pause a moment, play it again: back to back, short
            // clips would blur into one long noise.
            sound.play()
            let gap = max(sound.duration, 0.5) + 1.2
            repeatTimer = Timer.scheduledTimer(withTimeInterval: gap, repeats: true) { _ in
                Task { @MainActor in
                    Ringtone.sound?.stop()
                    Ringtone.sound?.play()
                }
            }
        }
        self.sound = sound
    }

    static func stop() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        sound?.stop()
        sound = nil
    }

    /// Plays a ringtone once, for choosing one in Settings.
    static func playPreview(_ choice: Choice) {
        stopPreview()
        guard sound == nil, let sound = makeSound(choice) else { return }
        sound.volume = 0.8
        sound.play()
        preview = sound
    }

    static func stopPreview() {
        preview?.stop()
        preview = nil
    }

    private static func makeSound(_ choice: Choice) -> NSSound? {
        switch choice.source {
        case .clip(let url): NSSound(contentsOf: url, byReference: true)
        case .generated(let style): NSSound(data: makeWAV(style))
        }
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

/// The soundboard: the ringtone clips, played once on a click (one at a time, so
/// rapid clicks don't pile up into noise).
@MainActor
enum Soundboard {
    private static var sound: NSSound?
    private static var lastStart = Date.distantPast

    static var clips: [Ringtone.Choice] { Ringtone.clips }

    static func play(_ id: String) {
        guard Date().timeIntervalSince(lastStart) > 0.25,
              let choice = Ringtone.clips.first(where: { $0.id == id }),
              case .clip(let url) = choice.source,
              let next = NSSound(contentsOf: url, byReference: true) else { return }
        lastStart = Date()
        sound?.stop()
        next.volume = 0.8
        next.play()
        sound = next
    }

    /// A picture for each clip's tile, from its name ("Hey Hey 3" → 👋).
    static func emoji(for title: String) -> String {
        let name = title.lowercased()
        let table: [(String, String)] = [
            ("title theme", "🎬"), ("intro", "🎺"), ("hey hey", "👋"), ("laugh", "😂"),
            ("aaiye", "🙏"), ("dramatic", "😱"), ("yes", "🙌"), ("turr", "💨"),
            ("flute", "🎶"), ("nahi", "🙅"), ("uhh", "😩"), ("haaa", "😮"),
            ("tabla", "🥁"), ("uii", "😵"), ("soap", "📺"), ("funny", "🤪"), ("locha", "🤯"),
        ]
        return table.first { name.contains($0.0) }?.1 ?? "🔊"
    }
}
