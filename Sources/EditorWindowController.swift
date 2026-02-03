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

    private let canvasView: EditorCanvasView
    private let scrollView = NSScrollView()
    private let toolSelector: NSSegmentedControl

    private var colorButtons: [NSButton] = []
    private let colors: [NSColor] = [
        .systemRed,
        .systemYellow,
        .systemGreen,
        .systemBlue,
        .systemOrange,
        .systemPurple
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
        self.toolSelector = NSSegmentedControl(labels: ["Pen", "Arrow", "Rect", "Oval", "Text"],
                                               trackingMode: .selectOne,
                                               target: nil,
                                               action: nil)

        let initialSize = image.size
        let windowWidth = max(580, min(900, initialSize.width + 80))
        let windowHeight = max(500, min(800, initialSize.height + 160))
        let contentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: contentRect,
                              styleMask: style,
                              backing: .buffered,
                              defer: false)
        window.title = "Screenshot Editor"
        window.center()
        window.setFrameAutosaveName("ScreenshotEditorWindow")
        window.contentMinSize = NSSize(width: 580, height: 400)

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

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 8
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])

        // Toolbar row
        let toolbarStack = NSStackView()
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 8

        toolSelector.segmentStyle = .texturedRounded
        toolSelector.target = self
        toolSelector.action = #selector(toolChanged(_:))
        toolSelector.selectedSegment = 0

        let colorStack = NSStackView()
        colorStack.orientation = .horizontal
        colorStack.spacing = 4

        for (index, color) in colors.enumerated() {
            let button = NSButton(frame: .zero)
            button.setButtonType(.momentaryChange)
            button.bezelStyle = .shadowlessSquare
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 3
            button.layer?.backgroundColor = color.cgColor
            button.tag = index
            button.target = self
            button.action = #selector(colorButtonPressed(_:))

            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 16).isActive = true

            colorButtons.append(button)
            colorStack.addArrangedSubview(button)
        }

        let undoButton = NSButton(title: "Undo", target: self, action: #selector(undoPressed))
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearPressed))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let copySaveButton = NSButton(title: "Copy+Save", target: self, action: #selector(copyAndSavePressed))
        let copyDeleteButton = NSButton(title: "Copy+Delete", target: self, action: #selector(copyAndDeletePressed))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePressed))
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deletePressed))

        [toolSelector,
         colorStack,
         undoButton,
         clearButton,
         spacer,
         copySaveButton,
         copyDeleteButton,
         saveButton,
         deleteButton].forEach { toolbarStack.addArrangedSubview($0) }

        rootStack.addArrangedSubview(toolbarStack)

        // Canvas / scroll view
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = minZoom
        scrollView.maxMagnification = maxZoom
        scrollView.documentView = canvasView
        scrollView.magnification = currentZoom

        rootStack.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        canvasView.onKeyCommand = { [weak self] command in
            self?.handleKeyCommand(command)
        }

        selectTool(at: 0)
        selectColor(index: 0)
    }

    // MARK: - Toolbar actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        selectTool(at: sender.selectedSegment)
    }

    private func selectTool(at index: Int) {
        let tool: EditorCanvasView.Tool
        switch index {
        case 0: tool = .pen
        case 1: tool = .arrow
        case 2: tool = .rectangle
        case 3: tool = .ellipse
        case 4: tool = .text
        default: tool = .pen
        }
        canvasView.currentTool = tool
    }

    @objc private func colorButtonPressed(_ sender: NSButton) {
        selectColor(index: sender.tag)
    }

    private func selectColor(index: Int) {
        guard colors.indices.contains(index) else { return }

        for (i, button) in colorButtons.enumerated() {
            if i == index {
                button.layer?.borderWidth = 2.0
                button.layer?.borderColor = NSColor.selectedControlColor.cgColor
            } else {
                button.layer?.borderWidth = 0.0
                button.layer?.borderColor = nil
            }
        }

        canvasView.currentColor = colors[index]
    }

    @objc private func undoPressed() {
        canvasView.undo()
    }

    @objc private func clearPressed() {
        canvasView.clearAll()
    }

    @objc private func savePressed() {
        finish(with: .saveOnly)
    }

    @objc private func copyAndSavePressed() {
        finish(with: .copyAndSave)
    }

    @objc private func copyAndDeletePressed() {
        finish(with: .copyAndDelete)
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
        }
    }

    private func setZoom(_ value: CGFloat) {
        let clamped = max(minZoom, min(maxZoom, value))
        currentZoom = clamped
        scrollView.magnification = clamped
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


