import AppKit
import CoreGraphics
import ScreenCaptureKit

protocol ScreenshotSoundPlaying {
    func playCaptureSound()
}

extension ScreenshotSoundPlayer: ScreenshotSoundPlaying {}

/// Handles screenshot capture, resizing, encoding and filename generation,
/// and then kicks off the rename/note workflow.
final class ScreenshotService: NSObject {
    private struct ScreenSnapshot: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    private let settingsStore: SettingsStore
    private let backupService: BackupService
    private let clipboardService: ClipboardService
    private let soundPlayer: ScreenshotSoundPlaying

    private let fileManager: FileManager
    private let desktopDirectory: URL

    private var selectionOverlay: SelectionOverlay?
    private var activeWorkflow: ScreenshotWorkflowController?
    private var isCaptureInProgress = false

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

    func captureArea() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureArea()
            }
            return
        }

        if selectionOverlay != nil {
            return
        }
        guard canStartNewCapture(), ensureScreenCapturePermission() else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let overlay = SelectionOverlay()
        overlay.delegate = self
        selectionOverlay = overlay
        overlay.beginSelection()
    }

    /// Captures the full contents of the display under the mouse.
    func captureFullScreen() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureFullScreen()
            }
            return
        }

        if selectionOverlay != nil {
            selectionOverlay?.cancelSelection()
            selectionOverlay = nil
        }
        guard canStartNewCapture(), ensureScreenCapturePermission() else {
            return
        }
        guard let screen = screenUnderMouse() ?? menuBarScreen() ?? NSScreen.main ?? NSScreen.screens.first else {
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

    var isBusyForUserCommands: Bool {
        isCaptureInProgress || activeWorkflow != nil || selectionOverlay != nil
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

    // MARK: - Capture pipeline

    private func canStartNewCapture() -> Bool {
        if isCaptureInProgress {
            return false
        }
        if activeWorkflow != nil {
            return false
        }
        return true
    }

    private func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        guard CGRequestScreenCaptureAccess() else {
            presentScreenRecordingPermissionError()
            return false
        }
        return true
    }

    private func captureRegion(in rect: CGRect, on screen: NSScreen) {
        if !Thread.isMainThread {
            let screenID = screen.displayID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let targetScreen = self.screenForDisplayID(screenID) ?? NSScreen.main ?? NSScreen.screens.first
                guard let targetScreen else { return }
                self.captureRegion(in: rect, on: targetScreen)
            }
            return
        }

        guard !isCaptureInProgress else {
            return
        }
        guard let displayID = screen.displayID else {
            presentError(title: "Screenshot failed", message: "Unable to determine display ID.")
            return
        }

        let snapshot = ScreenSnapshot(displayID: displayID,
                                      frame: screen.frame,
                                      scale: screen.backingScaleFactor)
        isCaptureInProgress = true

        Task { [weak self] in
            guard let self else { return }

            do {
                let cgImage = try await self.captureCGImage(rect: rect, on: snapshot)
                try await MainActor.run {
                    defer { self.isCaptureInProgress = false }
                    try self.finishCapture(with: cgImage, onDisplayID: snapshot.displayID)
                }
            } catch {
                await MainActor.run {
                    self.isCaptureInProgress = false
                    self.handleCaptureFailure(error)
                }
            }
        }
    }

    private func finishCapture(with cgImage: CGImage, onDisplayID displayID: CGDirectDisplayID) throws {
        let imageSize = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let image = NSImage(cgImage: cgImage, size: imageSize)
        let url = try saveImageToDesktop(image)
        soundPlayer.playCaptureSound()
        beginPostCaptureFlow(forExistingFileAt: url, on: screenForDisplayID(displayID))
    }

    private func captureCGImage(rect: CGRect, on screen: ScreenSnapshot) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw NSError(domain: "ScreenshotService",
                          code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "No display found for capture."])
        }
        guard let captureRect = ScreenshotServiceCoreLogic.screenCaptureRect(rectInScreenPoints: rect,
                                                                             screenFrame: screen.frame,
                                                                             scale: screen.scale) else {
            throw NSError(domain: "ScreenshotService",
                          code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Selected area is outside the display bounds."])
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRect.pointRect
        configuration.width = Int(captureRect.pixelRect.width)
        configuration.height = Int(captureRect.pixelRect.height)
        configuration.showsCursor = true
        configuration.scalesToFit = false

        let excludedApplications = content.applications.filter { application in
            application.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: excludedApplications,
                                     exceptingWindows: [])

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: NSError(domain: "ScreenshotService",
                                                          code: -5,
                                                          userInfo: [NSLocalizedDescriptionKey: "No image captured."]))
                }
            }
        }
    }

    // MARK: - Error handling

    private func handleCaptureFailure(_ error: Error) {
        if isPermissionFailure(error) {
            presentScreenRecordingPermissionError()
            return
        }

        presentError(title: "Screenshot failed", message: (error as NSError).localizedDescription)
    }

    private func isPermissionFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == -3801
    }

    // MARK: - Helpers

    private func screenUnderMouse() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
    }

    private func menuBarScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first(where: { $0.displayID == mainDisplayID })
    }

    private func screenForDisplayID(_ displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else {
            return nil
        }
        return NSScreen.screens.first(where: { $0.displayID == displayID })
    }

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

    private func presentScreenRecordingPermissionError() {
        let title = "Screen Recording Permission Required"
        let message = "Zoomies needs Screen Recording permission to take screenshots.\n\nOpen System Settings -> Privacy & Security -> Screen Recording, enable Zoomies, then try again."
        AlertPresenter.presentWarningWithSettingsButton(title: title, message: message)
    }

    private func presentError(title: String, message: String) {
        AlertPresenter.presentWarning(title: title, message: message)
    }
}

extension ScreenshotService: @unchecked Sendable {}

extension ScreenshotService: SelectionOverlayDelegate {
    func selectionOverlay(_ overlay: SelectionOverlay,
                          didFinishWith rectInScreenCoordinates: CGRect?,
                          onScreen screen: NSScreen) {
        if !Thread.isMainThread {
            let screenID = screen.displayID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let targetScreen = self.screenForDisplayID(screenID) ?? NSScreen.main ?? NSScreen.screens.first
                guard let targetScreen else { return }
                self.handleSelection(rect: rectInScreenCoordinates, on: targetScreen)
            }
            return
        }

        handleSelection(rect: rectInScreenCoordinates, on: screen)
    }

    private func handleSelection(rect: CGRect?, on screen: NSScreen) {
        selectionOverlay = nil
        guard let rect else {
            return
        }
        captureRegion(in: rect, on: screen)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
