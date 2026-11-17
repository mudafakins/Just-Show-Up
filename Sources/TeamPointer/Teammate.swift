import SwiftUI

struct Teammate: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isOnline: Bool
    var colorIndex: Int
    var avatarPath: String? = nil

    /// The photo's public address in Supabase Storage.
    var avatarURL: URL? {
        guard let avatarPath, let base = Self.storageBase else { return nil }
        return base.appendingPathComponent("storage/v1/object/public/avatars").appendingPathComponent(avatarPath)
    }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    /// Each teammate gets a stable colour, reused later for their cursor and ink.
    var color: Color {
        Teammate.palette[colorIndex % Teammate.palette.count]
    }

    private static let storageBase = AppConfig.load()?.supabaseURL

    static let palette: [Color] = [.pink, .orange, .green, .teal, .blue, .purple, .yellow, .red]
}
