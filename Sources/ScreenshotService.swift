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

    private struct PreparedCaptureSave {
        let image: NSImage
        let targetURL: URL
        let currentCounter: Int
    }

    @MainActor
    private struct ShareableContentPrefetch {
        let token: UUID
        let task: Task<SCShareableContent, Error>
        var fetchedAt: Date?
    }

    private let settingsStore: SettingsStore
    private let backupService: BackupService
    private let clipboardService: ClipboardService
    private let soundPlayer: ScreenshotSoundPlaying

    private let fileManager: FileManager
    private let desktopDirectory: URL
    private let capturePersistenceQueue = DispatchQueue(label: "Zoomies.CapturePersistence", qos: .userInitiated)

    private var selectionOverlay: SelectionOverlay?
    private var activeWorkflow: ScreenshotWorkflowController?
    private var isCaptureInProgress = false
    @MainActor private var shareableContentPrefetch: ShareableContentPrefetch?
    private let shareableContentPrefetchTTL: TimeInterval = 2

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

        let overlay = SelectionOverlay()
        overlay.delegate = self
        selectionOverlay = overlay
    }

    // MARK: - Public API

    func captureArea() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureArea()
            }
            return
        }

        if selectionOverlay?.isActive == true {
            return
        }
        guard canStartAreaCapture() else {
            return
        }

        showAreaOverlay()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAreaOverlay() {
        selectionOverlay?.beginSelection()
        prefetchShareableContent(trigger: "overlay")
    }

    /// Captures the full contents of the display under the mouse.
    func captureFullScreen() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureFullScreen()
            }
            return
        }

        if selectionOverlay?.isActive == true {
            selectionOverlay?.cancelSelection()
        }
        guard canStartFullScreenCapture() else {
            return
        }
        guard let screen = screenUnderMouse() ?? menuBarScreen() ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        captureRegion(in: screen.frame, on: screen)
    }

    /// Starts the rename/note flow for an already-saved image.
    func beginPostCaptureFlow(forExistingFileAt url: URL, on screen: NSScreen? = nil, escapeKeyDeletesFile: Bool = true) {
        beginPostCaptureFlow(forExistingFileAt: url,
                             initialImage: nil,
                             initialFilePersistence: nil,
                             on: screen,
                             escapeKeyDeletesFile: escapeKeyDeletesFile)
    }

    func beginPostCaptureFlow(forExistingFileAt url: URL,
                              initialImage: NSImage? = nil,
                              initialFilePersistence: Task<URL, Error>? = nil,
                              on screen: NSScreen? = nil,
                              escapeKeyDeletesFile: Bool = true) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginPostCaptureFlow(forExistingFileAt: url,
                                           initialImage: initialImage,
                                           initialFilePersistence: initialFilePersistence,
                                           on: screen,
                                           escapeKeyDeletesFile: escapeKeyDeletesFile)
            }
            return
        }

        guard activeWorkflow == nil else { return }

        let workflow = ScreenshotWorkflowController(
            fileURL: url,
            initialImage: initialImage,
            initialFilePersistence: initialFilePersistence,
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
        isCaptureInProgress || activeWorkflow != nil || selectionOverlay?.isActive == true
    }

    /// Saves an arbitrary image to the Desktop using the current settings
    /// (maxWidth, filename template) and returns the resulting URL.
    func saveImageToDesktop(_ image: NSImage) throws -> URL {
        let prepared = try prepareCaptureSave(for: image)
        return try persistPreparedCapture(prepared)
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

    func canStartAreaCapture() -> Bool {
        if selectionOverlay?.isActive == true {
            return false
        }
        return canStartNewCapture()
    }

    func canStartFullScreenCapture() -> Bool {
        canStartNewCapture()
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

        guard !isCaptureInProgress else { return }
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
        let preparedSave = try prepareCaptureSave(for: image)
        let initialFilePersistence = makeInitialFilePersistenceTask(for: preparedSave)
        beginPostCaptureFlow(forExistingFileAt: preparedSave.targetURL,
                             initialImage: preparedSave.image,
                             initialFilePersistence: initialFilePersistence,
                             on: screenForDisplayID(displayID))
        soundPlayer.playCaptureSound()
    }

    private func captureCGImage(rect: CGRect, on screen: ScreenSnapshot) async throws -> CGImage {
        let contentTask = await shareableContentTask(trigger: "capture")
        let content = try await contentTask.value
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
        let nsError = error as NSError
        // macOS already owns the native Screen Recording permission flow.
        // When the user declines capture authorization, avoid stacking our own alert on top.
        if ScreenshotServiceCoreLogic.shouldSuppressCaptureFailureAlert(nsError) {
            return
        }
        presentError(title: "Screenshot failed", message: nsError.localizedDescription)
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

    private func pngData(from image: NSImage) -> Data? {
        ScreenshotServiceCoreLogic.pngData(from: image)
    }

    private func uniqueScreenshotURL(in directory: URL, baseName: String) -> URL {
        ScreenshotServiceCoreLogic.uniqueScreenshotURL(
            in: directory,
            baseName: baseName,
            fileExists: { [fileManager] path in fileManager.fileExists(atPath: path) }
        )
    }

    private func prepareCaptureSave(for image: NSImage) throws -> PreparedCaptureSave {
        let settings = settingsStore.settings

        let finalImage: NSImage
        if settings.maxWidth > 0 {
            finalImage = resizedImageIfNeeded(image, maxWidth: settings.maxWidth)
        } else {
            finalImage = image
        }

        let date = Date()
        let currentCounter = settings.screenshotCounter
        let baseName = settings.filenameTemplate.makeFilename(date: date, counter: currentCounter)

        try fileManager.createDirectory(at: desktopDirectory, withIntermediateDirectories: true)
        let targetURL = uniqueScreenshotURL(in: desktopDirectory, baseName: baseName)
        return PreparedCaptureSave(image: finalImage,
                                   targetURL: targetURL,
                                   currentCounter: currentCounter)
    }

    private func makeInitialFilePersistenceTask(for preparedSave: PreparedCaptureSave) -> Task<URL, Error> {
        return Task { [weak self] in
            try await withCheckedThrowingContinuation { continuation in
                guard let self else {
                    continuation.resume(throwing: NSError(domain: "ScreenshotService",
                                                          code: -10,
                                                          userInfo: [NSLocalizedDescriptionKey: "Screenshot service was released before save completed."]))
                    return
                }

                self.capturePersistenceQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: NSError(domain: "ScreenshotService",
                                                              code: -10,
                                                              userInfo: [NSLocalizedDescriptionKey: "Screenshot service was released before save completed."]))
                        return
                    }

                    do {
                        let writtenURL = try self.persistPreparedCapture(preparedSave)
                        continuation.resume(returning: writtenURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func persistPreparedCapture(_ preparedSave: PreparedCaptureSave) throws -> URL {
        guard let data = pngData(from: preparedSave.image) else {
            throw NSError(domain: "ScreenshotService",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG data."])
        }

        try data.write(to: preparedSave.targetURL, options: .atomic)
        advanceScreenshotCounter(afterWritingCounter: preparedSave.currentCounter)
        return preparedSave.targetURL
    }

    private func advanceScreenshotCounter(afterWritingCounter currentCounter: Int) {
        let applyUpdate = { [settingsStore] in
            settingsStore.update { settings in
                settings.screenshotCounter = max(settings.screenshotCounter, currentCounter + 1)
            }
        }

        if Thread.isMainThread {
            applyUpdate()
        } else {
            DispatchQueue.main.sync(execute: applyUpdate)
        }
    }

    private func prefetchShareableContent(trigger: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.shareableContentTask(trigger: trigger)
        }
    }

    private func shareableContentTask(trigger: String) async -> Task<SCShareableContent, Error> {
        await MainActor.run {
            let now = Date()
            if let prefetch = shareableContentPrefetch {
                if prefetch.fetchedAt == nil {
                    return prefetch.task
                }

                if let fetchedAt = prefetch.fetchedAt,
                   now.timeIntervalSince(fetchedAt) < shareableContentPrefetchTTL {
                    return prefetch.task
                }
            }

            let token = UUID()
            let task = Task<SCShareableContent, Error> { [weak self] in
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    await MainActor.run {
                        guard let self, self.shareableContentPrefetch?.token == token else { return }
                        self.shareableContentPrefetch?.fetchedAt = Date()
                    }
                    return content
                } catch {
                    await MainActor.run {
                        guard let self, self.shareableContentPrefetch?.token == token else { return }
                        self.shareableContentPrefetch = nil
                    }
                    throw error
                }
            }

            shareableContentPrefetch = ShareableContentPrefetch(token: token, task: task, fetchedAt: nil)
            return task
        }
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
        guard let rect else { return }
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
