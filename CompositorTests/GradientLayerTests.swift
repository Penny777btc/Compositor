import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor struct GradientLayerTests {
    private let bluePink = LayerGradientStyle(kind: .linear, stops: [
        LayerGradientStop(red: 0.1, green: 0.35, blue: 0.95, location: 0),
        LayerGradientStop(red: 0.95, green: 0.15, blue: 0.55, location: 1),
    ], angle: 0)

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    @Test func aiCreatesOneSmoothEditableGradientInsteadOfShapeBands() throws {
        let session = EditorSession()
        let plan = try JSONDecoder().decode(AIEditorPlan.self, from: Data(#"""
        {
          "message":"Created a smooth gradient",
          "actions":[
            {"type":"create_canvas","width":101,"height":20},
            {"type":"add_gradient","name":"Background","gradient":"linear","colors":["#1A59F2","#F2268C"],"locations":[0,1],"angle":0,"width":101,"height":20,"x":0,"y":0}
          ]
        }
        """#.utf8))
        let results = AIEditorEngine.execute(plan, in: session)
        let layer = try #require(session.document?.layers.first)
        let gradient = try #require(layer.liveGradient)
        #expect(results.count == 2 && session.document?.layers.count == 1)
        #expect(gradient.style.kind == .linear && gradient.style.stops.count == 2)
        let left = try pixel(gradient.image, x: 0, y: 10)
        let middle = try pixel(gradient.image, x: 50, y: 10)
        let right = try pixel(gradient.image, x: 100, y: 10)
        #expect(left[2] > left[0] && right[0] > right[2])
        #expect(middle[0] > left[0] && middle[0] < right[0])
    }

    @Test func gradientStaysEditableAndRoundTrips() async throws {
        let session = EditorSession()
        session.createDocument(width: 320, height: 180)
        let id = try session.addGradientLayer(style: bluePink,
            frame: CGRect(x: 0, y: 0, width: 320, height: 180), name: "Background")
        var edited = bluePink
        edited.angle = 35
        try session.updateGradientLayer(id, style: edited)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 11)
        #expect(snapshot.manifest.layers.first?.gradient == edited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorGradientTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.shared.save(snapshot, to: root)
        let loaded = try await ProjectStore.shared.load(from: root)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: root)
        #expect(reopened.activeLayer?.liveGradient?.style == edited)
    }

    @Test func promptForbidsShapeBandSimulation() {
        let prompt = LocalAgentRunner.prompt(userText: "make a blue pink gradient", history: [], context: "Canvas: none")
        #expect(prompt.contains("must use add_gradient"))
        #expect(prompt.contains("imitate one unsupported visual effect"))
    }

    @Test func commandSchemaContainsNativeGradientActions() throws {
        let data = try #require(LocalAgentRunner.schema.data(using: .utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["type"] as? String == "object")
        #expect(LocalAgentRunner.schema.contains("add_gradient"))
        #expect(LocalAgentRunner.schema.contains("edit_gradient"))
    }

    @Test func executorRejectsLegacyGradientBands() throws {
        let session = EditorSession()
        let bands = (0..<8).map { index in
            AIEditorAction(type: "add_shape", name: "Band \(index)", shape: "rectangle",
                color: String(format: "#%02X0080", index * 30), width: 10, height: 40,
                x: Double(index * 10), y: 0)
        }
        let actions = [AIEditorAction(type: "create_canvas", width: 80, height: 40)] + bands
        let result = AIEditorEngine.execute(AIEditorPlan(message: "", actions: actions), in: session)
        #expect(session.document == nil)
        #expect(result.count == 1)
    }

}
