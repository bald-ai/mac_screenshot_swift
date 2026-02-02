import AppKit

/// Placeholder settings window.
///
/// The full UI (quality slider, max size dropdown, filename template editor,
/// shortcut recorder, etc.) will be implemented in later steps. For now we
/// expose a basic titled window so the rest of the application flow exists.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private let hotKeyService: HotKeyService

    init(settingsStore: SettingsStore, hotKeyService: HotKeyService) {
        self.settingsStore = settingsStore
        self.hotKeyService = hotKeyService

        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 400)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        let window = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
        window.center()
        window.title = "Screenshot App Settings"

        super.init(window: window)

        window.delegate = self
        configurePlaceholderContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configurePlaceholderContent() {
        guard let contentView = window?.contentView else { return }

        let label = NSTextField(labelWithString: "Settings UI not implemented yet. Core settings model and persistence are in place.")
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20)
        ])
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // When the settings window is closed, return the app to accessory mode
        // so it behaves like a menubar app again.
        NSApp.setActivationPolicy(.accessory)
    }
}
