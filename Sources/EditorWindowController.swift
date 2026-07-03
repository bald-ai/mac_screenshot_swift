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
    var onBackToNote: (() -> Void)?

    private let canvasView: EditorCanvasView
    private let scrollView = EditorScrollView()
    private let clipboardService = ClipboardService()
    private let settingsStore: SettingsStore
    private let notePreviewRaw: String?
    private let targetScreen: NSScreen?
    private var notePreviewContainer: NSView?
    private let editorShortcutLabel = NSTextField(labelWithString: "")
    // Toolbar Cancel (X) should mirror the Escape behavior:
    // - For editor sessions that own the temp file: delete on cancel.
    // - For Finder-selected originals: close without deleting.
    private let escapeFinalActionCommand: EditorCanvasView.FinalActionCommand

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

    // Match mac_screenshot behavior:
    // - The window opens sized to the image (with caps).
    // - The image may be scaled down to fit (baseScale <= 1).
    // - Zoom controls are relative to that baseScale (start at 100%).
    private var userZoomFactor: CGFloat = 1.0
    private var baseScale: CGFloat = 1.0
    private var defaultUserZoomFactor: CGFloat = 1.0
    // Total padding amount around the image (not per-side).
    private var totalPadding: CGFloat = 0.0

    // Auto-zoom small captures so they fill most of the editor canvas.
    private let autoZoomFillRatio: CGFloat = 0.90
    private let maxAutoUserZoom: CGFloat = 2.0

    // User zoom bounds (multiplier relative to fit).
    private let minUserZoom: CGFloat = 0.2
    private let maxUserZoom: CGFloat = 6.0

    // Absolute bounds enforced by NSScrollView.
    private let minEffectiveZoom: CGFloat = 0.02
    private let maxEffectiveZoom: CGFloat = 8.0

    private var didSendCompletion = false

    private weak var toolbarBackgroundView: NSView?
    private var toolbarMinimumWidth: CGFloat = 520.0
    private var toolbarMinimumHeight: CGFloat = 72.0

    // MARK: - Init

    convenience init?(imageURL: URL,
                      settingsStore: SettingsStore,
                      notePreview: String? = nil,
                      targetScreen: NSScreen? = nil,
                      escapeKeyDeletesFile: Bool = true) {
        guard let image = NSImage(contentsOf: imageURL) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unable to open image"
            alert.informativeText = "The captured image could not be loaded for editing."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
        self.init(image: image,
                  settingsStore: settingsStore,
                  notePreview: notePreview,
                  targetScreen: targetScreen,
                  escapeKeyDeletesFile: escapeKeyDeletesFile)
    }

    init(image: NSImage,
         settingsStore: SettingsStore,
         notePreview: String? = nil,
         targetScreen: NSScreen? = nil,
         escapeKeyDeletesFile: Bool = true) {
        let escapeFinal: EditorCanvasView.FinalActionCommand = escapeKeyDeletesFile ? .deleteOnly : .closeOnly
        self.canvasView = EditorCanvasView(image: image, escapeFinalAction: escapeFinal)
        self.settingsStore = settingsStore
        self.notePreviewRaw = notePreview
        self.targetScreen = targetScreen
        self.escapeFinalActionCommand = escapeFinal

        // Provisional size. We'll resize to match the image (native-like) after building UI.
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 520)

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = NSWindow(contentRect: contentRect,
                              styleMask: style,
                              backing: .buffered,
                              defer: false)
        window.title = "Edit Screenshot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        // Size is dynamic; do not autosave window frame.
        window.contentMinSize = NSSize(width: 580, height: 250)
        window.backgroundColor = .clear
        AppTheme.apply(to: window)

        super.init(window: window)

        window.delegate = self
        configureContent()

        // Now that UI exists, choose an initial window size based on the image and current screen.
        sizeWindowToImage()
        positionWindowOnTargetScreen()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window = window else { return }
        // Make the editor immediately key so keyboard shortcuts work without extra click.
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(canvasView)
        updateScrollLockAndRecentering()
    }

    func currentCompositeImage() -> NSImage {
        canvasView.compositeImage()
    }

    func dismissWithoutCompletion() {
        didSendCompletion = true
        close()
    }

    // MARK: - UI setup

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let surfaceView = MenuSurfaceMaterial.makeFillingView(frame: contentView.bounds)
        contentView.addSubview(surfaceView)

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 10
        rootStack.alignment = .centerX
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: surfaceView.safeAreaLayoutGuide.topAnchor, constant: 8),
            rootStack.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: surfaceView.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])

        let toolbarBackground = makeToolbarBackground()
        let toolbarStack = makeToolbarStack()
        toolbarBackground.addSubview(toolbarStack)
        toolbarBackgroundView = toolbarBackground

        NSLayoutConstraint.activate([
            toolbarStack.topAnchor.constraint(equalTo: toolbarBackground.topAnchor, constant: 6),
            toolbarStack.bottomAnchor.constraint(equalTo: toolbarBackground.bottomAnchor, constant: -6),
            toolbarStack.leadingAnchor.constraint(equalTo: toolbarBackground.leadingAnchor, constant: 8),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbarBackground.trailingAnchor, constant: -8)
        ])

        // Compute minimum toolbar size from intrinsic content (not from the provisional window width).
        // This is the main fix for "small screenshots open huge".
        toolbarMinimumWidth = max(420.0, toolbarStack.fittingSize.width + 16.0)
        toolbarMinimumHeight = max(72.0, toolbarStack.fittingSize.height + 12.0)

        rootStack.addArrangedSubview(toolbarBackground)

        configureEditorShortcutLabel()
        rootStack.addArrangedSubview(editorShortcutLabel)
        editorShortcutLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Native screenshot/markup windows do not show scrollers; panning still works
        // with trackpad/mouse when zoomed.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = minEffectiveZoom
        scrollView.maxMagnification = maxEffectiveZoom
        let centeringClipView = CenteringClipView()
        scrollView.contentView = centeringClipView
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = canvasView
        scrollView.magnification = 1.0
        scrollView.shouldAllowScroll = { [weak self] in
            return self?.isContentScrollable ?? true
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        // Allow the window to open small for small screenshots (native behavior).
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        // Note preview should feel like the burned-in bottom bar (but is UI-only).
        // Place it under the canvas so its position matches the final saved image.
        if let noteView = makeNotePreviewView() {
            notePreviewContainer = noteView
            rootStack.addArrangedSubview(noteView)
            noteView.translatesAutoresizingMaskIntoConstraints = false
            noteView.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }

        canvasView.onKeyCommand = { [weak self] command in
            self?.handleKeyCommand(command)
        }

        setupColorPicker()

        selectTool(.pen)
        selectColor(index: 0)
    }

    private func makeNotePreviewView() -> NSView? {
        let raw = (notePreviewRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // Match note burning rules (prefix + 1000 char cap), but do not modify the image here.
        var text = String(raw.prefix(1000))
        let settings = settingsStore.settings
        if settings.notePrefixEnabled {
            let prefix = settings.notePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                text = prefix + " " + text
            }
        }

        let container = NSView()

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])

        return container
    }

    private func makeToolbarBackground() -> NSView {
        let background = NSView()
        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        return background
    }

    private func configureEditorShortcutLabel() {
        editorShortcutLabel.stringValue = "Keys: W Pen    A Arrow    R Rectangle    E Ellipse    T Text    S Select    K/Q Colors    1-6 Pick color    Cmd+Z Undo    Option+Backspace Clear    Cmd+C/X/V Copy/Cut/Paste    Cmd +/-/0 Zoom    Shift+Tab Prompt    Enter Save    Cmd+Enter Copy+Save    Esc Cancel"
        editorShortcutLabel.font = NSFont.systemFont(ofSize: 11)
        editorShortcutLabel.textColor = NSColor.secondaryLabelColor
        editorShortcutLabel.alignment = .center
        editorShortcutLabel.lineBreakMode = .byWordWrapping
        editorShortcutLabel.maximumNumberOfLines = 0
        editorShortcutLabel.translatesAutoresizingMaskIntoConstraints = false
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

        let cancelButton = makeActionButton(symbol: "xmark", toolTip: "Cancel (Esc)", action: #selector(deletePressed))

        let saveButton = makeSaveButton()

        configureColorIndicator()

        zoomLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = NSColor.secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.setContentHuggingPriority(.required, for: .horizontal)
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        // Drawing tools - tight group
        let drawingTools = NSStackView(views: [
            penButton, arrowButton, rectButton, ovalButton,
            textButton, selectionButton
        ])
        drawingTools.orientation = .horizontal
        drawingTools.alignment = .centerY
        drawingTools.spacing = 2

        // Color indicator wrapped in a 32x32 container so it optically matches buttons
        let colorContainer = NSView()
        colorContainer.translatesAutoresizingMaskIntoConstraints = false
        colorContainer.addSubview(colorIndicatorButton)
        NSLayoutConstraint.activate([
            colorContainer.widthAnchor.constraint(equalToConstant: 26),
            colorContainer.heightAnchor.constraint(equalToConstant: 26),
            colorIndicatorButton.centerXAnchor.constraint(equalTo: colorContainer.centerXAnchor),
            colorIndicatorButton.centerYAnchor.constraint(equalTo: colorContainer.centerYAnchor),
        ])

        // Edit actions
        let editActions = NSStackView(views: [undoButton, clearButton])
        editActions.orientation = .horizontal
        editActions.alignment = .centerY
        editActions.spacing = 2

        // Zoom controls
        let zoomControls = NSStackView(views: [zoomOutButton, zoomLabel, zoomInButton])
        zoomControls.orientation = .horizontal
        zoomControls.alignment = .centerY
        zoomControls.spacing = 0

        // Session actions
        let sessionActions = NSStackView(views: [cancelButton, saveButton])
        sessionActions.orientation = .horizontal
        sessionActions.alignment = .centerY
        sessionActions.spacing = 2

        [drawingTools, colorContainer, editActions, zoomControls, sessionActions]
            .forEach { stack.addArrangedSubview($0) }

        // Spacing between groups: tighter within left side, breathe between logical sections
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

    private func makeSaveButton() -> NSButton {
        let button = makeActionButton(symbol: "tray.and.arrow.down",
                                      toolTip: "Save (Enter)",
                                      action: #selector(savePressed))
        button.title = ""
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

        let vc = NSViewController()
        vc.view = container
        colorPickerPopover.contentViewController = vc
        colorPickerPopover.behavior = .transient
        colorPickerPopover.delegate = self

        updateColorPickerSelection()
    }

    // MARK: - Toolbar actions

    @objc private func toolButtonPressed(_ sender: NSButton) {
        guard let tool = toolButtons.first(where: { $0.value === sender })?.key else { return }
        selectTool(tool)
    }

    private func selectTool(_ tool: EditorTool) {
        canvasView.setTool(tool)
        for (key, button) in toolButtons {
            let isActive = key == tool
            button.layer?.backgroundColor = isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
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
                button.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.95).cgColor
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
        colorIndicatorButton.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
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
                button.layer?.borderColor = NSColor.controlAccentColor.cgColor
                button.layer?.borderWidth = 2
            } else if index == selectedColorIndex {
                button.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.95).cgColor
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
        setZoom(userZoomFactor * 1.2)
    }

    @objc private func zoomOutPressed() {
        setZoom(userZoomFactor / 1.2)
    }

    @objc private func savePressed() {
        finish(with: .saveOnly)
    }

    @objc private func deletePressed() {
        // Match the Escape key behavior (configured per editor session).
        if escapeFinalActionCommand == .closeOnly {
            finish(with: .closeOnly)
        } else {
            finish(with: .deleteOnly)
        }
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
            case .closeOnly:
                finish(with: .closeOnly)
            }

        case .zoomIn:
            setZoom(userZoomFactor * 1.2)
        case .zoomOut:
            setZoom(userZoomFactor / 1.2)
        case .zoomReset:
            setZoom(defaultUserZoomFactor)
        case .undo:
            canvasView.undo()
        case .clear:
            canvasView.clearAll()
        case .selectColor(let index):
            selectColor(index: index)
            closeColorPicker()
        case .backToNote:
            closeColorPicker()
            onBackToNote?()
            window?.orderOut(nil)
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
            copySelectionOrEditedImageToClipboard()
        case .cutSelectionToClipboard:
            cutSelectionToClipboard()
        case .pasteSelectionInCanvas:
            pasteSelectionInCanvas()
        }
    }

    private func setZoom(_ value: CGFloat) {
        let clampedUser = max(minUserZoom, min(maxUserZoom, value))
        userZoomFactor = clampedUser
        applyZoom()
    }

    private func applyZoom() {
        let desired = baseScale * userZoomFactor
        let effective = max(minEffectiveZoom, min(maxEffectiveZoom, desired))

        // Keep the user factor consistent if we had to clamp the effective zoom.
        if baseScale > 0 {
            userZoomFactor = max(minUserZoom, min(maxUserZoom, effective / baseScale))
        }

        scrollView.magnification = effective

        // Match mac_screenshot: zoom label is user zoom (starts at 100%),
        // independent of any base downscaling needed to fit the window.
        let percent = Int(round(userZoomFactor * 100))
        zoomLabel.stringValue = "\(percent)%"

        updateScrollLockAndRecentering()
    }

    private func sizeWindowToImage() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()

        let imageSize = canvasView.baseImage.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let scaleFactor = max(window.backingScaleFactor, 1.0)
        let pixelSize = imagePixelSize(canvasView.baseImage)
        let pointW = pixelSize.width / scaleFactor
        let pointH = pixelSize.height / scaleFactor

        let minW: CGFloat = 580.0
        let minH: CGFloat = 250.0
        let toolbarH: CGFloat = toolbarMinimumHeight
        let shortcutH: CGFloat = editorShortcutLabel.fittingSize.height
        let noteH: CGFloat = (notePreviewContainer?.fittingSize.height ?? 0)
        let chromeW: CGFloat = 24.0
        // Root stack spacing is 10. If we have a note preview bar, add its height + spacing.
        let chromeH: CGFloat = 24.0 + toolbarH + 10.0 + shortcutH + 10.0 + (noteH > 0 ? (10.0 + noteH) : 0.0)
        let minContentSize = NSSize(width: minW, height: minH)
        let maxContentSize = EditorWindowLayoutLogic.maximumContentSize(
            visibleFrame: targetScreen?.visibleFrame ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
            minContentSize: minContentSize
        )

        let settings = settingsStore.settings
        let wasResized = settings.maxWidth > 0 && Int(pointW.rounded()) == settings.maxWidth
        let layout = EditorWindowLayoutLogic.makeLayout(
            EditorWindowLayoutInput(imagePointSize: NSSize(width: pointW, height: pointH),
                                    maxContentSize: maxContentSize,
                                    minContentSize: minContentSize,
                                    chromeSize: NSSize(width: chromeW, height: chromeH),
                                    wasResized: wasResized,
                                    autoZoomFillRatio: autoZoomFillRatio,
                                    maxAutoUserZoom: maxAutoUserZoom)
        )
        totalPadding = layout.totalPadding

        let pointToCanvasScaleW = pointW / imageSize.width
        let pointToCanvasScaleH = pointH / imageSize.height
        let pointToCanvasScale = min(pointToCanvasScaleW, pointToCanvasScaleH)
        baseScale = layout.fitScale * pointToCanvasScale

        window.setContentSize(layout.contentSize)

        defaultUserZoomFactor = layout.defaultUserZoomFactor
        userZoomFactor = defaultUserZoomFactor
        canvasView.setInitialTextZoomFactor(defaultUserZoomFactor)
        applyZoom()
    }

    private func positionWindowOnTargetScreen() {
        guard let window else { return }

        if let targetScreen {
            let frame = targetScreen.visibleFrame
            let windowSize = window.frame.size
            let origin = NSPoint(x: frame.midX - windowSize.width / 2,
                                 y: frame.midY - windowSize.height / 2)
            window.setFrameOrigin(origin)
            return
        }

        window.center()
    }

    private func imagePixelSize(_ image: NSImage) -> NSSize {
        if let bestBitmap = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { lhs, rhs in lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh }),
           bestBitmap.pixelsWide > 0,
           bestBitmap.pixelsHigh > 0 {
            return NSSize(width: CGFloat(bestBitmap.pixelsWide), height: CGFloat(bestBitmap.pixelsHigh))
        }

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        }

        return image.size
    }

    private var isContentScrollable: Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clipSize = scrollView.contentView.bounds.size
        let docSize = documentView.frame.size

        // Small epsilon so rounding at some magnifications doesn't count as scrollable.
        let epsilon: CGFloat = 1.0
        return (docSize.width > clipSize.width + epsilon) || (docSize.height > clipSize.height + epsilon)
    }

    private func updateScrollLockAndRecentering() {
        guard let documentView = scrollView.documentView else { return }
        let clipSize = scrollView.contentView.bounds.size
        canvasView.ensureDrawableAreaCoversVisibleSize(clipSize)
        let docSize = documentView.frame.size
        let epsilon: CGFloat = 1.0

        let scrollableX = docSize.width > clipSize.width + epsilon
        let scrollableY = docSize.height > clipSize.height + epsilon

        scrollView.horizontalScrollElasticity = scrollableX ? .automatic : .none
        scrollView.verticalScrollElasticity = scrollableY ? .automatic : .none

        // Keep non-scrollable axes centered (native feel).
        var origin = scrollView.contentView.bounds.origin

        if scrollableX {
            origin.x = max(0, min(origin.x, docSize.width - clipSize.width))
        } else {
            origin.x = floor((docSize.width - clipSize.width) / 2.0)
        }

        if scrollableY {
            let maxY = docSize.height - clipSize.height
            origin.y = max(0, min(origin.y, maxY))
        } else {
            origin.y = floor((docSize.height - clipSize.height) / 2.0)
        }

        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func copySelectionOrEditedImageToClipboard() {
        if let payload = canvasView.selectedRegionPayload() {
            clipboardService.writeImage(payload.image)
            return
        }
        clipboardService.writeImage(canvasView.compositeImage())
    }

    private func cutSelectionToClipboard() {
        guard let payload = canvasView.selectedRegionPayload() else { return }
        clipboardService.writeImage(payload.image)
        _ = canvasView.cutSelectedRegion()
    }

    private func pasteSelectionInCanvas() {
        _ = canvasView.pasteCopiedSelection()
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

    func windowDidResize(_ notification: Notification) {
        // Native screenshot editor does not auto-scale the image when you manually resize the window.
        // Keep zoom stable; just update panning lock and centering.
        updateScrollLockAndRecentering()
    }
}

extension EditorWindowController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        canvasView.isColorPickerOpen = false
        colorIndicatorButton.layer?.borderColor = NSColor.clear.cgColor
    }
}

/// Centers the document view when it is smaller than the visible area.
/// This matches the native screenshot editor feel (image stays centered while resizing).
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

        let docSize = documentView.frame.size
        let clipSize = bounds.size

        if docSize.width < clipSize.width {
            rect.origin.x = floor((docSize.width - clipSize.width) / 2.0)
        }
        if docSize.height <= clipSize.height {
            rect.origin.y = floor((docSize.height - clipSize.height) / 2.0)
        } else {
            let maxY = docSize.height - clipSize.height
            rect.origin.y = max(0, min(rect.origin.y, maxY))
        }

        return rect
    }
}

private final class EditorScrollView: NSScrollView {
    var shouldAllowScroll: (() -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if let shouldAllowScroll, !shouldAllowScroll() {
            return
        }
        super.scrollWheel(with: event)
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
