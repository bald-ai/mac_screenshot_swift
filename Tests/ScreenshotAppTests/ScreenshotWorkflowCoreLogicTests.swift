import XCTest
@testable import ScreenshotApp

final class ScreenshotWorkflowCoreLogicTests: XCTestCase {
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
