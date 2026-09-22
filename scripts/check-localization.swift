#!/usr/bin/env swift
import Foundation

// Run from any directory: swift /path/to/repository/scripts/check-localization.swift [repository-path]
// Compile the production parser together with this checker so validation cannot drift from runtime behavior.
let repository = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let validationProgram = #"""
let repository = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COMPOSITOR_LOCALIZATION_REPOSITORY"]!)
var failures: [String] = []
var checked = 0
var skipped = 0
var catalogCount = 0
func fail(_ catalog: URL, _ key: String, _ message: String) {
    failures.append("\(catalog.lastPathComponent): \(key.debugDescription): \(message)")
}
do {
    guard let enumerator = FileManager.default.enumerator(at: repository.appendingPathComponent("Compositor"),
        includingPropertiesForKeys: nil) else { throw CocoaError(.fileReadNoSuchFile) }
    let catalogs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "xcstrings" }.sorted { $0.path < $1.path }
    if catalogs.isEmpty { failures.append("No .xcstrings catalogs found under Compositor.") }
    for catalog in catalogs {
        catalogCount += 1
        let data = try Data(contentsOf: catalog)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            fail(catalog, "", "Invalid string catalog structure."); continue
        }
        if root["sourceLanguage"] as? String != "en" {
            fail(catalog, "", "Expected English source language.")
        }
        for key in strings.keys.sorted() {
            if key.isEmpty { skipped += 1; continue }
            guard let entry = strings[key] as? [String: Any] else {
                fail(catalog, key, "Invalid catalog entry."); continue
            }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            let english = localizations["en"] as? [String: Any]
            let englishUnit = english?["stringUnit"] as? [String: Any]
            let source = catalog.lastPathComponent == "InfoPlist.xcstrings"
                ? (englishUnit?["value"] as? String ?? key) : key
            if catalog.lastPathComponent == "InfoPlist.xcstrings", key == "NSHumanReadableCopyright", source.isEmpty {
                skipped += 1; continue
            }
            guard let chinese = localizations["zh-Hans"] as? [String: Any] else {
                fail(catalog, key, "Missing zh-Hans translation."); continue
            }
            if [english, chinese].compactMap({ $0 }).contains(where: { $0["variations"] != nil || $0["substitutions"] != nil }) {
                fail(catalog, key, "Nested variations/substitutions are not yet supported; add explicit validation before use.")
                continue
            }
            guard let unit = chinese["stringUnit"] as? [String: Any], let translation = unit["value"] as? String,
                  !translation.isEmpty else {
                fail(catalog, key, "Missing or empty zh-Hans stringUnit value."); continue
            }
            if unit["state"] as? String != "translated" {
                fail(catalog, key, "zh-Hans translation is not marked translated.")
            }
            if !LocalizationFormatSignature.isCompatible(source: source, translation: translation) {
                fail(catalog, key, "Invalid or incompatible format: \(source.debugDescription) → \(translation.debugDescription)")
            }
            checked += 1
        }
    }
} catch {
    failures.append("Could not read catalogs: \(error.localizedDescription)")
}
print("Checked \(checked) Chinese translations in \(catalogCount) catalogs; skipped \(skipped) empty keys/copyright values.")
print("Scope: catalog completeness and supported printf signatures only. UI extraction, dynamic-label coverage, layout, and call-site argument types still require review.")
if failures.isEmpty {
    print("Localization validation passed.")
} else {
    failures.forEach { print("ERROR: \($0)") }
    exit(1)
}
"""#

do {
    let runtime = try String(contentsOf: repository.appendingPathComponent("Compositor/Localization.swift"), encoding: .utf8)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-localization-swift-cache", isDirectory: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", "-module-cache-path", cache.path, "-e", runtime + "\n" + validationProgram]
    var environment = ProcessInfo.processInfo.environment
    environment["COMPOSITOR_LOCALIZATION_REPOSITORY"] = repository.path
    process.environment = environment
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("Localization checker failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
