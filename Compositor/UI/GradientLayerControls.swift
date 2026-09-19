import SwiftUI

struct GradientLayerControls: View {
    let session: EditorSession
    let layerID: UUID
    @State private var kind: LayerGradientKind
    @State private var colors: String
    @State private var locations: String
    @State private var angle: Double
    @State private var centerX: Double
    @State private var centerY: Double
    @State private var error: String?

    init(session: EditorSession, layerID: UUID) {
        self.session = session
        self.layerID = layerID
        let style = session.document?.layers.first(where: { $0.id == layerID })?.liveGradient?.style
            ?? LayerGradientStyle(stops: [
                LayerGradientStop(red: 0, green: 0, blue: 0, location: 0),
                LayerGradientStop(red: 1, green: 1, blue: 1, location: 1),
            ])
        _kind = State(initialValue: style.kind)
        _colors = State(initialValue: style.stops.map { $0.color.hex }.joined(separator: ", "))
        _locations = State(initialValue: style.stops.map { String(format: "%.3g", Double($0.location)) }.joined(separator: ", "))
        _angle = State(initialValue: Double(style.angle))
        _centerX = State(initialValue: Double(style.centerX))
        _centerY = State(initialValue: Double(style.centerY))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Gradient Layer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Gradient Type", selection: $kind) {
                Text("Linear").tag(LayerGradientKind.linear)
                Text("Radial").tag(LayerGradientKind.radial)
            }
            .pickerStyle(.segmented).labelsHidden()
            TextField("Colors, e.g. #246BFD, #F43F8C", text: $colors)
            TextField("Locations, e.g. 0, 1", text: $locations)
            if kind == .linear {
                HStack {
                    Text("Angle").foregroundStyle(.secondary)
                    TextField("Angle", value: $angle, format: .number).frame(width: 72)
                    Text("°").foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    TextField("Center X", value: $centerX, format: .number)
                    TextField("Center Y", value: $centerY, format: .number)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Button("Apply Gradient Changes") { apply() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func apply() {
        let colorValues = colors.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let locationValues = locations.split(separator: ",").compactMap {
            Double(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard (2...12).contains(colorValues.count), locationValues.count == colorValues.count else {
            error = L10n.text("Enter 2–12 colors and one matching location for each color.")
            return
        }
        var stops: [LayerGradientStop] = []
        for (hex, location) in zip(colorValues, locationValues) {
            guard let color = PaletteColor(hex: hex), location.isFinite else {
                error = L10n.text("Enter valid hex colors and locations from 0 to 1.")
                return
            }
            stops.append(LayerGradientStop(red: color.red, green: color.green, blue: color.blue,
                                           location: CGFloat(location)))
        }
        let style = LayerGradientStyle(kind: kind, stops: stops, angle: CGFloat(angle),
            centerX: CGFloat(centerX), centerY: CGFloat(centerY))
        do { try session.updateGradientLayer(layerID, style: style); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
