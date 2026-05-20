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
            settings.quality = 95
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
