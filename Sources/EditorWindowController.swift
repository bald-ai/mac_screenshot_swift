import AppKit

/// Window controller for the screenshot editor.
///
/// The editor provides basic annotation tools (pen, arrow, rectangle,
/// ellipse, text), a small color palette with keyboard access, an undo
/// stack, and zoom controls. When the user finishes (save, copy+save,
/// copy+delete, delete), the controller calls `onComplete` with the
/// final image and desired action. The caller (ScreenshotWorkflowController)
/// is responsible for writing the image to disk, clipboard operations,
/// and backup/delete semantics.
final class EditorWindowController: NSWindowController {
    typealias FinalAction = ScreenshotWorkflowController.FinalAction

    /// Called when the user finishes editing.
    /// - Parameters:
    ///   - image: The final composited image, or `nil` for delete-only.
    ///   - action: The requested final action.
    var onComplete: ((NSImage?, FinalAction) -> Void)?
    var onBackToNote: ((NSImage) -> Void)?

    private let canvasView: EditorCanvasView
    private let scrollView = NSScrollView()
    private let clipboardService = ClipboardService()

    private var toolButtons: [EditorTool: NSButton] = [:]
    private var colorPickerButtons: [NSButton] = []
    private var colorPickerPopover = NSPopover()
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

    private var currentZoom: CGFloat = 1.0
    private let minZoom: CGFloat = 0.5
    private let maxZoom: CGFloat = 3.0

    private var didSendCompletion = false

    // MARK: - Init

    convenience init?(imageURL: URL) {
        guard let image = NSImage(contentsOf: imageURL) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unable to open image"
            alert.informativeText = "The captured image could not be loaded for editing."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
        self.init(image: image)
    }

    init(image: NSImage) {
        self.canvasView = EditorCanvasView(image: image)

        let initialSize = image.size
        let windowWidth = max(580, min(900, initialSize.width + 80))
        let windowHeight = max(500, min(800, initialSize.height + 160))
        let contentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: contentRect,
                              styleMask: style,
                              backing: .buffered,
                              defer: false)
        window.title = "Edit Screenshot"
        window.center()
        window.setFrameAutosaveName("ScreenshotEditorWindow")
        window.contentMinSize = NSSize(width: 580, height: 400)
        window.backgroundColor = NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.19, alpha: 1.0)

        super.init(window: window)

        window.delegate = self
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvasView)
    }

    // MARK: - UI setup

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let backgroundView = EditorBackgroundView(frame: contentView.bounds)
        backgroundView.autoresizingMask = [.width, .height]
        contentView.addSubview(backgroundView, positioned: .below, relativeTo: nil)

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 10
        rootStack.alignment = .centerX
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])

        let toolbarBackground = makeToolbarBackground()
        let toolbarStack = makeToolbarStack()
        toolbarBackground.addSubview(toolbarStack)

        NSLayoutConstraint.activate([
            toolbarStack.topAnchor.constraint(equalTo: toolbarBackground.topAnchor, constant: 6),
            toolbarStack.bottomAnchor.constraint(equalTo: toolbarBackground.bottomAnchor, constant: -6),
            toolbarStack.leadingAnchor.constraint(equalTo: toolbarBackground.leadingAnchor, constant: 8),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbarBackground.trailingAnchor, constant: -8)
        ])

        rootStack.addArrangedSubview(toolbarBackground)

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = minZoom
        scrollView.maxMagnification = maxZoom
        scrollView.documentView = canvasView
        scrollView.magnification = currentZoom

        rootStack.addArrangedSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        canvasView.onKeyCommand = { [weak self] command in
            self?.handleKeyCommand(command)
        }

        setupColorPicker()

        selectTool(.pen)
        selectColor(index: 0)
    }

    private func makeToolbarBackground() -> NSView {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        background.layer?.shadowColor = NSColor.black.cgColor
        background.layer?.shadowOpacity = 0.25
        background.layer?.shadowRadius = 8
        background.layer?.shadowOffset = NSSize(width: 0, height: -1)
        background.translatesAutoresizingMaskIntoConstraints = false
        return background
    }

    private func makeToolbarStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let penButton = makeToolButton(symbol: "pencil", tool: .pen, toolTip: "Pen (W)")
        let arrowButton = makeToolButton(symbol: "arrow.right", tool: .arrow, toolTip: "Arrow (A)")
        let rectButton = makeToolButton(symbol: "square", tool: .rectangle, toolTip: "Rectangle (R)")
        let ovalButton = makeToolButton(symbol: "circle", tool: .ellipse, toolTip: "Ellipse (E)")
        let textButton = makeToolButton(symbol: "textformat", tool: .text, toolTip: "Text (T)")

        let undoButton = makeActionButton(symbol: "arrow.uturn.left", toolTip: "Undo (Cmd+Z)", action: #selector(undoPressed))
        let clearButton = makeActionButton(symbol: "trash", toolTip: "Clear (Option+Backspace)", action: #selector(clearPressed))

        let zoomOutButton = makeActionButton(symbol: "minus.magnifyingglass", toolTip: "Zoom Out (Cmd+-)", action: #selector(zoomOutPressed))
        let zoomInButton = makeActionButton(symbol: "plus.magnifyingglass", toolTip: "Zoom In (Cmd++)", action: #selector(zoomInPressed))

        let cancelButton = makeActionButton(symbol: "xmark", toolTip: "Cancel (Esc)", action: #selector(deletePressed))

        let saveButton = makeSaveButton()

        configureColorIndicator()

        zoomLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = NSColor.secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.setContentHuggingPriority(.required, for: .horizontal)
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        [
            penButton,
            arrowButton,
            rectButton,
            ovalButton,
            textButton,
            makeDivider(),
            colorIndicatorButton,
            makeDivider(),
            undoButton,
            clearButton,
            makeDivider(),
            zoomOutButton,
            zoomLabel,
            zoomInButton,
            makeDivider(),
            cancelButton,
            saveButton
        ].forEach { stack.addArrangedSubview($0) }

        return stack
    }

    private func makeToolButton(symbol: String, tool: EditorTool, toolTip: String) -> NSButton {
        let button = makeIconButton(symbol: symbol, toolTip: toolTip)
        button.target = self
        button.action = #selector(toolButtonPressed(_:))
        button.tag = toolTag(for: tool)
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
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeSaveButton() -> NSButton {
        let button = NSButton(frame: .zero)
        button.target = self
        button.action = #selector(savePressed)
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.refusesFirstResponder = true
        button.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor.labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.toolTip = "Save (Enter)"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.title = ""
        return button
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return divider
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
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor

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

        let vc = NSViewController()
        vc.view = container
        colorPickerPopover.contentViewController = vc
        colorPickerPopover.behavior = .transient
        colorPickerPopover.delegate = self

        updateColorPickerSelection()
    }

    private func toolTag(for tool: EditorTool) -> Int {
        switch tool {
        case .pen: return 0
        case .arrow: return 1
        case .rectangle: return 2
        case .ellipse: return 3
        case .text: return 4
        }
    }

    private func toolForTag(_ tag: Int) -> EditorTool? {
        switch tag {
        case 0: return .pen
        case 1: return .arrow
        case 2: return .rectangle
        case 3: return .ellipse
        case 4: return .text
        default: return nil
        }
    }

    // MARK: - Toolbar actions

    @objc private func toolButtonPressed(_ sender: NSButton) {
        guard let tool = toolForTag(sender.tag) else { return }
        selectTool(tool)
    }

    private func selectTool(_ tool: EditorTool) {
        canvasView.setTool(tool)
        for (key, button) in toolButtons {
            let isActive = key == tool
            button.layer?.backgroundColor = isActive
                ? NSColor(calibratedRed: 0.22, green: 0.43, blue: 0.85, alpha: 1.0).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = isActive ? .white : .labelColor
        }
    }

    @objc private func colorIndicatorPressed() {
        toggleColorPicker()
    }

    @objc private func colorPickerButtonPressed(_ sender: NSButton) {
        selectColor(index: sender.tag)
        closeColorPicker()
    }

    private func selectColor(index: Int) {
        guard colors.indices.contains(index) else { return }
        selectedColorIndex = index
        canvasView.currentColor = colors[index]
        colorIndicatorButton.layer?.backgroundColor = colors[index].cgColor
        updateColorPickerSelection()
    }

    private func updateColorPickerSelection() {
        for (index, button) in colorPickerButtons.enumerated() {
            let isSelected = index == selectedColorIndex
            if isSelected {
                button.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            } else {
                button.layer?.borderColor = NSColor.clear.cgColor
            }
        }
        updateColorFocus()
    }

    private func toggleColorPicker() {
        if colorPickerPopover.isShown {
            closeColorPicker()
        } else {
            openColorPicker()
        }
    }

    private func openColorPicker() {
        colorFocusIndex = selectedColorIndex
        updateColorFocus()
        colorPickerPopover.show(relativeTo: colorIndicatorButton.bounds, of: colorIndicatorButton, preferredEdge: .maxY)
        canvasView.isColorPickerOpen = true
        colorIndicatorButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        window?.makeFirstResponder(canvasView)
    }

    private func closeColorPicker() {
        colorPickerPopover.performClose(nil)
        canvasView.isColorPickerOpen = false
        colorIndicatorButton.layer?.borderColor = NSColor.clear.cgColor
    }

    private func updateColorFocus() {
        for (index, button) in colorPickerButtons.enumerated() {
            if index == colorFocusIndex {
                button.layer?.borderColor = NSColor.systemBlue.cgColor
                button.layer?.borderWidth = 2
            } else if index == selectedColorIndex {
                button.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
                button.layer?.borderWidth = 2
            } else {
                button.layer?.borderColor = NSColor.clear.cgColor
                button.layer?.borderWidth = 2
            }
        }
    }

    @objc private func undoPressed() {
        canvasView.undo()
    }

    @objc private func clearPressed() {
        canvasView.clearAll()
    }

    @objc private func zoomInPressed() {
        setZoom(currentZoom * 1.2)
    }

    @objc private func zoomOutPressed() {
        setZoom(currentZoom / 1.2)
    }

    @objc private func savePressed() {
        finish(with: .saveOnly)
    }

    @objc private func deletePressed() {
        finish(with: .deleteOnly)
    }

    // MARK: - Key commands from canvas

    private func handleKeyCommand(_ command: EditorCanvasView.KeyCommand) {
        switch command {
        case .finalAction(let action):
            switch action {
            case .saveOnly:
                finish(with: .saveOnly)
            case .copyAndSave:
                finish(with: .copyAndSave)
            case .copyAndDelete:
                finish(with: .copyAndDelete)
            case .deleteOnly:
                finish(with: .deleteOnly)
            }

        case .zoomIn:
            setZoom(currentZoom * 1.2)
        case .zoomOut:
            setZoom(currentZoom / 1.2)
        case .zoomReset:
            setZoom(1.0)
        case .undo:
            canvasView.undo()
        case .clear:
            canvasView.clearAll()
        case .selectColor(let index):
            selectColor(index: index)
            closeColorPicker()
        case .backToNote:
            let image = canvasView.compositeImage()
            didSendCompletion = true
            onBackToNote?(image)
            close()
        case .selectTool(let tool):
            selectTool(tool)
        case .toggleColorPicker:
            toggleColorPicker()
        case .colorPickerMove(let direction):
            let count = max(colorPickerButtons.count, 1)
            colorFocusIndex = (colorFocusIndex + direction + count) % count
            updateColorFocus()
        case .colorPickerSelect:
            selectColor(index: colorFocusIndex)
            closeColorPicker()
        case .colorPickerClose:
            closeColorPicker()
        case .copyToClipboard:
            copyEditedImageToClipboard()
        }
    }

    private func setZoom(_ value: CGFloat) {
        let clamped = max(minZoom, min(maxZoom, value))
        currentZoom = clamped
        scrollView.magnification = clamped
        let percent = Int(round(clamped * 100))
        zoomLabel.stringValue = "\(percent)%"
    }

    private func copyEditedImageToClipboard() {
        let image = canvasView.compositeImage()
        clipboardService.writeImage(image)
    }

    // MARK: - Finishing

    private func finish(with action: FinalAction) {
        guard let completion = onComplete else {
            close()
            return
        }

        let image = canvasView.compositeImage()
        didSendCompletion = true
        completion(image, action)
        close()
    }
}

extension EditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard !didSendCompletion else { return }
        guard let completion = onComplete else { return }
        let image = canvasView.compositeImage()
        didSendCompletion = true
        completion(image, .saveOnly)
    }
}

extension EditorWindowController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        canvasView.isColorPickerOpen = false
        colorIndicatorButton.layer?.borderColor = NSColor.clear.cgColor
    }
}

private final class EditorBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let colors = [
            NSColor(calibratedRed: 0.17, green: 0.31, blue: 0.45, alpha: 1.0),
            NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.40, alpha: 1.0),
            NSColor(calibratedRed: 0.42, green: 0.41, blue: 0.38, alpha: 1.0)
        ]
        if let gradient = NSGradient(colors: colors) ?? NSGradient(starting: colors.first ?? .black,
                                                                   ending: colors.last ?? .darkGray) {
            gradient.draw(in: bounds, angle: 135)
        } else {
            NSColor.black.setFill()
            bounds.fill()
        }
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
