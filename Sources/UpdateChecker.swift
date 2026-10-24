import AppKit

/// Checks GitHub Releases for a newer SwiftShot build.
///
/// SwiftShot is signed ad-hoc, so a downloaded update cannot silently replace
/// the running app (and macOS ties the Screen Recording grant to the code
/// signature anyway). Instead the checker notifies and hands the release to
/// the user: one click opens the release zip in the browser, and the user
/// drags the new app over the old one — settings live in UserDefaults and
/// survive the swap.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let releasesURL = URL(string: "https://api.github.com/repos/luongndcoder/SwiftShot/releases/latest")!
    private let defaults = UserDefaults.standard
    private var isChecking = false

    private enum Key {
        static let lastCheck = "updateLastCheckDate"
        static let skippedVersion = "updateSkippedVersion"
    }

    private enum CheckResult {
        case newer(version: String, downloadURL: URL)
        case upToDate
        case failed
    }

    /// The running app's marketing version (e.g. "1.2.0").
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Automatic check, run at launch: at most once a day, silent when there
    /// is nothing new (a version the user chose to skip stays silent too).
    func checkAutomaticallyIfDue() {
        if let last = defaults.object(forKey: Key.lastCheck) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        check(manual: false)
    }

    /// Manual checks (from the menu) always report the outcome.
    func check(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        Task { [weak self] in
            let result = await self?.fetchLatest()
            await MainActor.run {
                guard let self else { return }
                self.isChecking = false
                self.defaults.set(Date(), forKey: Key.lastCheck)
                switch result {
                case .newer(let version, let url):
                    if !manual, self.defaults.string(forKey: Key.skippedVersion) == version { return }
                    self.presentUpdateAlert(version: version, downloadURL: url)
                case .upToDate:
                    if manual {
                        self.presentSimpleAlert(
                            title: "You're up to date",
                            message: "SwiftShot \(self.currentVersion) is the latest version."
                        )
                    }
                case .failed, nil:
                    if manual {
                        self.presentSimpleAlert(
                            title: "Couldn't check for updates",
                            message: "Please check your internet connection and try again."
                        )
                    }
                }
            }
        }
    }

    // MARK: - GitHub

    private func fetchLatest() async -> CheckResult {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .failed }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isVersion(latest, newerThan: currentVersion) else { return .upToDate }

        // Prefer the release zip; fall back to the release page.
        var downloadURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String, name.hasSuffix(".zip"),
                   let urlString = asset["browser_download_url"] as? String,
                   let url = URL(string: urlString) {
                    downloadURL = url
                    break
                }
            }
        }
        guard let downloadURL else { return .failed }
        return .newer(version: latest, downloadURL: downloadURL)
    }

    /// Numeric dotted-version comparison ("1.10.0" > "1.9.0").
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Alerts

    private func presentUpdateAlert(version: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = "SwiftShot \(version) is available"
        alert.informativeText = "You're running SwiftShot \(currentVersion). Download the update, unzip it, and replace SwiftShot in your Applications folder — your settings are kept."
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(downloadURL)
        case .alertThirdButtonReturn:
            defaults.set(version, forKey: Key.skippedVersion)
        default:
            break
        }
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
