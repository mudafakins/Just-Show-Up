import SwiftUI
import Combine

@main
struct TeamPointerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The app lives entirely in the menu bar; this empty scene only satisfies SwiftUI.
        Settings { EmptyView() }
    }
}

/// Owns the menu bar icon and the popover (with its arrow) that drops from it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let team = TeamStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconUpdates: AnyCancellable?

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
        popover.animates = true

        // objectWillChange fires before the value changes, so read it on the next run-loop turn.
        iconUpdates = team.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: team.menuBarSymbol, accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate first so text fields in the popover can take keyboard focus.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Refresh the list each time the panel opens (new or removed teammates).
            if team.phase == .inTeam {
                Task { await team.reloadTeam() }
            }
        }
    }
}
