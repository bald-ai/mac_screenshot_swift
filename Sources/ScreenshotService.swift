import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Handles screenshot capture, resizing, encoding and filename generation,
/// and then kicks off the rename/note workflow.
final class ScreenshotService: NSObject {
    private let settingsStore: SettingsStore
    private let backupService: BackupService
    private let clipboardService: ClipboardService

    private let fileManager: FileManager
    private let desktopDirectory: URL

    private var selectionOverlay: SelectionOverlay?
    private var activeWorkflow: ScreenshotWorkflowController?

    init(settingsStore: SettingsStore,
         backupService: BackupService,
         clipboardService: ClipboardService,
         fileManager: FileManager = .default) {
        self.settingsStore = settingsStore
        self.backupService = backupService
        self.clipboardService = clipboardService
        self.fileManager = fileManager

        let home = fileManager.homeDirectoryForCurrentUser
        self.desktopDirectory = home.appendingPathComponent("Desktop", isDirectory: true)

        super.init()
    }

    // MARK: - Public API

    /// Starts an area capture on the active display using a full-screen
    /// transparent overlay.
    func captureArea() {
        guard canStartNewCapture() else { return }

        let overlay = SelectionOverlay()
        overlay.delegate = self
        selectionOverlay = overlay
        overlay.beginSelection()
    }

    /// Captures the full contents of the primary display.
    func captureFullScreen() {
        guard canStartNewCapture() else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        captureRegion(in: screen.frame, on: screen)
    }

    /// Starts the rename/note flow for an already-saved image. Used by the
    /// stitch service.
    func beginPostCaptureFlow(forExistingFileAt url: URL, on screen: NSScreen? = nil) {
        guard activeWorkflow == nil else {
            presentBusyAlert()
            return
        }

        let workflow = ScreenshotWorkflowController(
            fileURL: url,
            settingsStore: settingsStore,
            clipboardService: clipboardService,
            backupService: backupService,
            sourceScreen: screen
        )

        workflow.onFinish = { [weak self] in
            self?.activeWorkflow = nil
        }

        activeWorkflow = workflow
        workflow.start()
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

        try fileManager.createDirectory(at: desktopDirectory, withIntermediateDirectories: true)
        let url = uniqueScreenshotURL(in: desktopDirectory, date: Date())
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Internal capture pipeline

    private func canStartNewCapture() -> Bool {
        if activeWorkflow != nil {
            presentBusyAlert()
            return false
        }
        return true
    }

    private func captureRegion(in rect: CGRect, on screen: NSScreen) {
        Task { [weak self] in
            guard let self = self else { return }

            do {
                let cgImage = try await self.captureCGImage(rect: rect, on: screen)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                let url = try self.saveImageToDesktop(nsImage)
                self.beginPostCaptureFlow(forExistingFileAt: url, on: screen)
            } catch {
                self.presentError(title: "Screenshot failed", message: error.localizedDescription)
            }
        }
    }

    private func captureCGImage(rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await captureWithScreenshotManager(rect: rect, on: screen)
        } else {
            return try captureWithLegacyAPI(rect: rect, on: screen)
        }
    }

    @available(macOS 14.0, *)
    private func captureWithScreenshotManager(rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        guard let displayID = screen.displayID else {
            throw NSError(domain: "ScreenshotService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to determine display ID."])
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NSError(domain: "ScreenshotService", code: -3, userInfo: [NSLocalizedDescriptionKey: "No display found for capture."])
        }

        let scale = screen.backingScaleFactor
        let screenFrame = screen.frame
        let localRect = CGRect(
            x: (rect.origin.x - screenFrame.origin.x) * scale,
            y: (rect.origin.y - screenFrame.origin.y) * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        )

        var configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = Int(localRect.width)
        configuration.height = Int(localRect.height)
        configuration.showsCursor = true
        configuration.scalesToFit = false

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error = error {
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

    private func captureWithLegacyAPI(rect: CGRect, on screen: NSScreen) throws -> CGImage {
        guard let displayID = screen.displayID else {
            throw NSError(domain: "ScreenshotService", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unable to determine display ID."])
        }

        let scale = screen.backingScaleFactor
        let screenFrame = screen.frame
        let localRect = CGRect(
            x: (rect.origin.x - screenFrame.origin.x) * scale,
            y: (rect.origin.y - screenFrame.origin.y) * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        )

        if let image = CGDisplayCreateImageForRect(displayID, localRect) {
            return image
        }

        if let image = CGDisplayCreateImage(displayID) {
            return image
        }

        throw NSError(domain: "ScreenshotService", code: -6, userInfo: [NSLocalizedDescriptionKey: "CGDisplayCreateImage failed."])
    }

    // MARK: - Helpers

    private func resizedImageIfNeeded(_ image: NSImage, maxWidth: Int) -> NSImage {
        guard maxWidth > 0 else { return image }

        let originalSize = image.size
        guard originalSize.width > CGFloat(maxWidth) else { return image }

        let scale = CGFloat(maxWidth) / originalSize.width
        let newSize = NSSize(width: CGFloat(maxWidth), height: originalSize.height * scale)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()

        return newImage
    }

    private func jpegData(from image: NSImage, quality: Int) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let clamped = max(10, min(100, quality))
        let compression = CGFloat(clamped) / 100.0
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }

    private func uniqueScreenshotURL(in directory: URL, date: Date) -> URL {
        let template = settingsStore.settings.filenameTemplate
        var counter = 1

        while true {
            let baseName = template.makeFilename(date: date, counter: counter)
            let name = baseName.isEmpty ? "Screenshot" : baseName
            let url = directory.appendingPathComponent(name).appendingPathExtension("jpg")
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
            counter += 1
        }
    }

    private func presentBusyAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Finish current screenshot first"
        alert.informativeText = "Complete or cancel the current rename/note flow before taking another screenshot."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - SelectionOverlayDelegate

extension ScreenshotService: SelectionOverlayDelegate {
    func selectionOverlay(_ overlay: SelectionOverlay, didFinishWith rectInScreenCoordinates: CGRect?, onScreen screen: NSScreen) {
        selectionOverlay = nil
        guard let rect = rectInScreenCoordinates else {
            // User cancelled; no file is created and no UI is shown.
            return
        }
        captureRegion(in: rect, on: screen)
    }
}

// MARK: - NSScreen helpers

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
