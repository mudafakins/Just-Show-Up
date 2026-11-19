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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let team = TeamStore()
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileSelfTest.runIfAsked()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon()
        // Dragging files onto the menu bar icon opens the panel, so they can be
        // dropped on a teammate (a click in Finder would otherwise close it).
        statusItem.button?.window?.registerForDraggedTypes([.fileURL])
        statusItem.button?.window?.delegate = self

        let host = NSHostingController(rootView: TeamPanel().environmentObject(team).environmentObject(updater).environmentObject(team.files))
        // Let the popover grow and shrink with the panel's content.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true

        // Being rung opens the panel so the ring is right there.
        team.onRing = { [weak self] in self?.showPopover() }

        updater.onMessage = { [weak self] message in self?.team.notice = message }
        updater.isIdle = { [weak self] in
            guard let team = self?.team else { return false }
            return team.call == nil && team.incomingRing == nil && !team.isSharingScreen
        }
        updater.start()
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

    // The menu bar icon's window, as a drop target.
    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard team.phase == .inTeam else { return [] }
        showPopover()
        return .copy
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        team.phase == .inTeam ? .copy : []
    }

    /// Dropped on the icon itself rather than on a teammate: nothing to do.
    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

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
