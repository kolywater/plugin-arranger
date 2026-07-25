import AppKit
import Foundation

/// In-app self-update, sourced from GitHub releases. Modelled on the Song
/// Manager updater.
///
/// Builds are Developer ID signed but deliberately not notarized, so a bundle
/// downloaded from the internet carries `com.apple.quarantine` and Gatekeeper
/// would block the relaunch. We strip that attribute on the new bundle before
/// swapping it in. That's fighting Gatekeeper's intent, and is only acceptable
/// because this is a personal app on the user's own Macs.
///
/// Before swapping, the download is checked to be signed by our team — see
/// `verifySignature`. That guards the accessibility grant: silently replacing
/// ourselves with an ad-hoc or differently-signed build would change the
/// designated requirement and make macOS drop the permission.
///
/// Release convention on `kolywater/plugin-arranger`:
///   - tag `v<version>` (e.g. `v1.5`), matching MARKETING_VERSION,
///   - a single `.zip` asset built with `ditto -c -k --keepParent`.
@MainActor
final class Updater {
    static let shared = Updater()
    private init() {}

    private let repo = "kolywater/plugin-arranger"
    private let teamID = "N8666MD6Y8"

    private var isBusy = false

    struct ReleaseInfo {
        let version: String      // raw tag, e.g. "v1.5"
        let notes: String
        let downloadURL: URL
    }

    /// The running app's version, e.g. "1.5".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Check

    /// Query GitHub for the latest release. A background check stays silent
    /// unless an update is found; a user-initiated one also reports
    /// "up to date" and failures.
    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let release = try await fetchLatestRelease()
            let current = Self.parseVersion(Self.currentVersion)
            let latest = Self.parseVersion(release.version)
            debugLog("Update check: current \(current), latest \(latest)")

            guard Self.isNewer(latest, than: current) else {
                if userInitiated {
                    inform("You're up to date", "PluginArranger \(Self.currentVersion) is the latest version.")
                }
                return
            }
            promptToInstall(release)
        } catch {
            debugLog("Update check failed: \(error.localizedDescription)")
            if userInitiated {
                inform("Couldn't check for updates", error.localizedDescription)
            }
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.noRelease
        }
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = decoded.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
              let downloadURL = URL(string: asset.browser_download_url) else {
            throw UpdateError.noAsset
        }
        return ReleaseInfo(version: decoded.tag_name, notes: decoded.body ?? "", downloadURL: downloadURL)
    }

    // MARK: - Version comparison

    /// "v1.5" / "1.5" → [1, 5]. Tolerates a leading "v".
    static func parseVersion(_ string: String) -> [Int] {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let stripped = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        return stripped.split(separator: ".").compactMap { Int($0) }
    }

    /// Component-wise compare, padding the shorter side with zeros so
    /// "1.5" and "1.5.0" are equal and "1.10" beats "1.9".
    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Prompt

    private func promptToInstall(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "PluginArranger \(release.version) is available"
        alert.informativeText = release.notes.isEmpty
            ? "You have \(Self.currentVersion)."
            : "You have \(Self.currentVersion).\n\n\(release.notes)"
        alert.addButton(withTitle: "Update and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { await install(release) }
    }

    private func inform(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Install

    /// Download, verify, swap in, relaunch. Does not return on success — the
    /// app terminates so a detached helper can replace the running bundle.
    private func install(_ release: ReleaseInfo) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let zipURL = try await download(release.downloadURL)
            try installZip(zipURL)   // relaunches + terminates
        } catch {
            debugLog("Update failed: \(error.localizedDescription)")
            inform("Update failed", error.localizedDescription)
        }
    }

    private func download(_ url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginArrangerUpdate-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private func installZip(_ zipURL: URL) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("PluginArrangerUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: zipURL) }

        // ditto preserves bundle structure / symlinks better than unzip.
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, workDir.path])

        guard let newApp = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.badArchive
        }

        // Strip Gatekeeper quarantine so the relaunch isn't blocked. Delete
        // only that attribute — `xattr -c` also tries to clear the protected
        // com.apple.macl / com.apple.provenance and fails.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        try verifySignature(newApp)

        let currentApp = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier

        // We can't reliably replace our own running bundle from inside the
        // process, so hand off to a detached shell: wait for us to quit,
        // swap the bundle, relaunch.
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(shellQuote(currentApp.path))
        /bin/mv \(shellQuote(newApp.path)) \(shellQuote(currentApp.path))
        /usr/bin/open \(shellQuote(currentApp.path))
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try task.run()

        debugLog("Update staged, terminating for swap")
        NSApp.terminate(nil)
    }

    /// Refuse to install anything not signed by our Developer ID team. A build
    /// signed by anyone else — or ad-hoc — would change the designated
    /// requirement and cost the user their accessibility grant.
    private func verifySignature(_ app: URL) throws {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \(teamID)"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "--strict", "-R=\(requirement)", app.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw UpdateError.untrustedSignature
        }
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw UpdateError.commandFailed(launchPath)
        }
        return task.terminationStatus
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Wire

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    enum UpdateError: LocalizedError {
        case noRelease, noAsset, downloadFailed, badArchive, untrustedSignature
        case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .noRelease: return "No release found on GitHub."
            case .noAsset: return "The latest release has no .zip asset."
            case .downloadFailed: return "Download failed."
            case .badArchive: return "The downloaded archive didn't contain an app."
            case .untrustedSignature: return "The downloaded app isn't signed by the expected team — refusing to install."
            case .commandFailed(let c): return "Update step failed (\(c))."
            }
        }
    }
}
