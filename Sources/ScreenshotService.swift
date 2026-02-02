import AppKit

/// Handles screenshot capture, resizing, encoding and filename generation.
///
/// This file currently contains a minimal stub implementation so that the app
/// can compile and be wired together. A later pass will replace the internals
/// with a full ScreenCaptureKit-based pipeline and area selection overlay.
final class ScreenshotService {
    private let settingsStore: SettingsStore
    private let backupService: BackupService
    private let clipboardService: ClipboardService

    init(settingsStore: SettingsStore, backupService: BackupService, clipboardService: ClipboardService) {
        self.settingsStore = settingsStore
        self.backupService = backupService
        self.clipboardService = clipboardService
    }

    func captureArea() {
        // TODO: Implement ScreenCaptureKit-based area capture with selection overlay.
        notifyNotImplemented(feature: "Area Screenshot")
    }

    func captureFullScreen() {
        // TODO: Implement ScreenCaptureKit fullscreen capture.
        notifyNotImplemented(feature: "Fullscreen Screenshot")
    }

    // MARK: - Helpers

    private func notifyNotImplemented(feature: String) {
        let alert = NSAlert()
        alert.messageText = "\(feature) not yet implemented"
        alert.informativeText = "The core infrastructure (settings, tray, hotkeys) is in place. Screenshot capture will be implemented in a subsequent step."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
