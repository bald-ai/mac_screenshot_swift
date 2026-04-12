import XCTest
@testable import Zoomies

final class ScreenshotWorkflowCoreLogicTests: XCTestCase {
    func testEditableFilenameHidesExtensionForRenameField() {
        XCTAssertEqual(WorkflowFilenameLogic.editableFilename("Screenshot_18.59.19.jpg"), "Screenshot_18.59.19")
        XCTAssertEqual(WorkflowFilenameLogic.editableFilename("Screenshot"), "Screenshot")
    }

    func testSanitizeFilenameRemovesForbiddenCharactersAndPreservesExtension() {
        let originalURL = URL(fileURLWithPath: "/tmp/image.jpg")
        let sanitized = WorkflowFilenameLogic.sanitizeFilename("  bad:/name.jpg  ", preservingExtensionOf: originalURL)
        XCTAssertEqual(sanitized, "badname.jpg")
    }

    func testSanitizeFilenameFallsBackToOriginalBaseWhenBlank() {
        let originalURL = URL(fileURLWithPath: "/tmp/Original Name.png")
        let sanitized = WorkflowFilenameLogic.sanitizeFilename("  :/  ", preservingExtensionOf: originalURL)
        XCTAssertEqual(sanitized, "Original Name.png")
    }

    func testUniqueURLAddsSuffixWhenNeeded() {
        let dir = URL(fileURLWithPath: "/tmp")
        let taken = Set(["/tmp/Capture.jpg", "/tmp/Capture_2.jpg"])
        let output = WorkflowFilenameLogic.uniqueURL(forProposedName: "Capture.jpg", in: dir) { taken.contains($0) }
        XCTAssertEqual(output.lastPathComponent, "Capture_3.jpg")
    }

    func testIsSameFilenameTreatsMissingDisplayedExtensionAsUnchanged() {
        let originalURL = URL(fileURLWithPath: "/tmp/Screenshot_18.59.19.jpg")
        XCTAssertTrue(WorkflowFilenameLogic.isSameFilename("Screenshot_18.59.19", as: originalURL))
        XCTAssertFalse(WorkflowFilenameLogic.isSameFilename("Screenshot_18.59.20", as: originalURL))
    }

    func testWrapTextHandlesWhitespaceAndLongWords() {
        let lines = WorkflowTextWrapLogic.wrapText("   hello   world  ", maxWidth: 5) { CGFloat($0.count) }
        XCTAssertEqual(lines, ["hello", "world"])

        let longWord = WorkflowTextWrapLogic.wrapText("abcdefghijk", maxWidth: 4) { CGFloat($0.count) }
        XCTAssertEqual(longWord, ["abcd", "efgh", "ijk"])
    }

    func testWrapTextReturnsSingleEmptyLineForEmptyInput() {
        let lines = WorkflowTextWrapLogic.wrapText("   ", maxWidth: 10) { CGFloat($0.count) }
        XCTAssertEqual(lines, [""])
    }
}
