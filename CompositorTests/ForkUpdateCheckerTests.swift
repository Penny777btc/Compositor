import Foundation
import Testing
@testable import Compositor

struct ForkUpdateCheckerTests {
    @Test func versionsCompareEveryNumericComponent() throws {
        #expect(try #require(ForkVersion("1.2.10")) > #require(ForkVersion("1.2.9")))
        #expect(try #require(ForkVersion("1.2.2.10")) > #require(ForkVersion("1.2.2.9")))
        #expect(try #require(ForkVersion("1.2.2.1")) > #require(ForkVersion("1.2.2")))
        #expect(ForkVersion("1.2.2.0") == ForkVersion("1.2.2"))
        #expect(ForkVersion("01.002.2") == ForkVersion("1.2.2"))
    }

    @Test func malformedVersionsAreRejected() {
        for value in ["", ".1", "1.", "1..2", "v1.2.2", "1.2.2-beta", "1.2.-1", "1. 2", "１.2",
                      "1.2\n", "18446744073709551616", "1.2.3.4.5.6.7.8.9"] {
            #expect(ForkVersion(value) == nil, "Accepted malformed version: \(value)")
        }
    }

    @Test func newestNumericForkReleaseWinsRegardlessOfOrderingOrPrereleaseFlag() throws {
        let data = try fixture([
            release("1.2.9", prerelease: false),
            release("1.2.2.2"),
            release("1.2.10"),
            release("1.2.2.1"),
            release("9.0", tag: "v9.0"),
            release("8.0", draft: true)
        ])
        let result = try candidate(data)
        #expect(result?.version.rawValue == "1.2.10")
        #expect(result?.releaseURL.absoluteString == "https://github.com/Penny777btc/Compositor/releases/tag/zh-beta-v1.2.10")
    }

    @Test func equalAndOlderReleasesNeverPromptOrDowngrade() throws {
        #expect(try candidate(fixture([release("1.2.2.1"), release("1.2.2"), release("1.2.2.0")])) == nil)
        #expect(try candidate(fixture([])) == nil)
    }

    @Test func requiresTheFinishedDmgForThatExactVersion() throws {
        let data = try fixture([
            release("9.0", assetName: "Compositor.dmg"),
            release("8.0", assetName: "Compositor-ZH-Beta-7.0.dmg"),
            release("7.0", assetURL: "https://example.com/Compositor-ZH-Beta-7.0.dmg"),
            release("6.0", assetState: "new"),
            release("5.0", assetSize: 0),
            release("4.0", noAssets: true),
            release("1.2.3")
        ])
        #expect(try candidate(data)?.version.rawValue == "1.2.3")
    }

    @Test func rejectsUntrustedReleaseAndAssetLinks() throws {
        let path = "/Penny777btc/Compositor/releases/tag/zh-beta-v2.0"
        let invalidPages = [
            "http://github.com\(path)", "https://github.com.evil.example\(path)",
            "https://github.com@evil.example\(path)", "https://user@github.com\(path)",
            "https://github.com:443\(path)", "https://github.com\(path)?next=evil",
            "https://github.com\(path)#fragment", "https://github.com/robbietilton/Compositor/releases/tag/zh-beta-v2.0",
            "https://github.com/Penny777btc/Compositor/releases/tag/zh-beta-v3.0",
            "https://github.com/Penny777btc%2FCompositor/releases/tag/zh-beta-v2.0"
        ]
        for page in invalidPages {
            #expect(try candidate(fixture([release("2.0", pageURL: page)])) == nil, "Accepted URL: \(page)")
        }
        let mismatchedAsset = "https://github.com/Penny777btc/Compositor/releases/download/zh-beta-v3.0/Compositor-ZH-Beta-2.0.dmg"
        #expect(try candidate(fixture([release("2.0", assetURL: mismatchedAsset)])) == nil)
    }

    @Test func observesOnlyExplicitSystemRequirements() throws {
        let data = try fixture([
            release("5.0", body: "LSMinimumSystemVersion: 27.0"),
            release("4.0", body: "LSMinimumSystemVersion: unknown"),
            release("3.0", body: "macOS 99 mentioned in a comparison; this prose is not metadata."),
            release("2.0", body: "LSMinimumSystemVersion: 26.0")
        ])
        #expect(try candidate(data)?.version.rawValue == "3.0")
        #expect(try candidate(fixture([release("2.0", body: "LSMinimumSystemVersion: 26.0")]))?.version.rawValue == "2.0")
        #expect(try candidate(fixture([release("2.0", body: "LSMinimumSystemVersion: 26.1")])) == nil)
    }

    @Test func rejectsOversizedAndMalformedFeeds() throws {
        #expect(throws: (any Error).self) {
            try candidate(Data(repeating: 32, count: ForkReleaseFeed.maximumResponseBytes + 1))
        }
        #expect(throws: (any Error).self) { try candidate(Data("{\"message\":\"API rate limit exceeded\"}".utf8)) }
    }

    @MainActor @Test func automaticChecksDefaultOnAndPreferencePersistsWithoutStartingNetwork() throws {
        let suiteName = "ForkUpdateCheckerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let checker = ForkUpdateChecker(defaults: defaults, currentVersion: "1.2.2.1", canPresent: { false })
        #expect(checker.automaticallyChecksForUpdates)
        #expect(!checker.isChecking)
        checker.automaticallyChecksForUpdates = false
        let restored = ForkUpdateChecker(defaults: defaults, currentVersion: "1.2.2.1", canPresent: { false })
        #expect(!restored.automaticallyChecksForUpdates)
        checker.stop()
        restored.stop()
    }

    private func candidate(_ data: Data) throws -> ForkReleaseCandidate? {
        try ForkReleaseFeed.latestCandidate(in: data, newerThan: #require(ForkVersion("1.2.2.1")),
            runningSystemVersion: #require(ForkVersion("26.0")))
    }

    private func fixture(_ releases: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: releases)
    }

    private func release(_ version: String, tag: String? = nil, draft: Bool = false, prerelease: Bool = true,
                         pageURL: String? = nil, assetName: String? = nil, assetURL: String? = nil,
                         assetState: String = "uploaded", assetSize: Int = 100,
                         noAssets: Bool = false, body: String = "") -> [String: Any] {
        let releaseTag = tag ?? "zh-beta-v\(version)"
        let name = assetName ?? "Compositor-ZH-Beta-\(version).dmg"
        let asset: [String: Any] = [
            "name": name,
            "browser_download_url": assetURL ?? "https://github.com/Penny777btc/Compositor/releases/download/\(releaseTag)/\(name)",
            "state": assetState,
            "size": assetSize
        ]
        return ["tag_name": releaseTag, "draft": draft, "prerelease": prerelease, "body": body,
                "html_url": pageURL ?? "https://github.com/Penny777btc/Compositor/releases/tag/\(releaseTag)",
                "assets": noAssets ? [] : [asset]]
    }
}
