import AppKit

private let blockPasteboardType = NSPasteboard.PasteboardType("com.zoomies.filenameTemplate.block")

final class FilenameTemplateEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let settingsStore: SettingsStore

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let previewLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)

    private var blocks: [FilenameTemplate.Block] { settingsStore.settings.filenameTemplate.blocks }

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

    func reloadFromSettings() {
        tableView.reloadData()
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
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let headerLabel = NSTextField(labelWithString: "Filename Template")
        headerLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let descriptionLabel = NSTextField(labelWithString: "Drag to reorder. Time or Counter must remain enabled to avoid collisions.")
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = NSColor.secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("BlockColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([blockPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

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
        rootStack.addArrangedSubview(scrollView)
        rootStack.addArrangedSubview(previewStack)

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 130),
        ])
    }

    private func updatePreview() {
        let template = settingsStore.settings.filenameTemplate
        let exampleName = template.makeFilename(date: Date(), counter: 2)
        previewLabel.stringValue = "Preview: \(exampleName).png"
    }

    private func mutateTemplate(_ body: (inout FilenameTemplate) -> Void) {
        settingsStore.update { settings in
            body(&settings.filenameTemplate)
        }
        tableView.reloadData()
        updatePreview()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        blocks.count
    }

    // MARK: - Drag & Drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(blocks[row].id.uuidString, forType: blockPasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let uuidString = item.string(forType: blockPasteboardType),
              let draggedID = UUID(uuidString: uuidString) else { return false }

        guard let sourceIndex = blocks.firstIndex(where: { $0.id == draggedID }) else { return false }

        let destination = sourceIndex < row ? row - 1 : row

        mutateTemplate { template in
            template.moveBlock(id: draggedID, to: destination)
        }
        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let block = blocks[row]
        let cellID = NSUserInterfaceItemIdentifier("BlockCell")

        let cell: BlockCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? BlockCellView {
            cell = reused
        } else {
            cell = BlockCellView()
            cell.identifier = cellID
        }

        cell.configure(with: block)

        cell.onToggleEnabled = { [weak self] isEnabled in
            self?.mutateTemplate { template in
                template.setBlockEnabled(id: block.id, isEnabled: isEnabled)
            }
        }

        cell.onTextChanged = { [weak self] newText in
            self?.mutateTemplate { template in
                if let i = template.blocks.firstIndex(where: { $0.id == block.id }) {
                    template.blocks[i].text = newText
                }
            }
        }

        cell.onFormatChanged = { [weak self] newFormat in
            self?.mutateTemplate { template in
                if let i = template.blocks.firstIndex(where: { $0.id == block.id }) {
                    template.blocks[i].format = newFormat.isEmpty ? "" : newFormat
                }
            }
        }

        return cell
    }

    // MARK: - Actions

    @objc private func resetToDefaults() {
        settingsStore.update { settings in
            settings.filenameTemplate = .defaultTemplate
        }
        tableView.reloadData()
        updatePreview()
    }
}

// MARK: - Block Cell View

private final class BlockCellView: NSView, NSTextFieldDelegate {
    var onToggleEnabled: ((Bool) -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onFormatChanged: ((String) -> Void)?

    private let enabledCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let kindLabel = NSTextField(labelWithString: "")
    private let editorContainer = NSView()

    private var editField: NSTextField?
    private var datePickerSegment: NSSegmentedControl?
    private enum EditFieldRole: Int {
        case staticText = 1
        case format = 2
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayout() {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let dragHandle = NSTextField(labelWithString: "≡")
        dragHandle.font = NSFont.systemFont(ofSize: 14)
        dragHandle.textColor = .tertiaryLabelColor

        kindLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleEnabled(_:))

        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(dragHandle)
        row.addArrangedSubview(enabledCheckbox)
        row.addArrangedSubview(kindLabel)
        row.addArrangedSubview(editorContainer)

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            editorContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    func configure(with block: FilenameTemplate.Block) {
        enabledCheckbox.state = block.isEnabled ? .on : .off
        kindLabel.stringValue = Self.title(for: block.kind)

        editorContainer.subviews.forEach { $0.removeFromSuperview() }
        editField = nil
        datePickerSegment = nil

        switch block.kind {
        case .staticText:
            let field = NSTextField(string: block.text ?? "")
            field.placeholderString = "Static text"
            field.tag = EditFieldRole.staticText.rawValue
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            editorContainer.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: editorContainer.topAnchor),
                field.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
                field.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            ])
            editField = field

        case .date:
            let seg = NSSegmentedControl(labels: ["Year", "Month", "Day"], trackingMode: .selectAny, target: self, action: #selector(dateComponentsChanged(_:)))
            seg.translatesAutoresizingMaskIntoConstraints = false

            let components = Self.parseDateComponents(from: block.format)
            seg.setSelected(components.contains(.year), forSegment: 0)
            seg.setSelected(components.contains(.month), forSegment: 1)
            seg.setSelected(components.contains(.day), forSegment: 2)

            editorContainer.addSubview(seg)
            NSLayoutConstraint.activate([
                seg.topAnchor.constraint(equalTo: editorContainer.topAnchor),
                seg.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
                seg.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            ])
            datePickerSegment = seg

        case .time:
            let field = NSTextField(string: block.format ?? "HH.mm.ss")
            field.placeholderString = "HH.mm.ss"
            field.tag = EditFieldRole.format.rawValue
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            editorContainer.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: editorContainer.topAnchor),
                field.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
                field.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            ])
            editField = field

        case .counter:
            break
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        onToggleEnabled?(sender.state == .on)
    }

    @objc private func dateComponentsChanged(_ sender: NSSegmentedControl) {
        var parts: [String] = []
        if sender.isSelected(forSegment: 0) { parts.append("yyyy") }
        if sender.isSelected(forSegment: 1) { parts.append("MM") }
        if sender.isSelected(forSegment: 2) { parts.append("dd") }
        let format = parts.joined(separator: "-")
        onFormatChanged?(format)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === editField else { return }
        if field.tag == EditFieldRole.staticText.rawValue {
            onTextChanged?(field.stringValue)
        } else {
            onFormatChanged?(field.stringValue)
        }
    }

    // MARK: - Helpers

    private enum DateComponent { case year, month, day }

    private static func parseDateComponents(from format: String?) -> Set<DateComponent> {
        guard let fmt = format else { return [.year, .month, .day] }
        if fmt.isEmpty { return [] }
        var result = Set<DateComponent>()
        if fmt.contains("yyyy") { result.insert(.year) }
        if fmt.contains("MM") { result.insert(.month) }
        if fmt.contains("dd") { result.insert(.day) }
        return result
    }

    private static func title(for kind: FilenameTemplate.Block.Kind) -> String {
        switch kind {
        case .staticText: return "Text"
        case .date: return "Date"
        case .time: return "Time"
        case .counter: return "Counter"
        }
    }
}
