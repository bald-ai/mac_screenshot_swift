import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: TrayService!
    private var settingsWindowController: SettingsWindowController!

    private let settingsStore = SettingsStore()
    private var hotKeyService: HotKeyService!
    private var screenshotService: ScreenshotService!
    private var stitchService: StitchService!
    private var clipboardService: ClipboardService!
    private var backupService: BackupService!

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsStore.load()

        backupService = BackupService()
        clipboardService = ClipboardService()
        screenshotService = ScreenshotService(settingsStore: settingsStore,
                                             backupService: backupService,
                                             clipboardService: clipboardService)
        stitchService = StitchService(screenshotService: screenshotService)
        hotKeyService = HotKeyService()

        statusItemController = TrayService(
            onScreenshotArea: { [weak self] in self?.triggerAreaScreenshot() },
            onScreenshotFull: { [weak self] in self?.triggerFullScreenshot() },
            onStitchImages: { [weak self] in self?.triggerStitch() },
            onShowSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        settingsWindowController = SettingsWindowController(settingsStore: settingsStore,
                                                            hotKeyService: hotKeyService)

        registerHotKeys()
    }

    private func registerHotKeys() {
        hotKeyService.registerShortcuts(settings: settingsStore.settings,
                                        areaHandler: { [weak self] in self?.triggerAreaScreenshot() },
                                        fullHandler: { [weak self] in self?.triggerFullScreenshot() },
                                        stitchHandler: { [weak self] in self?.triggerStitch() })
    }

    private func triggerAreaScreenshot() {
        screenshotService.captureArea()
    }

    private func triggerFullScreenshot() {
        screenshotService.captureFullScreen()
    }

    private func triggerStitch() {
        stitchService.stitchFromFinderSelection()
    }

    private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.showWindow(nil)
    }
}
