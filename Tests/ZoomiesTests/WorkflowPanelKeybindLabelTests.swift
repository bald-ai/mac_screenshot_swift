import XCTest
import AppKit
@testable import Zoomies

final class WorkflowPanelKeybindLabelTests: XCTestCase {
    func testRenamePanelShowsKeybinds() throws {
        let controller = RenamePanelController(initialFilename: "Screenshot_01.24.45.png")
        let labels = findLabels(in: controller.window?.contentView).map(\.stringValue)

        XCTAssertTrue(labels.contains("Rename"))
        XCTAssertTrue(labels.contains { $0.contains("Keys:") })
        XCTAssertTrue(labels.contains { $0.contains("Enter: Save") })
        XCTAssertTrue(labels.contains { $0.contains("Cmd+Enter: Copy+Save") })
        XCTAssertTrue(labels.contains { $0.contains("Tab: Note") })
    }

    func testPromptPanelShowsKeybinds() throws {
        let controller = NotePanelController(initialText: "prompt for agent")
        let labels = findLabels(in: controller.window?.contentView).map(\.stringValue)

        XCTAssertTrue(labels.contains("Prompt / Note"))
        XCTAssertTrue(labels.contains { $0.contains("Keys:") })
        XCTAssertTrue(labels.contains { $0.contains("Shift+Tab: Rename") })
        XCTAssertTrue(labels.contains { $0.contains("Tab: Edit") })
    }

    func testEditorWindowShowsKeybinds() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let settingsStore = SettingsStore(fileManager: .default,
                                          fileURL: root.appendingPathComponent("settings.json"))
        let controller = EditorWindowController(image: TestSupport.solidImage(),
                                                settingsStore: settingsStore)
        let labels = findLabels(in: controller.window?.contentView).map(\.stringValue)

        XCTAssertTrue(labels.contains { $0.contains("Keys: W Pen") })
        XCTAssertTrue(labels.contains { $0.contains("K/Q Colors") })
        XCTAssertTrue(labels.contains { $0.contains("Shift+Tab Prompt") })
        XCTAssertTrue(labels.contains { $0.contains("Cmd+Enter Copy+Save") })
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
