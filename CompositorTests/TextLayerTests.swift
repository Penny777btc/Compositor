import Foundation
import Testing
@testable import Compositor

@MainActor struct TextLayerTests {
    @Test func textStaysEditableAndRoundTrips() async throws {
        let session = EditorSession()
        session.createDocument(width: 1200, height: 628)
        let style = TextLayerStyle(text: "TikTok Cover", fontName: "Helvetica Neue", fontSize: 84,
            red: 1, green: 0.2, blue: 0.4, alignment: .center, boxWidth: 900)
        let id = try session.addTextLayer(style: style, at: CGPoint(x: 150, y: 100), name: "Title")
        #expect(session.activeLayer?.liveText?.style == style)
        var edited = style
        edited.text = "Editable Title"; edited.fontSize = 96
        try session.updateTextLayer(id, style: edited)
        #expect(session.activeLayer?.liveText?.style == edited)

        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 11 && snapshot.manifest.layers.first?.text == edited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorTextTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.shared.save(snapshot, to: root)
        let loaded = try await ProjectStore.shared.load(from: root)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: root)
        #expect(reopened.activeLayer?.liveText?.style == edited)
    }

    @Test func aiTextCanResolveWeightTrackingAndFitAReferenceBox() throws {
        let session = EditorSession()
        session.createDocument(width: 1080, height: 1440)
        var action = AIEditorAction(type: "add_text")
        action.text = "Gemini 4"; action.fontName = "Helvetica Neue"; action.fontWeight = "black"
        action.width = 760; action.height = 150; action.fitText = true; action.tracking = -2
        action.x = 100; action.y = 80; action.color = "#05070A"
        _ = AIEditorEngine.execute(AIEditorPlan(message: "", actions: [action]), in: session)
        let style = try #require(session.activeLayer?.liveText?.style)
        #expect(style.fontName.lowercased().contains("black") || style.fontName.lowercased().contains("heavy"))
        #expect(style.tracking == -2 && style.fontSize > 20)
        #expect(session.activeLayer?.transform.size.height ?? 10_000 <= 151)
    }

    @Test func batchVariantsSaveEditableProjectsAndPNGs() async throws {
        let session = EditorSession()
        session.createDocument(width: 1200, height: 628)
        _ = try session.addTextLayer(style: TextLayerStyle(text: "Campaign", boxWidth: 700),
                                     at: CGPoint(x: 100, y: 100))
        let snapshot = try #require(session.projectSnapshot())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorVariants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await BatchVariantExporter.shared.export(snapshot, variants: [
            AIExportVariant(name: "TikTok Cover", width: 1080, height: 1920),
            AIExportVariant(name: "Square", width: 1080, height: 1080),
        ], to: folder)
        #expect(files.count == 4)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("TikTok Cover.comp").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Square.png").path))
        let project = try await ProjectStore.shared.load(from: folder.appendingPathComponent("Square.comp"))
        #expect(project.manifest.layers.first?.text?.text == "Campaign")
    }
}
