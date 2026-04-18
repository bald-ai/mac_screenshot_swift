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
        let quality: Int
        let currentCounter: Int
    }

    @MainActor
    private struct ShareableContentPrefetch {
        let token: UUID
        let task: Task<SCShareableContent, Error>
        var fetchedAt: Date?
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
    }

    // MARK: - Public API

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
        ScreenshotService.dbg("captureArea: showing overlay immediately after activate()")
        showAreaOverlay()
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
        prefetchShareableContent(trigger: "overlay")
        let overlay = SelectionOverlay()
        overlay.delegate = self
        selectionOverlay = overlay
        ScreenshotService.dbg("showAreaOverlay: created SelectionOverlay instance")
        overlay.beginSelection()
        ScreenshotService.dbg("showAreaOverlay: beginSelection() returned")
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

        guard activeWorkflow == nil else {
            ScreenshotService.dbg("beginPostCaptureFlow: BAIL — activeWorkflow already exists for \(activeWorkflow?.debugFilePathForLogging ?? "unknown")")
            return
        }

        ScreenshotService.dbg("beginPostCaptureFlow: file=\(url.path) screen=\(Self.describe(screen: screen)) escapeKeyDeletesFile=\(escapeKeyDeletesFile)")

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
        let preparedSave = try prepareCaptureSave(for: image)
        ScreenshotService.dbg("finishCapture: reserved target file \(preparedSave.targetURL.path)")
        let initialFilePersistence = makeInitialFilePersistenceTask(for: preparedSave)
        beginPostCaptureFlow(forExistingFileAt: preparedSave.targetURL,
                             initialImage: preparedSave.image,
                             initialFilePersistence: initialFilePersistence,
                             on: screenForDisplayID(displayID))
        ScreenshotService.dbg("finishCapture: launched rename workflow before disk write completes")
        soundPlayer.playCaptureSound()
        ScreenshotService.dbg("finishCapture: queued capture sound playback")
        ScreenshotService.endAreaDebugSession(.captureSucceeded)
    }

    private func captureCGImage(rect: CGRect, on screen: ScreenSnapshot) async throws -> CGImage {
        let contentTask = await shareableContentTask(trigger: "capture")
        ScreenshotService.dbg("captureCGImage: awaiting SCShareableContent for displayID=\(screen.displayID)")
        let content = try await contentTask.value
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

    private func prepareCaptureSave(for image: NSImage) throws -> PreparedCaptureSave {
        let settings = settingsStore.settings
        ScreenshotService.dbg("saveImageToDesktop: inputSize=\(Self.describe(size: image.size)) quality=\(settings.quality) maxWidth=\(settings.maxWidth) counter=\(settings.screenshotCounter)")

        let finalImage: NSImage
        if settings.maxWidth > 0 {
            finalImage = resizedImageIfNeeded(image, maxWidth: settings.maxWidth)
        } else {
            finalImage = image
        }
        ScreenshotService.dbg("saveImageToDesktop: finalSize=\(Self.describe(size: finalImage.size))")

        let date = Date()
        let currentCounter = settings.screenshotCounter
        let baseName = settings.filenameTemplate.makeFilename(date: date, counter: currentCounter)
        ScreenshotService.dbg("saveImageToDesktop: baseName=\(baseName) desktop=\(desktopDirectory.path)")

        try fileManager.createDirectory(at: desktopDirectory, withIntermediateDirectories: true)
        let targetURL = uniqueScreenshotURL(in: desktopDirectory, baseName: baseName)
        return PreparedCaptureSave(image: finalImage,
                                   targetURL: targetURL,
                                   quality: settings.quality,
                                   currentCounter: currentCounter)
    }

    private func makeInitialFilePersistenceTask(for preparedSave: PreparedCaptureSave) -> Task<URL, Error> {
        let targetURL = preparedSave.targetURL
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
                        ScreenshotService.dbg("finishCapture: background save completed file=\(writtenURL.path)")
                        continuation.resume(returning: writtenURL)
                    } catch {
                        ScreenshotService.dbg("finishCapture: background save FAILED target=\(targetURL.path) error=\(Self.describe(error: error))")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func persistPreparedCapture(_ preparedSave: PreparedCaptureSave) throws -> URL {
        guard let data = jpegData(from: preparedSave.image, quality: preparedSave.quality) else {
            ScreenshotService.dbg("saveImageToDesktop: FAILED — jpegData returned nil")
            throw NSError(domain: "ScreenshotService",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG data."])
        }

        try data.write(to: preparedSave.targetURL, options: .atomic)
        ScreenshotService.dbg("saveImageToDesktop: wrote file=\(preparedSave.targetURL.path) bytes=\(data.count)")
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

        ScreenshotService.dbg("saveImageToDesktop: incremented counter to \(settingsStore.settings.screenshotCounter)")
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
                    ScreenshotService.dbg("shareableContent[\(prefetch.token.uuidString)]: reusing in-flight fetch for \(trigger)")
                    return prefetch.task
                }

                if let fetchedAt = prefetch.fetchedAt,
                   now.timeIntervalSince(fetchedAt) < shareableContentPrefetchTTL {
                    ScreenshotService.dbg("shareableContent[\(prefetch.token.uuidString)]: reusing warm cache for \(trigger)")
                    return prefetch.task
                }
            }

            let token = UUID()
            ScreenshotService.dbg("shareableContent[\(token.uuidString)]: starting fetch for \(trigger)")
            let task = Task<SCShareableContent, Error> { [weak self] in
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    ScreenshotService.dbg("shareableContent[\(token.uuidString)]: fetch succeeded displays=\(content.displays.count) windows=\(content.windows.count) apps=\(content.applications.count)")
                    await MainActor.run {
                        guard let self, self.shareableContentPrefetch?.token == token else { return }
                        self.shareableContentPrefetch?.fetchedAt = Date()
                    }
                    return content
                } catch {
                    ScreenshotService.dbg("shareableContent[\(token.uuidString)]: fetch FAILED error=\(Self.describe(error: error))")
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
