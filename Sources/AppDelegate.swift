import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: TrayService!
    private var settingsWindowController: SettingsWindowController?

    private let settingsStore = SettingsStore()
    private var hotKeyService: HotKeyService!
    private var screenshotService: ScreenshotService!
    private var clipboardService: ClipboardService!
    private var scratchpadService: ScratchpadService!
    private var backupService: BackupService!
    private let screenshotSoundPlayer = ScreenshotSoundPlayer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.event("applicationDidFinishLaunching args=\(CommandLine.arguments.joined(separator: " ")) log=\(AppLog.fileURL.path)")
        settingsStore.load()
        AppLog.event("settings loaded openScratchpad=\(HotKeyService.describeShortcut(keyCode: settingsStore.settings.shortcuts.openScratchpad.keyCode, carbonFlags: settingsStore.settings.shortcuts.openScratchpad.modifierFlags))")

        backupService = BackupService()
        clipboardService = ClipboardService()
        
        // Intentional: clipboard cache is only needed to keep Cmd+Delete paste working
        // within the current app session. Purging on launch prevents stale cached files
        // from accumulating indefinitely across launches.
        backupService.purgeAllBackups()
        clipboardService.purgeAllCachedFiles()

        screenshotService = ScreenshotService(settingsStore: settingsStore,
                                             backupService: backupService,
                                             clipboardService: clipboardService,
                                             soundPlayer: screenshotSoundPlayer)
        screenshotSoundPlayer.prewarmCaptureSound()
        scratchpadService = ScratchpadService(clipboardService: clipboardService)
        hotKeyService = HotKeyService()

        statusItemController = TrayService(
            onOpenScratchpad: { [weak self] in
                self?.triggerOpenScratchpad()
            },
            onShowSettings: { [weak self] in
                self?.showSettings()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        registerHotKeys()
        showWelcomeInfo()
        AppLog.event("applicationDidFinishLaunching complete")
    }

    private func showWelcomeInfo() {
        DispatchQueue.main.async {
            // Intentional product decision: keep the explicit first-run-style welcome copy
            // visible on launch instead of replacing it with a softer or hidden help surface.
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "🚨🚨🚨 READ THIS YOU DUMFUS OR YOU WILL BE CONFUSED AS FUCK 🚨🚨🚨"
            alert.informativeText = """
            Default shortcuts:
            • Option+Shift+4 → Area capture
            • Option+Shift+3 → Full-screen capture
            • Option+Shift+2 → Select an image in Finder, press this to edit/rename it with Zoomies
            • Option+Shift+5 → Create a scratchpad note

            These avoid the default macOS Cmd+Shift screenshot shortcuts.

            ⚠️ Permissions: macOS will ask for Screen Recording permission the first time you capture. If you deny it, enable Zoomies in System Settings → Privacy & Security → Screen Recording, then try again.
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func registerHotKeys() {
        hotKeyService.onRegistrationFailures = { failures in
            AppLog.event("hotkey registration failures=\(failures.joined(separator: ", "))")
            DispatchQueue.main.async {
                AlertPresenter.presentWarning(
                    title: "Some shortcuts couldn't be registered",
                    message: """
                    These combos are already taken by macOS or another app, so they won't work:

                    \(failures.joined(separator: "\n"))

                    Free them up in System Settings → Keyboard → Keyboard Shortcuts, or pick a different combo in Zoomies Settings. You can always open the Scratchpad from the menu-bar icon.
                    """
                )
            }
        }
        hotKeyService.registerShortcuts(settings: settingsStore.settings,
                                        areaHandler: { [weak self] in self?.triggerAreaScreenshot() },
                                        fullHandler: { [weak self] in self?.triggerFullScreenshot() },
                                        reopenFinderSelectionHandler: { [weak self] in self?.triggerReopenFinderSelection() },
                                        openScratchpadHandler: { [weak self] in self?.triggerOpenScratchpad() })
        AppLog.event("registerHotKeys complete")
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

    private func triggerOpenScratchpad() {
        AppLog.event("triggerOpenScratchpad requested recording=\(settingsWindowController?.isRecordingAnyShortcut == true) screenshotBusy=\(screenshotService.isBusyForUserCommands)")
        // Menu-item actions run while NSMenu is tracking; defer opening the
        // scratchpad to the next runloop turn so the menu can dismiss first.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            AppLog.event("triggerOpenScratchpad deferred running recording=\(self.settingsWindowController?.isRecordingAnyShortcut == true)")
            if self.settingsWindowController?.isRecordingAnyShortcut == true {
                AppLog.event("triggerOpenScratchpad blocked: shortcut recorder is active")
                return
            }
            self.scratchpadService.open()
            AppLog.event("triggerOpenScratchpad called ScratchpadService.open")
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
