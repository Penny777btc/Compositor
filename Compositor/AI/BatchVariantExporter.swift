import Foundation

actor BatchVariantExporter {
    static let shared = BatchVariantExporter()

    func export(_ snapshot: ProjectSnapshot, variants: [AIExportVariant], to folder: URL) async throws -> [URL] {
        var written: [URL] = []
        for (index, variant) in variants.prefix(20).enumerated() {
            try Task.checkCancellation()
            guard (1...30_000).contains(variant.width), (1...30_000).contains(variant.height),
                  variant.width * variant.height <= 100_000_000 else { throw ProjectError.tooLarge }
            let resized = try await ImageResizer.shared.resize(snapshot,
                to: ImageSizeOptions(width: variant.width, height: variant.height,
                                     resolution: snapshot.manifest.resolution ?? 72, sampling: .high))
            let base = safeName(variant.name, fallback: "Variant-\(index + 1)-\(variant.width)x\(variant.height)")
            let project = folder.appendingPathComponent(base).appendingPathExtension("comp")
            let png = folder.appendingPathComponent(base).appendingPathExtension("png")
            try await ProjectStore.shared.save(resized, to: project)
            try await ImageExporter.shared.exportPNG(resized, to: png)
            written += [project, png]
        }
        return written
    }

    private func safeName(_ value: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? fallback : cleaned).prefix(120))
    }
}
