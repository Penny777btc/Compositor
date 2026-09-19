import AppKit

@MainActor
enum AIEditorEngine {
    static func context(for session: EditorSession) -> String {
        guard let document = session.document else {
            return "Canvas: none\nLayers: none"
        }
        let rows = session.layerRows.enumerated().map { index, entry in
            let record = entry.layer
            guard let layer = document.layers.first(where: { $0.id == record.id }) else { return "" }
            let type: String
            let details: String
            if layer.isGroup {
                type = "folder"; details = ""
            } else if let adjustment = layer.adjustment {
                type = "adjustment"; details = " kind=\(adjustment.kind.rawValue.debugDescription)"
            } else if let text = layer.liveText?.style {
                type = "editable_text"
                details = " content=\(String(text.text.prefix(500)).debugDescription) font=\(text.fontName.debugDescription) fontSize=\(text.fontSize) alignment=\(text.alignment.rawValue) boxWidth=\(text.boxWidth)"
            } else if let gradient = layer.liveGradient?.style {
                type = "editable_gradient"
                let stops = gradient.stops.map { "\($0.color.hex)@\($0.location)" }.joined(separator: ",")
                details = " kind=\(gradient.kind.rawValue) stops=\(stops.debugDescription) angle=\(gradient.angle) center=(\(gradient.centerX),\(gradient.centerY))"
            } else if let shape = layer.liveShape?.style {
                type = "editable_shape"
                details = " kind=\(shape.kind.rawValue) color=\(shape.color.hex) cornerRadius=\(shape.cornerRadius)"
            } else if let path = layer.liveVectorPath?.style {
                type = "editable_path"
                details = " points=\(path.points.count) stroke=\(path.stroke.palette.hex) lineWidth=\(path.lineWidth) closed=\(path.closed)"
            } else if let generation = layer.generation {
                type = "generated_image"
                details = " provider=\(generation.providerID.debugDescription) model=\(generation.model.debugDescription) role=\(generation.role.rawValue) prompt=\(String(generation.prompt.prefix(500)).debugDescription)"
            } else {
                type = "raster_image"; details = ""
            }
            let mask = layer.mask.map { "present(enabled=\($0.isEnabled))" } ?? "none"
            return "\(index + 1). id=\(layer.id.uuidString) name=\(layer.name.debugDescription) type=\(type) "
                + "visible=\(layer.isVisible) opacity=\(layer.opacity) "
                + "frame=(x:\(layer.transform.origin.x),y:\(layer.transform.origin.y),w:\(layer.transform.size.width),h:\(layer.transform.size.height)) "
                + "rotation=\(layer.transform.rotation) mask=\(mask)\(details)"
        }.joined(separator: "\n")
        return "Canvas: \(document.width) x \(document.height) px, sRGB\nLayers (top to bottom):\n\(rows.isEmpty ? "none" : rows)"
    }

    static func execute(_ plan: AIEditorPlan, in session: EditorSession) -> [String] {
        guard !plan.actions.isEmpty else { return [] }
        if plan.actions.count == 1, plan.actions[0].type == "no_action" { return [] }
        if plan.actions.count > 1, plan.actions.contains(where: { $0.type == "no_action" }) {
            return [L10n.text("The AI plan mixed no_action with editor changes, so nothing was applied.")]
        }
        if resemblesGradientBands(plan.actions, session: session) {
            return [L10n.text("The AI plan tried to simulate a gradient with shape bands. Use one editable gradient layer instead.")]
        }
        var results: [String] = []
        session.finishOpacityEdit()
        session.beginEdit("AI Edit")
        defer { session.endEdit() }
        for action in plan.actions.prefix(24) {
            do {
                try execute(action, in: session)
                results.append(L10n.format("Applied: %@", action.type))
            } catch {
                results.append(L10n.format("Skipped %@: %@", action.type, error.localizedDescription))
            }
        }
        return results
    }

    /// Reject the characteristic legacy workaround: many full-height or full-width colored rectangles tiled in order.
    /// Eight is deliberately conservative so ordinary cards, columns, and small decorative patterns remain valid.
    private static func resemblesGradientBands(_ actions: [AIEditorAction], session: EditorSession) -> Bool {
        let canvasWidth = actions.first(where: { $0.type == "create_canvas" })?.width
            ?? session.document.map { Double($0.width) }
        let canvasHeight = actions.first(where: { $0.type == "create_canvas" })?.height
            ?? session.document.map { Double($0.height) }
        guard let canvasWidth, let canvasHeight else { return false }
        let rectangles = actions.filter { $0.type == "add_shape" && ($0.shape == nil || $0.shape == "rectangle") }
        guard rectangles.count >= 8 else { return false }
        let vertical = rectangles.allSatisfy {
            abs(($0.y ?? 0)) < 0.5 && abs(($0.height ?? -1) - canvasHeight) < 0.5
                && $0.x != nil && $0.width != nil && $0.color != nil
        }
        let horizontal = rectangles.allSatisfy {
            abs(($0.x ?? 0)) < 0.5 && abs(($0.width ?? -1) - canvasWidth) < 0.5
                && $0.y != nil && $0.height != nil && $0.color != nil
        }
        return vertical || horizontal
    }

    private static func execute(_ action: AIEditorAction, in session: EditorSession) throws {
        switch action.type {
        case "create_canvas":
            guard session.document == nil else { throw CommandError.canvasExists }
            let width = try dimension(action.width), height = try dimension(action.height)
            session.createDocument(width: width, height: height, emptyLayer: false)
        case "add_shape":
            guard let document = session.document else { throw CommandError.noCanvas }
            let width = try positive(action.width), height = try positive(action.height)
            guard width * height <= 100_000_000 else { throw CommandError.invalidValue }
            let x = finite(action.x) ?? (Double(document.width) - width) / 2
            let y = finite(action.y) ?? (Double(document.height) - height) / 2
            let kind: ShapeKind = action.shape?.lowercased() == "ellipse" ? .ellipse : .rectangle
            let color = try palette(action.color ?? "#000000")
            let radius = kind == .rectangle ? min(max(0, finite(action.cornerRadius) ?? 0), width / 2, height / 2) : 0
            let image = try EditorSession.shapeImage(kind, size: CGSize(width: width, height: height), color: color,
                                                     cornerRadius: radius)
            let style = LayerShapeStyle(kind: kind, red: color.red, green: color.green, blue: color.blue,
                                        cornerRadius: radius)
            let name = action.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.addPixelLayer(image, at: CGPoint(x: x, y: y),
                name: name?.isEmpty == false ? name! : session.nextShapeName(kind), editName: "AI Shape",
                dropsSelection: false, shape: LayerShape(style: style, image: image))
        case "add_path":
            guard session.document != nil, let values = action.points, (2...256).contains(values.count) else {
                throw CommandError.invalidValue
            }
            let points = try values.map { value -> CGPoint in
                guard value.x.isFinite, value.y.isFinite else { throw CommandError.invalidValue }
                return CGPoint(x: value.x, y: value.y)
            }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { throw CommandError.invalidValue }
            let lineWidth = finite(action.lineWidth) ?? 8
            guard (0.5...2_000).contains(lineWidth) else { throw CommandError.invalidValue }
            let padding = max(2, lineWidth / 2 + 2)
            let frame = CGRect(x: minX - padding, y: minY - padding,
                width: max(1, maxX - minX + padding * 2), height: max(1, maxY - minY + padding * 2))
            let normalized = points.map { LayerPathPoint(x: ($0.x - frame.minX) / frame.width,
                                                         y: ($0.y - frame.minY) / frame.height) }
            let stroke = try palette(action.strokeColor ?? "#000000")
            let fill = try action.fillColor.map { try palette($0) }
            let style = LayerVectorPathStyle(points: normalized,
                stroke: LayerPathColor(red: stroke.red, green: stroke.green, blue: stroke.blue),
                fill: fill.map { LayerPathColor(red: $0.red, green: $0.green, blue: $0.blue) },
                lineWidth: lineWidth, closed: action.closed ?? false)
            _ = try session.addVectorPathLayer(style: style, frame: frame, name: action.name)
        case "add_gradient":
            guard let document = session.document else { throw CommandError.noCanvas }
            let width = try action.width.map(positive) ?? document.size.width
            let height = try action.height.map(positive) ?? document.size.height
            let x = finite(action.x) ?? (document.size.width - width) / 2
            let y = finite(action.y) ?? (document.size.height - height) / 2
            let style = try gradientStyle(action)
            _ = try session.addGradientLayer(style: style,
                frame: CGRect(x: x, y: y, width: width, height: height), name: action.name)
        case "edit_gradient":
            let id = try layerID(action, session: session)
            guard let current = session.document?.layers.first(where: { $0.id == id })?.liveGradient?.style else {
                throw CommandError.invalidValue
            }
            try session.updateGradientLayer(id, style: gradientStyle(action, fallback: current))
        case "add_text":
            guard let document = session.document, let text = action.text, !text.isEmpty else { throw CommandError.noCanvas }
            let style = try textStyle(action, fallbackText: text)
            let x = finite(action.x) ?? max(0, (document.size.width - style.boxWidth) / 2)
            let y = finite(action.y) ?? max(0, document.size.height / 2 - style.fontSize)
            _ = try session.addTextLayer(style: style, at: CGPoint(x: x, y: y), name: action.name)
        case "edit_text":
            let id = try layerID(action, session: session)
            guard let current = session.document?.layers.first(where: { $0.id == id })?.liveText?.style else {
                throw CommandError.invalidValue
            }
            let style = try textStyle(action, fallbackText: action.text ?? current.text, fallback: current)
            try session.updateTextLayer(id, style: style)
        case "rename_layer":
            let id = try layerID(action, session: session)
            guard let name = action.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw CommandError.invalidValue
            }
            session.renameLayer(id, to: name)
        case "set_opacity":
            let id = try layerID(action, session: session)
            guard let opacity = finite(action.opacity) else { throw CommandError.invalidValue }
            session.selectLayer(id)
            session.setLayerOpacity(opacity > 1 ? opacity / 100 : opacity)
        case "set_visibility":
            let id = try layerID(action, session: session)
            guard let visible = action.visible,
                  let layer = session.document?.layers.first(where: { $0.id == id }) else { throw CommandError.invalidValue }
            if layer.isVisible != visible { session.toggleLayerVisibility(id) }
        case "transform_layer":
            let id = try layerID(action, session: session)
            guard let index = session.document?.layers.firstIndex(where: { $0.id == id }) else { throw CommandError.layerMissing }
            var transform = session.document!.layers[index].transform
            if let x = finite(action.x) { transform.origin.x = x }
            if let y = finite(action.y) { transform.origin.y = y }
            if let width = finite(action.width) { transform.size.width = width }
            if let height = finite(action.height) { transform.size.height = height }
            if let rotation = finite(action.rotation) { transform.rotation = rotation }
            guard transform.isValid else { throw CommandError.invalidValue }
            session.document!.layers[index].transform = transform.rounded()
            session.redrawShape(at: index)
            session.redrawGradient(at: index)
            session.redrawVectorPath(at: index)
            session.selectLayer(id)
        case "duplicate_layer":
            let id = try layerID(action, session: session)
            session.selectLayer(id)
            session.duplicateActiveLayer()
        case "add_adjustment":
            if action.layerID != nil { session.selectLayer(try layerID(action, session: session)) }
            guard let raw = action.adjustment, let kind = adjustment(raw) else { throw CommandError.invalidValue }
            session.addAdjustment(kind)
        case "add_mask":
            let id = try layerID(action, session: session)
            session.selectLayer(id)
            session.addLayerMask(revealing: action.mask != "hide")
        case "group_layers":
            guard let values = action.layerIDs, !values.isEmpty else { throw CommandError.invalidValue }
            let ids = Set(try values.map { value -> UUID in
                guard let id = UUID(uuidString: value), session.document?.layers.contains(where: { $0.id == id }) == true else {
                    throw CommandError.layerMissing
                }
                return id
            })
            session.selectLayers(ids, primary: ids.first)
            session.groupSelectedLayers()
        case "reorder_layer":
            let id = try layerID(action, session: session)
            guard let position = action.position, position >= 1 else { throw CommandError.invalidValue }
            let rows = session.layerRows
            guard position <= rows.count else { throw CommandError.invalidValue }
            if position == rows.count { _ = session.placeLayer(id, in: nil, atBottom: true) }
            else {
                let target = rows[position - 1].layer
                _ = session.placeLayer(id, in: target.parentID, above: target.id)
            }
        case "extract_reference_region", "generate_image", "export_variants", "no_action": break
        default: throw CommandError.unsupported
        }
    }

    private static func layerID(_ action: AIEditorAction, session: EditorSession) throws -> UUID {
        guard let value = action.layerID, let id = UUID(uuidString: value),
              session.document?.layers.contains(where: { $0.id == id }) == true else { throw CommandError.layerMissing }
        return id
    }

    private static func finite(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return CGFloat(value)
    }
    private static func positive(_ value: Double?) throws -> CGFloat {
        guard let value = finite(value), value >= 1, value <= 30_000 else { throw CommandError.invalidValue }
        return value
    }
    private static func dimension(_ value: Double?) throws -> Int { Int(try positive(value).rounded()) }

    private static func palette(_ hex: String) throws -> PaletteColor {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { throw CommandError.invalidValue }
        return PaletteColor(red: CGFloat((rgb >> 16) & 0xff) / 255,
                            green: CGFloat((rgb >> 8) & 0xff) / 255,
                            blue: CGFloat(rgb & 0xff) / 255)
    }

    private static func textStyle(_ action: AIEditorAction, fallbackText: String,
                                  fallback: TextLayerStyle? = nil) throws -> TextLayerStyle {
        let base = fallback ?? TextLayerStyle(text: fallbackText)
        let rgb = try palette(action.color ?? base.color.hex)
        let align = action.alignment.flatMap(TextLayerAlignment.init(rawValue:)) ?? base.alignment
        let style = TextLayerStyle(text: action.text ?? fallbackText,
            fontName: action.fontName ?? base.fontName,
            fontSize: finite(action.fontSize) ?? base.fontSize,
            red: rgb.red, green: rgb.green, blue: rgb.blue,
            alignment: align, boxWidth: finite(action.width) ?? base.boxWidth)
        guard style.isValid else { throw CommandError.invalidValue }
        return style
    }

    private static func gradientStyle(_ action: AIEditorAction, fallback: LayerGradientStyle? = nil) throws -> LayerGradientStyle {
        let base = fallback ?? LayerGradientStyle(stops: [
            LayerGradientStop(red: 0, green: 0, blue: 0, location: 0),
            LayerGradientStop(red: 1, green: 1, blue: 1, location: 1),
        ])
        let stops: [LayerGradientStop]
        if let values = action.colors {
            guard (2...12).contains(values.count) else { throw CommandError.invalidValue }
            let locations = action.locations ?? values.indices.map { Double($0) / Double(values.count - 1) }
            guard locations.count == values.count else { throw CommandError.invalidValue }
            stops = try zip(values, locations).map { value, location in
                let color = try palette(value)
                guard location.isFinite else { throw CommandError.invalidValue }
                return LayerGradientStop(red: color.red, green: color.green, blue: color.blue,
                                         location: CGFloat(location))
            }
        } else { stops = base.stops }
        let kind = action.gradient.flatMap(LayerGradientKind.init(rawValue:)) ?? base.kind
        let style = LayerGradientStyle(kind: kind, stops: stops,
            angle: finite(action.angle) ?? base.angle,
            centerX: finite(action.centerX) ?? base.centerX,
            centerY: finite(action.centerY) ?? base.centerY)
        guard style.isValid else { throw CommandError.invalidValue }
        return style
    }

    private static func adjustment(_ value: String) -> AdjustmentKind? {
        switch value {
        case "hue_saturation": .hsv
        case "levels": .levels
        case "curves": .curves
        case "exposure": .exposure
        case "gradient_map": .gradientMap
        case "grain": .grain
        default: nil
        }
    }

    private enum CommandError: LocalizedError {
        case noCanvas, canvasExists, layerMissing, invalidValue, unsupported
        var errorDescription: String? {
            switch self {
            case .noCanvas: L10n.text("Create a canvas first.")
            case .canvasExists: L10n.text("A canvas already exists, so it was not replaced.")
            case .layerMissing: L10n.text("The requested layer no longer exists.")
            case .invalidValue: L10n.text("One or more values are invalid.")
            case .unsupported: L10n.text("That action is not supported yet.")
            }
        }
    }
}
