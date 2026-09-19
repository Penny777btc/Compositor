import AppKit

nonisolated enum TextLayerAlignment: String, Codable, CaseIterable, Sendable {
    case left, center, right
}

/// Editable text metadata. The layer also keeps a raster preview so all existing masks, filters, and exports work.
nonisolated struct TextLayerStyle: Codable, Equatable, Sendable {
    var text: String
    var fontName: String = "Helvetica Neue"
    var fontSize: CGFloat = 72
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
    var alignment: TextLayerAlignment = .left
    var boxWidth: CGFloat = 800
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isValid: Bool {
        !text.isEmpty && text.utf8.count <= 100_000 && !fontName.isEmpty && fontName.utf8.count <= 1_024
            && fontSize.isFinite && (1...1_000).contains(fontSize)
            && boxWidth.isFinite && (1...30_000).contains(boxWidth)
            && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

nonisolated struct LayerText: Equatable, @unchecked Sendable {
    var style: TextLayerStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: TextLayerStyle?, image: CGImage?) -> LayerText? {
        guard let style, style.isValid, let image else { return nil }
        return LayerText(style: style, image: image)
    }
}

extension ImageLayer {
    var liveText: LayerText? {
        guard let text, let image = asset?.image, image === text.image else { return nil }
        return text
    }
}

extension EditorSession {
    func addDefaultTextLayer() {
        guard let document else { return }
        let style = TextLayerStyle(text: L10n.text("Your text"), boxWidth: min(800, max(120, document.size.width - 80)))
        let origin = CGPoint(x: max(0, (document.size.width - style.boxWidth) / 2),
                             y: max(0, document.size.height / 2 - style.fontSize))
        do { _ = try addTextLayer(style: style, at: origin, name: L10n.text("Text")) }
        catch { brushError = error.localizedDescription }
    }

    @discardableResult
    func addTextLayer(style: TextLayerStyle, at origin: CGPoint, name: String? = nil) throws -> UUID {
        guard style.isValid else { throw TextLayerError.invalid }
        let image = try Self.textImage(style)
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        addPixelLayer(image, at: origin, name: title?.isEmpty == false ? title! : style.text,
                      editName: "New Text Layer", dropsSelection: false,
                      text: LayerText(style: style, image: image))
        guard let activeLayerID else { throw TextLayerError.render }
        return activeLayerID
    }

    func updateTextLayer(_ id: UUID, style: TextLayerStyle) throws {
        guard style.isValid, let index = document?.layers.firstIndex(where: { $0.id == id }),
              document?.layers[index].liveText != nil else { throw TextLayerError.invalid }
        let image = try Self.textImage(style)
        let thumbnail = try PixelAdjust.thumbnail(of: image)
        let current = document!.layers[index]
        var transform = current.transform
        transform.size = CGSize(width: image.width, height: image.height)
        beginEdit("Edit Text Layer")
        document!.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: current.name)
        document!.layers[index].transform = transform
        document!.layers[index].text = LayerText(style: style, image: image)
        endEdit()
    }

    static func textImage(_ style: TextLayerStyle) throws -> CGImage {
        guard style.isValid else { throw TextLayerError.invalid }
        let font = NSFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment == .center ? .center : style.alignment == .right ? .right : .left
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: style.text, attributes: [
            .font: font,
            .foregroundColor: NSColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let measured = text.boundingRect(with: CGSize(width: style.boxWidth, height: 30_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = max(1, Int(style.boxWidth.rounded(.up)))
        let height = max(1, Int((measured.height + style.fontSize * 0.2).rounded(.up)))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(with: CGRect(x: 0, y: 0, width: width, height: height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw TextLayerError.render }
        return image
    }
}

nonisolated enum TextLayerError: LocalizedError {
    case invalid, render
    var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("The text layer settings are invalid.")
        case .render: L10n.text("The text layer could not be rendered.")
        }
    }
}
