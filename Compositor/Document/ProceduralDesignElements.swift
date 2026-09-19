import CoreGraphics
import Foundation

nonisolated enum ProceduralDesignElements {
    static func tornPaperPoints(size: CGSize, roughness: CGFloat, seed: Int) -> [LayerPathPoint] {
        let width = max(1, size.width), height = max(1, size.height)
        let rough = min(max(0, roughness), min(width, height) * 0.2)
        let segmentsX = min(56, max(6, Int(width / 34)))
        let segmentsY = min(56, max(4, Int(height / 30)))
        var random = SeededRandom(seed: UInt64(bitPattern: Int64(seed)))
        func jitter() -> CGFloat { rough * CGFloat(random.nextUnit()) }
        var points: [CGPoint] = []
        for index in 0...segmentsX {
            points.append(CGPoint(x: width * CGFloat(index) / CGFloat(segmentsX), y: jitter()))
        }
        for index in 1...segmentsY {
            points.append(CGPoint(x: width - jitter(), y: height * CGFloat(index) / CGFloat(segmentsY)))
        }
        for index in stride(from: segmentsX - 1, through: 0, by: -1) {
            points.append(CGPoint(x: width * CGFloat(index) / CGFloat(segmentsX), y: height - jitter()))
        }
        if segmentsY > 1 {
            for index in stride(from: segmentsY - 1, through: 1, by: -1) {
                points.append(CGPoint(x: jitter(), y: height * CGFloat(index) / CGFloat(segmentsY)))
            }
        }
        return points.prefix(256).map { LayerPathPoint(x: min(1, max(0, $0.x / width)),
                                                        y: min(1, max(0, $0.y / height))) }
    }

    static func grainImage(width: Int, height: Int, seed: Int) throws -> CGImage {
        guard width > 0, height > 0, width * height <= 4_194_304 else { throw ProceduralElementError.invalid }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 255, count: bytesPerRow * height)
        var random = SeededRandom(seed: UInt64(bitPattern: Int64(seed)))
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let value = UInt8(truncatingIfNeeded: random.next() >> 24)
            bytes[offset] = value
            bytes[offset + 1] = value
            bytes[offset + 2] = value
        }
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let image = context.makeImage() else { throw ProceduralElementError.render }
        return image
    }

    private struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func nextUnit() -> Double { Double(next() & 0xffff) / Double(0xffff) }
    }
}

nonisolated enum ProceduralElementError: Error { case invalid, render }

extension EditorSession {
    @discardableResult
    func addGrainOverlay(frame: CGRect, intensity: Double, seed: Int, name: String? = nil) throws -> UUID {
        guard document != nil, frame.width >= 1, frame.height >= 1, intensity.isFinite,
              (0.01...0.8).contains(intensity) else { throw ProceduralElementError.invalid }
        let scale = min(1, 1024 / max(frame.width, frame.height))
        let width = max(64, Int((frame.width * scale).rounded()))
        let height = max(64, Int((frame.height * scale).rounded()))
        let image = try ProceduralDesignElements.grainImage(width: width, height: height, seed: seed)
        addPixelLayer(image, at: frame.origin, name: name ?? L10n.text("Paper Grain"),
            editName: "Add Paper Grain", dropsSelection: false)
        guard let id = activeLayerID, let index = document?.layers.firstIndex(where: { $0.id == id }) else {
            throw ProceduralElementError.render
        }
        document?.layers[index].transform.size = frame.size
        document?.layers[index].opacity = intensity
        document?.layers[index].blendMode = .overlay
        return id
    }
}
