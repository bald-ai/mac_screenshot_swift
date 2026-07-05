import XCTest
import AppKit
@testable import Zoomies

final class WorkflowImagePersistenceLogicTests: XCTestCase {
    func testEncodedImageDataConvertsNonPngExtensionToUniquePngURL() throws {
        let image = TestSupport.solidImage(width: 80, height: 40, color: .systemRed)
        let originalURL = URL(fileURLWithPath: "/tmp/example.heic")

        let encoded = try XCTUnwrap(
            WorkflowImagePersistenceLogic.encodedImageData(
                from: image,
                originalURL: originalURL,
                uniqueURL: { proposedName, directory in
                    XCTAssertEqual(proposedName, "example.png")
                    return directory.appendingPathComponent("example_2.png")
                }
            )
        )

        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(encoded.outputURL.lastPathComponent, "example_2.png")
    }

    func testEncodedImageDataEmbedsRoundTripMetadataForPNG() throws {
        let image = TestSupport.solidImage(width: 60, height: 30, color: .systemRed)
        let original = try TestSupport.solidImagePNGData(width: 40, height: 20, color: .systemBlue)

        let encoded = try XCTUnwrap(
            WorkflowImagePersistenceLogic.encodedImageData(
                from: image,
                originalURL: URL(fileURLWithPath: "/tmp/example.png"),
                cleanOriginalPNG: original,
                prompt: "embed me",
                uniqueURL: { name, directory in directory.appendingPathComponent(name) }
            )
        )

        let extracted = try XCTUnwrap(PNGMetadata.extract(fromPNG: encoded.data))
        XCTAssertEqual(extracted.prompt, "embed me")
        XCTAssertEqual(extracted.originalPNG, original)
    }

    func testEncodedImageDataEmbedsEditorStateWithoutPrompt() throws {
        let image = TestSupport.solidImage(width: 60, height: 30, color: .systemRed)
        let base = try TestSupport.solidImagePNGData(width: 40, height: 20, color: .systemBlue)
        let state = EditorCanvasState(
            baseImagePNG: base,
            items: [.arrow(start: .init(NSPoint(x: 1, y: 2)),
                           end: .init(NSPoint(x: 20, y: 10)),
                           color: .init(.systemRed),
                           lineWidth: 4)]
        )

        let encoded = try XCTUnwrap(
            WorkflowImagePersistenceLogic.encodedImageData(
                from: image,
                originalURL: URL(fileURLWithPath: "/tmp/example.png"),
                editorState: state,
                uniqueURL: { name, directory in directory.appendingPathComponent(name) }
            )
        )

        let extracted = try XCTUnwrap(PNGMetadata.extractEditorState(fromPNG: encoded.data))
        XCTAssertEqual(extracted.baseImagePNG, base)
        XCTAssertEqual(extracted.items, state.items)
    }

    func testEncodedImageDataEmbedsPromptAndEditorStateTogether() throws {
        let image = TestSupport.solidImage(width: 60, height: 30, color: .systemRed)
        let original = try TestSupport.solidImagePNGData(width: 40, height: 20, color: .systemBlue)
        let state = EditorCanvasState(
            baseImagePNG: original,
            items: [.text(.init(text: "label",
                                origin: .init(NSPoint(x: 8, y: 9)),
                                color: .init(.systemBlue),
                                fontSize: 18))]
        )

        let encoded = try XCTUnwrap(
            WorkflowImagePersistenceLogic.encodedImageData(
                from: image,
                originalURL: URL(fileURLWithPath: "/tmp/example.png"),
                cleanOriginalPNG: original,
                prompt: "embed me",
                editorState: state,
                uniqueURL: { name, directory in directory.appendingPathComponent(name) }
            )
        )

        let note = try XCTUnwrap(PNGMetadata.extract(fromPNG: encoded.data))
        let extractedState = try XCTUnwrap(PNGMetadata.extractEditorState(fromPNG: encoded.data))
        XCTAssertEqual(note.prompt, "embed me")
        XCTAssertEqual(note.originalPNG, original)
        XCTAssertEqual(extractedState.items, state.items)
    }

    func testEncodedImageDataSkipsEmbeddingWhenPromptEmpty() throws {
        let image = TestSupport.solidImage(width: 60, height: 30)
        let original = try TestSupport.solidImagePNGData(width: 40, height: 20)

        let encoded = try XCTUnwrap(
            WorkflowImagePersistenceLogic.encodedImageData(
                from: image,
                originalURL: URL(fileURLWithPath: "/tmp/example.png"),
                cleanOriginalPNG: original,
                prompt: "",
                uniqueURL: { name, directory in directory.appendingPathComponent(name) }
            )
        )

        XCTAssertNil(PNGMetadata.extract(fromPNG: encoded.data))
    }

    func testEncodedImageDataRewritesNonPNGInputToPNGAndEmbeds() throws {
        // PNG-only: a non-PNG input is rewritten to .png on save and still
        // carries the round-trip metadata.
        let image = TestSupport.solidImage(width: 60, height: 30)
        let original = try TestSupport.solidImagePNGData(width: 40, height: 20)

        let encoded = try XCTUnwrap(
            WorkflowImagePersistenceLogic.encodedImageData(
                from: image,
                originalURL: URL(fileURLWithPath: "/tmp/example.jpg"),
                cleanOriginalPNG: original,
                prompt: "embed me",
                uniqueURL: { name, directory in directory.appendingPathComponent(name) }
            )
        )

        XCTAssertEqual(encoded.outputURL.pathExtension, "png")
        XCTAssertTrue(PNGMetadata.isPNG(encoded.data))
        let extracted = try XCTUnwrap(PNGMetadata.extract(fromPNG: encoded.data))
        XCTAssertEqual(extracted.prompt, "embed me")
        XCTAssertEqual(extracted.originalPNG, original)
    }

    func testWriteEncodedImageDataRemovesOriginalWhenOutputMoves() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let originalURL = root.appendingPathComponent("shot.heic")
        let outputURL = root.appendingPathComponent("shot.png")
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
