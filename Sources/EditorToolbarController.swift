import AppKit

final class EditorToolbarController: NSObject {
    enum Action {
        case selectTool(EditorTool)
        case undo
        case clear
        case zoomIn
        case zoomOut
        case save
        case cancel
        case selectColor(Int)
    }

    var onAction: ((Action) -> Void)?
    var onColorPickerVisibilityChange: ((Bool) -> Void)?
    var onFocusCanvasRequested: (() -> Void)?

    let view: NSView

    private var toolButtons: [EditorTool: NSButton] = [:]
    private var colorPickerButtons: [NSButton] = []
    private let colorPickerPopover = NSPopover()
    private var colorFocusIndex = 0
    private var selectedColorIndex = 0

    private let colorIndicatorButton = NSButton(frame: .zero)
    private let zoomLabel = NSTextField(labelWithString: "100%")

    private let colors: [NSColor] = [
        NSColor(hex: "#ff3b30"),
        NSColor(hex: "#007aff"),
        NSColor(hex: "#34c759"),
        NSColor(hex: "#000000"),
        NSColor(hex: "#ffcc00"),
        NSColor(hex: "#ffffff")
    ]

    init(view: NSView? = nil) {
        let background = view ?? NSView()
        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        self.view = background

        super.init()

        let stack = makeToolbarStack()
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8)
        ])

        setupColorPicker()
    }

    var minimumSize: NSSize {
        view.layoutSubtreeIfNeeded()
        return NSSize(width: max(420.0, view.fittingSize.width),
                      height: max(72.0, view.fittingSize.height))
    }

    var isColorPickerShown: Bool {
        colorPickerPopover.isShown
    }

    var selectedColor: NSColor {
        colors[selectedColorIndex]
    }

    func setSelectedTool(_ tool: EditorTool) {
        for (key, button) in toolButtons {
            let isActive = key == tool
            button.layer?.backgroundColor = isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = isActive ? .white : .labelColor
        }
    }

    func setSelectedColor(index: Int) {
        guard colors.indices.contains(index) else { return }
        selectedColorIndex = index
        colorIndicatorButton.layer?.backgroundColor = colors[index].cgColor
        updateColorPickerSelection()
    }

    func setZoomPercentage(_ percentage: Int) {
        zoomLabel.stringValue = "\(percentage)%"
    }

    func toggleColorPicker() {
        if colorPickerPopover.isShown {
            closeColorPicker()
        } else {
            openColorPicker()
        }
    }

    func closeColorPicker() {
        if colorPickerPopover.isShown {
            colorPickerPopover.performClose(nil)
        } else {
            applyColorPickerClosedState()
        }
    }

    func moveColorFocus(direction: Int) {
        let count = max(colorPickerButtons.count, 1)
        colorFocusIndex = (colorFocusIndex + direction + count) % count
        updateColorFocus()
    }

    func activateFocusedColor() {
        onAction?(.selectColor(colorFocusIndex))
        closeColorPicker()
    }

    private func makeToolbarStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let penButton = makeToolButton(symbol: "pencil", tool: .pen, toolTip: "Pen (W)")
        let arrowButton = makeToolButton(symbol: "arrow.right", tool: .arrow, toolTip: "Arrow (A)")
        let rectButton = makeToolButton(symbol: "square", tool: .rectangle, toolTip: "Rectangle (R, Hold ⇧: Square)")
        let ovalButton = makeToolButton(symbol: "circle", tool: .ellipse, toolTip: "Ellipse (E, Hold ⇧: Circle)")
        let textButton = makeToolButton(symbol: "textformat", tool: .text, toolTip: "Text (T)")
        let selectionButton = makeToolButton(symbol: "rectangle.dashed", tool: .selection, toolTip: "Selection (S)")

        let undoButton = makeActionButton(symbol: "arrow.uturn.left", toolTip: "Undo (Cmd+Z)", action: #selector(undoPressed))
        let clearButton = makeActionButton(symbol: "eraser", toolTip: "Clear (Option+Backspace)", action: #selector(clearPressed))

        let zoomOutButton = makeActionButton(symbol: "minus.magnifyingglass", toolTip: "Zoom Out (Cmd+-)", action: #selector(zoomOutPressed))
        let zoomInButton = makeActionButton(symbol: "plus.magnifyingglass", toolTip: "Zoom In (Cmd++)", action: #selector(zoomInPressed))

        let cancelButton = makeActionButton(symbol: "xmark", toolTip: "Cancel (Esc)", action: #selector(cancelPressed))
        let saveButton = makeActionButton(symbol: "tray.and.arrow.down", toolTip: "Save (Enter)", action: #selector(savePressed))

        configureColorIndicator()

        zoomLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = NSColor.secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.setContentHuggingPriority(.required, for: .horizontal)
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let drawingTools = NSStackView(views: [
            penButton, arrowButton, rectButton, ovalButton,
            textButton, selectionButton
        ])
        drawingTools.orientation = .horizontal
        drawingTools.alignment = .centerY
        drawingTools.spacing = 2

        let colorContainer = NSView()
        colorContainer.translatesAutoresizingMaskIntoConstraints = false
        colorContainer.addSubview(colorIndicatorButton)
        NSLayoutConstraint.activate([
            colorContainer.widthAnchor.constraint(equalToConstant: 26),
            colorContainer.heightAnchor.constraint(equalToConstant: 26),
            colorIndicatorButton.centerXAnchor.constraint(equalTo: colorContainer.centerXAnchor),
            colorIndicatorButton.centerYAnchor.constraint(equalTo: colorContainer.centerYAnchor)
        ])

        let editActions = NSStackView(views: [undoButton, clearButton])
        editActions.orientation = .horizontal
        editActions.alignment = .centerY
        editActions.spacing = 2

        let zoomControls = NSStackView(views: [zoomOutButton, zoomLabel, zoomInButton])
        zoomControls.orientation = .horizontal
        zoomControls.alignment = .centerY
        zoomControls.spacing = 0

        let sessionActions = NSStackView(views: [cancelButton, saveButton])
        sessionActions.orientation = .horizontal
        sessionActions.alignment = .centerY
        sessionActions.spacing = 2

        [drawingTools, colorContainer, editActions, zoomControls, sessionActions]
            .forEach { stack.addArrangedSubview($0) }

        stack.spacing = 12
        stack.setCustomSpacing(6, after: drawingTools)
        stack.setCustomSpacing(18, after: colorContainer)
        stack.setCustomSpacing(12, after: editActions)
        stack.setCustomSpacing(12, after: zoomControls)

        return stack
    }

    private func makeToolButton(symbol: String, tool: EditorTool, toolTip: String) -> NSButton {
        let button = makeIconButton(symbol: symbol, toolTip: toolTip)
        button.target = self
        button.action = #selector(toolButtonPressed(_:))
        toolButtons[tool] = button
        return button
    }

    private func makeActionButton(symbol: String, toolTip: String, action: Selector) -> NSButton {
        let button = makeIconButton(symbol: symbol, toolTip: toolTip)
        button.target = self
        button.action = action
        return button
    }

    private func makeIconButton(symbol: String, toolTip: String) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.refusesFirstResponder = true
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor.labelColor
        button.toolTip = toolTip
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func configureColorIndicator() {
        colorIndicatorButton.isBordered = false
        colorIndicatorButton.bezelStyle = .shadowlessSquare
        colorIndicatorButton.refusesFirstResponder = true
        colorIndicatorButton.wantsLayer = true
        colorIndicatorButton.layer?.cornerRadius = 9
        colorIndicatorButton.layer?.borderWidth = 2
        colorIndicatorButton.layer?.borderColor = NSColor.clear.cgColor
        colorIndicatorButton.translatesAutoresizingMaskIntoConstraints = false
        colorIndicatorButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        colorIndicatorButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        colorIndicatorButton.toolTip = "Colors (K or Q)"
        colorIndicatorButton.target = self
        colorIndicatorButton.action = #selector(colorIndicatorPressed)
        colorIndicatorButton.title = ""
    }

    private func setupColorPicker() {
        let container = NSVisualEffectView()
        MenuSurfaceMaterial.apply(to: container)
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        colors.enumerated().forEach { index, color in
            let button = NSButton(frame: .zero)
            button.isBordered = false
            button.bezelStyle = .shadowlessSquare
            button.refusesFirstResponder = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 13
            button.layer?.backgroundColor = color.cgColor
            button.layer?.borderWidth = 2
            button.layer?.borderColor = NSColor.clear.cgColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            button.tag = index
            button.target = self
            button.action = #selector(colorPickerButtonPressed(_:))
            button.title = ""

            let numberLabel = NSTextField(labelWithString: "\(index + 1)")
            numberLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
            numberLabel.textColor = color.isLight ? NSColor.black : NSColor.white
            numberLabel.alignment = .center
            numberLabel.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(numberLabel)
            NSLayoutConstraint.activate([
                numberLabel.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                numberLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])

            colorPickerButtons.append(button)
            stack.addArrangedSubview(button)
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])

        let viewController = NSViewController()
        viewController.view = container
        colorPickerPopover.contentViewController = viewController
        colorPickerPopover.behavior = .transient
        colorPickerPopover.delegate = self

        updateColorPickerSelection()
    }

    private func openColorPicker() {
        colorFocusIndex = selectedColorIndex
        updateColorFocus()
        colorPickerPopover.show(relativeTo: colorIndicatorButton.bounds,
                                of: colorIndicatorButton,
                                preferredEdge: .maxY)
        colorIndicatorButton.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        onColorPickerVisibilityChange?(true)
        onFocusCanvasRequested?()
    }

    private func updateColorPickerSelection() {
        for (index, button) in colorPickerButtons.enumerated() {
            button.layer?.borderColor = index == selectedColorIndex
                ? NSColor.labelColor.withAlphaComponent(0.95).cgColor
                : NSColor.clear.cgColor
        }
        updateColorFocus()
    }

    private func updateColorFocus() {
        for (index, button) in colorPickerButtons.enumerated() {
            if index == colorFocusIndex {
                button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            } else if index == selectedColorIndex {
                button.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.95).cgColor
            } else {
                button.layer?.borderColor = NSColor.clear.cgColor
            }
            button.layer?.borderWidth = 2
        }
    }

    private func applyColorPickerClosedState() {
        colorIndicatorButton.layer?.borderColor = NSColor.clear.cgColor
        onColorPickerVisibilityChange?(false)
    }

    @objc private func toolButtonPressed(_ sender: NSButton) {
        guard let tool = toolButtons.first(where: { $0.value === sender })?.key else { return }
        onAction?(.selectTool(tool))
    }

    @objc private func colorIndicatorPressed() {
        toggleColorPicker()
    }

    @objc private func colorPickerButtonPressed(_ sender: NSButton) {
        onAction?(.selectColor(sender.tag))
        closeColorPicker()
    }

    @objc private func undoPressed() {
        onAction?(.undo)
    }

    @objc private func clearPressed() {
        onAction?(.clear)
    }

    @objc private func zoomInPressed() {
        onAction?(.zoomIn)
    }

    @objc private func zoomOutPressed() {
        onAction?(.zoomOut)
    }

    @objc private func savePressed() {
        onAction?(.save)
    }

    @objc private func cancelPressed() {
        onAction?(.cancel)
    }
}

extension EditorToolbarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        applyColorPickerClosedState()
    }
}

private extension NSColor {
    var isLight: Bool {
        guard let rgbColor = usingColorSpace(.deviceRGB) else { return false }
        let red = rgbColor.redComponent
        let green = rgbColor.greenComponent
        let blue = rgbColor.blueComponent
        let brightness = ((red * 299) + (green * 587) + (blue * 114)) / 1000
        return brightness > 0.5
    }

    convenience init(hex: String) {
        var normalized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if normalized.count == 6 {
            normalized.append("FF")
        }
        var value: UInt64 = 0
        Scanner(string: normalized).scanHexInt64(&value)
        let red = CGFloat((value >> 24) & 0xFF) / 255
        let green = CGFloat((value >> 16) & 0xFF) / 255
        let blue = CGFloat((value >> 8) & 0xFF) / 255
        let alpha = CGFloat(value & 0xFF) / 255
        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}
