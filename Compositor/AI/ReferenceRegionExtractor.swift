import CoreGraphics
import Foundation
import ImageIO

@MainActor
enum ReferenceRegionExtractor {
    static func execute(_ actions: [AIEditorAction], referenceURL: URL?, in session: EditorSession) throws -> [String] {
        let extractions = actions.filter { $0.type == "extract_reference_region" }
        guard !extractions.isEmpty else { return [] }
        guard let referenceURL,
              let source = CGImageSourceCreateWithURL(referenceURL as CFURL,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let document = session.document else { throw AIImageGenerationError.referenceMissing }
        var messages: [String] = []
        for action in extractions.prefix(16) {
            guard let sx = finite(action.sourceX), let sy = finite(action.sourceY),
                  let sw = finite(action.sourceWidth), let sh = finite(action.sourceHeight),
                  sw >= 1, sh >= 1 else { throw AIImageGenerationError.invalidRequest }
            let sourceRect = CGRect(x: sx, y: sy, width: sw, height: sh).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard sourceRect.width >= 1, sourceRect.height >= 1,
                  let cropped = image.cropping(to: sourceRect) else { throw AIImageGenerationError.invalidRequest }
            let width = finite(action.width) ?? sourceRect.width
            let height = finite(action.height) ?? sourceRect.height
            let x = finite(action.x) ?? (document.size.width - width) / 2
            let y = finite(action.y) ?? (document.size.height - height) / 2
            guard width >= 1, height >= 1 else { throw AIImageGenerationError.invalidRequest }
            let name = action.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.addPixelLayer(cropped, at: CGPoint(x: x, y: y),
                name: name?.isEmpty == false ? name! : L10n.text("Reference Extract"),
                editName: "Extract Reference Region", dropsSelection: false,
                displaySize: CGSize(width: width, height: height))
            messages.append(L10n.format("Extracted reference layer: %@", name?.isEmpty == false ? name! : L10n.text("Reference Extract")))
        }
        return messages
    }

    private static func finite(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return CGFloat(value)
    }
}
