import AppKit

/// Editor view for configuring the filename template used when saving
/// screenshots.
///
/// Features:
/// - Shows the current ordered list of template blocks.
/// - Allows reordering blocks via Up/Down buttons.
/// - Allows enabling/disabling blocks via a checkbox while preserving the
///   "time or counter must remain enabled" invariant (enforced by
///   `FilenameTemplate`).
/// - Allows editing the text of static-text blocks.
/// - Optionally allows editing the date/time format strings.
/// - Shows a live preview filename and offers a "Reset to defaults" button.
final class FilenameTemplateEditorView: NSView {
    private let settingsStore: SettingsStore

    private let blocksStackView = NSStackView()
    private let previewLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        configureUI()
        reloadFromSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Rebuilds the UI from the current settings.
    func reloadFromSettings() {
        reloadBlocks()
        updatePreview()
    }

    // MARK: - UI

    private func configureUI() {
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let headerLabel = NSTextField(labelWithString: "Filename Template")
        headerLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let descriptionLabel = NSTextField(labelWithString: "Reorder and toggle parts of the filename. Time or Counter must remain enabled to avoid collisions.")
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = NSColor.secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        blocksStackView.orientation = .vertical
        blocksStackView.alignment = .leading
        blocksStackView.spacing = 4
        blocksStackView.translatesAutoresizingMaskIntoConstraints = false

        let previewStack = NSStackView()
        previewStack.orientation = .horizontal
        previewStack.alignment = .centerY
        previewStack.spacing = 8

        previewLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        previewLabel.textColor = NSColor.secondaryLabelColor

        resetButton.target = self
        resetButton.action = #selector(resetToDefaults)

        previewStack.addArrangedSubview(previewLabel)
        previewStack.addArrangedSubview(resetButton)

        rootStack.addArrangedSubview(headerLabel)
        rootStack.addArrangedSubview(descriptionLabel)
        rootStack.addArrangedSubview(blocksStackView)
        rootStack.addArrangedSubview(previewStack)
    }

    private func reloadBlocks() {
        // Clear existing rows.
        for view in blocksStackView.arrangedSubviews {
            blocksStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let template = settingsStore.settings.filenameTemplate
        let blocks = template.blocks

        guard !blocks.isEmpty else { return }

        for (index, block) in blocks.enumerated() {
            let isFirst = (index == 0)
            let isLast = (index == blocks.count - 1)

            let row = BlockRowView(block: block, isFirst: isFirst, isLast: isLast)

            row.onMoveUp = { [weak self] in
                guard let self = self else { return }
                self.mutateTemplate { template in
                    template.moveBlock(id: block.id, to: max(0, index - 1))
                }
            }

            row.onMoveDown = { [weak self] in
                guard let self = self else { return }
                self.mutateTemplate { template in
                    template.moveBlock(id: block.id, to: min(blocks.count - 1, index + 1))
                }
            }

            row.onToggleEnabled = { [weak self] isEnabled in
                guard let self = self else { return }
                self.mutateTemplate { template in
                    template.setBlockEnabled(id: block.id, isEnabled: isEnabled)
                }
            }

            row.onTextChanged = { [weak self] newText in
                guard let self = self else { return }
                self.mutateTemplate { template in
                    if let i = template.blocks.firstIndex(where: { $0.id == block.id }) {
                        template.blocks[i].text = newText
                    }
                }
            }

            row.onFormatChanged = { [weak self] newFormat in
                guard let self = self else { return }
                self.mutateTemplate { template in
                    if let i = template.blocks.firstIndex(where: { $0.id == block.id }) {
                        let trimmed = newFormat.trimmingCharacters(in: .whitespacesAndNewlines)
                        template.blocks[i].format = trimmed.isEmpty ? nil : trimmed
                    }
                }
            }

            blocksStackView.addArrangedSubview(row)
        }
    }

    private func updatePreview() {
        let template = settingsStore.settings.filenameTemplate
        let exampleName = template.makeFilename(date: Date(), counter: 2)
        previewLabel.stringValue = "Preview: \(exampleName).jpg"
    }

    private func mutateTemplate(_ body: (inout FilenameTemplate) -> Void) {
        settingsStore.update { settings in
            body(&settings.filenameTemplate)
        }
        reloadBlocks()
        updatePreview()
    }

    // MARK: - Actions

    @objc private func resetToDefaults() {
        settingsStore.update { settings in
            settings.filenameTemplate = .defaultTemplate
        }
        reloadBlocks()
        updatePreview()
    }
}

// MARK: - Block row view

private final class BlockRowView: NSView, NSTextFieldDelegate {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onToggleEnabled: ((Bool) -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onFormatChanged: ((String) -> Void)?

    private let enabledCheckbox: NSButton
    private let kindLabel: NSTextField
    private var textField: NSTextField?
    private var formatField: NSTextField?

    init(block: FilenameTemplate.Block, isFirst: Bool, isLast: Bool) {
        enabledCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        kindLabel = NSTextField(labelWithString: BlockRowView.title(for: block.kind))

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        configureUI(block: block, isFirst: isFirst, isLast: isLast)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI(block: FilenameTemplate.Block, isFirst: Bool, isLast: Bool) {
        let upButton = NSButton(title: "↑", target: self, action: #selector(moveUp))
        upButton.setButtonType(.momentaryChange)
        upButton.isBordered = false
        upButton.isEnabled = !isFirst

        let downButton = NSButton(title: "↓", target: self, action: #selector(moveDown))
        downButton.setButtonType(.momentaryChange)
        downButton.isBordered = false
        downButton.isEnabled = !isLast

        enabledCheckbox.state = block.isEnabled ? .on : .off
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleEnabled(_:))

        kindLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        rowStack.addArrangedSubview(upButton)
        rowStack.addArrangedSubview(downButton)
        rowStack.addArrangedSubview(enabledCheckbox)
        rowStack.addArrangedSubview(kindLabel)

        switch block.kind {
        case .staticText:
            let field = NSTextField(string: block.text ?? "")
            field.placeholderString = "Static text"
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            textField = field
            rowStack.addArrangedSubview(field)

        case .date, .time:
            let field = NSTextField(string: block.format ?? BlockRowView.defaultFormat(for: block.kind))
            field.placeholderString = BlockRowView.defaultFormat(for: block.kind)
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            formatField = field
            rowStack.addArrangedSubview(field)

        case .counter:
            break
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(spacer)
    }

    // MARK: - Actions

    @objc private func moveUp() {
        onMoveUp?()
    }

    @objc private func moveDown() {
        onMoveDown?()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        let isOn = sender.state == .on
        onToggleEnabled?(isOn)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field === textField {
            onTextChanged?(field.stringValue)
        } else if field === formatField {
            onFormatChanged?(field.stringValue)
        }
    }

    // MARK: - Helpers

    private static func title(for kind: FilenameTemplate.Block.Kind) -> String {
        switch kind {
        case .staticText:
            return "Text"
        case .date:
            return "Date"
        case .time:
            return "Time"
        case .counter:
            return "Counter"
        }
    }

    private static func defaultFormat(for kind: FilenameTemplate.Block.Kind) -> String {
        switch kind {
        case .date:
            return "yyyy-MM-dd"
        case .time:
            return "HH.mm.ss"
        case .staticText, .counter:
            return ""
        }
    }
}
