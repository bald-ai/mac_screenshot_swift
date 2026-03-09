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

    private func makeWorkflow(root: URL,
                              fileURL: URL,
                              clipboardDirectory: URL) throws -> ScreenshotWorkflowController {
        try TestSupport.writeSolidImagePNG(to: fileURL, width: 80, height: 40)

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
                                            settingsStore: settingsStore,
                                            clipboardService: clipboardService,
                                            backupService: backupService,
                                            sourceScreen: nil,
                                            escapeKeyDeletesFile: true)
    }
}
