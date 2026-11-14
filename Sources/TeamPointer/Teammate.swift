import SwiftUI

struct Teammate: Identifiable, Equatable {
    let id: UUID
    var name: String
    var email: String
    var isOnline: Bool
    var colorIndex: Int

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    /// Each teammate gets a stable colour, reused later for their cursor and ink.
    var color: Color {
        Teammate.palette[colorIndex % Teammate.palette.count]
    }

    static let palette: [Color] = [.pink, .orange, .green, .teal, .blue, .purple, .yellow, .red]
}
