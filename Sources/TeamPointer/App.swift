import SwiftUI

@main
struct TeamPointerApp: App {
    @StateObject private var team = TeamStore()

    var body: some Scene {
        MenuBarExtra {
            TeamPanel()
                .environmentObject(team)
        } label: {
            Image(systemName: team.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
