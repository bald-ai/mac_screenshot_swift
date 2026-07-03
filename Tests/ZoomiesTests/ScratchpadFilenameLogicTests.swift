import XCTest
@testable import Zoomies

final class ScratchpadFilenameLogicTests: XCTestCase {
    func testDefaultBaseNameFormat() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        // Build the expected value with an identically-configured formatter so the
        // assertion is deterministic across machines (both use the local timezone).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let expected = "Note \(formatter.string(from: date))"

        XCTAssertEqual(ScratchpadFilenameLogic.defaultBaseName(date: date), expected)

        // And sanity-check the shape regardless of date/timezone.
        let pattern = #"^Note \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}$"#
        XCTAssertNotNil(expected.range(of: pattern, options: .regularExpression))
    }

    func testResolveBaseNameStripsMdExtension() {
        let resolved = ScratchpadFilenameLogic.resolveBaseName(userInput: "meeting-notes.md", fallback: "Fallback")
        XCTAssertEqual(resolved, "meeting-notes")
    }

    func testResolveBaseNameSanitizesSlashesAndColons() {
        let resolved = ScratchpadFilenameLogic.resolveBaseName(userInput: "a/b:c", fallback: "Fallback")
        XCTAssertEqual(resolved, "abc")
    }

    func testResolveBaseNameFallbackOnEmpty() {
        let resolved = ScratchpadFilenameLogic.resolveBaseName(userInput: "", fallback: "Fallback")
        XCTAssertEqual(resolved, "Fallback")
    }

    func testResolveBaseNameFallbackOnWhitespace() {
        let resolved = ScratchpadFilenameLogic.resolveBaseName(userInput: "    ", fallback: "Fallback")
        XCTAssertEqual(resolved, "Fallback")
    }

    func testResolveBaseNameFallbackOnNil() {
        let resolved = ScratchpadFilenameLogic.resolveBaseName(userInput: nil, fallback: "Fallback")
        XCTAssertEqual(resolved, "Fallback")
    }
}
