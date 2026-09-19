import AppKit
import SwiftUI

private struct InstalledFontFace: Identifiable, Hashable {
    let postScriptName: String
    let styleName: String
    var id: String { postScriptName }
}

@MainActor
private enum InstalledFontCatalog {
    static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }

    static func faces(in family: String) -> [InstalledFontFace] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.compactMap { member in
            guard member.count >= 2,
                  let postScriptName = member[0] as? String,
                  let styleName = member[1] as? String else { return nil }
            return InstalledFontFace(postScriptName: postScriptName, styleName: styleName)
        }.sorted {
            if $0.styleName.localizedCaseInsensitiveCompare("Regular") == .orderedSame { return true }
            if $1.styleName.localizedCaseInsensitiveCompare("Regular") == .orderedSame { return false }
            return $0.styleName.localizedStandardCompare($1.styleName) == .orderedAscending
        }
    }

    static func family(for postScriptName: String) -> String? {
        NSFont(name: postScriptName, size: 12)?.familyName
    }

    static func previewFace(in family: String) -> String {
        faces(in: family).first?.postScriptName ?? family
    }
}

private struct FontFamilyPicker: View {
    @Binding var selection: String
    @State private var isPresented = false
    @State private var search = ""

    private var filteredFamilies: [String] {
        guard !search.isEmpty else { return InstalledFontCatalog.families }
        return InstalledFontCatalog.families.filter {
            $0.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selection).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(spacing: 8) {
                TextField("Search Fonts", text: $search)
                    .textFieldStyle(.roundedBorder)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(filteredFamilies, id: \.self) { family in
                                Button {
                                    selection = family
                                    isPresented = false
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.semibold))
                                            .frame(width: 12)
                                            .opacity(family == selection ? 1 : 0)
                                        Text(family)
                                            .lineLimit(1)
                                        Spacer(minLength: 12)
                                        Text("Aa 字体")
                                            .font(.custom(InstalledFontCatalog.previewFace(in: family), size: 18))
                                            .lineLimit(1)
                                            .frame(width: 88, alignment: .leading)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(family == selection ? Color.accentColor.opacity(0.18) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .id(family)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(selection, anchor: .center) }
                }
            }
            .padding(10)
            .frame(width: 360, height: 460)
        }
        .help(L10n.text("Font Family"))
    }
}

struct TextLayerControls: View {
    let session: EditorSession
    let layerID: UUID
    @State private var text: String
    @State private var fontFamily: String
    @State private var fontName: String
    @State private var fontSize: Double
    @State private var width: Double
    @State private var tracking: Double
    @State private var color: String
    @State private var alignment: TextLayerAlignment
    @State private var error: String?

    init(session: EditorSession, layerID: UUID) {
        self.session = session
        self.layerID = layerID
        let style = session.document?.layers.first(where: { $0.id == layerID })?.liveText?.style
            ?? TextLayerStyle(text: "Text")
        _text = State(initialValue: style.text)
        _fontFamily = State(initialValue: InstalledFontCatalog.family(for: style.fontName) ?? style.fontName)
        _fontName = State(initialValue: style.fontName)
        _fontSize = State(initialValue: Double(style.fontSize))
        _width = State(initialValue: Double(style.boxWidth))
        _tracking = State(initialValue: Double(style.tracking ?? 0))
        _color = State(initialValue: style.color.hex)
        _alignment = State(initialValue: style.alignment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Text Layer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Text", text: $text, axis: .vertical).lineLimit(1...4)
            HStack {
                FontFamilyPicker(selection: $fontFamily)
                TextField("Size", value: $fontSize, format: .number).frame(width: 58)
            }
            let faces = InstalledFontCatalog.faces(in: fontFamily)
            Picker("Font Style", selection: $fontName) {
                if !faces.contains(where: { $0.postScriptName == fontName }) {
                    Text(fontName).tag(fontName)
                }
                ForEach(faces) { face in
                    Text(face.styleName)
                        .font(.custom(face.postScriptName, size: 12))
                        .tag(face.postScriptName)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help(L10n.text("Font Style"))
            HStack {
                TextField("Width", value: $width, format: .number)
                TextField("Color", text: $color).textCase(.uppercase)
            }
            HStack {
                Text("Tracking").font(.caption).foregroundStyle(.secondary)
                TextField("Tracking", value: $tracking, format: .number).frame(width: 76)
            }
            Picker("Alignment", selection: $alignment) {
                Text("Left").tag(TextLayerAlignment.left)
                Text("Center").tag(TextLayerAlignment.center)
                Text("Right").tag(TextLayerAlignment.right)
            }.pickerStyle(.segmented).labelsHidden()
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Button("Apply Text Changes") { apply() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(text.isEmpty || fontSize < 1 || width < 1)
        }
        .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.vertical, 10)
        .onChange(of: fontFamily) { _, family in
            let faces = InstalledFontCatalog.faces(in: family)
            guard !faces.contains(where: { $0.postScriptName == fontName }), let first = faces.first else { return }
            fontName = first.postScriptName
        }
    }

    private func apply() {
        guard let rgb = PaletteColor(hex: color) else { error = L10n.text("Enter a valid hex color."); return }
        let style = TextLayerStyle(text: text, fontName: fontName, fontSize: CGFloat(fontSize),
            red: rgb.red, green: rgb.green, blue: rgb.blue, alignment: alignment, boxWidth: CGFloat(width),
            tracking: CGFloat(tracking))
        do { try session.updateTextLayer(layerID, style: style); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
