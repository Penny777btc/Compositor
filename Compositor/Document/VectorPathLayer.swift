import AppKit

nonisolated struct LayerPathPoint: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

nonisolated struct LayerPathColor: Codable, Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var palette: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

nonisolated struct LayerVectorPathStyle: Codable, Equatable, Sendable {
    var points: [LayerPathPoint]
    var stroke: LayerPathColor
    var fill: LayerPathColor?
    var lineWidth: CGFloat
    var closed: Bool
    var isValid: Bool {
        (2...256).contains(points.count) && points.allSatisfy(\.isValid) && stroke.isValid
            && (fill?.isValid ?? true) && lineWidth.isFinite && (0.5...2_000).contains(lineWidth)
            && (!closed || points.count >= 3)
    }
}

nonisolated struct LayerVectorPath: Equatable, @unchecked Sendable {
    var style: LayerVectorPathStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerVectorPathStyle?, image: CGImage?) -> LayerVectorPath? {
        guard let style, style.isValid, let image else { return nil }
        return LayerVectorPath(style: style, image: image)
    }
}

extension ImageLayer {
    var liveVectorPath: LayerVectorPath? {
        guard let vectorPath, let image = asset?.image, image === vectorPath.image else { return nil }
        return vectorPath
    }
}

extension EditorSession {
    @discardableResult
    func addVectorPathLayer(style: LayerVectorPathStyle, frame: CGRect, name: String? = nil) throws -> UUID {
        guard style.isValid, frame.width >= 1, frame.height >= 1,
              frame.width * frame.height <= CGFloat(Self.maxShapePixels) else { throw VectorPathLayerError.invalid }
        let image = try Self.vectorPathImage(style, size: frame.size)
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        addPixelLayer(image, at: frame.origin,
            name: title?.isEmpty == false ? title! : L10n.text("Vector Path"), editName: "New Vector Path",
            dropsSelection: false, vectorPath: LayerVectorPath(style: style, image: image))
        guard let activeLayerID else { throw VectorPathLayerError.render }
        return activeLayerID
    }

    func redrawVectorPath(at index: Int) {
        guard let layer = document?.layers[index], let vector = layer.liveVectorPath, let asset = layer.asset else { return }
        let width = max(1, Int(layer.transform.size.width.rounded()))
        let height = max(1, Int(layer.transform.size.height.rounded()))
        guard width * height <= Self.maxShapePixels,
              let image = try? Self.vectorPathImage(vector.style, size: CGSize(width: width, height: height)),
              let thumbnail = try? PixelAdjust.thumbnail(of: image) else { return }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].vectorPath = LayerVectorPath(style: vector.style, image: image)
    }

    static func vectorPathImage(_ style: LayerVectorPathStyle, size: CGSize) throws -> CGImage {
        guard style.isValid, size.width >= 1, size.height >= 1 else { throw VectorPathLayerError.invalid }
        let context = try BrushRaster.context(width: Int(size.width.rounded()), height: Int(size.height.rounded()), mask: false)
        let path = CGMutablePath()
        let first = style.points[0]
        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
        for point in style.points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
        }
        if style.closed { path.closeSubpath() }
        context.addPath(path)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(srgbRed: style.stroke.red, green: style.stroke.green,
            blue: style.stroke.blue, alpha: 1))
        if let fill = style.fill, style.closed {
            context.setFillColor(CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
            context.drawPath(using: .fillStroke)
        } else { context.strokePath() }
        guard let image = context.makeImage() else { throw VectorPathLayerError.render }
        return image
    }
}

nonisolated enum VectorPathLayerError: LocalizedError {
    case invalid, render
    var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("The vector path settings are invalid.")
        case .render: L10n.text("The vector path could not be rendered.")
        }
    }
}
