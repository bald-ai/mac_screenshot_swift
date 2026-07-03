import XCTest
import AppKit
@testable import Zoomies

final class WorkflowPanelLayoutTests: XCTestCase {
    func testRenamePanelStaysCompactWithoutKeybindLabels() throws {
        let controller = RenamePanelController(initialFilename: "Screenshot_01.24.45.png")
        let labels = findLabels(in: controller.window?.contentView).map(\.stringValue)

        XCTAssertEqual(controller.window?.contentView?.frame.width ?? 0, 410, accuracy: 0.5)
        XCTAssertEqual(controller.window?.contentView?.frame.height ?? 0, 96, accuracy: 0.5)
        XCTAssertFalse(labels.contains { $0.contains("Keys:") || $0.contains("Cmd+Enter") })
    }

    func testPromptPanelStaysCompactWithoutKeybindLabels() throws {
        let controller = NotePanelController(initialText: "prompt for agent")
        let labels = findLabels(in: controller.window?.contentView).map(\.stringValue)

        XCTAssertEqual(controller.window?.contentView?.frame.width ?? 0, 410, accuracy: 0.5)
        XCTAssertEqual(controller.window?.contentView?.frame.height ?? 0, 120, accuracy: 0.5)
        XCTAssertFalse(labels.contains { $0.contains("Keys:") || $0.contains("Cmd+Enter") })
    }

    func testEditorWindowDoesNotShowKeybindLabel() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let settingsStore = SettingsStore(fileManager: .default,
                                          fileURL: root.appendingPathComponent("settings.json"))
        let controller = EditorWindowController(image: TestSupport.solidImage(),
                                                settingsStore: settingsStore)
        let labels = findLabels(in: controller.window?.contentView).map(\.stringValue)

        XCTAssertFalse(labels.contains { $0.contains("Tools:") || $0.contains("Cmd+Enter Copy+Save") })
    }

    private func findLabels(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var result: [NSTextField] = []
        if let label = view as? NSTextField {
            result.append(label)
        }
        for subview in view.subviews {
            result.append(contentsOf: findLabels(in: subview))
        }
        return result
    }
}
