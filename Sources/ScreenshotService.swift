import AppKit
import ScreenCaptureKit
import CoreGraphics

protocol ScreenshotSoundPlaying {
    func playCaptureSound()
}

extension ScreenshotSoundPlayer: ScreenshotSoundPlaying {}

/// Handles screenshot capture, resizing, encoding and filename generation,
/// and then kicks off the rename/note workflow.
final class ScreenshotService: NSObject {
    private let settingsStore: SettingsStore
    private let backupService: BackupService
    private let clipboardService: ClipboardService
    private let soundPlayer: ScreenshotSoundPlaying

    private let fileManager: FileManager
    private let desktopDirectory: URL

    private var activeWorkflow: ScreenshotWorkflowController?
    private var isCaptureInProgress = false
    private var isSystemAreaCaptureInProgress = false
    private var systemAreaCaptureProcess: Process?

    private struct ScreenSnapshot: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    init(settingsStore: SettingsStore,
         backupService: BackupService,
         clipboardService: ClipboardService,
         fileManager: FileManager = .default,
         desktopDirectory: URL? = nil,
         soundPlayer: ScreenshotSoundPlaying = ScreenshotSoundPlayer()) {
        self.settingsStore = settingsStore
        self.backupService = backupService
        self.clipboardService = clipboardService
        self.soundPlayer = soundPlayer
        self.fileManager = fileManager

        if let desktopDirectory {
            self.desktopDirectory = desktopDirectory
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            self.desktopDirectory = home.appendingPathComponent("Desktop", isDirectory: true)
        }

        super.init()
    }

    // MARK: - Public API

    /// Starts an area capture using the native macOS area picker.
    func captureArea() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureArea()
            }
            return
        }

        guard canStartNewCapture() else {
            return
        }

        beginSystemAreaCapture()
    }

    /// Captures the full contents of the primary display.
    func captureFullScreen() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureFullScreen()
            }
            return
        }

        guard canStartNewCapture() else {
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        captureRegion(in: screen.frame, on: screen)
    }

    /// Starts the rename/note flow for an already-saved image.
    func beginPostCaptureFlow(forExistingFileAt url: URL, on screen: NSScreen? = nil, escapeKeyDeletesFile: Bool = true) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginPostCaptureFlow(forExistingFileAt: url, on: screen, escapeKeyDeletesFile: escapeKeyDeletesFile)
            }
            return
        }

        guard activeWorkflow == nil else {
            // Ignore requests while a workflow is active; avoid modal alerts that can
            // wedge the UI if the app isn't frontmost.
            return
        }

        let workflow = ScreenshotWorkflowController(
            fileURL: url,
            settingsStore: settingsStore,
            clipboardService: clipboardService,
            backupService: backupService,
            sourceScreen: screen,
            escapeKeyDeletesFile: escapeKeyDeletesFile
        )

        workflow.onFinish = { [weak self] in
            self?.activeWorkflow = nil
        }

        activeWorkflow = workflow
        workflow.start()
    }

    /// Single shared "busy gate" for user commands.
    /// If true, other commands should be ignored to avoid wedging UI state.
    var isBusyForUserCommands: Bool {
        isCaptureInProgress || isSystemAreaCaptureInProgress || activeWorkflow != nil
    }

    /// Saves an arbitrary image to the Desktop using the current settings
    /// (quality, maxWidth, filename template) and returns the resulting URL.
    func saveImageToDesktop(_ image: NSImage) throws -> URL {
        let settings = settingsStore.settings

        let finalImage: NSImage
        if settings.maxWidth > 0 {
            finalImage = resizedImageIfNeeded(image, maxWidth: settings.maxWidth)
        } else {
            finalImage = image
        }

        guard let data = jpegData(from: finalImage, quality: settings.quality) else {
            throw NSError(domain: "ScreenshotService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG data."])
        }

        let date = Date()
        let currentCounter = settings.screenshotCounter
        let baseName = settings.filenameTemplate.makeFilename(date: date, counter: currentCounter)

        try fileManager.createDirectory(at: desktopDirectory, withIntermediateDirectories: true)
        let url = uniqueScreenshotURL(in: desktopDirectory, baseName: baseName)
        try data.write(to: url, options: .atomic)

        settingsStore.update { settings in
            settings.screenshotCounter = currentCounter + 1
        }

        return url
    }

    // MARK: - Internal capture pipeline

    private func canStartNewCapture() -> Bool {
        if isCaptureInProgress {
            return false
        }
        if isSystemAreaCaptureInProgress {
            return false
        }
        if activeWorkflow != nil {
            // Do not present a modal NSAlert here.
            //
            // `NSAlert.runModal()` can create a hidden app-modal session when the app is not
            // frontmost (common for an accessory menu bar app), which makes the current
            // rename/note panel appear "stuck" and unfocusable. While a workflow is active,
            // we simply ignore new capture triggers.
            return false
        }
        return true
    }

    private func beginSystemAreaCapture() {
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("screenshotapp-area-\(UUID().uuidString)")
            .appendingPathExtension("png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", tempURL.path]

        isSystemAreaCaptureInProgress = true
        systemAreaCaptureProcess = process

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.finishSystemAreaCapture(tempURL: tempURL, process: process)
            }
        }

        do {
            try process.run()
        } catch {
            isSystemAreaCaptureInProgress = false
            systemAreaCaptureProcess = nil
            presentError(title: "Screenshot failed", message: "Could not start native area capture.")
        }
    }

    private func finishSystemAreaCapture(tempURL: URL, process: Process) {
        isSystemAreaCaptureInProgress = false
        systemAreaCaptureProcess = nil

        guard process.terminationStatus == 0 else {
            // User cancelled the macOS picker.
            try? fileManager.removeItem(at: tempURL)
            return
        }

        guard fileManager.fileExists(atPath: tempURL.path) else {
            // User cancelled picker without capturing.
            return
        }
        guard let image = NSImage(contentsOf: tempURL) else {
            try? fileManager.removeItem(at: tempURL)
            return
        }

        do {
            let url = try saveImageToDesktop(image)
            soundPlayer.playCaptureSound()
            let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
            beginPostCaptureFlow(forExistingFileAt: url, on: targetScreen)
        } catch {
            presentError(title: "Screenshot failed", message: error.localizedDescription)
        }

        try? fileManager.removeItem(at: tempURL)
    }

    private func captureRegion(in rect: CGRect, on screen: NSScreen) {
        if !Thread.isMainThread {
            let screenID = screen.displayID
            DispatchQueue.main.async { [weak self] in
                let targetScreen = self?.screenForDisplayID(screenID) ?? NSScreen.main ?? NSScreen.screens.first
                guard let targetScreen = targetScreen else { return }
                self?.captureRegion(in: rect, on: targetScreen)
            }
            return
        }

        if isCaptureInProgress {
            return
        }

        guard let displayID = screen.displayID else {
            presentError(title: "Screenshot failed", message: "Unable to determine display ID.")
            return
        }

        let screenSnapshot = ScreenSnapshot(displayID: displayID,
                                            frame: screen.frame,
                                            scale: screen.backingScaleFactor)

        isCaptureInProgress = true
        Task { [weak self] in
            guard let self = self else {
                return
            }
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.isCaptureInProgress = false
                }
            }

            let screenID = screenSnapshot.displayID
            do {
                let cgImage = try await self.captureCGImage(rect: rect, on: screenSnapshot)
                
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                
                let url = try self.saveImageToDesktop(nsImage)
                
                DispatchQueue.main.async { [weak self] in
                    self?.soundPlayer.playCaptureSound()
                    let targetScreen = self?.screenForDisplayID(screenID)
                    self?.beginPostCaptureFlow(forExistingFileAt: url, on: targetScreen)
                }
            } catch {
                self.presentError(title: "Screenshot failed", message: error.localizedDescription)
            }
        }
    }

    private func captureCGImage(rect: CGRect, on screen: ScreenSnapshot) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await captureWithScreenshotManager(rect: rect, on: screen)
        } else {
            return try captureWithLegacyAPI(rect: rect, on: screen)
        }
    }

    @available(macOS 14.0, *)
    private func captureWithScreenshotManager(rect: CGRect, on screen: ScreenSnapshot) async throws -> CGImage {

        let displayID = screen.displayID

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NSError(domain: "ScreenshotService", code: -3, userInfo: [NSLocalizedDescriptionKey: "No display found for capture."])
        }

        guard let captureRect = captureRects(rectInScreenPoints: rect, screen: screen) else {
            throw NSError(domain: "ScreenshotService",
                          code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "Selected area is outside the screen bounds."])
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRect.pointRect
        configuration.width = Int(captureRect.pixelRect.width)
        configuration.height = Int(captureRect.pixelRect.height)
        configuration.showsCursor = true
        configuration.scalesToFit = false

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, error in
                if let error = error {
                    if let self = self, self.shouldFallbackToLegacy(error) {
                        do {
                            let legacy = try self.captureWithLegacyAPI(rect: rect, on: screen)
                            continuation.resume(returning: legacy)
                            return
                        } catch {
                        }
                    }
                    continuation.resume(throwing: error)
                } else if let image = image {
                    continuation.resume(returning: image)
                } else {
                    let err = NSError(domain: "ScreenshotService", code: -4, userInfo: [NSLocalizedDescriptionKey: "No image captured."])
                    continuation.resume(throwing: err)
                }
            }
        }
    }

    private func captureWithLegacyAPI(rect: CGRect, on screen: ScreenSnapshot) throws -> CGImage {
        let displayID = screen.displayID
        guard let captureRect = captureRects(rectInScreenPoints: rect, screen: screen) else {
            throw NSError(domain: "ScreenshotService", code: -6, userInfo: [NSLocalizedDescriptionKey: "Selected area is outside the screen bounds."])
        }

        if let image = CGDisplayCreateImage(displayID, rect: captureRect.pixelRect) {
            return image
        }

        throw NSError(domain: "ScreenshotService", code: -6, userInfo: [NSLocalizedDescriptionKey: "CGDisplayCreateImage failed for selected region."])
    }

    // MARK: - Helpers

    private func resizedImageIfNeeded(_ image: NSImage, maxWidth: Int) -> NSImage {
        ScreenshotServiceCoreLogic.resizedImageIfNeeded(image, maxWidth: maxWidth)
    }

    private func jpegData(from image: NSImage, quality: Int) -> Data? {
        ScreenshotServiceCoreLogic.jpegData(from: image, quality: quality)
    }

    private func uniqueScreenshotURL(in directory: URL, baseName: String) -> URL {
        ScreenshotServiceCoreLogic.uniqueScreenshotURL(
            in: directory,
            baseName: baseName,
            fileExists: { [fileManager] path in fileManager.fileExists(atPath: path) }
        )
    }

    private func presentError(title: String, message: String) {
        presentAlert(title: title, message: message)
    }

    private func presentAlert(title: String, message: String) {
        let showAlert = {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        if Thread.isMainThread {
            showAlert()
        } else {
            DispatchQueue.main.async(execute: showAlert)
        }
    }

    private func captureRects(rectInScreenPoints rect: CGRect,
                              screen: ScreenSnapshot) -> (pointRect: CGRect, pixelRect: CGRect)? {
        ScreenshotServiceCoreLogic.captureRects(
            rectInScreenPoints: rect,
            screenFrame: screen.frame,
            scale: screen.scale
        )
    }

    private func shouldFallbackToLegacy(_ error: Error) -> Bool {
        ScreenshotServiceCoreLogic.shouldFallbackToLegacy(error)
    }
}

// ScreenshotService mutates UI state only on the main thread; capture work
// is isolated to the async task. We mark it @unchecked Sendable to silence
// Swift 6 Sendable warnings for main-queue hops.
extension ScreenshotService: @unchecked Sendable {}

// MARK: - NSScreen helpers

private extension ScreenshotService {
    func screenForDisplayID(_ displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID = displayID else { return nil }
        return NSScreen.screens.first(where: { $0.displayID == displayID })
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
