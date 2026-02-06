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
    private var isCaptureInProgress = false

    private struct ScreenSnapshot: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

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
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureArea()
            }
            return
        }

        Logger.shared.info("ScreenshotService: captureArea called")
        if selectionOverlay != nil {
            // While selection is active, repeated area-hotkey triggers should be ignored.
            // Cancellation is owned by explicit user action (Esc/right-click/etc) and other flows.
            Logger.shared.info("ScreenshotService: captureArea - selection already active, ignoring")
            return
        }
        guard canStartNewCapture() else {
            Logger.shared.info("ScreenshotService: captureArea - cannot start new capture")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let overlay = SelectionOverlay()
        overlay.delegate = self
        selectionOverlay = overlay
        Logger.shared.info("ScreenshotService: Starting selection overlay")
        overlay.beginSelection()
        Logger.shared.info("ScreenshotService: captureArea completed")
    }

    /// Captures the full contents of the primary display.
    func captureFullScreen() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureFullScreen()
            }
            return
        }

        Logger.shared.info("ScreenshotService: captureFullScreen called")
        if selectionOverlay != nil {
            Logger.shared.info("ScreenshotService: captureFullScreen - selection active, cancelling overlay and continuing with fullscreen capture")
            selectionOverlay?.cancelSelection()
            selectionOverlay = nil
        }
        guard canStartNewCapture() else {
            Logger.shared.info("ScreenshotService: captureFullScreen - cannot start new capture")
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Logger.shared.error("ScreenshotService: captureFullScreen - no screen found")
            return
        }
        Logger.shared.info("ScreenshotService: captureFullScreen - capturing on screen \(screen)")

        captureRegion(in: screen.frame, on: screen)
        Logger.shared.info("ScreenshotService: captureFullScreen completed")
    }

    /// Starts the rename/note flow for an already-saved image. Used by the
    /// stitch service.
    func beginPostCaptureFlow(forExistingFileAt url: URL, on screen: NSScreen? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginPostCaptureFlow(forExistingFileAt: url, on: screen)
            }
            return
        }

        Logger.shared.info("ScreenshotService: beginPostCaptureFlow called for \(url)")
        guard activeWorkflow == nil else {
            Logger.shared.info("ScreenshotService: beginPostCaptureFlow - workflow already active")
            // Ignore requests while a workflow is active; avoid modal alerts that can
            // wedge the UI if the app isn't frontmost.
            return
        }
        Logger.shared.info("ScreenshotService: beginPostCaptureFlow - creating workflow controller")

        let workflow = ScreenshotWorkflowController(
            fileURL: url,
            settingsStore: settingsStore,
            clipboardService: clipboardService,
            backupService: backupService,
            sourceScreen: screen
        )
        Logger.shared.info("ScreenshotService: beginPostCaptureFlow - workflow created")

        workflow.onFinish = { [weak self] in
            Logger.shared.info("ScreenshotService: Workflow onFinish called")
            self?.activeWorkflow = nil
        }
        Logger.shared.info("ScreenshotService: beginPostCaptureFlow - onFinish set")

        activeWorkflow = workflow
        Logger.shared.info("ScreenshotService: beginPostCaptureFlow - workflow assigned to activeWorkflow")
        workflow.start()
        Logger.shared.info("ScreenshotService: beginPostCaptureFlow - workflow.start() called")
    }

    /// Single shared "busy gate" for user commands (captures + stitch).
    /// If true, other commands should be ignored to avoid wedging UI state.
    var isBusyForUserCommands: Bool {
        isCaptureInProgress || activeWorkflow != nil || selectionOverlay != nil
    }

    /// Cancels the active workflow and clears the activeWorkflow reference.
    /// This should be called when force-closing windows via IPC.
    func cancelActiveWorkflow() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.cancelActiveWorkflow()
            }
            return
        }

        Logger.shared.info("ScreenshotService: cancelActiveWorkflow called")
        guard let workflow = activeWorkflow else {
            Logger.shared.info("ScreenshotService: No active workflow to cancel")
            return
        }
        Logger.shared.info("ScreenshotService: Cancelling workflow")
        workflow.cancel()
        activeWorkflow = nil
        Logger.shared.info("ScreenshotService: Workflow cancelled and cleared")
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
        Logger.shared.info("ScreenshotService: canStartNewCapture called, activeWorkflow is nil: \(activeWorkflow == nil)")
        if isCaptureInProgress {
            Logger.shared.info("ScreenshotService: Cannot start new capture - capture already in progress")
            return false
        }
        if activeWorkflow != nil {
            Logger.shared.info("ScreenshotService: Cannot start new capture - workflow already active")
            // Do not present a modal NSAlert here.
            //
            // `NSAlert.runModal()` can create a hidden app-modal session when the app is not
            // frontmost (common for an accessory menu bar app), which makes the current
            // rename/note panel appear "stuck" and unfocusable. While a workflow is active,
            // we simply ignore new capture triggers.
            return false
        }
        Logger.shared.info("ScreenshotService: Can start new capture")
        return true
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
            Logger.shared.info("ScreenshotService: captureRegion - capture already in progress, ignoring")
            return
        }

        guard let displayID = screen.displayID else {
            Logger.shared.error("ScreenshotService: captureRegion - missing display ID")
            presentError(title: "Screenshot failed", message: "Unable to determine display ID.")
            return
        }

        let screenSnapshot = ScreenSnapshot(displayID: displayID,
                                            frame: screen.frame,
                                            scale: screen.backingScaleFactor)
        Logger.shared.info("ScreenshotService: Screen snapshot frame: \(screenSnapshot.frame), scale: \(screenSnapshot.scale)")

        Logger.shared.info("ScreenshotService: captureRegion called with rect \(rect)")
        isCaptureInProgress = true
        Task { [weak self] in
            guard let self = self else {
                Logger.shared.error("ScreenshotService: captureRegion - self is nil")
                return
            }
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.isCaptureInProgress = false
                }
            }

            Logger.shared.info("ScreenshotService: Starting captureCGImage")
            let screenID = screenSnapshot.displayID
            do {
                let cgImage = try await self.captureCGImage(rect: rect, on: screenSnapshot)
                Logger.shared.info("ScreenshotService: captureCGImage completed, image size: \(cgImage.width)x\(cgImage.height)")
                
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                Logger.shared.info("ScreenshotService: Created NSImage")
                
                let url = try self.saveImageToDesktop(nsImage)
                Logger.shared.info("ScreenshotService: Image saved to \(url)")
                
                DispatchQueue.main.async { [weak self] in
                    let targetScreen = self?.screenForDisplayID(screenID)
                    self?.beginPostCaptureFlow(forExistingFileAt: url, on: targetScreen)
                }
                Logger.shared.info("ScreenshotService: Post-capture flow started")
            } catch {
                Logger.shared.error("ScreenshotService: captureRegion failed with error: \(error)")
                self.presentError(title: "Screenshot failed", message: error.localizedDescription)
            }
        }
    }

    private func captureCGImage(rect: CGRect, on screen: ScreenSnapshot) async throws -> CGImage {
        Logger.shared.info("ScreenshotService: captureCGImage called")
        if #available(macOS 14.0, *) {
            Logger.shared.info("ScreenshotService: Using ScreenshotManager (macOS 14+)")
            return try await captureWithScreenshotManager(rect: rect, on: screen)
        } else {
            Logger.shared.info("ScreenshotService: Using Legacy API")
            return try captureWithLegacyAPI(rect: rect, on: screen)
        }
    }

    @available(macOS 14.0, *)
    private func captureWithScreenshotManager(rect: CGRect, on screen: ScreenSnapshot) async throws -> CGImage {
        Logger.shared.info("ScreenshotService: captureWithScreenshotManager started")

        let displayID = screen.displayID
        Logger.shared.info("ScreenshotService: Display ID: \(displayID)")
        Logger.shared.info("ScreenshotService: Screen frame: \(screen.frame), scale: \(screen.scale)")
        Logger.shared.info("ScreenshotService: Requested rect (points): \(rect)")

        Logger.shared.info("ScreenshotService: Getting SCShareableContent")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        Logger.shared.info("ScreenshotService: Got content with \(content.displays.count) displays")
        
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            Logger.shared.error("ScreenshotService: No display found for capture")
            throw NSError(domain: "ScreenshotService", code: -3, userInfo: [NSLocalizedDescriptionKey: "No display found for capture."])
        }
        Logger.shared.info("ScreenshotService: Using display: \(display.displayID)")

        let scale = screen.scale
        let screenFrame = screen.frame
        guard let captureRect = captureRects(rectInScreenPoints: rect, screen: screen) else {
            throw NSError(domain: "ScreenshotService",
                          code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "Selected area is outside the screen bounds."])
        }
        Logger.shared.info("ScreenshotService: clampedPointRect: \(captureRect.pointRect), clampedPixelRect: \(captureRect.pixelRect)")

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRect.pointRect
        configuration.width = Int(captureRect.pixelRect.width)
        configuration.height = Int(captureRect.pixelRect.height)
        configuration.showsCursor = true
        configuration.scalesToFit = false
        Logger.shared.info("ScreenshotService: SC config width=\(configuration.width) height=\(configuration.height) sourceRect(points)=\(configuration.sourceRect)")

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        Logger.shared.info("ScreenshotService: Starting SCScreenshotManager.captureImage")

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, error in
                if let error = error {
                    self?.logCaptureError(error, context: "SCScreenshotManager.captureImage")
                    if let self = self, self.shouldFallbackToLegacy(error) {
                        Logger.shared.warning("ScreenshotService: Falling back to legacy capture after invalid parameter")
                        do {
                            let legacy = try self.captureWithLegacyAPI(rect: rect, on: screen)
                            continuation.resume(returning: legacy)
                            return
                        } catch {
                            self.logCaptureError(error, context: "Legacy fallback failed")
                        }
                    }
                    continuation.resume(throwing: error)
                } else if let image = image {
                    Logger.shared.info("ScreenshotService: captureImage succeeded")
                    continuation.resume(returning: image)
                } else {
                    Logger.shared.error("ScreenshotService: captureImage returned nil")
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
        Logger.shared.info("ScreenshotService: Legacy clampedPixelRect: \(captureRect.pixelRect)")

        if let image = CGDisplayCreateImage(displayID, rect: captureRect.pixelRect) {
            return image
        }

        throw NSError(domain: "ScreenshotService", code: -6, userInfo: [NSLocalizedDescriptionKey: "CGDisplayCreateImage failed for selected region."])
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

    private func uniqueScreenshotURL(in directory: URL, baseName: String) -> URL {
        let name = baseName.isEmpty ? "Screenshot" : baseName
        var url = directory.appendingPathComponent(name).appendingPathExtension("jpg")
        if !fileManager.fileExists(atPath: url.path) {
            return url
        }

        var suffix = 2
        while true {
            let suffixedName = "\(name)_\(suffix)"
            url = directory.appendingPathComponent(suffixedName).appendingPathExtension("jpg")
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
            suffix += 1
        }
    }

    private func presentBusyAlert() {
        presentAlert(title: "Finish current screenshot first",
                     message: "Complete or cancel the current rename/note flow before taking another screenshot.")
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
        let screenFrame = screen.frame
        let scale = screen.scale

        let localRectPoints = CGRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )

        let pointBounds = CGRect(origin: .zero, size: screenFrame.size)
        let flippedY = pointBounds.height - (localRectPoints.origin.y + localRectPoints.height)
        let pointRectTopLeft = CGRect(
            x: localRectPoints.origin.x,
            y: flippedY,
            width: localRectPoints.size.width,
            height: localRectPoints.size.height
        )
        let clampedPoints = pointRectTopLeft.integral.intersection(pointBounds)

        let pixelRect = CGRect(
            x: clampedPoints.origin.x * scale,
            y: clampedPoints.origin.y * scale,
            width: clampedPoints.size.width * scale,
            height: clampedPoints.size.height * scale
        )

        Logger.shared.info("ScreenshotService: localRectPoints: \(localRectPoints), pointRectTopLeft: \(pointRectTopLeft), clampedPoints: \(clampedPoints), pixelRect: \(pixelRect)")

        guard clampedPoints.width >= 1, clampedPoints.height >= 1 else { return nil }
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        return (pointRect: clampedPoints, pixelRect: pixelRect.integral)
    }

    private func logCaptureError(_ error: Error, context: String) {
        let nsError = error as NSError
        Logger.shared.error("ScreenshotService: \(context) error domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
        Logger.shared.error("ScreenshotService: \(context) localizedDescription=\(nsError.localizedDescription)")
    }

    private func shouldFallbackToLegacy(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain, nsError.code == -50 {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("invalid") && message.contains("parameter")
    }
}

// ScreenshotService mutates UI state only on the main thread; capture work
// is isolated to the async task. We mark it @unchecked Sendable to silence
// Swift 6 Sendable warnings for main-queue hops.
extension ScreenshotService: @unchecked Sendable {}

// MARK: - SelectionOverlayDelegate

extension ScreenshotService: SelectionOverlayDelegate {
    func selectionOverlay(_ overlay: SelectionOverlay, didFinishWith rectInScreenCoordinates: CGRect?, onScreen screen: NSScreen) {
        if !Thread.isMainThread {
            let rectCopy = rectInScreenCoordinates
            let screenID = screen.displayID
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let targetScreen = self.screenForDisplayID(screenID) ?? NSScreen.main ?? NSScreen.screens.first
                guard let targetScreen = targetScreen else { return }
                self.handleSelection(rect: rectCopy, on: targetScreen)
            }
            return
        }

        handleSelection(rect: rectInScreenCoordinates, on: screen)
    }
}

// MARK: - NSScreen helpers

private extension ScreenshotService {
    func handleSelection(rect: CGRect?, on screen: NSScreen) {
        Logger.shared.info("ScreenshotService: selectionOverlay delegate called")
        selectionOverlay = nil
        guard let rect = rect else {
            // User cancelled; no file is created and no UI is shown.
            Logger.shared.info("ScreenshotService: Selection cancelled by user")
            return
        }
        Logger.shared.info("ScreenshotService: Selection completed with rect: \(rect)")
        captureRegion(in: rect, on: screen)
    }

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
