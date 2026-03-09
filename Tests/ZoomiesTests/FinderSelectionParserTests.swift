import XCTest
@testable import Zoomies

final class FinderSelectionParserTests: XCTestCase {
    func testParsesNoneAndEmpty() {
        XCTAssertEqual(FinderSelectionParser.parseSelectionResult("NONE"), .none)
        XCTAssertEqual(FinderSelectionParser.parseSelectionResult("   "), .none)
    }

    func testParsesMultipleWithMinimumTwo() {
        XCTAssertEqual(FinderSelectionParser.parseSelectionResult("MULTI:7"), .multiple(count: 7))
        XCTAssertEqual(FinderSelectionParser.parseSelectionResult("MULTI:1"), .multiple(count: 2))
        XCTAssertEqual(FinderSelectionParser.parseSelectionResult("MULTI:x"), .multiple(count: 2))
    }

    func testParsesSingleWithExistingPath() {
        let result = FinderSelectionParser.parseSelectionResult("ONE:/tmp/test.png", fileExists: { $0 == "/tmp/test.png" })
        switch result {
        case .single(let url):
            XCTAssertEqual(url.path, "/tmp/test.png")
        default:
            XCTFail("Expected .single")
        }
    }

    func testParsesSingleMissingPathAsNone() {
        let result = FinderSelectionParser.parseSelectionResult("ONE:/tmp/missing.png", fileExists: { _ in false })
        XCTAssertEqual(result, .none)
    }

    func testUnexpectedValueBecomesNone() {
        XCTAssertEqual(FinderSelectionParser.parseSelectionResult("UNKNOWN"), .none)
    }

    func testSelectionReturnsFirstNonNoneResultWithoutRetry() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }
        let file = root.appendingPathComponent("picked.png")
        try Data("x".utf8).write(to: file, options: .atomic)

        var calls = 0
        let result = try FinderSelectionService.selection { _ in
            calls += 1
            return "ONE:\(file.path)"
        }

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result, .single(url: file))
    }

    func testSelectionRetriesAfterNoneAndReturnsSecondResult() throws {
        var callIndex = 0
        let result = try FinderSelectionService.selection { _ in
            callIndex += 1
            return callIndex == 1 ? "NONE" : "MULTI:3"
        }

        XCTAssertEqual(callIndex, 2)
        XCTAssertEqual(result, .multiple(count: 3))
    }

    func testSelectionReturnsNoneAfterTwoNoneResponses() throws {
        var calls = 0
        let result = try FinderSelectionService.selection { _ in
            calls += 1
            return "NONE"
        }

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result, .none)
    }

    func testSelectionPropagatesScriptError() {
        XCTAssertThrowsError(try FinderSelectionService.selection { _ in
            throw NSError(domain: "FinderSelectionServiceTests", code: -9)
        })
    }
}
