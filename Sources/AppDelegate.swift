import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: TrayService!
    private var settingsWindowController: SettingsWindowController?

    private let settingsStore = SettingsStore()
    private var hotKeyService: HotKeyService!
    private var screenshotService: ScreenshotService!
    private var clipboardService: ClipboardService!
    private var backupService: BackupService!

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsStore.load()

        backupService = BackupService()
        clipboardService = ClipboardService()
        
        // Keep the cache directories tidy across dev/test loops (matches legacy app behavior).
        backupService.purgeAllBackups()
        clipboardService.purgeAllCachedFiles()

        screenshotService = ScreenshotService(settingsStore: settingsStore,
                                             backupService: backupService,
                                             clipboardService: clipboardService)
        hotKeyService = HotKeyService()

        statusItemController = TrayService(
            onShowSettings: { [weak self] in
                self?.showSettings()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        registerHotKeys()
        showWelcomeInfo()
    }

    private func showWelcomeInfo() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "🚨🚨🚨 READ THIS YOU DUMFUS OR YOU WILL BE CONFUSED AS FUCK 🚨🚨🚨"
            alert.informativeText = """
            Default shortcuts:
            • Ctrl+Shift+4 → Area capture
            • Ctrl+Shift+3 → Full-screen capture
            • Ctrl+Shift+2 → Select an image in Finder, press this to edit/rename it with Zoomies

            💡 I recommend rebinding to Cmd+Shift+3 / Cmd+Shift+4 / Cmd+Shift+2 (the default macOS screenshot shortcuts) — they are much more comfortable. First, unbind or rebind the default macOS shortcuts in System Settings → Keyboard → Keyboard Shortcuts → Screenshots, then set the new shortcuts in Zoomies Settings.

            ⚠️ Permissions: macOS may ask for Screen Recording permission. On macOS 26 and up it is required — on older versions it probably isn't, so if screenshots work without granting it, you can safely ignore the popup.
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
        if settingsWindowController?.isRecordingAnyShortcut == true {
            return
        }
        screenshotService.captureArea()
    }

    private func triggerFullScreenshot() {
        if settingsWindowController?.isRecordingAnyShortcut == true {
            return
        }
        screenshotService.captureFullScreen()
    }

    private func triggerReopenFinderSelection() {
        if settingsWindowController?.isRecordingAnyShortcut == true {
            return
        }
        if screenshotService.isBusyForUserCommands {
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
            let nsError = error as NSError
            if nsError.domain == "FinderSelectionService" && nsError.code == -2 {
                AlertPresenter.presentWarningWithSettingsButton(
                    title: "Automation Permission Required",
                    message: "Zoomies needs permission to communicate with Finder.\n\nOpen System Settings → Privacy & Security → Automation, and enable Finder under Zoomies.",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
            } else {
                presentError(title: "Finder Error", message: error.localizedDescription)
            }
        }
    }

    private func showSettings() {
        // Menu-item actions run while NSMenu is tracking; defer opening the window
        // to the next runloop turn so the menu can dismiss first.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let settingsWindowController = self.settingsWindowControllerOrCreate()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func settingsWindowControllerOrCreate() -> SettingsWindowController {
        if let existing = settingsWindowController {
            return existing
        }
        let created = SettingsWindowController(settingsStore: settingsStore, hotKeyService: hotKeyService)
        settingsWindowController = created
        return created
    }

    private func presentError(title: String, message: String) {
        AlertPresenter.presentWarning(title: title, message: message)
    }
}
