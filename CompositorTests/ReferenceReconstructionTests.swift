import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor struct ReferenceReconstructionTests {
    @Test func referenceGuardRejectsTypographyOnlyReconstructionAndBuildsCorrection() {
        let analysis = AIReferenceAnalysis(summary: "Poster with two product screenshots and a collage landscape",
            visualStyle: "hand-drawn editorial", palette: ["#FFD75A"],
            composition: ["two product images"], layerStrategy: ["crown, arrow, screenshots, mountain collage"])
        let weakPlan = AIEditorPlan(message: "Rebuilt", referenceAnalysis: analysis,
            actions: [AIEditorAction(type: "add_gradient"), AIEditorAction(type: "add_text"),
                      AIEditorAction(type: "add_text"), AIEditorAction(type: "add_text")])
        let reason = AIReferencePlanGuard.revisionReason(for: weakPlan, userText: "模仿这张参考图")
        #expect(reason != nil)
        let correction = AIReferencePlanGuard.revisionPrompt(
            originalPrompt: "original", rejectedPlan: weakPlan, reason: reason ?? "")
        #expect(correction.contains("extract_reference_region"))
        #expect(correction.contains("add_path"))

        let strongPlan = AIEditorPlan(message: "Rebuilt", referenceAnalysis: analysis,
            actions: [AIEditorAction(type: "extract_reference_region"), AIEditorAction(type: "add_path")])
        #expect(AIReferencePlanGuard.revisionReason(for: strongPlan, userText: "模仿这张参考图") == nil)
    }

    private func png(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url, options: .atomic)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[offset + $0]) }
    }

    @Test func localReferenceAnalysisFindsTextFramesAndPalette() async throws {
        let context = try BrushRaster.context(width: 512, height: 180, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 180))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: "HELLO", attributes: [
            .font: NSFont.systemFont(ofSize: 92, weight: .bold), .foregroundColor: NSColor.black,
        ]).draw(at: CGPoint(x: 46, y: 35))
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OCR-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try png(image, to: url)
        let result = try await ReferenceImageAnalyzer.analyze(url)
        #expect(result.width == 512 && result.height == 180)
        #expect(result.texts.contains { $0.text.uppercased().contains("HELLO") })
        #expect(!result.palette.isEmpty)
        #expect(result.promptContext.contains("top-left pixel coordinates"))
    }

    @Test func exactReferenceRegionBecomesItsOwnLayer() throws {
        let context = try BrushRaster.context(width: 100, height: 40, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 40))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 50, y: 0, width: 50, height: 40))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Crop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try png(image, to: url)
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        var action = AIEditorAction(type: "extract_reference_region")
        action.name = "Right Screenshot"; action.sourceX = 50; action.sourceY = 0
        action.sourceWidth = 50; action.sourceHeight = 40
        action.x = 20; action.y = 10; action.width = 100; action.height = 80
        let messages = try ReferenceRegionExtractor.execute([action], referenceURL: url, in: session)
        let layer = try #require(session.activeLayer)
        #expect(messages.count == 1 && layer.name == "Right Screenshot")
        #expect(layer.transform == LayerTransform(origin: CGPoint(x: 20, y: 10), size: CGSize(width: 100, height: 80)))
        let sampled = try pixel(try #require(layer.asset?.image), x: 25, y: 20)
        #expect(sampled[2] > 240 && sampled[0] < 10)
    }

    @Test func aiPathIsEditableScalableAndPersistent() async throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        var action = AIEditorAction(type: "add_path")
        action.name = "Hand Arrow"
        action.points = [AIVectorPoint(x: 40, y: 80), AIVectorPoint(x: 160, y: 120), AIVectorPoint(x: 130, y: 80)]
        action.strokeColor = "#05070A"; action.lineWidth = 12; action.closed = false
        _ = AIEditorEngine.execute(AIEditorPlan(message: "", actions: [action]), in: session)
        let layer = try #require(session.activeLayer)
        #expect(layer.liveVectorPath?.style.points.count == 3)
        #expect(layer.liveVectorPath?.style.stroke.palette.hex == "05070A")
        let oldImage = try #require(layer.asset?.image)
        let id = layer.id
        var transform = layer.transform; transform.size.width *= 2
        var resize = AIEditorAction(type: "transform_layer")
        resize.layerID = id.uuidString; resize.width = Double(transform.size.width)
        _ = AIEditorEngine.execute(AIEditorPlan(message: "", actions: [resize]), in: session)
        #expect(session.activeLayer?.asset?.image !== oldImage)
        #expect(session.activeLayer?.liveVectorPath != nil)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 11 && snapshot.manifest.layers.last?.vectorPath != nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        #expect(try await ProjectStore.shared.load(from: url).manifest.layers.last?.vectorPath != nil)
    }
}
