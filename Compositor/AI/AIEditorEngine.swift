import AppKit

@MainActor
enum AIEditorEngine {
    static func context(for session: EditorSession) -> String {
        guard let document = session.document else {
            return "Canvas: none\nLayers: none"
        }
        let rows = session.layerRows.enumerated().map { index, entry in
            let layer = entry.layer
            let type = layer.isGroup == true ? "folder" : layer.adjustment != nil ? "adjustment" : layer.shape != nil ? "shape" : "image"
            return "\(index + 1). id=\(layer.id.uuidString) name=\(layer.name.debugDescription) type=\(type) "
                + "visible=\(layer.isVisible) opacity=\(layer.opacity ?? 1) "
                + "frame=(x:\(layer.transform.origin.x),y:\(layer.transform.origin.y),w:\(layer.transform.size.width),h:\(layer.transform.size.height)) "
                + "rotation=\(layer.transform.rotation)"
        }.joined(separator: "\n")
        return "Canvas: \(document.width) x \(document.height) px, sRGB\nLayers (top to bottom):\n\(rows.isEmpty ? "none" : rows)"
    }

    static func execute(_ plan: AIEditorPlan, in session: EditorSession) -> [String] {
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
            session.selectLayer(id)
        case "duplicate_layer":
            let id = try layerID(action, session: session)
            session.selectLayer(id)
            session.duplicateActiveLayer()
        case "no_action": break
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
