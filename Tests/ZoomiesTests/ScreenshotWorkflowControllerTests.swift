import XCTest
import AppKit
@testable import Zoomies

final class ScreenshotWorkflowControllerTests: XCTestCase {
    func testHandleEditorCompletionSaveOnlyPersistsEditedImage() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("shot.png")
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)
        let workflow = try makeWorkflow(root: root, fileURL: fileURL, clipboardDirectory: clipboardDirectory)

        let finished = expectation(description: "workflow finished")
        workflow.onFinish = { finished.fulfill() }

        let editedImage = TestSupport.solidImage(width: 180, height: 90, color: .systemRed)
        workflow.handleEditorCompletion(editedImage: editedImage, action: .saveOnly)
        wait(for: [finished], timeout: 2.0)

        let saved = try XCTUnwrap(NSImage(contentsOf: fileURL))
        XCTAssertEqual(saved.size.width, 180, accuracy: 1.0)
        XCTAssertEqual(saved.size.height, 90, accuracy: 1.0)

        let cachedFiles = try FileManager.default.contentsOfDirectory(at: clipboardDirectory,
                                                                      includingPropertiesForKeys: nil)
        XCTAssertTrue(cachedFiles.isEmpty)
    }

    func testHandleEditorCompletionCopyAndDeleteDeletesOriginalAndCachesEditedImage() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("shot.png")
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)
        let workflow = try makeWorkflow(root: root, fileURL: fileURL, clipboardDirectory: clipboardDirectory)

        let finished = expectation(description: "workflow finished")
        workflow.onFinish = { finished.fulfill() }

        let editedImage = TestSupport.solidImage(width: 140, height: 70, color: .systemGreen)
        workflow.handleEditorCompletion(editedImage: editedImage, action: .copyAndDelete)
        wait(for: [finished], timeout: 2.0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let cachedFiles = try FileManager.default.contentsOfDirectory(at: clipboardDirectory,
                                                                      includingPropertiesForKeys: nil)
        XCTAssertEqual(cachedFiles.count, 1)
        XCTAssertEqual(cachedFiles.first?.lastPathComponent, "shot.png")
    }

    func testRenameSaveBurnsPendingNoteFromPreviousNotePanelVisit() throws {
        // Regression: typing a note, returning to Rename via Shift+Tab, then saving
        // from Rename used to silently drop the note text.
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("shot.png")
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)
        let workflow = try makeWorkflow(root: root, fileURL: fileURL, clipboardDirectory: clipboardDirectory)

        let originalImage = try XCTUnwrap(NSImage(contentsOf: fileURL))
        let originalHeight = originalImage.size.height

        let finished = expectation(description: "workflow finished")
        workflow.onFinish = { finished.fulfill() }

        // Simulate: user typed text in the Note panel, then pressed Shift+Tab to return
        // to the Rename panel. (Setting the field directly avoids spawning a real window.)
        workflow.pendingNoteText = "prompt for the AI"
        // Then user pressed Enter on the Rename panel to save.
        workflow.handleRenameAction(.save(newName: fileURL.lastPathComponent))

        wait(for: [finished], timeout: 2.0)

        let saved = try XCTUnwrap(NSImage(contentsOf: fileURL))
        XCTAssertGreaterThan(saved.size.height,
                             originalHeight,
                             "Saved image should be taller because the carried-over note text was burned in.")
    }

    func testRenameSaveWithoutPendingNoteLeavesImageUntouched() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("shot.png")
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)
        let workflow = try makeWorkflow(root: root, fileURL: fileURL, clipboardDirectory: clipboardDirectory)

        let originalImage = try XCTUnwrap(NSImage(contentsOf: fileURL))
        let originalHeight = originalImage.size.height

        let finished = expectation(description: "workflow finished")
        workflow.onFinish = { finished.fulfill() }

        workflow.handleRenameAction(.save(newName: fileURL.lastPathComponent))

        wait(for: [finished], timeout: 2.0)

        let saved = try XCTUnwrap(NSImage(contentsOf: fileURL))
        XCTAssertEqual(saved.size.height, originalHeight, accuracy: 1.0)
    }

    func testHandleEditorCompletionWaitsForPendingInitialPersistence() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("pending-shot.png")
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)
        let initialImage = TestSupport.solidImage(width: 80, height: 40, color: .systemBlue)
        let initialPersistence = Task<URL, Error> {
            try await Task.sleep(nanoseconds: 150_000_000)
            try TestSupport.writeSolidImagePNG(to: fileURL, width: 80, height: 40, color: .systemBlue)
            return fileURL
        }

        let workflow = try makeWorkflow(root: root,
                                        fileURL: fileURL,
                                        clipboardDirectory: clipboardDirectory,
                                        initialImage: initialImage,
                                        initialFilePersistence: initialPersistence,
                                        writeOriginalFile: false)

        let finished = expectation(description: "workflow finished")
        workflow.onFinish = { finished.fulfill() }

        let editedImage = TestSupport.solidImage(width: 180, height: 90, color: .systemRed)
        workflow.handleEditorCompletion(editedImage: editedImage, action: .saveOnly)
        wait(for: [finished], timeout: 3.0)

        let saved = try XCTUnwrap(NSImage(contentsOf: fileURL))
        XCTAssertEqual(saved.size.width, 180, accuracy: 1.0)
        XCTAssertEqual(saved.size.height, 90, accuracy: 1.0)
    }

    func testSaveThenReopenRoundTripsCleanImageAndPrompt() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("shot.png")
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)

        // Save a screenshot with a note. The burned PNG embeds the clean original + prompt.
        let saveWorkflow = try makeWorkflow(root: root, fileURL: fileURL, clipboardDirectory: clipboardDirectory)
        let originalHeight = try XCTUnwrap(NSImage(contentsOf: fileURL)).size.height

        let saved = expectation(description: "saved")
        saveWorkflow.onFinish = { saved.fulfill() }
        saveWorkflow.pendingNoteText = "round trip me"
        saveWorkflow.handleRenameAction(.save(newName: fileURL.lastPathComponent))
        wait(for: [saved], timeout: 2.0)

        // On disk the file is taller (note burned) yet still carries the clean original.
        let burned = try XCTUnwrap(NSImage(contentsOf: fileURL))
        XCTAssertGreaterThan(burned.size.height, originalHeight)

        let savedData = try Data(contentsOf: fileURL)
        let extracted = try XCTUnwrap(PNGMetadata.extract(fromPNG: savedData))
        XCTAssertEqual(extracted.prompt, "round trip me")
        let recovered = try XCTUnwrap(NSImage(data: extracted.originalPNG))
        XCTAssertEqual(recovered.size.width, 80, accuracy: 1.0)
        XCTAssertEqual(recovered.size.height, 40, accuracy: 1.0)

        // Reopening the saved file pre-fills the prompt (the Note panel reads pendingNoteText).
        let reopenWorkflow = try makeWorkflow(root: root,
                                              fileURL: fileURL,
                                              clipboardDirectory: clipboardDirectory,
                                              writeOriginalFile: false)
        XCTAssertEqual(reopenWorkflow.pendingNoteText, "round trip me")
    }

    func testResavePreservesOriginalOriginalNotOnceBurnedImage() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("shot.png")
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)

        // First save with a note.
        let first = try makeWorkflow(root: root, fileURL: fileURL, clipboardDirectory: clipboardDirectory)
        let firstDone = expectation(description: "first save")
        first.onFinish = { firstDone.fulfill() }
        first.pendingNoteText = "first"
        first.handleRenameAction(.save(newName: fileURL.lastPathComponent))
        wait(for: [firstDone], timeout: 2.0)

        let afterFirstData = try Data(contentsOf: fileURL)
        let afterFirst = try XCTUnwrap(PNGMetadata.extract(fromPNG: afterFirstData))

        // Reopen, change the note, and re-save.
        let second = try makeWorkflow(root: root,
                                      fileURL: fileURL,
                                      clipboardDirectory: clipboardDirectory,
                                      writeOriginalFile: false)
        XCTAssertEqual(second.pendingNoteText, "first")
        let secondDone = expectation(description: "second save")
        second.onFinish = { secondDone.fulfill() }
        second.pendingNoteText = "second"
        second.handleRenameAction(.save(newName: fileURL.lastPathComponent))
        wait(for: [secondDone], timeout: 2.0)

        let afterSecondData = try Data(contentsOf: fileURL)
        let afterSecond = try XCTUnwrap(PNGMetadata.extract(fromPNG: afterSecondData))
        XCTAssertEqual(afterSecond.prompt, "second")
        // The embedded original is still the true 80x40 original, NOT the once-burned taller image.
        let recovered = try XCTUnwrap(NSImage(data: afterSecond.originalPNG))
        XCTAssertEqual(recovered.size.width, 80, accuracy: 1.0)
        XCTAssertEqual(recovered.size.height, 40, accuracy: 1.0)
        XCTAssertEqual(afterSecond.originalPNG, afterFirst.originalPNG,
                       "Re-saving must preserve the original-original, never re-embed the burned image.")
    }

    func testEditorEditsBecomeNewBaselineAndOnlyNoteRoundTrips() throws {
        // Edge case: drawings/edits made in the Editor bake into the saved file and
        // become the new clean baseline. Only the note text is un-baked on reopen;
        // the editor edits are intentionally NOT reversible.
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("shot.png") // clean original is 80x40
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)
        let workflow = try makeWorkflow(root: root, fileURL: fileURL, clipboardDirectory: clipboardDirectory)
        workflow.pendingNoteText = "describe the drawing"

        let done = expectation(description: "saved")
        workflow.onFinish = { done.fulfill() }

        // Simulate an editor that produced a 120x60 flattened image (e.g. with drawings),
        // distinct from the 80x40 clean original.
        let edited = TestSupport.solidImage(width: 120, height: 60, color: .systemGreen)
        workflow.handleEditorCompletion(editedImage: edited, action: .saveOnly)
        wait(for: [done], timeout: 2.0)

        let savedData = try Data(contentsOf: fileURL)
        let extracted = try XCTUnwrap(PNGMetadata.extract(fromPNG: savedData))
        XCTAssertEqual(extracted.prompt, "describe the drawing")
        let baseline = try XCTUnwrap(NSImage(data: extracted.originalPNG))
        // The embedded baseline is the EDITED image (120x60), not the pre-edit 80x40 original.
        XCTAssertEqual(baseline.size.width, 120, accuracy: 1.0)
        XCTAssertEqual(baseline.size.height, 60, accuracy: 1.0)
    }

    func testEditorCompletionEmbedsEditableStateForFutureReopen() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("foreign.png")
        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)
        let workflow = try makeWorkflow(root: root, fileURL: fileURL, clipboardDirectory: clipboardDirectory)

        let base = try Data(contentsOf: fileURL)
        let state = EditorCanvasState(
            baseImagePNG: base,
            items: [
                .arrow(start: .init(NSPoint(x: 5, y: 6)),
                       end: .init(NSPoint(x: 35, y: 18)),
                       color: .init(.systemRed),
                       lineWidth: 4),
                .text(.init(text: "delete me later",
                            origin: .init(NSPoint(x: 10, y: 12)),
                            color: .init(.systemBlue),
                            fontSize: 22))
            ]
        )

        let finished = expectation(description: "workflow finished")
        workflow.onFinish = { finished.fulfill() }

        let editedImage = TestSupport.solidImage(width: 80, height: 40, color: .systemGreen)
        workflow.handleEditorCompletion(editedImage: editedImage, action: .saveOnly, editorState: state)
        wait(for: [finished], timeout: 2.0)

        let savedData = try Data(contentsOf: fileURL)
        let extracted = try XCTUnwrap(PNGMetadata.extractEditorState(fromPNG: savedData))
        XCTAssertEqual(extracted.baseImagePNG, base)
        XCTAssertEqual(extracted.items, state.items)
    }

    func testReopenedNonPNGSaveConvertsToPNGWithoutCrashing() throws {
        // PNG-only: reopening a foreign JPEG and saving rewrites it as .png and
        // removes the original. (A plain reopened JPEG has no embedded baseline,
        // so no round-trip metadata is added — but it must not crash.)
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("shot.jpg")
        let jpeg = try TestSupport.solidImageJPEGData(width: 80, height: 40)
        try jpeg.write(to: fileURL, options: .atomic)

        let clipboardDirectory = root.appendingPathComponent("clipboard", isDirectory: true)
        let workflow = try makeWorkflow(root: root,
                                        fileURL: fileURL,
                                        clipboardDirectory: clipboardDirectory,
                                        writeOriginalFile: false)

        let done = expectation(description: "saved")
        workflow.onFinish = { done.fulfill() }
        workflow.pendingNoteText = "note on a jpeg"
        workflow.handleRenameAction(.save(newName: fileURL.lastPathComponent))
        wait(for: [done], timeout: 2.0)

        // The .jpg is gone; a valid .png was written in its place.
        let pngURL = root.appendingPathComponent("shot.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pngURL.path))
        let data = try Data(contentsOf: pngURL)
        XCTAssertTrue(PNGMetadata.isPNG(data))
    }

    private func makeWorkflow(root: URL,
                              fileURL: URL,
                              clipboardDirectory: URL,
                              initialImage: NSImage? = nil,
                              initialFilePersistence: Task<URL, Error>? = nil,
                              writeOriginalFile: Bool = true) throws -> ScreenshotWorkflowController {
        if writeOriginalFile {
            try TestSupport.writeSolidImagePNG(to: fileURL, width: 80, height: 40)
        }

        let settingsStore = SettingsStore(fileManager: .default,
                                          fileURL: root.appendingPathComponent("settings.json"))
        settingsStore.load()
        settingsStore.update { settings in
            settings.notePrefixEnabled = false
        }

        let backupService = BackupService(fileManager: .default,
                                          backupsDirectory: root.appendingPathComponent("backups", isDirectory: true))
        let clipboardService = ClipboardService(fileManager: .default,
                                                cacheDirectory: clipboardDirectory)

        return ScreenshotWorkflowController(fileURL: fileURL,
                                            initialImage: initialImage,
                                            initialFilePersistence: initialFilePersistence,
                                            settingsStore: settingsStore,
                                            clipboardService: clipboardService,
                                            backupService: backupService,
                                            sourceScreen: nil,
                                            escapeKeyDeletesFile: true)
    }
}
