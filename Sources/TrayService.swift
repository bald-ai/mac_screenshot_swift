import AppKit

/// Manages the NSStatusItem (menubar icon and menu).
final class TrayService {
    private let statusItem: NSStatusItem
    private var menu: NSMenu?

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
        Logger.shared.info("TrayService: Initializing...")
        self.onScreenshotArea = onScreenshotArea
        self.onScreenshotFull = onScreenshotFull
        self.onStitchImages = onStitchImages
        self.onShowSettings = onShowSettings
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        Logger.shared.info("TrayService: Status item created")
        configureStatusItem()
        menu = makeMenu()
        Logger.shared.info("TrayService: Initialization complete")
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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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
        guard let event = NSApp.currentEvent else {
            onShowSettings()
            return
        }

        let showMenu: () -> Void = { [weak self] in
            guard let self = self, let menu = self.menu, let button = self.statusItem.button else { return }
            let location = NSPoint(x: 0, y: button.bounds.height + 2)
            menu.popUp(positioning: nil, at: location, in: button)
        }

        switch event.type {
        case .rightMouseUp:
            showMenu()

        case .leftMouseUp:
            // Control-click should behave like right-click.
            if event.modifierFlags.contains(.control) {
                showMenu()
            } else {
                onShowSettings()
            }

        default:
            break
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
