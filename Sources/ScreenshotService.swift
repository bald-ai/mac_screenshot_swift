import AppKit

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
    private var isSystemCaptureInProgress = false
    private var systemCaptureProcess: Process?

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

    /// Captures the full contents of the display under the mouse using macOS screencapture.
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

        beginSystemFullScreenCapture()
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
        isSystemCaptureInProgress || activeWorkflow != nil
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
        if isSystemCaptureInProgress {
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
        beginSystemCapture(
            arguments: ["-i", "-x"],
            onCompletion: { [weak self] status, tempURL in
                self?.finishSystemAreaCapture(tempURL: tempURL, terminationStatus: status)
            }
        )
    }

    private func beginSystemFullScreenCapture() {
        let targetScreen = screenUnderMouse() ?? menuBarScreen() ?? NSScreen.main ?? NSScreen.screens.first
        let arguments = fullScreenCaptureArguments(for: targetScreen)
        beginSystemCapture(
            arguments: arguments,
            onCompletion: { [weak self] status, tempURL in
                self?.finishSystemFullScreenCapture(tempURL: tempURL,
                                                   terminationStatus: status,
                                                   targetScreen: targetScreen)
            }
        )
    }

    private func beginSystemCapture(arguments: [String],
                                    onCompletion: @escaping (Int32, URL) -> Void) {
        let tempURL = makeTemporaryScreenshotURL()
        isSystemCaptureInProgress = true

        runScreencapture(arguments: arguments + [tempURL.path]) { [weak self] status in
            guard let self = self else { return }
            self.isSystemCaptureInProgress = false
            onCompletion(status, tempURL)
        }
    }

    private func finishSystemAreaCapture(tempURL: URL, terminationStatus: Int32) {
        if terminationStatus == -1 {
            try? fileManager.removeItem(at: tempURL)
            presentError(title: "Screenshot failed", message: "Could not start native area capture.")
            return
        }

        guard terminationStatus == 0 else {
            try? fileManager.removeItem(at: tempURL)
            if !CGPreflightScreenCaptureAccess() {
                presentScreenRecordingPermissionError()
                return
            }
            // User cancelled the macOS picker.
            return
        }

        switch loadTemporaryImage(at: tempURL) {
        case .missing:
            // User cancelled picker without capturing.
            return
        case .unreadable:
            presentError(title: "Screenshot failed", message: "Could not read captured image.")
            return
        case .loaded(let image):
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
        }
    }

    private func finishSystemFullScreenCapture(tempURL: URL,
                                               terminationStatus: Int32,
                                               targetScreen: NSScreen?) {
        if terminationStatus == -1 {
            try? fileManager.removeItem(at: tempURL)
            presentError(title: "Screenshot failed", message: "Could not start native full-screen capture.")
            return
        }

        guard terminationStatus == 0 else {
            try? fileManager.removeItem(at: tempURL)
            if !CGPreflightScreenCaptureAccess() {
                presentScreenRecordingPermissionError()
            } else {
                presentError(title: "Screenshot failed", message: "System capture exited with status \(terminationStatus).")
            }
            return
        }

        switch loadTemporaryImage(at: tempURL) {
        case .missing:
            presentError(title: "Screenshot failed", message: "Captured image file not found.")
            return
        case .unreadable:
            presentError(title: "Screenshot failed", message: "Could not read captured image.")
            return
        case .loaded(let image):
            do {
                let url = try saveImageToDesktop(image)
                soundPlayer.playCaptureSound()
                beginPostCaptureFlow(forExistingFileAt: url, on: targetScreen)
            } catch {
                presentError(title: "Screenshot failed", message: error.localizedDescription)
            }
        }
    }

    private func makeTemporaryScreenshotURL() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("zoomies-\(UUID().uuidString)")
            .appendingPathExtension("png")
    }

    private func runScreencapture(arguments: [String], completion: @escaping (Int32) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        systemCaptureProcess = process

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.systemCaptureProcess = nil
                completion(process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            systemCaptureProcess = nil
            completion(-1)
        }
    }

    private func loadTemporaryImage(at url: URL) -> TemporaryImageResult {
        let result = ScreenshotServiceCoreLogic.loadTemporaryImage(
            at: url,
            fileExists: { [fileManager] path in fileManager.fileExists(atPath: path) },
            loadImage: { path in NSImage(contentsOf: path) }
        )
        try? fileManager.removeItem(at: url)
        return result
    }

    private func screenUnderMouse() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
    }

    private func menuBarScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first { screen in
            screenDisplayID(screen) == mainDisplayID
        }
    }

    private func fullScreenCaptureArguments(for screen: NSScreen?) -> [String] {
        guard let displayID = screen.flatMap(screenDisplayID),
              let displayNumber = screencaptureDisplayNumber(for: displayID) else {
            return ["-x", "-m"]
        }
        return ["-x", "-D\(displayNumber)"]
    }

    private func screencaptureDisplayNumber(for targetDisplayID: CGDirectDisplayID) -> Int? {
        let maxDisplayCount: UInt32 = 32
        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(maxDisplayCount))
        var actualDisplayCount: UInt32 = 0

        let result = CGGetActiveDisplayList(maxDisplayCount, &displayIDs, &actualDisplayCount)
        guard result == .success else {
            return nil
        }

        let activeDisplayIDs = Array(displayIDs.prefix(Int(actualDisplayCount)))
        return ScreenshotServiceCoreLogic.screencaptureDisplayNumber(
            for: targetDisplayID,
            activeDisplayIDs: activeDisplayIDs,
            mainDisplayID: CGMainDisplayID()
        )
    }

    private func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
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

    private func presentScreenRecordingPermissionError() {
        let title = "Screen Recording Permission Required"
        let message = "Zoomies needs Screen Recording permission to take screenshots.\n\nOpen System Settings → Privacy & Security → Screen Recording, enable Zoomies, then quit and reopen the app."
        AlertPresenter.presentWarningWithSettingsButton(title: title, message: message)
    }

    private func presentError(title: String, message: String) {
        presentAlert(title: title, message: message)
    }

    private func presentAlert(title: String, message: String) {
        AlertPresenter.presentWarning(title: title, message: message)
    }
}

// ScreenshotService mutates UI state on the main thread and capture callbacks
// are hopped back to the main queue. We mark it @unchecked Sendable to silence
// Swift 6 Sendable warnings for queue hops.
extension ScreenshotService: @unchecked Sendable {}
