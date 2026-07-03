import AppKit

/// Manages the NSStatusItem (menubar icon and menu).
final class TrayService {
    private let statusItem: NSStatusItem
    private var menu: NSMenu?

    private let onOpenScratchpad: () -> Void
    private let onShowSettings: () -> Void
    private let onQuit: () -> Void

    init(
        onOpenScratchpad: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenScratchpad = onOpenScratchpad
        self.onShowSettings = onShowSettings
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItem()
        menu = makeMenu()
        AppLog.event("TrayService initialized statusButtonExists=\(statusItem.button != nil) menuItems=\(menu?.items.map { $0.title }.joined(separator: ", ") ?? "nil")")
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Zoomies")
            } else {
                button.title = "Z"
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        AppTheme.apply(to: menu)

        menu.addItem(NSMenuItem(title: "Open Scratchpad", action: #selector(didSelectOpenScratchpad), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(didSelectSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

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
        AppLog.event("statusItemClicked eventType=\(String(describing: NSApp.currentEvent?.type.rawValue))")
        guard let event = NSApp.currentEvent else {
            AppLog.event("statusItemClicked has no currentEvent; showing settings")
            onShowSettings()
            return
        }

        let showMenu: () -> Void = { [weak self] in
            guard let self = self, let menu = self.menu, let button = self.statusItem.button else { return }
            let location = NSPoint(x: 0, y: button.bounds.height + 2)
            menu.popUp(positioning: nil, at: location, in: button)
        }

        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            AppLog.event("statusItemClicked showing menu")
            showMenu()
        }
    }

    @objc private func didSelectOpenScratchpad() {
        AppLog.event("didSelectOpenScratchpad")
        onOpenScratchpad()
    }

    @objc private func didSelectSettings() {
        AppLog.event("didSelectSettings")
        onShowSettings()
    }

    @objc private func didSelectQuit() {
        AppLog.event("didSelectQuit")
        onQuit()
    }
}
