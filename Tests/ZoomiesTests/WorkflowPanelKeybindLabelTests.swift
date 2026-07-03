import XCTest
import AppKit
@testable import Zoomies

final class WorkflowPanelKeybindLabelTests: XCTestCase {
    func testRenamePanelShowsKeybinds() throws {
        let controller = RenamePanelController(initialFilename: "Screenshot_01.24.45.png")
        let allLabels = findLabels(in: controller.window?.contentView)
        let labels = allLabels.map(\.stringValue)

        XCTAssertTrue(labels.contains("Rename"))
        XCTAssertTrue(labels.contains { $0.contains("Keys:") })
        XCTAssertTrue(labels.contains { $0.contains("Enter: Save") })
        XCTAssertTrue(labels.contains { $0.contains("Cmd+Enter: Copy+Save") })
        XCTAssertTrue(labels.contains { $0.contains("Tab: Note") })
        XCTAssertEqual(controller.window?.contentView?.frame.width ?? 0, 410, accuracy: 0.5)
        XCTAssertEqual(keybindLabel(in: allLabels)?.preferredMaxLayoutWidth ?? 0, 370, accuracy: 0.5)
    }

    func testPromptPanelShowsKeybinds() throws {
        let controller = NotePanelController(initialText: "prompt for agent")
        let allLabels = findLabels(in: controller.window?.contentView)
        let labels = allLabels.map(\.stringValue)

        XCTAssertTrue(labels.contains("Prompt / Note"))
        XCTAssertTrue(labels.contains { $0.contains("Keys:") })
        XCTAssertTrue(labels.contains { $0.contains("Shift+Tab: Rename") })
        XCTAssertTrue(labels.contains { $0.contains("Tab: Edit") })
        XCTAssertEqual(controller.window?.contentView?.frame.width ?? 0, 410, accuracy: 0.5)
        XCTAssertEqual(keybindLabel(in: allLabels)?.preferredMaxLayoutWidth ?? 0, 370, accuracy: 0.5)
    }

    func testEditorWindowShowsKeybinds() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let settingsStore = SettingsStore(fileManager: .default,
                                          fileURL: root.appendingPathComponent("settings.json"))
        let controller = EditorWindowController(image: TestSupport.solidImage(),
                                                settingsStore: settingsStore)
        let labels = findLabels(in: controller.window?.contentView).map(\.stringValue)

        XCTAssertTrue(labels.contains { $0.contains("Tools: W Pen") })
        XCTAssertTrue(labels.contains { $0.contains("K/Q Colors") })
        XCTAssertTrue(labels.contains { $0.contains("Shift+Tab Prompt") })
        XCTAssertTrue(labels.contains { $0.contains("Cmd+Enter Copy+Save") })
        XCTAssertLessThanOrEqual(controller.window?.contentView?.frame.width ?? 0, 600)
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

    private func keybindLabel(in labels: [NSTextField]) -> NSTextField? {
        labels.first { $0.stringValue.contains("Keys:") }
    }
}
