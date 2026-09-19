import Foundation
import Testing
@testable import Compositor

struct LocalizationFormatTests {
    @Test func malformedTranslationsFallBackInsteadOfReachingFoundationFormatting() {
        let source = "New: %lld × %lld pixels · %@ uncompressed"
        let malformed = "新尺寸：%1$lld × %2$lld 像素 · %@未压缩"
        let corrected = "新尺寸：%1$lld × %2$lld 像素 · %3$@ 未压缩"
        #expect(!LocalizationFormatSignature.isCompatible(source: source, translation: malformed))
        #expect(LocalizationFormatSignature.isCompatible(source: source, translation: corrected))
        #expect(LocalizationFormatSignature.isCompatible(source: "%lld%%", translation: "%lld%%"))
    }

    @Test func everySimplifiedChineseFormatMatchesItsSourceKey() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Localizable.xcstrings", "InfoPlist.xcstrings"] {
            let url = repository.appendingPathComponent("Compositor").appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            for (source, rawEntry) in strings {
                guard let entry = rawEntry as? [String: Any],
                      let localizations = entry["localizations"] as? [String: Any],
                      let chinese = localizations["zh-Hans"] as? [String: Any],
                      let unit = chinese["stringUnit"] as? [String: Any],
                      let translation = unit["value"] as? String else { continue }
                #expect(LocalizationFormatSignature.isCompatible(source: source, translation: translation),
                    "Placeholder mismatch in \(name): \(source.debugDescription) → \(translation.debugDescription)")
            }
        }
    }
}
