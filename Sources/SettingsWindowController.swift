import AppKit

/// Settings window with controls for max size, note prefix, and
/// global shortcut configuration.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let settingsStore: SettingsStore
    private let hotKeyService: HotKeyService

    // UI elements we need to read/write after initialization.
    private let maxSizePopUp: NSPopUpButton
    private let notePrefixCheckbox: NSButton
    private let notePrefixField: NSTextField
    private let notePrefixCountLabel: NSTextField
    private let filenameTemplateEditor: FilenameTemplateEditorView

    private let areaShortcutRecorder: ShortcutRecorderView
    private let fullShortcutRecorder: ShortcutRecorderView
    private let reopenShortcutRecorder: ShortcutRecorderView
    private let scratchpadShortcutRecorder: ShortcutRecorderView
    private let duplicateWarningLabel: NSTextField

    /// Fixed set of max-width options shown in the dropdown.
    private let maxWidthOptions: [Int] = [0, 800, 1200, 1600, 1920, 2400]

    init(settingsStore: SettingsStore, hotKeyService: HotKeyService) {
        self.settingsStore = settingsStore
        self.hotKeyService = hotKeyService

        maxSizePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        notePrefixCheckbox = NSButton(checkboxWithTitle: "Enable Note Prefix", target: nil, action: nil)
        notePrefixField = NSTextField(string: "")
        notePrefixCountLabel = NSTextField(labelWithString: "0/50")
        filenameTemplateEditor = FilenameTemplateEditorView(settingsStore: settingsStore)

        areaShortcutRecorder = ShortcutRecorderView(frame: .zero)
        fullShortcutRecorder = ShortcutRecorderView(frame: .zero)
        reopenShortcutRecorder = ShortcutRecorderView(frame: .zero)
        scratchpadShortcutRecorder = ShortcutRecorderView(frame: .zero)
        duplicateWarningLabel = NSTextField(labelWithString: "")

        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 520)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        let window = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
        window.center()
        window.title = "Zoomies Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        AppTheme.apply(to: window)

        super.init(window: window)

        window.delegate = self
        configureContent()
        populateFromSettings()
    }
    
    /// Returns true while the user is actively recording a shortcut.
    /// Used to ignore global hotkeys during recording (prevents accidental triggers).
    var isRecordingAnyShortcut: Bool {
        areaShortcutRecorder.isRecordingShortcut
        || fullShortcutRecorder.isRecordingShortcut
        || reopenShortcutRecorder.isRecordingShortcut
        || scratchpadShortcutRecorder.isRecordingShortcut
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Configuration

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        contentView.subviews.forEach { $0.removeFromSuperview() }

        let surfaceView = MenuSurfaceMaterial.makeFillingView(frame: contentView.bounds)
        contentView.addSubview(surfaceView)

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        surfaceView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: surfaceView.safeAreaLayoutGuide.topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: surfaceView.trailingAnchor, constant: -20),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: surfaceView.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        // MARK: General section

        let generalHeader = NSTextField(labelWithString: "General")
        generalHeader.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        // Max width row
        let maxSizeLabel = NSTextField(labelWithString: "Max Width")
        maxSizeLabel.translatesAutoresizingMaskIntoConstraints = false

        maxSizePopUp.translatesAutoresizingMaskIntoConstraints = false
        configureMaxSizePopUp()

        let maxSizeRow = NSStackView(views: [maxSizeLabel, maxSizePopUp])
        maxSizeRow.orientation = .horizontal
        maxSizeRow.alignment = .centerY
        maxSizeRow.spacing = 8

        maxSizeLabel.setContentHuggingPriority(.required, for: .horizontal)

        rootStack.addArrangedSubview(generalHeader)
        rootStack.addArrangedSubview(maxSizeRow)
        rootStack.addArrangedSubview(makeSeparator())

        // MARK: Note Settings section

        let noteHeader = NSTextField(labelWithString: "Note Settings")
        noteHeader.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        notePrefixCheckbox.translatesAutoresizingMaskIntoConstraints = false
        notePrefixCheckbox.target = self
        notePrefixCheckbox.action = #selector(notePrefixToggled(_:))

        let notePrefixToggleRow = NSStackView(views: [notePrefixCheckbox])
        notePrefixToggleRow.orientation = .horizontal
        notePrefixToggleRow.alignment = .centerY
        notePrefixToggleRow.spacing = 8

        let prefixTextLabel = NSTextField(labelWithString: "Prefix Text")
        prefixTextLabel.setContentHuggingPriority(.required, for: .horizontal)

        notePrefixField.translatesAutoresizingMaskIntoConstraints = false
        notePrefixField.delegate = self
        notePrefixField.target = self
        notePrefixField.action = #selector(notePrefixFieldEdited(_:))

        notePrefixCountLabel.translatesAutoresizingMaskIntoConstraints = false
        notePrefixCountLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        notePrefixCountLabel.textColor = NSColor.secondaryLabelColor
        notePrefixCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        let notePrefixRow = NSStackView(views: [prefixTextLabel, notePrefixField, notePrefixCountLabel])
        notePrefixRow.orientation = .horizontal
        notePrefixRow.alignment = .centerY
        notePrefixRow.spacing = 8

        rootStack.addArrangedSubview(noteHeader)
        rootStack.addArrangedSubview(notePrefixToggleRow)
        rootStack.addArrangedSubview(notePrefixRow)
        rootStack.addArrangedSubview(makeSeparator())

        // MARK: Filename Template section

        rootStack.addArrangedSubview(filenameTemplateEditor)
        rootStack.addArrangedSubview(makeSeparator())

        // MARK: Shortcuts section

        let shortcutsHeader = NSTextField(labelWithString: "Shortcuts")
        shortcutsHeader.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        // Shortcut rows
        let areaLabel = NSTextField(labelWithString: "Screenshot Area:")
        let fullLabel = NSTextField(labelWithString: "Screenshot Full:")
        let reopenLabel = NSTextField(labelWithString: "Reopen Finder Selection:")
        let scratchpadLabel = NSTextField(labelWithString: "Scratchpad:")

        [areaLabel, fullLabel, reopenLabel, scratchpadLabel].forEach { label in
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        areaShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        fullShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        reopenShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        scratchpadShortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        scratchpadShortcutRecorder.setAccessibilityIdentifier("settings.shortcut.scratchpad")
        [areaShortcutRecorder, fullShortcutRecorder, reopenShortcutRecorder, scratchpadShortcutRecorder].forEach { recorder in
            recorder.setContentHuggingPriority(.required, for: .horizontal)
            recorder.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        areaShortcutRecorder.onChange = { [weak self] value in
            self?.handleShortcutChange(kind: .area, newValue: value)
        }
        fullShortcutRecorder.onChange = { [weak self] value in
            self?.handleShortcutChange(kind: .full, newValue: value)
        }
        reopenShortcutRecorder.onChange = { [weak self] value in
            self?.handleShortcutChange(kind: .reopenFinderSelection, newValue: value)
        }
        scratchpadShortcutRecorder.onChange = { [weak self] value in
            self?.handleShortcutChange(kind: .scratchpad, newValue: value)
        }

        let areaSpacer = NSView()
        areaSpacer.translatesAutoresizingMaskIntoConstraints = false
        let areaRow = NSStackView(views: [areaLabel, areaSpacer, areaShortcutRecorder])
        areaRow.orientation = .horizontal
        areaRow.alignment = .centerY
        areaRow.distribution = .fill
        areaRow.spacing = 14

        let fullSpacer = NSView()
        fullSpacer.translatesAutoresizingMaskIntoConstraints = false
        let fullRow = NSStackView(views: [fullLabel, fullSpacer, fullShortcutRecorder])
        fullRow.orientation = .horizontal
        fullRow.alignment = .centerY
        fullRow.distribution = .fill
        fullRow.spacing = 14

        let reopenSpacer = NSView()
        reopenSpacer.translatesAutoresizingMaskIntoConstraints = false
        let reopenRow = NSStackView(views: [reopenLabel, reopenSpacer, reopenShortcutRecorder])
        reopenRow.orientation = .horizontal
        reopenRow.alignment = .centerY
        reopenRow.distribution = .fill
        reopenRow.spacing = 14

        let scratchpadSpacer = NSView()
        scratchpadSpacer.translatesAutoresizingMaskIntoConstraints = false
        let scratchpadRow = NSStackView(views: [scratchpadLabel, scratchpadSpacer, scratchpadShortcutRecorder])
        scratchpadRow.orientation = .horizontal
        scratchpadRow.alignment = .centerY
        scratchpadRow.distribution = .fill
        scratchpadRow.spacing = 14

        // Duplicate warning label
        duplicateWarningLabel.textColor = NSColor.systemRed
        duplicateWarningLabel.isHidden = true

        rootStack.addArrangedSubview(shortcutsHeader)
        rootStack.addArrangedSubview(areaRow)
        rootStack.addArrangedSubview(fullRow)
        rootStack.addArrangedSubview(reopenRow)
        rootStack.addArrangedSubview(scratchpadRow)
        rootStack.addArrangedSubview(duplicateWarningLabel)

        NSLayoutConstraint.activate([
            areaRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            fullRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            reopenRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            scratchpadRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            areaShortcutRecorder.widthAnchor.constraint(equalToConstant: 300),
            fullShortcutRecorder.widthAnchor.constraint(equalTo: areaShortcutRecorder.widthAnchor),
            reopenShortcutRecorder.widthAnchor.constraint(equalTo: areaShortcutRecorder.widthAnchor),
            scratchpadShortcutRecorder.widthAnchor.constraint(equalTo: areaShortcutRecorder.widthAnchor)
        ])
    }

    private func configureMaxSizePopUp() {
        maxSizePopUp.removeAllItems()

        for width in maxWidthOptions {
            let title: String
            if width == 0 {
                title = "Original (no resize)"
            } else {
                title = "\(width) px"
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
        notePrefixCountLabel.isEnabled = settings.notePrefixEnabled
        updateNotePrefixCountLabel(for: settings.notePrefix)

        // Filename template
        filenameTemplateEditor.reloadFromSettings()

        // Shortcuts
        applyShortcutsToRecorders(from: settings.shortcuts)
    }

    private func applyShortcutsToRecorders(from shortcuts: Shortcuts) {
        areaShortcutRecorder.recordedShortcut = .init(from: shortcuts.screenshotArea)
        fullShortcutRecorder.recordedShortcut = .init(from: shortcuts.screenshotFull)
        reopenShortcutRecorder.recordedShortcut = .init(from: shortcuts.reopenFinderSelection)
        scratchpadShortcutRecorder.recordedShortcut = .init(from: shortcuts.openScratchpad)
    }

    // MARK: - Actions

    @objc private func maxSizeChanged(_ sender: NSPopUpButton) {
        let width = sender.selectedItem?.tag ?? 0
        settingsStore.update { settings in
            settings.maxWidth = width
        }
    }

    @objc private func notePrefixToggled(_ sender: NSButton) {
        let isOn = sender.state == .on
        notePrefixField.isEnabled = isOn
        notePrefixCountLabel.isEnabled = isOn
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
        updateNotePrefixCountLabel(for: text)

        settingsStore.update { settings in
            settings.notePrefix = text
        }
    }

    private enum ShortcutKind {
        case area
        case full
        case reopenFinderSelection
        case scratchpad
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
        case .reopenFinderSelection:
            shortcuts.reopenFinderSelection = newShortcut
        case .scratchpad:
            shortcuts.openScratchpad = newShortcut
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
            shortcuts.reopenFinderSelection,
            shortcuts.openScratchpad
        ]
        let set = Set(values)
        return set.count < values.count
    }

    // MARK: - NSTextFieldDelegate

    private func updateNotePrefixCountLabel(for text: String) {
        let count = text.count
        notePrefixCountLabel.stringValue = "\(count)/50"
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === notePrefixField else { return }

        var text = field.stringValue
        if text.count > 50 {
            text = String(text.prefix(50))
            field.stringValue = text
        }
        updateNotePrefixCountLabel(for: text)

        settingsStore.update { settings in
            settings.notePrefix = text
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // When the settings window is closed, return the app to accessory mode
        // so it behaves like a menubar app again.
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }
}

private extension ShortcutRecorderView.RecordedShortcut {
    init(from shortcut: Shortcut) {
        self.init(keyCode: shortcut.keyCode, carbonFlags: shortcut.modifierFlags)
    }
}
