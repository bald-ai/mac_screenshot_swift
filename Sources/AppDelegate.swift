import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: TrayService!
    private var settingsWindowController: SettingsWindowController!
    private var ipcService: IPCService!

    private let settingsStore = SettingsStore()
    private var hotKeyService: HotKeyService!
    private var screenshotService: ScreenshotService!
    private var clipboardService: ClipboardService!
    private var backupService: BackupService!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.info("AppDelegate: Application launching...")
        
        settingsStore.load()
        Logger.shared.info("AppDelegate: Settings loaded")

        backupService = BackupService()
        clipboardService = ClipboardService()
        Logger.shared.info("AppDelegate: Services initialized")
        
        // Keep the cache directories tidy across dev/test loops (matches legacy app behavior).
        backupService.purgeAllBackups()
        clipboardService.purgeAllCachedFiles()

        screenshotService = ScreenshotService(settingsStore: settingsStore,
                                             backupService: backupService,
                                             clipboardService: clipboardService)
        hotKeyService = HotKeyService()
        Logger.shared.info("AppDelegate: HotKeyService created")

        statusItemController = TrayService(
            onScreenshotArea: { [weak self] in 
                Logger.shared.info("AppDelegate: Area screenshot triggered from menu")
                self?.triggerAreaScreenshot() 
            },
            onScreenshotFull: { [weak self] in 
                Logger.shared.info("AppDelegate: Full screenshot triggered from menu")
                self?.triggerFullScreenshot() 
            },
            onShowSettings: { [weak self] in 
                Logger.shared.info("AppDelegate: Show settings triggered")
                self?.showSettings() 
            },
            onQuit: { 
                Logger.shared.info("AppDelegate: Quit triggered")
                NSApp.terminate(nil) 
            }
        )
        Logger.shared.info("AppDelegate: TrayService created")

        settingsWindowController = SettingsWindowController(settingsStore: settingsStore,
                                                            hotKeyService: hotKeyService)
        Logger.shared.info("AppDelegate: SettingsWindowController created")
        
        // Start IPC service for CLI control
        ipcService = IPCService(appDelegate: self)
        ipcService.start()
        Logger.shared.info("AppDelegate: IPC service started")

        registerHotKeys()
        Logger.shared.info("AppDelegate: Application finished launching")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        Logger.shared.info("AppDelegate: Application terminating")
        ipcService?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func registerHotKeys() {
        hotKeyService.registerShortcuts(settings: settingsStore.settings,
                                        areaHandler: { [weak self] in self?.triggerAreaScreenshot() },
                                        fullHandler: { [weak self] in self?.triggerFullScreenshot() },
                                        reopenFinderSelectionHandler: { [weak self] in self?.triggerReopenFinderSelection() })
    }

    private func triggerAreaScreenshot() {
        Logger.shared.info("AppDelegate: triggerAreaScreenshot called")
        if settingsWindowController.isRecordingAnyShortcut {
            Logger.shared.info("AppDelegate: triggerAreaScreenshot ignored (shortcut recording active)")
            return
        }
        screenshotService.captureArea()
        Logger.shared.info("AppDelegate: triggerAreaScreenshot completed")
    }

    private func triggerFullScreenshot() {
        Logger.shared.info("AppDelegate: triggerFullScreenshot called")
        if settingsWindowController.isRecordingAnyShortcut {
            Logger.shared.info("AppDelegate: triggerFullScreenshot ignored (shortcut recording active)")
            return
        }
        screenshotService.captureFullScreen()
        Logger.shared.info("AppDelegate: triggerFullScreenshot completed")
    }

    private func triggerReopenFinderSelection() {
        Logger.shared.info("AppDelegate: triggerReopenFinderSelection called")
        if settingsWindowController.isRecordingAnyShortcut {
            Logger.shared.info("AppDelegate: triggerReopenFinderSelection ignored (shortcut recording active)")
            return
        }
        if screenshotService.isBusyForUserCommands {
            Logger.shared.info("AppDelegate: triggerReopenFinderSelection ignored (app busy)")
            return
        }

        do {
            let selection = try FinderSelectionService.selection()
            let url: URL
            switch selection {
            case .none:
                presentError(title: "No Finder Selection", message: "Select an image file in Finder, then press the shortcut again.")
                return
            case .multiple(let count):
                presentError(title: "Multiple Finder Items Selected", message: "Select exactly 1 image file in Finder (you selected \(count)), then press the shortcut again.")
                return
            case .single(let selectedURL):
                url = selectedURL
            }
            guard NSImage(contentsOf: url) != nil else {
                presentError(title: "Not an Image", message: "The selected Finder item is not a readable image.")
                return
            }

            screenshotService.beginPostCaptureFlow(forExistingFileAt: url, on: nil, escapeKeyDeletesFile: false)
        } catch {
            presentError(title: "Finder Error", message: error.localizedDescription)
        }

        Logger.shared.info("AppDelegate: triggerReopenFinderSelection completed")
    }

    private func showSettings() {
        Logger.shared.info("AppDelegate: showSettings called")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.showWindow(nil)
        Logger.shared.info("AppDelegate: showSettings completed")
    }

    private func presentError(title: String, message: String) {
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

    // MARK: - IPC Access

    func triggerFullScreenshotFromIPC() {
        Logger.shared.info("AppDelegate: triggerFullScreenshotFromIPC called")
        triggerFullScreenshot()
    }

    func triggerAreaScreenshotFromIPC() {
        Logger.shared.info("AppDelegate: triggerAreaScreenshotFromIPC called")
        triggerAreaScreenshot()
    }

    func cancelActiveWorkflowFromIPC() {
        Logger.shared.info("AppDelegate: cancelActiveWorkflowFromIPC called")
        screenshotService.cancelActiveWorkflow()
    }
}
