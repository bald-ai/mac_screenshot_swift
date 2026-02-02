import AppKit

/// Settings window with controls for quality, max size, note prefix, and
/// global shortcut configuration.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let settingsStore: SettingsStore
    private let hotKeyService: HotKeyService

    // UI elements we need to read/write after initialization.
    private let qualitySlider: NSSlider
    private let qualityValueLabel: NSTextField
    private let maxSizePopUp: NSPopUpButton
    private let notePrefixCheckbox: NSButton
    private let notePrefixField: NSTextField

    private let areaShortcutRecorder: ShortcutRecorderView
    private let fullShortcutRecorder: ShortcutRecorderView
    private let stitchShortcutRecorder: ShortcutRecorderView
    private let duplicateWarningLabel: NSTextField

    /// Fixed set of max-width options shown in the dropdown.
    private let maxWidthOptions: [Int] = [0, 800, 1024, 1440, 1920]

    init(settingsStore: SettingsStore, hotKeyService: HotKeyService) {
        self.settingsStore = settingsStore
        self.hotKeyService = hotKeyService

        qualitySlider = NSSlider(value: 90, minValue: 10, maxValue: 100, target: nil, action: nil)
        qualityValueLabel = NSTextField(labelWithString: "")
        maxSizePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        notePrefixCheckbox = NSButton(checkboxWithTitle: "Prefix note with:", target: nil, action: nil)
        notePrefixField = NSTextField(string: "")

        areaShortcutRecorder = ShortcutRecorderView(frame: .zero)
        fullShortcutRecorder = ShortcutRecorderView(frame: .zero)
        stitchShortcutRecorder = ShortcutRecorderView(frame: .zero)
        duplicateWarningLabel = NSTextField(labelWithString: "")

        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 420)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        let window = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
        window.center()
        window.title = "Screenshot App Settings"

        super.init(window: window)

        window.delegate = self
        configureContent()
        populateFromSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Configuration

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        contentView.subviews.forEach { $0.removeFromSuperview() }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])

        // Quality row
        let qualityLabel = NSTextField(labelWithString: "JPEG Quality:")
        qualityLabel.translatesAutoresizingMaskIntoConstraints = false

        qualitySlider.translatesAutoresizingMaskIntoConstraints = false
        qualitySlider.minValue = 10
        qualitySlider.maxValue = 100
        qualitySlider.numberOfTickMarks = (100 - 10) / 5 + 1
        qualitySlider.allowsTickMarkValuesOnly = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualitySliderChanged(_:))

        qualityValueLabel.translatesAutoresizingMaskIntoConstraints = false

        let qualityRow = NSStackView(views: [qualityLabel, qualitySlider, qualityValueLabel])
        qualityRow.orientation = .horizontal
        qualityRow.alignment = .centerY
        qualityRow.spacing = 8
        qualityRow.distribution = .fill

        qualityLabel.setContentHuggingPriority(.required, for: .horizontal)
        qualityValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Max size row
        let maxSizeLabel = NSTextField(labelWithString: "Max width:")
        maxSizeLabel.translatesAutoresizingMaskIntoConstraints = false

        maxSizePopUp.translatesAutoresizingMaskIntoConstraints = false
        configureMaxSizePopUp()

        let maxSizeRow = NSStackView(views: [maxSizeLabel, maxSizePopUp])
        maxSizeRow.orientation = .horizontal
        maxSizeRow.alignment = .centerY
        maxSizeRow.spacing = 8

        maxSizeLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Note prefix row
        notePrefixCheckbox.translatesAutoresizingMaskIntoConstraints = false
        notePrefixCheckbox.target = self
        notePrefixCheckbox.action = #selector(notePrefixToggled(_:))

        notePrefixField.translatesAutoresizingMaskIntoConstraints = false
        notePrefixField.delegate = self
        notePrefixField.target = self
        notePrefixField.action = #selector(notePrefixFieldEdited(_:))

        let notePrefixRow = NSStackView(views: [notePrefixCheckbox, notePrefixField])
        notePrefixRow.orientation = .horizontal
        notePrefixRow.alignment = .centerY
        notePrefixRow.spacing = 8

        notePrefixCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        // Shortcuts header
        let shortcutsHeader = NSTextField(labelWithString: "Global Shortcuts")
        shortcutsHeader.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        // Shortcut rows
        let areaLabel = NSTextField(labelWithString: "Screenshot Area:")
        let fullLabel = NSTextField(labelWithString: "Screenshot Full:")
        let stitchLabel = NSTextField(labelWithString: "Stitch Images:")

        [areaLabel, fullLabel, stitchLabel].forEach { label in
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        areaShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        fullShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        stitchShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false

        areaShortcutRecorder.onChange = { [weak self] value in
            self?.handleShortcutChange(kind: .area, newValue: value)
        }
        fullShortcutRecorder.onChange = { [weak self] value in
            self?.handleShortcutChange(kind: .full, newValue: value)
        }
        stitchShortcutRecorder.onChange = { [weak self] value in
            self?.handleShortcutChange(kind: .stitch, newValue: value)
        }

        let areaRow = NSStackView(views: [areaLabel, areaShortcutRecorder])
        areaRow.orientation = .horizontal
        areaRow.alignment = .centerY
        areaRow.spacing = 8

        let fullRow = NSStackView(views: [fullLabel, fullShortcutRecorder])
        fullRow.orientation = .horizontal
        fullRow.alignment = .centerY
        fullRow.spacing = 8

        let stitchRow = NSStackView(views: [stitchLabel, stitchShortcutRecorder])
        stitchRow.orientation = .horizontal
        stitchRow.alignment = .centerY
        stitchRow.spacing = 8

        // Duplicate warning label
        duplicateWarningLabel.textColor = NSColor.systemRed
        duplicateWarningLabel.isHidden = true

        // Assemble root stack
        rootStack.addArrangedSubview(qualityRow)
        rootStack.addArrangedSubview(maxSizeRow)
        rootStack.addArrangedSubview(notePrefixRow)
        rootStack.addArrangedSubview(NSBox.separator())
        rootStack.addArrangedSubview(shortcutsHeader)
        rootStack.addArrangedSubview(areaRow)
        rootStack.addArrangedSubview(fullRow)
        rootStack.addArrangedSubview(stitchRow)
        rootStack.addArrangedSubview(duplicateWarningLabel)
    }

    private func configureMaxSizePopUp() {
        maxSizePopUp.removeAllItems()

        for width in maxWidthOptions {
            let title: String
            if width == 0 {
                title = "Original size"
            } else {
                title = "Max width: \(width) px"
            }

            maxSizePopUp.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
            if let item = maxSizePopUp.lastItem {
                item.tag = width
            }
        }

        maxSizePopUp.target = self
        maxSizePopUp.action = #selector(maxSizeChanged(_:))
    }

    private func populateFromSettings() {
        let settings = settingsStore.settings

        // Quality
        qualitySlider.integerValue = settings.quality
        qualityValueLabel.stringValue = "\(settings.quality)"

        // Max width
        let indexForCurrent = maxSizePopUp.indexOfItem(withTag: settings.maxWidth)
        if indexForCurrent != -1 {
            maxSizePopUp.selectItem(at: indexForCurrent)
        } else {
            let indexForOriginal = maxSizePopUp.indexOfItem(withTag: 0)
            if indexForOriginal != -1 {
                maxSizePopUp.selectItem(at: indexForOriginal)
            }
        }

        // Note prefix
        notePrefixCheckbox.state = settings.notePrefixEnabled ? .on : .off
        notePrefixField.stringValue = settings.notePrefix
        notePrefixField.isEnabled = settings.notePrefixEnabled

        // Shortcuts
        applyShortcutsToRecorders(from: settings.shortcuts)
    }

    private func applyShortcutsToRecorders(from shortcuts: Shortcuts) {
        areaShortcutRecorder.recordedShortcut = .init(from: shortcuts.screenshotArea)
        fullShortcutRecorder.recordedShortcut = .init(from: shortcuts.screenshotFull)
        stitchShortcutRecorder.recordedShortcut = .init(from: shortcuts.stitchImages)
    }

    // MARK: - Actions

    @objc private func qualitySliderChanged(_ sender: NSSlider) {
        // Snap to nearest step of 5.
        let rawValue = Int(sender.doubleValue.rounded())
        let snapped = max(10, min(100, (rawValue / 5) * 5))
        sender.integerValue = snapped
        qualityValueLabel.stringValue = "\(snapped)"

        settingsStore.update { settings in
            settings.quality = snapped
        }
    }

    @objc private func maxSizeChanged(_ sender: NSPopUpButton) {
        let width = sender.selectedItem?.tag ?? 0
        settingsStore.update { settings in
            settings.maxWidth = width
        }
    }

    @objc private func notePrefixToggled(_ sender: NSButton) {
        let isOn = sender.state == .on
        notePrefixField.isEnabled = isOn
        settingsStore.update { settings in
            settings.notePrefixEnabled = isOn
        }
    }

    @objc private func notePrefixFieldEdited(_ sender: NSTextField) {
        var text = sender.stringValue
        if text.count > 50 {
            text = String(text.prefix(50))
            sender.stringValue = text
        }

        settingsStore.update { settings in
            settings.notePrefix = text
        }
    }

    private enum ShortcutKind {
        case area
        case full
        case stitch
    }

    private func handleShortcutChange(kind: ShortcutKind, newValue: ShortcutRecorderView.RecordedShortcut) {
        duplicateWarningLabel.isHidden = true
        duplicateWarningLabel.stringValue = ""

        let newShortcut = Shortcut(keyCode: newValue.keyCode, modifierFlags: newValue.carbonFlags)
        var shortcuts = settingsStore.settings.shortcuts

        switch kind {
        case .area:
            shortcuts.screenshotArea = newShortcut
        case .full:
            shortcuts.screenshotFull = newShortcut
        case .stitch:
            shortcuts.stitchImages = newShortcut
        }

        if hasDuplicate(shortcuts: shortcuts) {
            NSSound.beep()
            duplicateWarningLabel.isHidden = false
            duplicateWarningLabel.stringValue = "Shortcut already in use. Please choose a different combination."

            // Revert recorder to the previous value from persisted settings.
            let currentShortcuts = settingsStore.settings.shortcuts
            applyShortcutsToRecorders(from: currentShortcuts)
            return
        }

        settingsStore.update { settings in
            settings.shortcuts = shortcuts
        }

        // Re-apply in case normalization changed anything, then update hotkeys.
        applyShortcutsToRecorders(from: settingsStore.settings.shortcuts)
        hotKeyService.updateShortcuts(settings: settingsStore.settings)
    }

    private func hasDuplicate(shortcuts: Shortcuts) -> Bool {
        let values: [Shortcut] = [
            shortcuts.screenshotArea,
            shortcuts.screenshotFull,
            shortcuts.stitchImages
        ]
        let set = Set(values)
        return set.count < values.count
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === notePrefixField else { return }

        var text = field.stringValue
        if text.count > 50 {
            text = String(text.prefix(50))
            field.stringValue = text
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // When the settings window is closed, return the app to accessory mode
        // so it behaves like a menubar app again.
        NSApp.setActivationPolicy(.accessory)
    }
}

private extension ShortcutRecorderView.RecordedShortcut {
    init(from shortcut: Shortcut) {
        self.init(keyCode: shortcut.keyCode, carbonFlags: shortcut.modifierFlags)
    }
}
