import AppKit
import CryptoKit
import UserNotifications

/// Update discovery and delivery for the macOS IME.
///
/// The IME is a background agent with no window of its own, so an update is:
///   1. a daily `GET` of the release feed (UpdateFeed), throttled to once per
///      `checkInterval` and skipped for placeholder `0.0.0` builds;
///   2. when the feed is ahead of this build, one user notification per new
///      version plus a live entry in the Input menu (InputController.menu());
///   3. on request, a download of the matching `.pkg` — verified against the
///      feed's SHA-256 — handed to Installer.app. That is the very installer a
///      double-click on the release asset runs, admin prompt included, and its
///      postinstall restarts the IME, so nothing here needs privileges.
///
/// The check sends nothing but the request itself (no identifiers beyond a
/// `User-Agent` naming this app and its version). It can be switched off from
/// the menu; the state lives in the app's UserDefaults.
///
/// Everything mutates state on the main thread; URLSession callbacks hop back
/// to it before touching `phase` or defaults.
final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    /// Where the manager currently is; the menu mirrors it.
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
    }

    /// A release newer than this build.
    struct Available: Equatable {
        let tag: String
        let version: ReleaseVersion
        let pageURL: URL
        /// The `.pkg` for this machine's arch — nil when the release has none
        /// (then the release page is the fallback).
        let installer: ReleaseAsset?
    }

    enum UpdateError: Error {
        case network(Error?)
        case status(Int)
        case digestMismatch
        case filesystem(Error)
    }

    private enum Key {
        static let autoCheck = "JdUpdateAutoCheck"
        static let lastCheck = "JdUpdateLastCheck"
        static let latestTag = "JdUpdateLatestTag"
        static let latestPage = "JdUpdateLatestPage"
        static let installerName = "JdUpdateInstallerName"
        static let installerURL = "JdUpdateInstallerURL"
        static let installerSize = "JdUpdateInstallerSize"
        static let installerSHA256 = "JdUpdateInstallerSHA256"
        static let notifiedTag = "JdUpdateNotifiedTag"
    }

    private let defaults = UserDefaults.standard
    private let session: URLSession
    private(set) var phase: Phase = .idle

    /// This build's version — `CFBundleShortVersionString`, which
    /// build-pkg.sh sets from core/build.zig.zon. Nil when it isn't a
    /// well-formed release version.
    let currentVersion: ReleaseVersion?

    private override init() {
        let bundleVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        currentVersion = ReleaseVersion(bundleVersion)

        // Ephemeral: no cookies, no cache — the feed is fetched once a day
        // and the installer once per version, so caching has nothing to add.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": "ime-jd-macos/\(bundleVersion)"]
        session = URLSession(configuration: config)
        super.init()
    }

    // MARK: - Settings & recorded state

    var isAutoCheckEnabled: Bool {
        get { defaults.object(forKey: Key.autoCheck) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoCheck) }
    }

    /// The newest release the feed has reported, if it is ahead of this
    /// build. Persisted, so it survives the IME being relaunched.
    var availableUpdate: Available? {
        guard let current = currentVersion,
              let tag = defaults.string(forKey: Key.latestTag),
              let version = ReleaseVersion(tag), version > current,
              let page = defaults.string(forKey: Key.latestPage).flatMap(URL.init(string:))
        else { return nil }
        var installer: ReleaseAsset?
        if let name = defaults.string(forKey: Key.installerName),
           let url = defaults.string(forKey: Key.installerURL).flatMap(URL.init(string:)) {
            installer = ReleaseAsset(
                name: name,
                url: url,
                size: defaults.integer(forKey: Key.installerSize),
                sha256: defaults.string(forKey: Key.installerSHA256)
            )
        }
        return Available(tag: tag, version: version, pageURL: page, installer: installer)
    }

    private func record(_ latest: LatestRelease) {
        defaults.set(latest.tag, forKey: Key.latestTag)
        defaults.set(latest.pageURL.absoluteString, forKey: Key.latestPage)
        let name = UpdateFeed.installerName(tag: latest.tag, arch: UpdateFeed.hostArch)
        if let asset = latest.asset(named: name) {
            defaults.set(asset.name, forKey: Key.installerName)
            defaults.set(asset.url.absoluteString, forKey: Key.installerURL)
            defaults.set(asset.size, forKey: Key.installerSize)
            defaults.set(asset.sha256, forKey: Key.installerSHA256)
        } else {
            for key in [Key.installerName, Key.installerURL, Key.installerSize, Key.installerSHA256] {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Checking

    /// The automatic path: silently, at most once per `checkInterval`, only
    /// when enabled and only for real release builds. Called on every server
    /// activation and at launch; it costs one defaults read when nothing is
    /// due.
    func checkIfDue() {
        guard isAutoCheckEnabled, let current = currentVersion, !current.isPlaceholder else { return }
        if let last = defaults.object(forKey: Key.lastCheck) as? Date,
           Date().timeIntervalSince(last) < UpdateFeed.checkInterval {
            return
        }
        check(interactive: false)
    }

    /// The menu path: always runs, and reports the outcome in an alert.
    func checkNow() {
        check(interactive: true)
    }

    private func check(interactive: Bool) {
        guard phase == .idle else { return }
        phase = .checking
        // Stamp before the request, so a failing feed is retried tomorrow
        // rather than on every activation.
        defaults.set(Date(), forKey: Key.lastCheck)

        var request = URLRequest(url: UpdateFeed.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .idle
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data, let latest = LatestRelease(json: data) else {
                    NSLog("JdIME: update check failed (HTTP %d): %@", status,
                          error?.localizedDescription ?? "unusable payload")
                    if interactive {
                        self.alertCheckFailed(status: status, error: error)
                    }
                    return
                }
                NSLog("JdIME: update check: latest %@ (this build %@)", latest.tag, self.currentVersionText)
                self.record(latest)
                self.report(latest, interactive: interactive)
            }
        }.resume()
    }

    private func report(_ latest: LatestRelease, interactive: Bool) {
        guard let current = currentVersion, latest.version > current else {
            if interactive {
                alertUpToDate()
            }
            return
        }
        if interactive {
            alertUpdateAvailable(latest)
        } else if defaults.string(forKey: Key.notifiedTag) != latest.tag {
            // One notification per new version; the menu keeps showing it.
            defaults.set(latest.tag, forKey: Key.notifiedTag)
            notifyUpdateAvailable(latest.tag)
        }
    }

    // MARK: - Installing

    /// Download the installer for `availableUpdate`, verify it, and hand it
    /// to Installer.app. Falls back to opening the release page when the
    /// release has no installer for this machine.
    func downloadAndInstall() {
        guard let update = availableUpdate else { return }
        guard let installer = update.installer else {
            open(update.pageURL)
            return
        }
        guard phase == .idle else { return }
        phase = .downloading

        session.downloadTask(with: installer.url) { [weak self] location, response, error in
            // Stage synchronously: URLSession deletes the temporary file as
            // soon as this closure returns.
            let staged: Result<URL, UpdateError>
            if let location {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                staged = status == 200
                    ? UpdateManager.stage(location, as: installer)
                    : .failure(.status(status))
            } else {
                staged = .failure(.network(error))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .idle
                switch staged {
                case .success(let pkg):
                    // Installer.app takes it from here: admin prompt, the
                    // payload copy, and the postinstall that restarts us.
                    NSWorkspace.shared.open(pkg)
                case .failure(let failure):
                    NSLog("JdIME: update download failed: %@", String(describing: failure))
                    self.alertDownloadFailed(failure, page: update.pageURL)
                }
            }
        }.resume()
    }

    /// Verify the download against the feed's SHA-256 and move it into this
    /// app's cache directory. Runs on the URLSession queue.
    private static func stage(_ location: URL, as installer: ReleaseAsset) -> Result<URL, UpdateError> {
        do {
            if let expected = installer.sha256 {
                let data = try Data(contentsOf: location)
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { return .failure(.digestMismatch) }
            }
            let fm = FileManager.default
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = caches
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.hronro.ime-jd", isDirectory: true)
                .appendingPathComponent("updates", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent(installer.name)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            return .success(destination)
        } catch {
            return .failure(.filesystem(error))
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Notifications

    /// Route notification clicks to the install. Call once at launch, before
    /// any notification can be delivered.
    func installNotificationDelegate() {
        // Not under XCTest: the test host runs straight out of DerivedData,
        // where UNUserNotificationCenter finds no Launch Services record for
        // the process and aborts it.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    private func notifyUpdateAvailable(_ tag: String) {
        let center = UNUserNotificationCenter.current()
        // Authorization is requested lazily, the first time there is
        // something to say; the menu entry covers users who decline.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "键道输入法有新版本"
            content.body = "\(tag) 已发布，点击下载并安装。"
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "update-\(tag)", content: content, trigger: nil))
        }
    }

    // MARK: - Alerts

    private var currentVersionText: String {
        currentVersion.map(String.init(describing:)) ?? "0.0.0"
    }

    private func alertUpToDate() {
        runAlert(
            title: "已是最新版本",
            text: "键道输入法 \(currentVersionText) 已经是最新版本。",
            buttons: ["好"]
        )
    }

    private func alertUpdateAvailable(_ latest: LatestRelease) {
        let hasInstaller = availableUpdate?.installer != nil
        let text = hasInstaller
            ? "当前版本 \(currentVersionText)。下载完成后将自动打开安装器，安装时需要输入管理员密码。"
            : "当前版本 \(currentVersionText)。此版本没有适用于本机的安装包，请前往发布页面下载。"
        let response = runAlert(
            title: "发现新版本 \(latest.tag)",
            text: text,
            buttons: [hasInstaller ? "下载并安装" : "前往发布页面", "查看更新说明", "稍后"]
        )
        switch response {
        case .alertFirstButtonReturn:
            downloadAndInstall()
        case .alertSecondButtonReturn:
            open(latest.pageURL)
        default:
            break
        }
    }

    private func alertCheckFailed(status: Int, error: Error?) {
        let reason = error?.localizedDescription ?? (status == 0 ? "服务器没有返回可用的版本信息" : "HTTP \(status)")
        let response = runAlert(
            title: "无法检查更新",
            text: "\(reason)\n\n可以稍后再试，或手动前往发布页面查看。",
            buttons: ["前往发布页面", "好"],
            style: .warning
        )
        if response == .alertFirstButtonReturn {
            open(UpdateFeed.releasesPageURL)
        }
    }

    private func alertDownloadFailed(_ failure: UpdateError, page: URL) {
        let reason: String
        switch failure {
        case .network(let error): reason = error?.localizedDescription ?? "网络错误"
        case .status(let code): reason = "HTTP \(code)"
        case .digestMismatch: reason = "下载的文件校验失败（SHA-256 不匹配），已放弃安装"
        case .filesystem(let error): reason = error.localizedDescription
        }
        let response = runAlert(
            title: "下载安装包失败",
            text: "\(reason)\n\n可以稍后再试，或手动前往发布页面下载。",
            buttons: ["前往发布页面", "好"],
            style: .warning
        )
        if response == .alertFirstButtonReturn {
            open(page)
        }
    }

    @discardableResult
    private func runAlert(
        title: String, text: String, buttons: [String], style: NSAlert.Style = .informational
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        buttons.forEach { alert.addButton(withTitle: $0) }
        // We are an accessory app; without this the panel opens behind the
        // frontmost app's windows.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        return alert.runModal()
    }
}

extension UpdateManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            downloadAndInstall()
        }
        completionHandler()
    }
}
