import AppKit
import Foundation
import Observation

/// Fork versions have numeric components, including the fourth component used for localization releases.
nonisolated struct ForkVersion: Comparable, Sendable {
    let rawValue: String
    private let components: [UInt64]

    init?(_ value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 80, (1...8).contains(pieces.count),
              pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = pieces.compactMap { UInt64($0) }
        guard numbers.count == pieces.count else { return nil }
        rawValue = value
        components = numbers
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

nonisolated struct ForkReleaseCandidate: Sendable {
    let version: ForkVersion
    let releaseURL: URL
}

nonisolated enum ForkReleaseFeed {
    static let endpoint = URL(string: "https://api.github.com/repos/Penny777btc/Compositor/releases?per_page=20")!
    static let maximumResponseBytes = 1_048_576

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let body: String?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let state: String
        let size: Int64
    }

    static func latestCandidate(in data: Data, newerThan current: ForkVersion,
                                runningSystemVersion: ForkVersion) throws -> ForkReleaseCandidate? {
        guard data.count <= maximumResponseBytes else { throw ForkUpdateError.responseTooLarge }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> ForkReleaseCandidate? in
            let prefix = "zh-beta-v"
            guard !release.draft, release.tag_name.hasPrefix(prefix),
                  let version = ForkVersion(String(release.tag_name.dropFirst(prefix.count))), version > current,
                  let page = trustedGitHubURL(release.html_url,
                    path: "/Penny777btc/Compositor/releases/tag/\(release.tag_name)") else { return nil }

            // Only an explicit metadata line defines a requirement. Prose in release notes is not inferred.
            // Maintainers can add `LSMinimumSystemVersion: 26.0` when a release raises the requirement.
            let requirementLines = (release.body ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("LSMinimumSystemVersion:") }
            for line in requirementLines {
                let value = String(line.dropFirst("LSMinimumSystemVersion:".count)).trimmingCharacters(in: .whitespaces)
                guard let minimum = ForkVersion(value), minimum <= runningSystemVersion else { return nil }
            }

            let assetName = "Compositor-ZH-Beta-\(version.rawValue).dmg"
            guard release.assets.contains(where: { asset in
                asset.name == assetName && asset.state == "uploaded" && asset.size > 0
                    && trustedGitHubURL(asset.browser_download_url,
                        path: "/Penny777btc/Compositor/releases/download/\(release.tag_name)/\(assetName)") != nil
            }) else { return nil }
            // GitHub prereleases are deliberately included: they are how the Chinese fork is published.
            return ForkReleaseCandidate(version: version, releaseURL: page)
        }.max { $0.version < $1.version }
    }

    static func trustedGitHubURL(_ value: String, path: String) -> URL? {
        guard let components = URLComponents(string: value), components.scheme == "https",
              components.host == "github.com", components.port == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == path else { return nil }
        return components.url
    }
}

nonisolated private enum ForkUpdateError: Error {
    case invalidCurrentVersion, invalidResponse, responseTooLarge
}

/// Never follow redirects: this check may contact only the configured GitHub API endpoint.
nonisolated private final class ForkUpdateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private actor ForkReleaseLoader {
    func load(current: ForkVersion, systemVersion: ForkVersion) async throws -> ForkReleaseCandidate? {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: ForkReleaseFeed.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Compositor-ZH-Beta-Update-Checker", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: ForkUpdateRedirectPolicy())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == ForkReleaseFeed.endpoint else { throw ForkUpdateError.invalidResponse }
        guard response.expectedContentLength <= ForkReleaseFeed.maximumResponseBytes else {
            throw ForkUpdateError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < ForkReleaseFeed.maximumResponseBytes else { throw ForkUpdateError.responseTooLarge }
            data.append(byte)
        }
        return try ForkReleaseFeed.latestCandidate(in: data, newerThan: current, runningSystemVersion: systemVersion)
    }
}

/// Checks this fork's releases and opens their release page only when requested. It never downloads or installs code.
@MainActor @Observable
final class ForkUpdateChecker {
    var automaticallyChecksForUpdates: Bool {
        didSet {
            defaults.set(automaticallyChecksForUpdates, forKey: Self.enabledKey)
            if automaticallyChecksForUpdates {
                checkAutomaticallyIfDue()
            } else {
                if !wantsManualResult { cancelCheck() }
                if pendingResult?.isManual == false { cancelPresentation() }
            }
        }
    }
    private(set) var isChecking = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let canPresent: () -> Bool
    @ObservationIgnored private let loader = ForkReleaseLoader()
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var pendingResult: PendingResult?
    @ObservationIgnored private var wantsManualResult = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var isPresenting = false

    private static let enabledKey = "forkUpdates.automaticallyChecks"
    private static let lastCheckKey = "forkUpdates.lastCheck"
    private static let notifiedVersionKey = "forkUpdates.lastNotifiedVersion"
    private static let interval: TimeInterval = 24 * 60 * 60

    private enum Outcome {
        case available(ForkReleaseCandidate)
        case current
        case failed
    }
    private struct PendingResult {
        let outcome: Outcome
        let isManual: Bool
    }

    init(defaults: UserDefaults = .standard,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         canPresent: @escaping () -> Bool) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.canPresent = canPresent
        automaticallyChecksForUpdates = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard !started else { return }
        started = true
        // Activation alone misses an editor left open for days. The hourly wake only checks whether
        // the 24-hour interval has elapsed; it does not fetch while the app is inactive or checks are disabled.
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60 * 60)) } catch { return }
                guard let self else { return }
                self.checkAutomaticallyIfDue()
            }
        }
        launchTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self else { return }
            self.launchTask = nil
            self.ready = true
            self.checkAutomaticallyIfDue()
        }
    }

    func applicationDidBecomeActive() { checkAutomaticallyIfDue() }

    func stop() {
        started = false
        ready = false
        launchTask?.cancel()
        launchTask = nil
        periodicTask?.cancel()
        periodicTask = nil
        cancelCheck()
        cancelPresentation()
    }

    func checkForUpdates() { beginCheck(manual: true) }

    private func checkAutomaticallyIfDue() {
        guard started, ready, automaticallyChecksForUpdates, NSApp.isActive else { return }
        let now = Date()
        if let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(lastCheck) < Self.interval, lastCheck.timeIntervalSince(now) < 60 { return }
        beginCheck(manual: false)
    }

    private func beginCheck(manual: Bool) {
        guard !isPresenting else { return }
        if !manual, pendingResult != nil { return }
        if checkTask != nil {
            wantsManualResult = wantsManualResult || manual
            return
        }
        if manual { cancelPresentation() }
        wantsManualResult = manual
        isChecking = true
        defaults.set(Date(), forKey: Self.lastCheckKey)
        let id = UUID()
        requestID = id
        checkTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let outcome: Outcome
            do {
                guard let current = ForkVersion(self.currentVersion) else { throw ForkUpdateError.invalidCurrentVersion }
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let systemVersion = ForkVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")!
                if let release = try await self.loader.load(current: current, systemVersion: systemVersion) {
                    outcome = .available(release)
                } else {
                    outcome = .current
                }
            } catch {
                outcome = .failed
            }
            guard !Task.isCancelled, self.requestID == id else { return }
            let manual = self.wantsManualResult
            self.checkTask = nil
            self.requestID = nil
            self.wantsManualResult = false
            self.isChecking = false
            if !manual {
                guard self.automaticallyChecksForUpdates, case .available(let release) = outcome else { return }
                if let previous = self.defaults.string(forKey: Self.notifiedVersionKey).flatMap(ForkVersion.init),
                   release.version <= previous { return }
            }
            self.pendingResult = PendingResult(outcome: outcome, isManual: manual)
            self.schedulePresentation()
        }
    }

    private func cancelCheck() {
        checkTask?.cancel()
        checkTask = nil
        requestID = nil
        wantsManualResult = false
        isChecking = false
    }

    private func cancelPresentation() {
        presentationTask?.cancel()
        presentationTask = nil
        pendingResult = nil
    }

    private func schedulePresentation() {
        guard presentationTask == nil else { return }
        presentationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let pending = self.pendingResult else { return }
                if NSApp.isActive && NSApp.modalWindow == nil && NSEvent.pressedMouseButtons == 0
                    && !NSApp.windows.contains(where: { $0.attachedSheet != nil }) && self.canPresent() {
                    self.pendingResult = nil
                    self.presentationTask = nil
                    self.present(pending)
                    return
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func present(_ result: PendingResult) {
        isPresenting = true
        defer { isPresenting = false }
        let alert = NSAlert()
        switch result.outcome {
        case .available(let release):
            alert.messageText = L10n.text("Fork Update Available")
            alert.informativeText = L10n.format("Compositor ZH Beta %@ is available. You’re using %@.\n\nThis is an unofficial Chinese fork. Open its GitHub release page to review the notes and download the update.", release.version.rawValue, currentVersion)
            alert.addButton(withTitle: L10n.text("Open Release Page"))
            alert.addButton(withTitle: L10n.text("Later"))
            let response = alert.runModal()
            // A deferred alert is not a notification. Persist only after the alert actually appeared.
            let previous = defaults.string(forKey: Self.notifiedVersionKey).flatMap(ForkVersion.init)
            if previous == nil || release.version > previous! {
                defaults.set(release.version.rawValue, forKey: Self.notifiedVersionKey)
            }
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(release.releaseURL) }
        case .current:
            alert.messageText = L10n.text("No Fork Updates Found")
            alert.informativeText = L10n.format("You’re using Compositor ZH Beta %@. No newer compatible release was found on this fork’s release page.", currentVersion)
            alert.addButton(withTitle: L10n.text("OK"))
            alert.runModal()
        case .failed:
            alert.messageText = L10n.text("Couldn’t Check for Fork Updates")
            alert.informativeText = L10n.text("Please check your internet connection and try again later.")
            alert.addButton(withTitle: L10n.text("OK"))
            alert.runModal()
        }
    }
}
