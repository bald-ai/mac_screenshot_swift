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

    fileprivate enum DebugSessionOutcome: String {
        case blockedOverlayActive = "blocked-overlay-active"
        case blockedBusy = "blocked-busy"
        case cancelledSelection = "cancelled-selection"
        case captureFailure = "capture-failure"
        case captureSucceeded = "capture-succeeded"
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

    private var activationObserver: NSObjectProtocol?
    private var activationTimeout: DispatchWorkItem?

    func captureArea() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.captureArea()
            }
            return
        }

        ScreenshotService.startAreaDebugSession(trigger: "area-capture hotkey")
        ScreenshotService.dbg("captureArea: entered on main thread")
        ScreenshotService.dbg("captureArea: preflight selectionOverlay=\(selectionOverlay != nil) activeWorkflow=\(activeWorkflow != nil) isCaptureInProgress=\(isCaptureInProgress)")
        ScreenshotService.dbg("captureArea: mouseLocation=\(Self.describe(point: NSEvent.mouseLocation)) screens=\(Self.describeScreens(NSScreen.screens))")

        if selectionOverlay != nil {
            ScreenshotService.dbg("captureArea: BAIL — selectionOverlay already exists")
            ScreenshotService.endAreaDebugSession(.blockedOverlayActive)
            return
        }
        guard canStartAreaCapture() else {
            ScreenshotService.dbg("captureArea: BAIL — canStartAreaCapture returned false")
            ScreenshotService.endAreaDebugSession(.blockedBusy)
            return
        }

        ScreenshotService.dbg("captureArea: NSApp.isActive=\(NSApp.isActive) BEFORE activate()")
        NSApp.activate(ignoringOtherApps: true)
        ScreenshotService.dbg("captureArea: NSApp.isActive=\(NSApp.isActive) AFTER activate()")

        if NSApp.isActive {
            ScreenshotService.dbg("captureArea: WARM path — showing overlay immediately")
            showAreaOverlay()
        } else {
            ScreenshotService.dbg("captureArea: COLD path — waiting for didBecomeActive")
            waitForActivationThenShowOverlay()
        }
    }

    private static let debugLogQueue = DispatchQueue(label: "Zoomies.DebugLogQueue")
    private static var currentDebugSessionID = "no-session"
    static var debugLogURLOverride: URL?

    private static var debugLogURL: URL {
        if let debugLogURLOverride {
            return debugLogURLOverride
        }

        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("zoomies_debug.log")
    }

    static func startAreaDebugSession(trigger: String) {
        let sessionID = makeDebugSessionID()
        let header = [
            "=== Zoomies Area Capture Debug Session ===",
            "session=\(sessionID)",
            "trigger=\(trigger)",
            "startedAt=\(timestamp())",
            "processID=\(ProcessInfo.processInfo.processIdentifier)",
            "appActive=\(NSApp.isActive)",
            "activationPolicy=\(NSApp.activationPolicy().rawValue)",
            "=========================================="
        ].joined(separator: "\n") + "\n"

        debugLogQueue.sync {
            currentDebugSessionID = sessionID
            writeDebugData(Data(header.utf8), resetFile: true)
        }
    }

    static func dbg(_ msg: String) {
        let line = "[\(timestamp())][session:\(debugSessionID())][thread:\(Thread.isMainThread ? "main" : "background")] \(msg)\n"
        debugLogQueue.sync {
            writeDebugData(Data(line.utf8))
        }
    }

    fileprivate static func endAreaDebugSession(_ outcome: DebugSessionOutcome) {
        dbg("SESSION END — outcome=\(outcome.rawValue)")
    }

    static func resetDebugLoggingForTests() {
        debugLogQueue.sync {
            currentDebugSessionID = "no-session"
            debugLogURLOverride = nil
        }
    }

    private static func debugSessionID() -> String {
        debugLogQueue.sync {
            currentDebugSessionID
        }
    }

    private static func writeDebugData(_ data: Data, resetFile: Bool = false) {
        let url = debugLogURL
        if resetFile {
            try? data.write(to: url, options: .atomic)
            return
        }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeDebugSessionID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private func showAreaOverlay() {
        ScreenshotService.dbg("showAreaOverlay: NSApp.isActive=\(NSApp.isActive) isKey=\(NSApp.keyWindow != nil)")
        guard selectionOverlay == nil else {
            ScreenshotService.dbg("showAreaOverlay: BAIL — selectionOverlay already exists")
            return
        }
        let overlay = SelectionOverlay()
        overlay.delegate = self
        selectionOverlay = overlay
        ScreenshotService.dbg("showAreaOverlay: created SelectionOverlay instance")
        overlay.beginSelection()
        ScreenshotService.dbg("showAreaOverlay: beginSelection() returned")
    }

    private func waitForActivationThenShowOverlay() {
        cancelActivationWait()
        ScreenshotService.dbg("activation: waiting up to 3.0s for didBecomeActive")

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            ScreenshotService.dbg("activation: didBecomeActive fired — NSApp.isActive=\(NSApp.isActive)")
            self?.cancelActivationWait()
            self?.showAreaOverlay()
        }

        let timeout = DispatchWorkItem { [weak self] in
            ScreenshotService.dbg("activation: TIMEOUT — activation never completed")
            self?.cancelActivationWait()
        }
        activationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: timeout)
    }

    private func cancelActivationWait() {
        ScreenshotService.dbg("activation: cancelActivationWait observer=\(activationObserver != nil) timeout=\(activationTimeout != nil)")
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }
        activationTimeout?.cancel()
        activationTimeout = nil
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
        guard canStartFullScreenCapture() else {
            return
        }
        guard let screen = screenUnderMouse() ?? menuBarScreen() ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        ScreenshotService.dbg("captureFullScreen: selected screen=\(Self.describe(screen: screen))")
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
            ScreenshotService.dbg("beginPostCaptureFlow: BAIL — activeWorkflow already exists for \(activeWorkflow?.debugFilePathForLogging ?? "unknown")")
            return
        }

        ScreenshotService.dbg("beginPostCaptureFlow: file=\(url.path) screen=\(Self.describe(screen: screen)) escapeKeyDeletesFile=\(escapeKeyDeletesFile)")

        let workflow = ScreenshotWorkflowController(
            fileURL: url,
            settingsStore: settingsStore,
            clipboardService: clipboardService,
            backupService: backupService,
            sourceScreen: screen,
            escapeKeyDeletesFile: escapeKeyDeletesFile
        )

        workflow.onFinish = { [weak self] in
            ScreenshotService.dbg("beginPostCaptureFlow: workflow finished for file=\(workflow.debugFilePathForLogging)")
            self?.activeWorkflow = nil
        }

        activeWorkflow = workflow
        ScreenshotService.dbg("beginPostCaptureFlow: starting workflow")
        workflow.start()
    }

    var isBusyForUserCommands: Bool {
        isCaptureInProgress || activeWorkflow != nil || selectionOverlay != nil
    }

    /// Saves an arbitrary image to the Desktop using the current settings
    /// (quality, maxWidth, filename template) and returns the resulting URL.
    func saveImageToDesktop(_ image: NSImage) throws -> URL {
        let settings = settingsStore.settings
        ScreenshotService.dbg("saveImageToDesktop: inputSize=\(Self.describe(size: image.size)) quality=\(settings.quality) maxWidth=\(settings.maxWidth) counter=\(settings.screenshotCounter)")

        let finalImage: NSImage
        if settings.maxWidth > 0 {
            finalImage = resizedImageIfNeeded(image, maxWidth: settings.maxWidth)
        } else {
            finalImage = image
        }
        ScreenshotService.dbg("saveImageToDesktop: finalSize=\(Self.describe(size: finalImage.size))")

        guard let data = jpegData(from: finalImage, quality: settings.quality) else {
            ScreenshotService.dbg("saveImageToDesktop: FAILED — jpegData returned nil")
            throw NSError(domain: "ScreenshotService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG data."])
        }

        let date = Date()
        let currentCounter = settings.screenshotCounter
        let baseName = settings.filenameTemplate.makeFilename(date: date, counter: currentCounter)
        ScreenshotService.dbg("saveImageToDesktop: baseName=\(baseName) desktop=\(desktopDirectory.path)")

        try fileManager.createDirectory(at: desktopDirectory, withIntermediateDirectories: true)
        let url = uniqueScreenshotURL(in: desktopDirectory, baseName: baseName)
        try data.write(to: url, options: .atomic)
        ScreenshotService.dbg("saveImageToDesktop: wrote file=\(url.path) bytes=\(data.count)")

        settingsStore.update { settings in
            settings.screenshotCounter = currentCounter + 1
        }
        ScreenshotService.dbg("saveImageToDesktop: incremented counter to \(settingsStore.settings.screenshotCounter)")

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

    func canStartAreaCapture() -> Bool {
        if selectionOverlay != nil {
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

        guard !isCaptureInProgress else {
            ScreenshotService.dbg("captureRegion: BAIL — capture already in progress")
            return
        }
        guard let displayID = screen.displayID else {
            ScreenshotService.dbg("captureRegion: FAILED — unable to determine display ID for screen=\(Self.describe(screen: screen))")
            presentError(title: "Screenshot failed", message: "Unable to determine display ID.")
            return
        }

        let snapshot = ScreenSnapshot(displayID: displayID,
                                      frame: screen.frame,
                                      scale: screen.backingScaleFactor)
        ScreenshotService.dbg("captureRegion: rect=\(Self.describe(rect: rect)) screen=\(Self.describe(screen: screen)) displayID=\(displayID)")
        isCaptureInProgress = true
        let captureStartedAt = Date()
        ScreenshotService.dbg("captureRegion: launching async ScreenCaptureKit task")

        Task { [weak self] in
            guard let self else { return }

            do {
                let cgImage = try await self.captureCGImage(rect: rect, on: snapshot)
                try await MainActor.run {
                    defer { self.isCaptureInProgress = false }
                    let elapsedMs = Int(Date().timeIntervalSince(captureStartedAt) * 1000)
                    ScreenshotService.dbg("captureRegion: captureCGImage succeeded after \(elapsedMs)ms size=\(cgImage.width)x\(cgImage.height)")
                    try self.finishCapture(with: cgImage, onDisplayID: snapshot.displayID)
                }
            } catch {
                await MainActor.run {
                    self.isCaptureInProgress = false
                    let elapsedMs = Int(Date().timeIntervalSince(captureStartedAt) * 1000)
                    ScreenshotService.dbg("captureRegion: captureCGImage FAILED after \(elapsedMs)ms error=\(Self.describe(error: error))")
                    self.handleCaptureFailure(error)
                }
            }
        }
    }

    private func finishCapture(with cgImage: CGImage, onDisplayID displayID: CGDirectDisplayID) throws {
        let imageSize = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        NSLog("ScreenshotService: saving capture %d×%d px", cgImage.width, cgImage.height)
        ScreenshotService.dbg("finishCapture: cgImageSize=\(cgImage.width)x\(cgImage.height) onDisplayID=\(displayID)")
        let image = NSImage(cgImage: cgImage, size: imageSize)
        let url = try saveImageToDesktop(image)
        ScreenshotService.dbg("finishCapture: saved image to \(url.path)")
        soundPlayer.playCaptureSound()
        ScreenshotService.dbg("finishCapture: played capture sound")
        beginPostCaptureFlow(forExistingFileAt: url, on: screenForDisplayID(displayID))
        ScreenshotService.endAreaDebugSession(.captureSucceeded)
    }

    private func captureCGImage(rect: CGRect, on screen: ScreenSnapshot) async throws -> CGImage {
        ScreenshotService.dbg("captureCGImage: requesting SCShareableContent for displayID=\(screen.displayID)")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        ScreenshotService.dbg("captureCGImage: received shareable content displays=\(content.displays.count) windows=\(content.windows.count) apps=\(content.applications.count)")
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            ScreenshotService.dbg("captureCGImage: FAILED — no matching display for displayID=\(screen.displayID)")
            throw NSError(domain: "ScreenshotService",
                          code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "No display found for capture."])
        }
        guard let captureRect = ScreenshotServiceCoreLogic.screenCaptureRect(rectInScreenPoints: rect,
                                                                             screenFrame: screen.frame,
                                                                             scale: screen.scale) else {
            ScreenshotService.dbg("captureCGImage: FAILED — selection rect outside bounds rect=\(Self.describe(rect: rect)) screenFrame=\(Self.describe(rect: screen.frame)) scale=\(screen.scale)")
            throw NSError(domain: "ScreenshotService",
                          code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Selected area is outside the display bounds."])
        }
        ScreenshotService.dbg("captureCGImage: using display frame=\(Self.describe(rect: display.frame))")
        ScreenshotService.dbg("captureCGImage: sourceRect.points=\(Self.describe(rect: captureRect.pointRect)) sourceRect.pixels=\(Self.describe(rect: captureRect.pixelRect))")

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRect.pointRect
        configuration.width = Int(captureRect.pixelRect.width)
        configuration.height = Int(captureRect.pixelRect.height)
        configuration.showsCursor = true
        configuration.scalesToFit = false
        ScreenshotService.dbg("captureCGImage: configuration width=\(configuration.width) height=\(configuration.height) showsCursor=\(configuration.showsCursor)")

        let excludedApplications = content.applications.filter { application in
            application.processID == ProcessInfo.processInfo.processIdentifier
        }
        ScreenshotService.dbg("captureCGImage: excludingApplications.count=\(excludedApplications.count)")
        let filter = SCContentFilter(display: display,
                                     excludingApplications: excludedApplications,
                                     exceptingWindows: [])

        return try await withCheckedThrowingContinuation { continuation in
            ScreenshotService.dbg("captureCGImage: calling SCScreenshotManager.captureImage")
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    ScreenshotService.dbg("captureCGImage: callback FAILED error=\(Self.describe(error: error))")
                    continuation.resume(throwing: error)
                } else if let image {
                    ScreenshotService.dbg("captureCGImage: callback returned image size=\(image.width)x\(image.height)")
                    continuation.resume(returning: image)
                } else {
                    ScreenshotService.dbg("captureCGImage: callback returned neither image nor error")
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
        ScreenshotService.dbg("handleCaptureFailure: error=\(Self.describe(error: error))")
        // macOS already owns the native Screen Recording permission flow.
        // When the user declines capture authorization, avoid stacking our own alert on top.
        if ScreenshotServiceCoreLogic.shouldSuppressCaptureFailureAlert(nsError) {
            ScreenshotService.dbg("handleCaptureFailure: suppressing alert for system-owned permission failure")
            ScreenshotService.endAreaDebugSession(.captureFailure)
            return
        }
        presentError(title: "Screenshot failed", message: nsError.localizedDescription)
        ScreenshotService.endAreaDebugSession(.captureFailure)
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

    private func presentError(title: String, message: String) {
        ScreenshotService.dbg("presentError: title=\(title) message=\(message)")
        AlertPresenter.presentWarning(title: title, message: message)
    }

    static func describe(point: CGPoint) -> String {
        "(\(String(format: "%.1f", point.x)), \(String(format: "%.1f", point.y)))"
    }

    static func describe(size: CGSize) -> String {
        "\(String(format: "%.1f", size.width))x\(String(format: "%.1f", size.height))"
    }

    static func describe(rect: CGRect) -> String {
        "(x:\(String(format: "%.1f", rect.origin.x)), y:\(String(format: "%.1f", rect.origin.y)), w:\(String(format: "%.1f", rect.width)), h:\(String(format: "%.1f", rect.height)))"
    }

    static func describe(screen: NSScreen?) -> String {
        guard let screen else {
            return "nil"
        }

        let displayIDText: String
        if let displayID = screen.displayID {
            displayIDText = String(displayID)
        } else {
            displayIDText = "nil"
        }

        return "displayID=\(displayIDText) frame=\(describe(rect: screen.frame)) visible=\(describe(rect: screen.visibleFrame)) scale=\(String(format: "%.2f", screen.backingScaleFactor))"
    }

    static func describeScreens(_ screens: [NSScreen]) -> String {
        screens.enumerated().map { index, screen in
            "#\(index): \(describe(screen: screen))"
        }.joined(separator: " | ")
    }

    static func describe(error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
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
        ScreenshotService.dbg("handleSelection: rect=\(rect.map { Self.describe(rect: $0) } ?? "nil") screen=\(Self.describe(screen: screen))")
        selectionOverlay = nil
        guard let rect else {
            ScreenshotService.endAreaDebugSession(.cancelledSelection)
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
