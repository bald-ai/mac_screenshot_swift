import XCTest
import AppKit
@testable import Zoomies

final class NotePanelControllerTests: XCTestCase {
    func testNotePanelLocksEditorTextToWhite() throws {
        let controller = NotePanelController(initialText: "hello")
        let textView = try XCTUnwrap(findTextView(in: controller.window?.contentView))

        XCTAssertEqual(textView.textColor, .white)
        XCTAssertEqual(textView.insertionPointColor, .white)
        XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? NSColor, .white)

        textView.typingAttributes[.foregroundColor] = NSColor.black
        textView.textStorage?.addAttribute(.foregroundColor,
                                           value: NSColor.black,
                                           range: NSRange(location: 0, length: textView.string.count))
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))

        XCTAssertEqual(textView.textColor, .white)
        XCTAssertEqual(textView.insertionPointColor, .white)
        XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? NSColor, .white)

        let effectiveColor = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(effectiveColor, .white)
    }

    func testScratchpadModeUsesNotePanelWithoutScreenshotOnlyActions() throws {
        let controller = NotePanelController(initialText: "",
                                             escapeKeyDeletesFile: false,
                                             showsCopyAndDelete: false,
                                             showsEditorShortcut: false)
        let labels = findLabels(in: controller.window?.contentView).map(\.stringValue)

        XCTAssertTrue(labels.contains("Note"))
        XCTAssertTrue(labels.contains { $0.contains("Esc: Close") })
        XCTAssertTrue(labels.contains { $0.contains("Shift+Tab: Rename") })
        XCTAssertFalse(labels.contains { $0.contains("Copy+Delete") })
        XCTAssertFalse(labels.contains { $0.contains("Tab: Editor") })
    }

    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }

        return nil
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
