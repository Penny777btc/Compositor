import CoreGraphics
import ImageIO
import Vision

nonisolated struct AIReferenceTextObservation: Sendable, Equatable {
    let text: String
    let confidence: Float
    /// Pixel coordinates in the reference image, with a top-left origin like the editor canvas.
    let frame: CGRect
}

nonisolated struct AIReferenceRegionObservation: Sendable, Equatable {
    let kind: String
    let confidence: Float
    /// Candidate pixel bounds with a top-left origin. These are geometry hints, not semantic guarantees.
    let frame: CGRect
}

nonisolated struct AIReferenceLocalAnalysis: Sendable, Equatable {
    let width: Int
    let height: Int
    let texts: [AIReferenceTextObservation]
    let palette: [String]
    let regions: [AIReferenceRegionObservation]

    var promptContext: String {
        let textRows = texts.prefix(80).enumerated().map { index, item in
            "\(index + 1). text=\(item.text.debugDescription) confidence=\(String(format: "%.3f", item.confidence)) "
                + "frame=(x:\(Int(item.frame.minX.rounded())),y:\(Int(item.frame.minY.rounded())),"
                + "w:\(Int(item.frame.width.rounded())),h:\(Int(item.frame.height.rounded())))"
        }.joined(separator: "\n")
        let regionRows = regions.prefix(32).enumerated().map { index, item in
            "\(index + 1). kind=\(item.kind) confidence=\(String(format: "%.3f", item.confidence)) "
                + "frame=(x:\(Int(item.frame.minX.rounded())),y:\(Int(item.frame.minY.rounded())),"
                + "w:\(Int(item.frame.width.rounded())),h:\(Int(item.frame.height.rounded())))"
        }.joined(separator: "\n")
        return """
        Reference pixels: \(width) x \(height)
        Locally sampled palette: \(palette.joined(separator: ", "))
        Local OCR observations (top-left pixel coordinates):
        \(textRows.isEmpty ? "none" : textRows)
        Local candidate visual regions (top-left pixel coordinates; verify against the attached image):
        \(regionRows.isEmpty ? "none" : regionRows)
        """
    }
}

nonisolated enum ReferenceImageAnalyzer {
    static func analyze(_ url: URL) async throws -> AIReferenceLocalAnalysis {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AIImageGenerationError.referenceInvalid
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.006
            let rectangles = VNDetectRectanglesRequest()
            rectangles.maximumObservations = 32
            rectangles.minimumConfidence = 0.35
            rectangles.minimumSize = 0.04
            rectangles.minimumAspectRatio = 0.15
            rectangles.maximumAspectRatio = 1
            rectangles.quadratureTolerance = 18
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            try handler.perform([request, rectangles, saliency])
            let texts = (request.results ?? []).compactMap { observation -> AIReferenceTextObservation? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                let frame = CGRect(x: box.minX * CGFloat(image.width),
                    y: (1 - box.maxY) * CGFloat(image.height),
                    width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
                return AIReferenceTextObservation(text: candidate.string, confidence: candidate.confidence, frame: frame)
            }.sorted { left, right in
                if abs(left.frame.minY - right.frame.minY) > 4 { return left.frame.minY < right.frame.minY }
                return left.frame.minX < right.frame.minX
            }
            let rectangleRegions = (rectangles.results ?? []).map {
                AIReferenceRegionObservation(kind: "rectangle", confidence: $0.confidence,
                    frame: pixelFrame($0.boundingBox, width: image.width, height: image.height))
            }
            let salientRegions = (saliency.results?.first?.salientObjects ?? []).map {
                AIReferenceRegionObservation(kind: "salient", confidence: $0.confidence,
                    frame: pixelFrame($0.boundingBox, width: image.width, height: image.height))
            }
            let candidates = deduplicated(rectangleRegions + salientRegions,
                imageWidth: image.width, imageHeight: image.height)
            return AIReferenceLocalAnalysis(width: image.width, height: image.height,
                texts: texts, palette: try palette(image), regions: candidates)
        }.value
    }

    private static func pixelFrame(_ box: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(x: box.minX * CGFloat(width), y: (1 - box.maxY) * CGFloat(height),
            width: box.width * CGFloat(width), height: box.height * CGFloat(height))
    }

    private static func deduplicated(_ input: [AIReferenceRegionObservation],
                                     imageWidth: Int, imageHeight: Int) -> [AIReferenceRegionObservation] {
        let imageArea = CGFloat(imageWidth * imageHeight)
        var output: [AIReferenceRegionObservation] = []
        for candidate in input.sorted(by: { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }) {
            let area = candidate.frame.width * candidate.frame.height
            guard area >= imageArea * 0.002, area <= imageArea * 0.82 else { continue }
            let duplicate = output.contains { existing in
                let intersection = existing.frame.intersection(candidate.frame)
                guard !intersection.isNull else { return false }
                let overlap = intersection.width * intersection.height
                return overlap / min(area, existing.frame.width * existing.frame.height) > 0.82
            }
            if !duplicate { output.append(candidate) }
        }
        return output
    }

    private static func palette(_ image: CGImage) throws -> [String] {
        let width = 32, height = 32, bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw AIImageGenerationError.referenceInvalid
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts: [Int: Int] = [:]
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 32 {
            let r = Int(bytes[index]) >> 4, g = Int(bytes[index + 1]) >> 4, b = Int(bytes[index + 2]) >> 4
            counts[(r << 8) | (g << 4) | b, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(8).map { key, _ in
            let r = ((key >> 8) & 0xf) * 17, g = ((key >> 4) & 0xf) * 17, b = (key & 0xf) * 17
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }
}
