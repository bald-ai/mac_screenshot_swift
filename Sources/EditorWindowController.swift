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

// MARK: - Editor canvas view

private final class EditorCanvasView: NSView, NSTextFieldDelegate {
    enum Tool {
        case pen
        case arrow
        case rectangle
        case ellipse
        case text
    }

    enum FinalActionCommand {
        case saveOnly
        case copyAndSave
        case copyAndDelete
        case deleteOnly
    }

    enum KeyCommand {
        case finalAction(FinalActionCommand)
        case zoomIn
        case zoomOut
        case zoomReset
        case undo
        case clear
        case selectColor(index: Int)
    }

    var onKeyCommand: ((KeyCommand) -> Void)?

    let baseImage: NSImage
    var currentTool: Tool = .pen
    var currentColor: NSColor = .systemRed

    private enum Item {
        case pen(points: [NSPoint], color: NSColor, lineWidth: CGFloat)
        case arrow(start: NSPoint, end: NSPoint, color: NSColor, lineWidth: CGFloat)
        case rect(rect: NSRect, color: NSColor, lineWidth: CGFloat)
        case ellipse(rect: NSRect, color: NSColor, lineWidth: CGFloat)
        case text(TextItem)
    }

    private struct TextItem {
        var text: String
        var origin: NSPoint // top-left in view coordinates
        var color: NSColor
        var fontSize: CGFloat
    }

    private var items: [Item] = []
    private var undoStack: [[Item]] = []

    // In-progress drawing state
    private var currentPoints: [NSPoint] = [] // for pen
    private var dragStartPoint: NSPoint?
    private var dragCurrentPoint: NSPoint?

    // Text editing/dragging
    private var editingTextIndex: Int?
    private var textEditor: NSTextField?
    private var draggingTextIndex: Int?
    private var textDragOffset: NSPoint = .zero

    // MARK: - Init

    init(image: NSImage) {
        self.baseImage = image
        let frame = NSRect(origin: .zero, size: image.size)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Public API

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        items = previous
        needsDisplay = true
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        pushUndoSnapshot()
        items.removeAll()
        needsDisplay = true
    }

    func compositeImage() -> NSImage? {
        let size = baseImage.size
        let result = NSImage(size: size)

        result.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let imageRect = NSRect(origin: .zero, size: size)
        baseImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        for item in items {
            draw(item: item)
        }

        result.unlockFocus()
        return result
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.black.setFill()
        bounds.fill()

        let imageRect = NSRect(origin: .zero, size: baseImage.size)
        baseImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        for item in items {
            draw(item: item)
        }

        // In-progress shapes
        if let start = dragStartPoint, let current = dragCurrentPoint {
            switch currentTool {
            case .pen:
                drawPen(points: currentPoints, color: currentColor, lineWidth: 2.0, isPreview: true)
            case .arrow:
                drawArrow(from: start, to: current, color: currentColor, lineWidth: 3.0, isPreview: true)
            case .rectangle:
                let rect = normalizedRect(from: start, to: current)
                drawRect(rect, color: currentColor, lineWidth: 2.0, isPreview: true)
            case .ellipse:
                let rect = normalizedRect(from: start, to: current)
                drawEllipse(rect, color: currentColor, lineWidth: 2.0, isPreview: true)
            case .text:
                break
            }
        } else if currentTool == .pen && !currentPoints.isEmpty {
            drawPen(points: currentPoints, color: currentColor, lineWidth: 2.0, isPreview: true)
        }
    }

    private func draw(item: Item) {
        switch item {
        case .pen(let points, let color, let lineWidth):
            drawPen(points: points, color: color, lineWidth: lineWidth, isPreview: false)
        case .arrow(let start, let end, let color, let lineWidth):
            drawArrow(from: start, to: end, color: color, lineWidth: lineWidth, isPreview: false)
        case .rect(let rect, let color, let lineWidth):
            drawRect(rect, color: color, lineWidth: lineWidth, isPreview: false)
        case .ellipse(let rect, let color, let lineWidth):
            drawEllipse(rect, color: color, lineWidth: lineWidth, isPreview: false)
        case .text(let item):
            drawText(item)
        }
    }

    private func drawPen(points: [NSPoint], color: NSColor, lineWidth: CGFloat, isPreview: Bool) {
        guard points.count > 1 else { return }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }

        (isPreview ? color.withAlphaComponent(0.7) : color).setStroke()
        path.stroke()
    }

    private func drawRect(_ rect: NSRect, color: NSColor, lineWidth: CGFloat, isPreview: Bool) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        (isPreview ? color.withAlphaComponent(0.7) : color).setStroke()
        path.stroke()
    }

    private func drawEllipse(_ rect: NSRect, color: NSColor, lineWidth: CGFloat, isPreview: Bool) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        (isPreview ? color.withAlphaComponent(0.7) : color).setStroke()
        path.stroke()
    }

    private func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor, lineWidth: CGFloat, isPreview: Bool) {
        guard distance(from: start, to: end) >= 2 else { return }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.move(to: start)
        path.line(to: end)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)
        let arrowLength: CGFloat = 14
        let arrowAngle: CGFloat = .pi / 6 // 30°

        let tip = end
        let point1 = NSPoint(x: tip.x - arrowLength * cos(angle - arrowAngle),
                             y: tip.y - arrowLength * sin(angle - arrowAngle))
        let point2 = NSPoint(x: tip.x - arrowLength * cos(angle + arrowAngle),
                             y: tip.y - arrowLength * sin(angle + arrowAngle))

        path.move(to: tip)
        path.line(to: point1)
        path.move(to: tip)
        path.line(to: point2)

        (isPreview ? color.withAlphaComponent(0.7) : color).setStroke()
        path.stroke()
    }

    private func drawText(_ item: TextItem) {
        let attributes = textAttributes(for: item)
        let rect = textBounds(for: item)
        (item.text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func textAttributes(for item: TextItem) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: item.fontSize, weight: .semibold),
            .foregroundColor: item.color
        ]
    }

    private func textBounds(for item: TextItem) -> NSRect {
        let attributes = textAttributes(for: item)
        let size = (item.text as NSString).size(withAttributes: attributes)
        let width = max(size.width, 40)
        let height = max(size.height, 18)
        return NSRect(x: item.origin.x, y: item.origin.y, width: width, height: height)
    }

    private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> NSRect {
        let minX = min(p1.x, p2.x)
        let maxX = max(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        let maxY = max(p1.y, p2.y)
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func distance(from p1: NSPoint, to p2: NSPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }

    private func pushUndoSnapshot() {
        if undoStack.count >= 30 {
            undoStack.removeFirst()
        }
        undoStack.append(items)
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if currentTool == .text {
            if let (index, rect) = hitTestText(at: point) {
                draggingTextIndex = index
                textDragOffset = NSPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
                return
            } else {
                endTextEditingIfNeeded()

                let item = TextItem(text: "Text", origin: point, color: currentColor, fontSize: 16)
                pushUndoSnapshot()
                items.append(.text(item))
                let index = items.count - 1
                beginEditingText(at: index)
                needsDisplay = true
                return
            }
        }

        endTextEditingIfNeeded()

        dragStartPoint = point
        dragCurrentPoint = point
        currentPoints.removeAll()

        if currentTool == .pen {
            currentPoints.append(point)
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let index = draggingTextIndex {
            if case var .text(item) = items[index] {
                let newOrigin = NSPoint(x: point.x - textDragOffset.x, y: point.y - textDragOffset.y)
                item.origin = newOrigin
                items[index] = .text(item)
                needsDisplay = true
            }
            return
        }

        guard dragStartPoint != nil else { return }

        dragCurrentPoint = point

        if currentTool == .pen {
            currentPoints.append(point)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if draggingTextIndex != nil {
            draggingTextIndex = nil
            // Moving text is undoable as a single step.
            pushUndoSnapshot()
            return
        }

        guard let start = dragStartPoint else { return }
        dragCurrentPoint = point

        switch currentTool {
        case .pen:
            if currentPoints.count > 1 {
                pushUndoSnapshot()
                items.append(.pen(points: currentPoints, color: currentColor, lineWidth: 2.0))
            }
        case .arrow:
            if distance(from: start, to: point) >= 2 {
                pushUndoSnapshot()
                items.append(.arrow(start: start, end: point, color: currentColor, lineWidth: 3.0))
            }
        case .rectangle:
            let rect = normalizedRect(from: start, to: point)
            if rect.width >= 2, rect.height >= 2 {
                pushUndoSnapshot()
                items.append(.rect(rect: rect, color: currentColor, lineWidth: 2.0))
            }
        case .ellipse:
            let rect = normalizedRect(from: start, to: point)
            if rect.width >= 2, rect.height >= 2 {
                pushUndoSnapshot()
                items.append(.ellipse(rect: rect, color: currentColor, lineWidth: 2.0))
            }
        case .text:
            break
        }

        dragStartPoint = nil
        dragCurrentPoint = nil
        currentPoints.removeAll()
        needsDisplay = true
    }

    // MARK: - Text editing helpers

    private func hitTestText(at point: NSPoint) -> (Int, NSRect)? {
        for (index, item) in items.enumerated() {
            guard case let .text(textItem) = item else { continue }
            let rect = textBounds(for: textItem).insetBy(dx: -4, dy: -4)
            if rect.contains(point) {
                return (index, rect)
            }
        }
        return nil
    }

    private func beginEditingText(at index: Int) {
        guard case let .text(item) = items[index] else { return }

        endTextEditingIfNeeded()

        let rect = textBounds(for: item)
        let field = NSTextField(frame: rect)
        field.stringValue = item.text
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = item.color
        field.font = NSFont.systemFont(ofSize: item.fontSize, weight: .semibold)
        field.focusRingType = .none
        field.delegate = self

        addSubview(field)
        window?.makeFirstResponder(field)

        editingTextIndex = index
        textEditor = field
    }

    private func endTextEditingIfNeeded() {
        guard let index = editingTextIndex, let editor = textEditor else { return }
        let newText = editor.stringValue

        if case var .text(item) = items[index] {
            if item.text != newText {
                pushUndoSnapshot()
                item.text = newText
                items[index] = .text(item)
            }
        }

        editor.removeFromSuperview()
        editingTextIndex = nil
        textEditor = nil
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endTextEditingIfNeeded()
    }

    // MARK: - Keyboard handling

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if let final = interpretFinalActionCommand(from: event, flags: flags) {
            onKeyCommand?(.finalAction(final))
            return
        }

        if flags.contains(.command), let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            switch chars {
            case "=", "+":
                onKeyCommand?(.zoomIn)
                return
            case "-":
                onKeyCommand?(.zoomOut)
                return
            case "0":
                onKeyCommand?(.zoomReset)
                return
            case "z", "Z":
                onKeyCommand?(.undo)
                return
            case "k", "K":
                onKeyCommand?(.clear)
                return
            default:
                break
            }
        }

        if flags.isEmpty, let chars = event.charactersIgnoringModifiers, let first = chars.first {
            if let digit = Int(String(first)), (1...6).contains(digit) {
                onKeyCommand?(.selectColor(index: digit - 1))
                return
            }
        }

        super.keyDown(with: event)
    }

    private func interpretFinalActionCommand(from event: NSEvent, flags: NSEvent.ModifierFlags) -> FinalActionCommand? {
        switch event.keyCode {
        case 36: // Return
            if flags.contains(.command) {
                return .copyAndSave
            } else {
                return .saveOnly
            }
        case 51: // Delete / Backspace
            if flags.contains(.command) {
                return .copyAndDelete
            }
        case 53: // Escape
            return .deleteOnly
        default:
            break
        }

        return nil
    }
}
