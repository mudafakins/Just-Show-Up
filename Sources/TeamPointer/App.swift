import SwiftUI
import Combine

// A plain AppKit entry point. A SwiftUI `App` would need a scene, and the only
// windowless one (Settings) opens an empty Settings window on Cmd+comma.
@main
enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = makeMainMenu()
        app.run()
    }

    /// The menu bar is never visible (the app has no Dock icon), but text fields
    /// rely on these items for Cmd+C / Cmd+V / Cmd+A and friends.
    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }
}

/// Owns the menu bar icon and the popover (with its arrow) that drops from it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let team = TeamStore()
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    /// The panel, shown in the popover (menu bar style) or the window (window style).
    private var host: NSHostingController<AnyView>!
    /// The normal window used in window style.
    private var window: NSWindow?
    private var style = AppStyle.current

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ColorSelfTest.runIfAsked()
        #endif
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon()

        host = NSHostingController(rootView: AnyView(TeamPanel().environmentObject(team).environmentObject(updater)))
        // Let the popover (or window) grow and shrink with the panel's content.
        host.sizingOptions = .preferredContentSize
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        applyStyle(showWindow: true)

        // Switch style as soon as it changes in Settings.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AppStyle.current != self.style else { return }
                self.style = AppStyle.current
                self.applyStyle(showWindow: true)
            }
        }

        // Being rung opens the panel so the ring is right there.
        team.onRing = { [weak self] in self?.showForRing() }

        updater.onMessage = { [weak self] message in self?.team.notice = message }
        updater.isIdle = { [weak self] in
            guard let team = self?.team else { return false }
            return team.call == nil && team.incomingRing == nil && !team.isSharingScreen
        }
        updater.start()
        #if DEBUG
        RingSelfTest.runIfAsked(team: team)
        #endif
    }

    /// The menu bar always shows the app's mark, whatever the app is doing.
    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // Drawn as text so it follows the menu bar's light/dark colour.
        button.image = nil
        button.font = NSFont.systemFont(ofSize: 14)
        button.title = "✦✦"
        button.setAccessibilityLabel(AppInfo.name)
    }

    // MARK: App style

    /// Menu bar style: a popover under the menu bar icon, no Dock icon.
    /// Window style: a normal window and a Dock icon; the menu bar icon stays too.
    private func applyStyle(showWindow: Bool) {
        switch style {
        case .menuBar:
            window?.contentViewController = nil
            window?.orderOut(nil)
            popover.contentViewController = host
            NSApp.setActivationPolicy(.accessory)
        case .window:
            if popover.isShown { popover.performClose(nil) }
            popover.contentViewController = nil
            NSApp.setActivationPolicy(.regular)
            let window = self.window ?? makeWindow()
            window.contentViewController = host
            if showWindow { self.showWindow() }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = AppInfo.name
        // The panel already shows the name; keep the title bar clean.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        self.window = window
        return window
    }

    private func showWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshTeam()
    }

    /// Someone is calling me: bring the panel up so the ring is right there.
    private func showForRing() {
        switch style {
        case .menuBar:
            showPopover()
        case .window:
            // Front without stealing focus; the Dock icon bounces until I come to the app.
            window?.orderFrontRegardless()
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if style == .window { showWindow() }
        return true
    }

    private func refreshTeam() {
        // Refresh the list each time the panel opens (new or removed teammates).
        if team.phase == .inTeam {
            Task { await team.reloadTeam() }
        }
    }

    @objc private func togglePopover() {
        if style == .window { return showWindow() }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard style == .menuBar, let button = statusItem.button, !popover.isShown else { return }
        // Activate first so text fields in the popover can take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        watchForOutsideClicks()
        refreshTeam()
    }

    /// `.transient` alone misses clicks in other apps when ours isn't the active app,
    /// so also watch for clicks anywhere outside our own windows.
    private func watchForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown { popover.performClose(nil) }
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Closing the window hides it; the app keeps running so calls still ring.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

/// How the app shows itself, chosen in Settings → App Style.
enum AppStyle: String, CaseIterable {
    case menuBar, window

    static let key = "appStyle"

    static var current: AppStyle {
        UserDefaults.standard.string(forKey: key).flatMap(AppStyle.init(rawValue:)) ?? .menuBar
    }

    var title: String {
        switch self {
        case .menuBar: "Menu Bar"
        case .window: "Window and Dock"
        }
    }
}
