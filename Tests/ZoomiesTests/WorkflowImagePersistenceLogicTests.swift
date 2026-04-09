import XCTest
import AppKit
@testable import Zoomies

final class WorkflowImagePersistenceLogicTests: XCTestCase {
    func testEncodedImageDataConvertsHeicExtensionToUniqueJpgURL() throws {
        let image = TestSupport.solidImage(width: 80, height: 40, color: .systemRed)
        let originalURL = URL(fileURLWithPath: "/tmp/example.heic")

        let encoded = try XCTUnwrap(
            WorkflowImagePersistenceLogic.encodedImageData(
                from: image,
                originalURL: originalURL,
                quality: 95,
                uniqueURL: { proposedName, directory in
                    XCTAssertEqual(proposedName, "example.jpg")
                    return directory.appendingPathComponent("example_2.jpg")
                }
            )
        )

        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(encoded.outputURL.lastPathComponent, "example_2.jpg")
    }

    func testWriteEncodedImageDataRemovesOriginalWhenOutputMoves() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let originalURL = root.appendingPathComponent("shot.heic")
        let outputURL = root.appendingPathComponent("shot.jpg")
        let fileManager = FileManager.default

        try Data("old".utf8).write(to: originalURL, options: .atomic)

        let finalURL = try WorkflowImagePersistenceLogic.writeEncodedImageData(
            Data("new".utf8),
            to: outputURL,
            originalURL: originalURL,
            fileManager: fileManager
        )

        XCTAssertEqual(finalURL, outputURL)
        XCTAssertTrue(fileManager.fileExists(atPath: outputURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: originalURL.path))
    }
}
