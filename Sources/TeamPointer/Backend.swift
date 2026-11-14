import Foundation
import Supabase

/// Keys loaded from Config.json inside the app bundle
/// (copied from the Git-ignored Config.local.json by scripts/build-app.sh).
struct AppConfig: Decodable {
    let supabaseURL: URL
    let supabaseKey: String

    static func load() -> AppConfig? {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data),
              config.supabaseURL.host?.contains("YOUR-PROJECT") == false
        else { return nil }
        return config
    }
}

enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Just Show Up!"
    }
}

/// Keeps the sign-in session in a private file instead of the Keychain.
/// Unsigned (ad-hoc) builds get a new signature on every rebuild, which would
/// make the Keychain ask for permission each time.
struct FileSessionStorage: AuthLocalStorage {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("JustShowUp/session", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func file(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe)
    }

    func store(key: String, value: Data) throws {
        let url = file(key)
        try value.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func retrieve(key: String) throws -> Data? {
        try? Data(contentsOf: file(key))
    }

    func remove(key: String) throws {
        try? FileManager.default.removeItem(at: file(key))
    }
}

/// A row of the `profiles` table.
struct ProfileRow: Decodable {
    let id: UUID
    let email: String
    let name: String
    let colorIndex: Int
    let teamID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, email, name
        case colorIndex = "color_index"
        case teamID = "team_id"
    }
}

struct InviteRow: Decodable {
    let email: String
}

/// What each online app publishes on the team's presence channel.
struct PresenceState: Codable {
    let userID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

func makeSupabaseClient(_ config: AppConfig) -> SupabaseClient {
    SupabaseClient(
        supabaseURL: config.supabaseURL,
        supabaseKey: config.supabaseKey,
        options: SupabaseClientOptions(
            // Implicit flow: we sign in by typing the emailed code, never by opening a link.
            auth: .init(storage: FileSessionStorage(), flowType: .implicit)
        )
    )
}

func friendlyMessage(_ error: Error) -> String {
    if let error = error as? PostgrestError { return error.message }
    return error.localizedDescription
}
