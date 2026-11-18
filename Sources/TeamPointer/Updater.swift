import AppKit
import Security

/// Keeps the app up to date from the project's GitHub Releases.
///
/// A release (made with scripts/release.sh) carries `JustShowUp-mac.zip`. The app
/// checks on launch and every few hours; when a newer version is out, the settings
/// gear gets a dot and the menu offers "Update to vX". Installing downloads the zip,
/// checks it is signed with the same certificate as this copy, swaps the app in
/// place and relaunches.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let download: URL
    }

    static let repository = "mudafakins/Just-Show-Up"
    static let macAsset = "JustShowUp-mac.zip"

    @Published private(set) var available: Release?
    @Published private(set) var isBusy = false

    /// Shows a short message in the panel (wired to the team's notice line).
    var onMessage: (String) -> Void = { _ in }
    /// Whether restarting now would interrupt anything (a room, a ringing call).
    var isIdle: () -> Bool = { true }

    static let autoKey = "autoUpdate"
    /// Install new versions without asking (on by default), when nothing is going on.
    static var installsAutomatically: Bool {
        UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true
    }

    private var timer: Timer?
    private var idleTimer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        Task {
            await check(userInitiated: false)
            await installIfIdle()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
        // A waiting update installs once I'm out of rooms and calls.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.installIfIdle() }
        }
    }

    /// Installs a waiting update when updating automatically and nothing is going on.
    func installIfIdle() async {
        guard Self.installsAutomatically, available != nil, !isBusy, isIdle() else { return }
        await install()
    }

    // MARK: checking

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                available = nil
                if userInitiated { onMessage("You're on the latest version (\(Self.currentVersion)).") }
                return
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }

            struct Payload: Decodable {
                struct Asset: Decodable { let name: String; let browser_download_url: URL }
                let tag_name: String
                let assets: [Asset]
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
            if Self.isNewer(version, than: Self.currentVersion),
               let asset = payload.assets.first(where: { $0.name == Self.macAsset }) {
                available = Release(version: version, download: asset.browser_download_url)
                if userInitiated { onMessage("Version \(version) is ready. Choose Update in settings.") }
            } else {
                available = nil
                if userInitiated { onMessage("You're on the latest version (\(Self.currentVersion)).") }
            }
        } catch {
            if userInitiated { onMessage("Couldn't check for updates. Check your internet connection.") }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: installing

    func install() async {
        guard let release = available, !isBusy else { return }
        isBusy = true
        onMessage("Downloading version \(release.version)…")
        do {
            let newApp = try await download(release)
            try relaunch(replacingWith: newApp)
        } catch {
            isBusy = false
            onMessage((error as? UpdateError)?.message ?? "Update failed: \(error.localizedDescription)")
        }
    }

    private func download(_ release: Release) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: release.download)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("JustShowUpUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path])
        try? FileManager.default.removeItem(at: file)

        guard let app = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.badDownload }

        // Only accept an app signed with the same certificate as this one, with the
        // same bundle ID, and actually newer.
        guard let mine = Self.signingCertificate(of: Bundle.main.bundleURL) else { throw UpdateError.unsignedSelf }
        guard Self.isValidlySigned(app), Self.signingCertificate(of: app) == mine else { throw UpdateError.untrusted }
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info?["CFBundleShortVersionString"] as? String,
              Self.isNewer(version, than: Self.currentVersion) else { throw UpdateError.untrusted }
        return app
    }

    /// Swaps the new app into place once this process has quit, then opens it.
    private func relaunch(replacingWith newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        // Opened straight from Downloads, macOS runs a read-only copy from a hidden
        // folder ("App Translocation"), which can't be replaced.
        guard !current.path.contains("/AppTranslocation/") else { throw UpdateError.translocated }
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable }

        let backup = newApp.deletingLastPathComponent().appendingPathComponent("previous.app")
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        mv "$2" "$4" || { open "$2"; exit 1; }
        if mv "$3" "$2"; then
          xattr -dr com.apple.quarantine "$2" 2>/dev/null
          rm -rf "$4"
        else
          mv "$4" "$2"
        fi
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "updater",
                             String(ProcessInfo.processInfo.processIdentifier),
                             current.path, newApp.path, backup.path]
        try process.run()
        NSApp.terminate(nil)
    }

    // MARK: helpers

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.badDownload }
    }

    private static func isValidlySigned(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    /// The leaf signing certificate of an app, or nil when it is ad-hoc signed.
    private static func signingCertificate(of app: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}

enum UpdateError: Error {
    case server, badDownload, untrusted, unsignedSelf, notWritable, translocated

    var message: String {
        switch self {
        case .server: "Couldn't download the update. Try again later."
        case .badDownload: "The update download was damaged. Try again."
        case .untrusted: "The update isn't signed by your team's certificate, so it wasn't installed."
        case .unsignedSelf: "This copy can't verify updates. Install the latest version by hand once."
        case .notWritable: "Can't replace the app here. Move it to the Applications folder, then try again."
        case .translocated: "macOS is running a temporary copy, so it can't update. Quit, drag Just Show Up! into Applications, open it from there, then update."
        }
    }
}
