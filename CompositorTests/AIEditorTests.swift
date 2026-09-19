import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor struct AIEditorTests {
    @Test func createsCanvasAndEditableShapeAsOneUndoStep() throws {
        let session = EditorSession()
        let count = session.history.undoCount
        let plan = try JSONDecoder().decode(AIEditorPlan.self, from: Data(#"""
        {
          "message": "Made a card",
          "actions": [
            {"type":"create_canvas","width":1920,"height":1080},
            {"type":"add_shape","name":"Hero Card","shape":"rectangle","color":"#246BFD","width":800,"height":360,"x":560,"y":360,"cornerRadius":48}
          ]
        }
        """#.utf8))

        let results = AIEditorEngine.execute(plan, in: session)
        let document = try #require(session.document)
        let layer = try #require(document.layers.first)
        #expect(document.width == 1920 && document.height == 1080)
        #expect(layer.name == "Hero Card")
        #expect(layer.transform.origin == CGPoint(x: 560, y: 360))
        #expect(layer.transform.size == CGSize(width: 800, height: 360))
        #expect(layer.liveShape?.style.cornerRadius == 48)
        #expect(results.count == 2)
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.document == nil)
    }

    @Test func editsAnExistingLayerByStableID() throws {
        let session = EditorSession()
        session.createDocument(width: 640, height: 480, emptyLayer: true)
        let id = try #require(session.activeLayerID)
        let json = """
        {
          "message": "Updated the layer",
          "actions": [
            {"type":"rename_layer","layerID":"\(id.uuidString)","name":"Card"},
            {"type":"set_opacity","layerID":"\(id.uuidString)","opacity":65},
            {"type":"set_visibility","layerID":"\(id.uuidString)","visible":false},
            {"type":"transform_layer","layerID":"\(id.uuidString)","x":12,"y":24,"width":320,"height":180,"rotation":15}
          ]
        }
        """
        let plan = try JSONDecoder().decode(AIEditorPlan.self, from: Data(json.utf8))
        _ = AIEditorEngine.execute(plan, in: session)
        let layer = try #require(session.document?.layers.first)
        #expect(layer.name == "Card")
        #expect(layer.opacity == 0.65)
        #expect(!layer.isVisible)
        #expect(layer.transform == LayerTransform(origin: CGPoint(x: 12, y: 24),
            size: CGSize(width: 320, height: 180), rotation: 15))
    }
}
