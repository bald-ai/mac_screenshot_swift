import AppKit

/// Manages the NSStatusItem (menubar icon and menu).
final class TrayService {
    private let statusItem: NSStatusItem

    private let onScreenshotArea: () -> Void
    private let onScreenshotFull: () -> Void
    private let onStitchImages: () -> Void
    private let onShowSettings: () -> Void
    private let onQuit: () -> Void

    init(
        onScreenshotArea: @escaping () -> Void,
        onScreenshotFull: @escaping () -> Void,
        onStitchImages: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onScreenshotArea = onScreenshotArea
        self.onScreenshotFull = onScreenshotFull
        self.onStitchImages = onStitchImages
        self.onShowSettings = onShowSettings
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItem()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Screenshot App")
            } else {
                button.title = "SS"
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }

        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Screenshot Area", action: #selector(didSelectScreenshotArea), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Screenshot Full", action: #selector(didSelectScreenshotFull), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stitch Images", action: #selector(didSelectStitchImages), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show App", action: #selector(didSelectShowApp), keyEquivalent: ""))

        let quitItem = NSMenuItem(title: "Quit", action: #selector(didSelectQuit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        menu.items.forEach { item in
            item.target = self
        }

        return menu
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_ sender: Any?) {
        // For now, simply show the menu. In a later step we can refine this so
        // that left-click focuses the settings window and right-click shows the menu.
        if let button = statusItem.button, let menu = statusItem.menu {
            statusItem.popUpMenu(menu)
            // Ensure the status item remains highlighted only while the menu is open.
            button.performClick(nil)
        }
    }

    @objc private func didSelectScreenshotArea() {
        onScreenshotArea()
    }

    @objc private func didSelectScreenshotFull() {
        onScreenshotFull()
    }

    @objc private func didSelectStitchImages() {
        onStitchImages()
    }

    @objc private func didSelectShowApp() {
        onShowSettings()
    }

    @objc private func didSelectQuit() {
        onQuit()
    }
}
