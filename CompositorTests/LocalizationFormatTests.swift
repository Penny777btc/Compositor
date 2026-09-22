import Foundation
import Testing
@testable import Compositor

struct LocalizationFormatTests {
    @Test func malformedTranslationsFallBackInsteadOfCrashingFoundation() {
        let source = "New: %lld × %lld pixels · %@ uncompressed"
        #expect(!LocalizationFormatSignature.isCompatible(source: source,
            translation: "新尺寸：%1$lld × %2$lld 像素 · %@未压缩"))
        #expect(LocalizationFormatSignature.isCompatible(source: source,
            translation: "新尺寸：%1$lld × %2$lld 像素 · %3$@ 未压缩"))
        let rendered = L10n.format(source: source,
            translation: "新尺寸：%1$lld × %2$lld 像素 · %@未压缩",
            arguments: [Int64(640), Int64(480), "1 MB"], locale: Locale(identifier: "en_US_POSIX"))
        #expect(rendered == "New: 640 × 480 pixels · 1 MB uncompressed")
    }

    @Test func unsupportedOrIncompleteDirectivesFallBack() {
        for translation in ["%*lld", "%.*lld", "%1$*2$lld", "%lld %n", "%lld %Q", "%lld %", "%lld %2$", "%0$lld", "%2$lld"] {
            #expect(!LocalizationFormatSignature.isCompatible(source: "%lld", translation: translation),
                "Accepted unsafe translation: \(translation)")
            #expect(L10n.format(source: "%lld", translation: translation, arguments: [Int64(42)]) == "42")
        }
        #expect(!LocalizationFormatSignature.isCompatible(source: "%@", translation: "%s"))
        #expect(!LocalizationFormatSignature.isCompatible(source: "%lld", translation: "%d"))
        #expect(!LocalizationFormatSignature.parse("100%*lld").isValid)
        #expect(LocalizationFormatSignature.parse("1%@").arguments.count == 1)
        #expect(L10n.format(source: "%lld", translation: "%lld", arguments: []) == "%lld")
    }

    @Test func escapedPercentSignsDoNotConsumeArguments() {
        #expect(LocalizationFormatSignature.parse("%%d").arguments.isEmpty)
        #expect(LocalizationFormatSignature.parse("%%@ %%n").arguments.isEmpty)
        #expect(!LocalizationFormatSignature.isCompatible(source: "%d", translation: "%%d"))
        #expect(LocalizationFormatSignature.isCompatible(source: "%lld%%", translation: "%1$lld%%"))
        #expect(L10n.format(source: "%lld%%", translation: "%1$lld%%", arguments: [Int64(50)]) == "50%")
        #expect(LocalizationFormatSignature.parse("%%%lld").arguments.count == 1)
    }

    @Test func ordinaryPercentagesRemainLiteralCatalogText() {
        for (source, translation) in [
            ("%", "%"), ("100%", "100%"),
            ("Pixel Grid (800% and above)", "像素网格（800% 及以上）"),
            ("Auto: 120% of the font size.", "自动：字号的 120%。")
        ] {
            #expect(LocalizationFormatSignature.isCompatible(source: source, translation: translation))
            #expect(LocalizationFormatSignature.parse(source).arguments.isEmpty)
        }
        // Even an accidental call to the formatter must not interpret prose as "% a" or "% o".
        #expect(L10n.format(source: "800% and above", translation: "800% 及以上", arguments: []) == "800% and above")
    }

    @Test func positionalReorderingAndFixedPrecisionAreSupported() {
        #expect(LocalizationFormatSignature.isCompatible(source: "%@ %lld", translation: "%2$lld %1$@"))
        #expect(LocalizationFormatSignature.isCompatible(source: "%02lld %.2f", translation: "%2$.1f %1$04lld"))
        #expect(!LocalizationFormatSignature.isCompatible(source: "%@ %lld", translation: "%2$lld %@"))
        #expect(!LocalizationFormatSignature.isCompatible(source: "%@ %lld", translation: "%1$@ %1$@"))
    }

    @Test func everySimplifiedChineseEntryIsPresentAndMatchesItsEnglishSource() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = try #require(FileManager.default.enumerator(at: repository.appendingPathComponent("Compositor"),
            includingPropertiesForKeys: nil))
        let catalogs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "xcstrings" }
        #expect(!catalogs.isEmpty)
        for catalog in catalogs {
            let data = try Data(contentsOf: catalog)
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            for (key, rawEntry) in strings where !key.isEmpty {
                let entry = try #require(rawEntry as? [String: Any])
                let localizations = try #require(entry["localizations"] as? [String: Any], "Missing translations: \(key)")
                let english = localizations["en"] as? [String: Any]
                let englishUnit = english?["stringUnit"] as? [String: Any]
                let source = catalog.lastPathComponent == "InfoPlist.xcstrings" ? (englishUnit?["value"] as? String ?? key) : key
                if catalog.lastPathComponent == "InfoPlist.xcstrings", key == "NSHumanReadableCopyright", source.isEmpty { continue }
                let chinese = try #require(localizations["zh-Hans"] as? [String: Any], "Missing zh-Hans: \(key)")
                #expect([english, chinese].compactMap { $0 }.allSatisfy { $0["variations"] == nil && $0["substitutions"] == nil },
                    "Nested catalog entries require explicit validation support: \(key)")
                let unit = try #require(chinese["stringUnit"] as? [String: Any], "Missing translation unit: \(key)")
                let translation = try #require(unit["value"] as? String)
                #expect(!translation.isEmpty, "Empty translation: \(key)")
                #expect(unit["state"] as? String == "translated", "Translation needs review: \(key)")
                #expect(LocalizationFormatSignature.isCompatible(source: source, translation: translation),
                    "Placeholder mismatch: \(source.debugDescription) → \(translation.debugDescription)")
            }
        }
    }
}
