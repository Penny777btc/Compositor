import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor struct AIImageGenerationTests {
    private struct FakeProvider: AIImageGenerationProvider {
        let identifier = "test.images"
        let displayName = "Test Images"
        let isConfigured = true
        let png: Data
        func generate(_ request: AIImageGenerationRequest) async throws -> AIImageGenerationArtifact {
            #expect(request.prompt == "A paper-cut mountain landscape")
            return AIImageGenerationArtifact(data: png, mediaType: "image/png", model: "test-image-1",
                revisedPrompt: "A layered paper-cut mountain landscape")
        }
    }

    private func png() throws -> Data {
        let image = try EditorSession.shapeImage(.rectangle, size: CGSize(width: 64, height: 64),
            color: PaletteColor(red: 0.2, green: 0.5, blue: 0.9))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func action() -> AIEditorAction {
        var action = AIEditorAction(type: "generate_image")
        action.name = "Mountain Art"
        action.prompt = "A paper-cut mountain landscape"
        action.imageRole = "illustration"
        action.imageBackground = "opaque"
        action.imageQuality = "high"
        action.width = 320
        action.height = 180
        action.x = 40
        action.y = 20
        return action
    }

    @Test func providerResultBecomesAPlacedLayerWithSafeProvenance() async throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 240)
        let messages = try await AIImageGenerationPipeline.execute([action()],
            provider: FakeProvider(png: try png()), referenceURL: nil, in: session)
        let layer = try #require(session.activeLayer)
        #expect(messages.count == 1)
        #expect(layer.name == "Mountain Art")
        #expect(layer.transform == LayerTransform(origin: CGPoint(x: 40, y: 20), size: CGSize(width: 320, height: 180)))
        #expect(layer.asset?.image.width == 64)
        #expect(layer.generation?.providerID == "test.images")
        #expect(layer.generation?.model == "test-image-1")
        #expect(layer.generation?.role == .illustration)
        #expect(layer.generation?.revisedPrompt == "A layered paper-cut mountain landscape")

        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 11)
        #expect(snapshot.manifest.layers.last?.generation == layer.generation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorGeneratedImage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.shared.save(snapshot, to: root)
        let loaded = try await ProjectStore.shared.load(from: root)
        #expect(loaded.manifest.layers.last?.generation == layer.generation)
    }

    @Test func unconfiguredProviderKeepsRequestsPendingWithoutFakePixels() {
        let session = EditorSession()
        let controller = AIChatController()
        let plan = AIEditorPlan(message: "Ready", actions: [
            AIEditorAction(type: "create_canvas", width: 400, height: 240), action(),
        ])
        controller.pendingPlan = plan
        controller.applyPending(in: session)
        #expect(session.document?.layers.isEmpty == true)
        #expect(controller.pendingImageActions.count == 1)
        #expect(controller.messages.last?.text.contains("provider") == true
            || controller.messages.last?.text.contains("提供商") == true)
    }

    @Test func selectedReferenceIsValidatedAndCopiedIntoAppCache() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Reference Source \(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        try png().write(to: source, options: .atomic)
        let controller = AIChatController()
        try await controller.attachReferenceImage(from: source)
        let cached = try #require(controller.referenceImageURL)
        #expect(cached != source)
        #expect(controller.referenceImageName == source.lastPathComponent)
        #expect(FileManager.default.isReadableFile(atPath: cached.path))
        controller.clearReferenceImage()
        #expect(controller.referenceImageURL == nil)
    }

    @Test func referenceAnalysisAndImageToolAreInTheStrictSchema() throws {
        let data = try #require(LocalAgentRunner.schema.data(using: .utf8))
        _ = try JSONSerialization.jsonObject(with: data)
        #expect(LocalAgentRunner.schema.contains("referenceAnalysis"))
        #expect(LocalAgentRunner.schema.contains("generate_image"))
        let prompt = LocalAgentRunner.prompt(userText: "Rebuild this design", history: [], context: "Canvas: none",
            hasReferenceImage: true)
        #expect(prompt.contains("Reference image attached: yes"))
        #expect(prompt.contains("Never bake text"))
    }

    @Test func localAgentSearchesHomebrewAppBundlesAndPath() {
        let paths = LocalAgentRunner.executableCandidates(for: .codex,
            environment: ["PATH": "/custom/bin:/opt/homebrew/bin"])
        #expect(paths.first == "/opt/homebrew/bin/codex")
        #expect(paths.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        #expect(paths.contains("/custom/bin/codex"))
        #expect(paths.filter { $0 == "/opt/homebrew/bin/codex" }.count == 1)
    }

}
