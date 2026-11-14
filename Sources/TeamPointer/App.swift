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
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconUpdates: AnyCancellable?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon()

        let host = NSHostingController(rootView: TeamPanel().environmentObject(team))
        // Let the popover grow and shrink with the panel's content.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true

        // objectWillChange fires before the value changes, so read it on the next run-loop turn.
        iconUpdates = team.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if let symbol = team.menuBarSymbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            // The app's mark. Drawn as text so it follows the menu bar's light/dark colour.
            button.image = nil
            button.font = NSFont.systemFont(ofSize: 14)
            button.title = TestTeammate.isActive ? "✦T" : "✦✦"
            button.setAccessibilityLabel(AppInfo.name)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        // Activate first so text fields in the popover can take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        watchForOutsideClicks()
        // Refresh the list each time the panel opens (new or removed teammates).
        if team.phase == .inTeam {
            Task { await team.reloadTeam() }
        }
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
