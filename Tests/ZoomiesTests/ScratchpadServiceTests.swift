import XCTest
import AppKit
@testable import Zoomies

final class ScratchpadServiceTests: XCTestCase {
    func testWriteWritesUTF8MarkdownFile() throws {
        let desktop = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(desktop) }
        let writer = ScratchpadNoteWriter(directory: desktop)

        let url = try writer.write(text: "hello", baseName: "Note A")

        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "Note A")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, "hello")
    }

    func testWriteCreatesUniqueFilenameOnCollision() throws {
        let desktop = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(desktop) }
        let writer = ScratchpadNoteWriter(directory: desktop)

        let first = try writer.write(text: "a", baseName: "Dup")
        let second = try writer.write(text: "b", baseName: "Dup")

        XCTAssertEqual(first.lastPathComponent, "Dup.md")
        XCTAssertEqual(second.lastPathComponent, "Dup_2.md")
        XCTAssertNotEqual(first, second)
    }

    func testWriteCreatesDirectoryIfMissing() throws {
        let base = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(base) }
        let missingDesktop = base.appendingPathComponent("nested/desktop", isDirectory: true)
        let writer = ScratchpadNoteWriter(directory: missingDesktop)

        let url = try writer.write(text: "x", baseName: "N")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
