import AppKit
import SwiftUI

// Drawing on a shared screen.
//
// Every shared screen has one InkBoard, identified by the sharer's user id.
// Positions are normalised (0...1 across the shared content, origin top-left),
// so a stroke lands on the same spot on the sharer's real screen and in every
// viewer's window regardless of their sizes. Ink is never part of the video:
// each Mac draws it locally from these messages, which keeps it instant and sharp.

/// One drawing event, sent over the call's data channel.
struct InkMessage: Codable {
    enum Kind: String, Codable {
        case begin, points, end, cursor, leave, clear, info
    }

    var kind: Kind
    /// Whose shared screen this is about.
    var board: UUID
    var stroke: String?
    var points: [[Double]]?
    /// Whether the stroke fades away by itself.
    var fade: Bool?
    /// Width / height of the shared content (sent by the sharer).
    var aspect: Double?

    enum CodingKeys: String, CodingKey {
        case kind = "k", board = "b", stroke = "s", points = "p", fade = "f", aspect = "a"
    }
}

extension Notification.Name {
    static let inkBoardChanged = Notification.Name("inkBoardChanged")
}

enum InkSettings {
    static let keepInkKey = "keepInk"
    /// When true, new strokes stay until cleared instead of fading.
    static var keepInk: Bool { UserDefaults.standard.bool(forKey: keepInkKey) }

    static let holdBeforeFade: TimeInterval = 2.5
    static let fadeDuration: TimeInterval = 0.7
}

@MainActor
final class InkBoard {
    struct Stroke {
        let id: String
        let user: UUID
        var points: [CGPoint]
        let fade: Bool
        var endedAt: Date?
        var lastUpdate: Date
    }

    struct Cursor {
        var point: CGPoint
        var seen: Date
    }

    private(set) var strokes: [Stroke] = []
    private(set) var cursors: [UUID: Cursor] = [:]
    /// Width / height of the shared content, once known.
    var aspect: Double? {
        didSet { if aspect != oldValue { changed() } }
    }

    func apply(_ message: InkMessage, from user: UUID) {
        let now = Date()
        let points = (message.points ?? []).compactMap { pair -> CGPoint? in
            guard pair.count == 2 else { return nil }
            return CGPoint(x: min(max(pair[0], 0), 1), y: min(max(pair[1], 0), 1))
        }

        switch message.kind {
        case .begin:
            guard let id = message.stroke else { return }
            strokes.append(Stroke(
                id: id, user: user, points: points,
                fade: message.fade ?? true, endedAt: nil, lastUpdate: now
            ))
            if let last = points.last { cursors[user] = Cursor(point: last, seen: now) }
        case .points:
            guard let index = strokes.lastIndex(where: { $0.id == message.stroke && $0.user == user }) else { return }
            strokes[index].points.append(contentsOf: points)
            strokes[index].lastUpdate = now
            if let last = points.last { cursors[user] = Cursor(point: last, seen: now) }
        case .end:
            guard let index = strokes.lastIndex(where: { $0.id == message.stroke && $0.user == user }) else { return }
            strokes[index].endedAt = now
        case .cursor:
            if let point = points.last { cursors[user] = Cursor(point: point, seen: now) }
        case .leave:
            cursors[user] = nil
        case .clear:
            strokes.removeAll()
        case .info:
            if let aspect = message.aspect, aspect > 0 { self.aspect = aspect }
            return
        }
        changed()
    }

    func removeUser(_ user: UUID) {
        cursors[user] = nil
        changed()
    }

    func reset() {
        strokes.removeAll()
        cursors.removeAll()
        changed()
    }

    /// Opacity of a stroke right now (fading strokes dim, then disappear).
    func opacity(of stroke: Stroke, at now: Date) -> CGFloat {
        guard stroke.fade else { return 1 }
        // A stroke whose "end" never arrived (the drawer dropped) still fades.
        let end = stroke.endedAt ?? (now.timeIntervalSince(stroke.lastUpdate) > 5 ? stroke.lastUpdate : nil)
        guard let end else { return 1 }
        let age = now.timeIntervalSince(end) - InkSettings.holdBeforeFade
        if age <= 0 { return 1 }
        return max(0, 1 - age / InkSettings.fadeDuration)
    }

    /// Drops finished fades and stale cursors. Returns true while something is still animating.
    func tick(now: Date = Date()) -> Bool {
        strokes.removeAll { $0.fade && opacity(of: $0, at: now) <= 0 }
        cursors = cursors.filter { now.timeIntervalSince($0.value.seen) < 4 }
        return strokes.contains { $0.fade } || !cursors.isEmpty
    }

    private func changed() {
        NotificationCenter.default.post(name: .inkBoardChanged, object: self)
    }
}

/// Who people are, for colouring ink and labelling cursors.
@MainActor
struct InkPeople {
    var me: UUID
    var color: (UUID) -> NSColor
    var name: (UUID) -> String
}

/// Draws a board's ink and cursors, and (when interactive) turns mouse drags into strokes.
@MainActor
final class InkView: NSView {
    private let board: InkBoard
    private let people: InkPeople
    private let send: (InkMessage) -> Void
    /// Viewer windows letterbox the video, so ink must follow the same fitted rectangle.
    private let fitsAspect: Bool
    var fallbackAspect: Double?

    var isInteractive = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            if !isInteractive { finishStroke() }
        }
    }

    private var animation: Timer?
    private var activeStroke: String?
    private var pending: [CGPoint] = []
    private var lastFlush = Date.distantPast
    private var lastCursorSent = Date.distantPast
    private var observer: NSObjectProtocol?

    init(board: InkBoard, people: InkPeople, fitsAspect: Bool, send: @escaping (InkMessage) -> Void) {
        self.board = board
        self.people = people
        self.fitsAspect = fitsAspect
        self.send = send
        super.init(frame: .zero)
        observer = NotificationCenter.default.addObserver(
            forName: .inkBoardChanged, object: board, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.boardChanged() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isInteractive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if isInteractive { addCursorRect(contentRect, cursor: .crosshair) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    /// Where the shared content sits inside this view.
    private var contentRect: CGRect {
        guard fitsAspect, let aspect = board.aspect ?? fallbackAspect, aspect > 0,
              bounds.width > 0, bounds.height > 0
        else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    private func viewPoint(_ normalised: CGPoint) -> CGPoint {
        let rect = contentRect
        return CGPoint(x: rect.minX + normalised.x * rect.width, y: rect.minY + normalised.y * rect.height)
    }

    private func normalised(_ event: NSEvent) -> CGPoint? {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    // MARK: Drawing

    private func boardChanged() {
        needsDisplay = true
        if animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.animate() }
            }
        }
    }

    private func animate() {
        let stillAnimating = board.tick()
        needsDisplay = true
        if !stillAnimating {
            animation?.invalidate()
            animation = nil
        }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        let rect = contentRect
        let lineWidth = max(3, rect.width * 0.0035)

        for stroke in board.strokes {
            let alpha = board.opacity(of: stroke, at: now)
            guard alpha > 0, let first = stroke.points.first else { continue }
            let color = people.color(stroke.user).withAlphaComponent(alpha)
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: viewPoint(first))
            if stroke.points.count == 1 {
                // A single tap: draw a dot.
                path.line(to: viewPoint(first))
            }
            for point in stroke.points.dropFirst() {
                path.line(to: viewPoint(point))
            }
            color.setStroke()
            path.stroke()
        }

        for (user, cursor) in board.cursors where user != people.me {
            drawCursor(at: viewPoint(cursor.point), color: people.color(user), name: people.name(user))
        }
    }

    private func drawCursor(at point: CGPoint, color: NSColor, name: String) {
        // Pointer arrow (the view is flipped, so y grows downwards).
        let arrow = NSBezierPath()
        arrow.move(to: point)
        arrow.line(to: CGPoint(x: point.x, y: point.y + 17))
        arrow.line(to: CGPoint(x: point.x + 4.5, y: point.y + 13))
        arrow.line(to: CGPoint(x: point.x + 12, y: point.y + 12.5))
        arrow.close()
        arrow.lineJoinStyle = .round
        arrow.lineWidth = 1.5
        color.setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.stroke()

        // Name tag.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let label = name.components(separatedBy: " ").first ?? name
        let textSize = (label as NSString).size(withAttributes: attributes)
        let tag = CGRect(x: point.x + 12, y: point.y + 16, width: textSize.width + 12, height: textSize.height + 4)
        let pill = NSBezierPath(roundedRect: tag, xRadius: tag.height / 2, yRadius: tag.height / 2)
        color.setFill()
        pill.fill()
        (label as NSString).draw(at: CGPoint(x: tag.minX + 6, y: tag.minY + 2), withAttributes: attributes)
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        guard isInteractive, let point = normalised(event),
              (0...1).contains(point.x), (0...1).contains(point.y)
        else { return }
        let id = UUID().uuidString
        activeStroke = id
        pending = []
        lastFlush = Date()
        var message = InkMessage(kind: .begin, board: boardID)
        message.stroke = id
        message.points = [[point.x, point.y]]
        message.fade = !InkSettings.keepInk
        send(message)
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeStroke != nil, let point = normalised(event) else { return }
        pending.append(CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1)))
        // Batch points so a fast drag is a few dozen messages a second, not hundreds.
        if Date().timeIntervalSince(lastFlush) > 0.03 { flush() }
    }

    override func mouseUp(with event: NSEvent) {
        finishStroke()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive, activeStroke == nil, let point = normalised(event) else { return }
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        guard Date().timeIntervalSince(lastCursorSent) > 0.035 else { return }
        lastCursorSent = Date()
        var message = InkMessage(kind: .cursor, board: boardID)
        message.points = [[point.x, point.y]]
        send(message)
    }

    override func mouseExited(with event: NSEvent) {
        guard isInteractive, activeStroke == nil else { return }
        send(InkMessage(kind: .leave, board: boardID))
    }

    private func flush() {
        guard let id = activeStroke, !pending.isEmpty else { return }
        var message = InkMessage(kind: .points, board: boardID)
        message.stroke = id
        message.points = pending.map { [$0.x, $0.y] }
        pending = []
        lastFlush = Date()
        send(message)
    }

    private func finishStroke() {
        guard let id = activeStroke else { return }
        flush()
        activeStroke = nil
        var message = InkMessage(kind: .end, board: boardID)
        message.stroke = id
        send(message)
    }

    /// Set by whoever creates the view: the sharer this board belongs to.
    var boardID = UUID()
}

/// A click-through, see-through window laid over the sharer's own screen (or the one
/// shared window) where everyone's ink and cursors appear.
@MainActor
final class SharerOverlay {
    enum Target {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private let window: OverlayWindow
    private let inkView: InkView
    private let target: Target
    private var follow: Timer?
    private var escapeMonitor: Any?
    /// Called when the user presses Esc to leave draw mode.
    var onExitDrawMode: (() -> Void)?

    /// Width / height of what is being shared, for viewers to letterbox ink the same way.
    var aspect: Double? {
        let size = window.frame.size
        return size.height > 0 ? Double(size.width / size.height) : nil
    }

    init(board: InkBoard, boardID: UUID, people: InkPeople, target: Target, send: @escaping (InkMessage) -> Void) {
        self.target = target
        window = OverlayWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        inkView = InkView(board: board, people: people, fitsAspect: false, send: send)
        inkView.boardID = boardID
        inkView.autoresizingMask = [.width, .height]
        window.contentView = inkView

        updateFrame()
        window.orderFrontRegardless()

        if case .window = target {
            // Follow the shared window as it moves or resizes.
            follow = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrame() }
            }
        }
    }

    private func updateFrame() {
        switch target {
        case .display(let id):
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            } ?? NSScreen.main
            if let frame = screen?.frame, frame != window.frame {
                window.setFrame(frame, display: true)
            }
        case .window(let id):
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                  let primary = NSScreen.screens.first
            else {
                // Minimised, hidden or closed: nothing to draw over.
                if window.isVisible { window.orderOut(nil) }
                return
            }
            // CoreGraphics measures from the top-left of the primary screen; AppKit from its bottom-left.
            let frame = CGRect(
                x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
                width: bounds.width, height: bounds.height
            )
            if frame != window.frame { window.setFrame(frame, display: true) }
            if !window.isVisible { window.orderFrontRegardless() }
        }
    }

    /// Draw mode lets the sharer draw on their own screen; otherwise clicks pass straight through.
    func setDrawMode(_ on: Bool) {
        window.ignoresMouseEvents = !on
        inkView.isInteractive = on
        if on {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if escapeMonitor == nil {
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53 else { return event } // Esc
                    self?.onExitDrawMode?()
                    return nil
                }
            }
        } else if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    func close() {
        setDrawMode(false)
        follow?.invalidate()
        follow = nil
        window.orderOut(nil)
    }
}

/// The small control strip in a viewer window: keep-ink toggle and clear.
struct InkControls: View {
    @AppStorage(InkSettings.keepInkKey) private var keepInk = false
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { keepInk.toggle() } label: {
                Image(systemName: keepInk ? "pin.fill" : "pin.slash")
                    .frame(width: 26, height: 22)
            }
            .help(keepInk ? "Drawings stay until cleared. Click to make them fade." : "Drawings fade. Click to keep them until cleared.")

            Button(action: clear) {
                Image(systemName: "eraser")
                    .frame(width: 26, height: 22)
            }
            .help("Clear all drawings")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .padding(8)
    }
}
