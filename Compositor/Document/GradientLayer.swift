import AppKit

nonisolated enum LayerGradientKind: String, Codable, CaseIterable, Sendable {
    case linear, radial
}

nonisolated struct LayerGradientStop: Codable, Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var location: CGFloat
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isValid: Bool {
        [red, green, blue, location].allSatisfy(\.isFinite)
            && [red, green, blue, location].allSatisfy { (0...1).contains($0) }
    }
}

/// Editable metadata for a smooth gradient layer. The PNG stored beside it remains a compatibility preview.
nonisolated struct LayerGradientStyle: Codable, Equatable, Sendable {
    var kind: LayerGradientKind = .linear
    var stops: [LayerGradientStop]
    /// Degrees clockwise from left to right for a linear gradient.
    var angle: CGFloat = 0
    /// Unit coordinates used as the center of a radial gradient.
    var centerX: CGFloat = 0.5
    var centerY: CGFloat = 0.5

    var isValid: Bool {
        (2...12).contains(stops.count) && stops.allSatisfy(\.isValid)
            && zip(stops, stops.dropFirst()).allSatisfy { pair in pair.0.location <= pair.1.location }
            && stops.first?.location == 0 && stops.last?.location == 1
            && angle.isFinite && abs(angle) <= 360_000
            && centerX.isFinite && (0...1).contains(centerX)
            && centerY.isFinite && (0...1).contains(centerY)
    }
}

nonisolated struct LayerGradient: Equatable, @unchecked Sendable {
    var style: LayerGradientStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerGradientStyle?, image: CGImage?) -> LayerGradient? {
        guard let style, style.isValid, let image else { return nil }
        return LayerGradient(style: style, image: image)
    }
}

extension ImageLayer {
    var liveGradient: LayerGradient? {
        guard let gradient, let image = asset?.image, image === gradient.image else { return nil }
        return gradient
    }
}

extension EditorSession {
    @discardableResult
    func addGradientLayer(style: LayerGradientStyle, frame: CGRect, name: String? = nil) throws -> UUID {
        guard style.isValid, frame.width >= 1, frame.height >= 1,
              frame.width.isFinite, frame.height.isFinite,
              frame.width * frame.height <= CGFloat(Self.maxShapePixels) else { throw GradientLayerError.invalid }
        let image = try Self.gradientImage(style, size: frame.size)
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        addPixelLayer(image, at: frame.origin,
            name: title?.isEmpty == false ? title! : L10n.text("Gradient"), editName: "New Gradient Layer",
            dropsSelection: false, gradient: LayerGradient(style: style, image: image))
        guard let activeLayerID else { throw GradientLayerError.render }
        return activeLayerID
    }

    func updateGradientLayer(_ id: UUID, style: LayerGradientStyle) throws {
        guard style.isValid, let index = document?.layers.firstIndex(where: { $0.id == id }),
              document?.layers[index].liveGradient != nil else { throw GradientLayerError.invalid }
        beginEdit("Edit Gradient Layer")
        defer { endEdit() }
        try redrawGradient(at: index, style: style)
    }

    func redrawGradient(at index: Int) {
        guard let layer = document?.layers[index], let gradient = layer.liveGradient else { return }
        try? redrawGradient(at: index, style: gradient.style)
    }

    private func redrawGradient(at index: Int, style: LayerGradientStyle) throws {
        guard let layer = document?.layers[index], let asset = layer.asset else { throw GradientLayerError.invalid }
        let width = max(1, Int(layer.transform.size.width.rounded()))
        let height = max(1, Int(layer.transform.size.height.rounded()))
        guard width * height <= Self.maxShapePixels else { throw GradientLayerError.invalid }
        let image = try Self.gradientImage(style, size: CGSize(width: width, height: height))
        let thumbnail = try PixelAdjust.thumbnail(of: image)
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].gradient = LayerGradient(style: style, image: image)
    }

    static func gradientImage(_ style: LayerGradientStyle, size: CGSize) throws -> CGImage {
        guard style.isValid, size.width >= 1, size.height >= 1 else { throw GradientLayerError.invalid }
        let context = try BrushRaster.context(width: Int(size.width.rounded()), height: Int(size.height.rounded()), mask: false)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = style.stops.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
        let locations = style.stops.map(\.location)
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else {
            throw GradientLayerError.render
        }
        let bounds = CGRect(origin: .zero, size: size)
        switch style.kind {
        case .linear:
            let radians = style.angle * .pi / 180
            let vector = CGVector(dx: cos(radians), dy: sin(radians))
            let half = abs(vector.dx) * size.width / 2 + abs(vector.dy) * size.height / 2
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            context.drawLinearGradient(gradient,
                start: CGPoint(x: center.x - vector.dx * half, y: center.y - vector.dy * half),
                end: CGPoint(x: center.x + vector.dx * half, y: center.y + vector.dy * half),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            let center = CGPoint(x: size.width * style.centerX, y: size.height * style.centerY)
            let radius = [bounds.minX, bounds.maxX].flatMap { x in
                [bounds.minY, bounds.maxY].map { y in hypot(x - center.x, y - center.y) }
            }.max() ?? max(size.width, size.height)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        guard let image = context.makeImage() else { throw GradientLayerError.render }
        return image
    }
}

nonisolated enum GradientLayerError: LocalizedError {
    case invalid, render
    var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("The gradient layer settings are invalid.")
        case .render: L10n.text("The gradient layer could not be rendered.")
        }
    }
}
