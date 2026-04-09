import XCTest
import AppKit
@testable import Zoomies

final class WorkflowNoteRendererTests: XCTestCase {
    func testPrepareNoteTextAppliesPrefixAndTrimRules() {
        var settings = Settings.default
        settings.notePrefixEnabled = true
        settings.notePrefix = "TODO"

        let note = WorkflowNoteRenderer.prepareNoteText("  hello world  ", settings: settings)

        XCTAssertEqual(note, WorkflowPreparedNote(identity: "hello world", rendered: "TODO hello world"))
    }

    func testPrepareNoteTextReturnsNilForBlankInput() {
        XCTAssertNil(WorkflowNoteRenderer.prepareNoteText("   ", settings: .default))
    }

    func testBurnAddsBottomNoteAreaAndMinimumWidth() throws {
        let image = TestSupport.solidImage(width: 120, height: 60, color: .systemBlue)

        let rendered = try XCTUnwrap(WorkflowNoteRenderer.burn(note: "Short note", into: image))

        XCTAssertEqual(rendered.size.width, 400, accuracy: 0.5)
        XCTAssertGreaterThan(rendered.size.height, 60)
    }
}
