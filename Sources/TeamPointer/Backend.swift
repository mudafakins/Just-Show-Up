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

/// "Test teammate" mode: a second copy of the app on the same Mac that joins the team
/// as its own person and answers calls by itself, so one Mac can try everything.
/// Started from the gear menu, which launches the app again with these arguments.
enum TestTeammate {
    static let isActive = CommandLine.arguments.contains("--dummy")
    static let name = "Test Buddy"

    /// The team code passed with `--join CODE`.
    static var joinCode: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--join"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
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
        // The test teammate keeps its own identity, separate from the real one on this Mac.
        let folder = TestTeammate.isActive ? "JustShowUp/session-test-teammate" : "JustShowUp/session"
        directory = base.appendingPathComponent(folder, isDirectory: true)
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
    let name: String
    let colorIndex: Int
    let teamID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, name
        case colorIndex = "color_index"
        case teamID = "team_id"
    }
}

struct TeamRow: Decodable {
    let code: String
}

/// What each online app publishes on the team's presence channel.
struct PresenceState: Codable {
    let userID: String
    /// Whether this person is in the team room. Missing from older builds.
    var inRoom: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case inRoom = "in_room"
    }
}

func makeSupabaseClient(_ config: AppConfig) -> SupabaseClient {
    SupabaseClient(
        supabaseURL: config.supabaseURL,
        supabaseKey: config.supabaseKey,
        options: SupabaseClientOptions(
            auth: .init(storage: FileSessionStorage())
        )
    )
}

func friendlyMessage(_ error: Error) -> String {
    if let error = error as? PostgrestError { return error.message }
    // Edge Functions answer errors as {"error": "..."}; show that text rather than a bare status code.
    if case let FunctionsError.httpError(code, data) = error {
        if let body = try? JSONDecoder().decode([String: String].self, from: data), let message = body["error"] {
            return message
        }
        return "The server answered with error \(code)."
    }
    return error.localizedDescription
}
