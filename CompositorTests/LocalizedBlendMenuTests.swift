import AppKit
import Testing
@testable import Compositor

@MainActor
struct LocalizedBlendMenuTests {
    @Test func groupedMenuPreservesEveryModesIdentity() {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        BlendModePicker.populateMenu(button)
        let items = button.itemArray.filter { !$0.isSeparatorItem }
        #expect(items.compactMap { $0.representedObject as? String } == LayerBlendMode.allCases.map(\.rawValue))
        #expect(button.itemArray.filter(\.isSeparatorItem).count == LayerBlendMode.groups.count - 1)
    }

    @Test func choosingAfterASeparatorUsesIdentityNotMenuIndex() throws {
        let session = EditorSession()
        session.createDocument(width: 20, height: 20)
        session.addBlankLayer()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        BlendModePicker.populateMenu(button)
        let coordinator = BlendModePicker.Coordinator(session: session)
        let menu = try #require(button.menu)
        let item = try #require(button.itemArray.first { ($0.representedObject as? String) == LayerBlendMode.screen.rawValue })
        coordinator.menuWillOpen(menu)
        button.select(item)
        coordinator.choose(button)
        #expect(session.activeLayer?.blendMode == .screen)
        coordinator.menuWillOpen(menu)
        let color = try #require(button.itemArray.first { ($0.representedObject as? String) == LayerBlendMode.color.rawValue })
        coordinator.menu(menu, willHighlight: color)
        coordinator.choose(button)
        #expect(session.activeLayer?.blendMode == .color)
        #expect(button.selectedItem === color)
        session.previewBlendMode(nil, for: nil)
    }
}
