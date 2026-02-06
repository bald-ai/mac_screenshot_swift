import AppKit

/// High-level tool selection for the editor canvas.
/// Exposed separately so other parts of the app can talk to the canvas
/// without depending on its internal implementation details.
enum EditorTool: Hashable {
    case pen
    case arrow
    case rectangle
    case ellipse
    case text
}

/// Main drawing canvas used by the screenshot editor.
///
/// Responsibilities:
/// - Draw the base image
/// - Manage annotation items (pen, arrow, rectangle, ellipse, text)
/// - Handle mouse/keyboard input for drawing and text editing
/// - Provide an undo stack (up to 30 steps)
/// - Communicate high-level key commands back to the window controller
final class EditorCanvasView: NSView, NSTextViewDelegate {
    // MARK: - Commands sent back to the controller

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
        case backToNote
        case selectTool(EditorTool)
        case toggleColorPicker
        case colorPickerMove(direction: Int)
        case colorPickerSelect
        case colorPickerClose
        case copyToClipboard
    }

    /// Type used by EditorWindowController when switching tools.
    typealias Tool = EditorTool

    /// Callback for key-level commands (zoom, undo, final actions, color).
    var onKeyCommand: ((KeyCommand) -> Void)?

    // MARK: - Public state

    let baseImage: NSImage
    var currentTool: Tool = .pen
    var currentColor: NSColor = .systemRed
    var isColorPickerOpen: Bool = false

    // MARK: - Internal model

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
    private let maxUndoLevels = 30

    // In-progress drawing state
    private var currentPoints: [NSPoint] = [] // for pen
    private var dragStartPoint: NSPoint?
    private var dragCurrentPoint: NSPoint?

    // Text editing/dragging
    private var editingTextIndex: Int?
    private var textEditor: EditorInlineTextView?
    private var draggingTextIndex: Int?
    private var textDragOffset: NSPoint = .zero
    private var shouldPushUndoOnTextEnd = false
    private var selectedTextIndex: Int?
    private var editingOriginalText: String?
    private var editingWasNewItem = false
    private var isCommittingText = false
    private var isCancellingText = false
    private let textPadding = NSSize(width: 6, height: 4)

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

    // MARK: - Public API (Agent 3 spec)

    func setTool(_ tool: EditorTool) {
        currentTool = tool
        if tool != .text {
            selectedTextIndex = nil
            endTextEditingIfNeeded()
        }
        needsDisplay = true
    }

    func setColor(_ color: NSColor) {
        currentColor = color
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        items = previous
        updateCanvasSizeIfNeeded()
        selectedTextIndex = nil
        needsDisplay = true
    }

    /// Clear all annotations.
    func clear() {
        clearAll()
    }

    /// Kept for compatibility with EditorWindowController.
    func clearAll() {
        guard !items.isEmpty else { return }
        pushUndoSnapshot()
        items.removeAll()
        selectedTextIndex = nil
        endTextEditingIfNeeded()
        setFrameSize(baseImage.size)
        needsDisplay = true
    }

    func zoomIn() {
        onKeyCommand?(.zoomIn)
    }

    func zoomOut() {
        onKeyCommand?(.zoomOut)
    }

    func resetZoom() {
        onKeyCommand?(.zoomReset)
    }

    /// Render the final composited image at the original resolution.
    func renderFinalImage() -> NSImage {
        compositeImage()
    }

    /// Kept for compatibility with EditorWindowController.
    func compositeImage() -> NSImage {
        let size = baseImage.size
        let result = NSImage(size: size)

        result.lockFocusFlipped(true)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let imageRect = NSRect(origin: .zero, size: size)
        baseImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

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
        baseImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

        for item in items {
            draw(item: item)
        }

        if let index = selectedTextIndex, textEditor == nil {
            if case let .text(textItem) = items[index] {
                let rect = textBounds(for: textItem).insetBy(dx: -2, dy: -2)
                let path = NSBezierPath(rect: rect)
                let dash: [CGFloat] = [4, 3]
                path.setLineDash(dash, count: dash.count, phase: 0)
                NSColor.white.withAlphaComponent(0.8).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
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

        // Simple smoothing by drawing through midpoints.
        path.move(to: points[0])
        if points.count == 2 {
            path.line(to: points[1])
        } else {
            for i in 1..<points.count {
                let mid = NSPoint(x: (points[i - 1].x + points[i].x) / 2,
                                   y: (points[i - 1].y + points[i].y) / 2)
                path.curve(to: mid, controlPoint1: points[i - 1], controlPoint2: points[i])
            }
            if let last = points.last {
                path.line(to: last)
            }
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
        let rect = textBounds(for: item).insetBy(dx: textPadding.width, dy: textPadding.height)
        (item.text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
    }

    private func textAttributes(for item: TextItem) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: item.fontSize, weight: .regular),
            .foregroundColor: item.color
        ]
    }

    private func textBounds(for item: TextItem) -> NSRect {
        let font = NSFont.systemFont(ofSize: item.fontSize, weight: .regular)
        let size = textContentSize(for: item.text, font: font)
        let width = max(size.width + textPadding.width * 2, 60)
        let height = max(size.height + textPadding.height * 2, 28)
        return NSRect(x: item.origin.x, y: item.origin.y, width: width, height: height)
    }

    private func textContentSize(for text: String, font: NSFont) -> NSSize {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var maxWidth: CGFloat = 0
        for line in lines {
            let lineSize = (String(line) as NSString).size(withAttributes: [.font: font])
            maxWidth = max(maxWidth, lineSize.width)
        }
        let lineHeight = font.boundingRectForFont.size.height
        let height = max(1, lines.count)
        return NSSize(width: maxWidth, height: lineHeight * CGFloat(height))
    }

    // MARK: - Geometry helpers

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
        if undoStack.count >= maxUndoLevels {
            undoStack.removeFirst()
        }
        undoStack.append(items)
    }

    /// Ensure the canvas is large enough to contain the base image and all annotations.
    private func updateCanvasSizeIfNeeded() {
        var unionRect = NSRect(origin: .zero, size: baseImage.size)

        for item in items {
            switch item {
            case .pen(let points, _, _):
                guard let first = points.first else { continue }
                var minX = first.x
                var minY = first.y
                var maxX = first.x
                var maxY = first.y
                for p in points.dropFirst() {
                    minX = min(minX, p.x)
                    minY = min(minY, p.y)
                    maxX = max(maxX, p.x)
                    maxY = max(maxY, p.y)
                }
                let rect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                unionRect = unionRect.union(rect)

            case .arrow(let start, let end, _, _):
                let rect = normalizedRect(from: start, to: end)
                unionRect = unionRect.union(rect)

            case .rect(let rect, _, _):
                unionRect = unionRect.union(rect)

            case .ellipse(let rect, _, _):
                unionRect = unionRect.union(rect)

            case .text(let textItem):
                unionRect = unionRect.union(textBounds(for: textItem))
            }
        }

        let newWidth = max(unionRect.maxX, baseImage.size.width)
        let newHeight = max(unionRect.maxY, baseImage.size.height)
        let newSize = NSSize(width: ceil(newWidth), height: ceil(newHeight))

        if newSize != frame.size {
            setFrameSize(newSize)
            needsDisplay = true
        }
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if currentTool == .text {
            let clickCount = event.clickCount

            if let (index, rect) = hitTestText(at: point) {
                selectedTextIndex = index
                if clickCount >= 2 {
                    endTextEditingIfNeeded()
                    beginEditingText(at: index, pushUndoOnEnd: true, isNewItem: false)
                } else {
                    endTextEditingIfNeeded()
                    pushUndoSnapshot()
                    draggingTextIndex = index
                    textDragOffset = NSPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
                }
                needsDisplay = true
                return
            } else {
                selectedTextIndex = nil
                endTextEditingIfNeeded()

                let item = TextItem(text: "", origin: point, color: currentColor, fontSize: 24)
                pushUndoSnapshot()
                items.append(.text(item))
                let index = items.count - 1
                selectedTextIndex = index
                beginEditingText(at: index, pushUndoOnEnd: false, isNewItem: true)
                updateCanvasSizeIfNeeded()
                needsDisplay = true
                return
            }
        }

        selectedTextIndex = nil
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
            updateCanvasSizeIfNeeded()
            needsDisplay = true
            return
        }

        guard let start = dragStartPoint else { return }
        dragCurrentPoint = point

        switch currentTool {
        case .pen:
            if currentPoints.count > 1 {
                pushUndoSnapshot()
                items.append(.pen(points: currentPoints, color: currentColor, lineWidth: 2.0))
                updateCanvasSizeIfNeeded()
            }
        case .arrow:
            if distance(from: start, to: point) >= 2 {
                pushUndoSnapshot()
                items.append(.arrow(start: start, end: point, color: currentColor, lineWidth: 3.0))
                updateCanvasSizeIfNeeded()
            }
        case .rectangle:
            let rect = normalizedRect(from: start, to: point)
            if rect.width >= 2, rect.height >= 2 {
                pushUndoSnapshot()
                items.append(.rect(rect: rect, color: currentColor, lineWidth: 2.0))
                updateCanvasSizeIfNeeded()
            }
        case .ellipse:
            let rect = normalizedRect(from: start, to: point)
            if rect.width >= 2, rect.height >= 2 {
                pushUndoSnapshot()
                items.append(.ellipse(rect: rect, color: currentColor, lineWidth: 2.0))
                updateCanvasSizeIfNeeded()
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

    private func beginEditingText(at index: Int, pushUndoOnEnd: Bool, isNewItem: Bool) {
        guard case let .text(item) = items[index] else { return }

        endTextEditingIfNeeded()

        let rect = textBounds(for: item)
        let editor = EditorInlineTextView(frame: rect)
        editor.string = item.text
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.drawsBackground = false
        editor.textColor = item.color
        editor.font = NSFont.systemFont(ofSize: item.fontSize, weight: .regular)
        editor.textContainerInset = textPadding
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.lineBreakMode = .byClipping
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        editor.focusRingType = .none
        editor.delegate = self
        editor.onCommit = { [weak self] in
            self?.commitTextEditing()
        }
        editor.onCancel = { [weak self] in
            self?.cancelTextEditing()
        }
        editor.onDidChange = { [weak self] in
            self?.resizeTextEditorToFit()
        }
        editor.wantsLayer = true
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        editor.layer?.cornerRadius = 4

        addSubview(editor)
        window?.makeFirstResponder(editor)

        editingTextIndex = index
        editingOriginalText = item.text
        editingWasNewItem = isNewItem
        shouldPushUndoOnTextEnd = pushUndoOnEnd
        textEditor = editor
        resizeTextEditorToFit()
    }

    private func resizeTextEditorToFit() {
        guard let editor = textEditor else { return }
        let font = editor.font ?? NSFont.systemFont(ofSize: 24, weight: .regular)
        let text = editor.string
        let contentSize = textContentSize(for: text, font: font)
        let width = max(contentSize.width + textPadding.width * 2, 60)
        let height = max(contentSize.height + textPadding.height * 2, 28)
        editor.frame.size = NSSize(width: width, height: height)
    }

    private func commitTextEditing() {
        guard !isCommittingText else { return }
        guard let index = editingTextIndex, let editor = textEditor else { return }
        isCommittingText = true
        defer { isCommittingText = false }

        let updatedText = trimTrailingWhitespace(editor.string.replacingOccurrences(of: "\r", with: ""))
        let isEmpty = updatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isEmpty {
            if editingWasNewItem {
                items.remove(at: index)
                selectedTextIndex = nil
            } else if let original = editingOriginalText, case var .text(item) = items[index] {
                item.text = original
                items[index] = .text(item)
            }
        } else if case var .text(item) = items[index] {
            let colorChanged = item.color != currentColor
            let textChanged = item.text != updatedText
            if shouldPushUndoOnTextEnd && (textChanged || colorChanged) {
                pushUndoSnapshot()
            }
            item.text = updatedText
            item.color = currentColor
            items[index] = .text(item)
            selectedTextIndex = index
        }

        removeTextEditor()
        updateCanvasSizeIfNeeded()
        needsDisplay = true
    }

    private func cancelTextEditing() {
        guard let index = editingTextIndex else { return }
        isCancellingText = true
        if editingWasNewItem {
            items.remove(at: index)
            selectedTextIndex = nil
        } else if let original = editingOriginalText, case var .text(item) = items[index] {
            item.text = original
            items[index] = .text(item)
            selectedTextIndex = index
        }
        removeTextEditor()
        updateCanvasSizeIfNeeded()
        needsDisplay = true
        isCancellingText = false
    }

    private func removeTextEditor() {
        textEditor?.removeFromSuperview()
        editingTextIndex = nil
        textEditor = nil
        editingOriginalText = nil
        editingWasNewItem = false
        shouldPushUndoOnTextEnd = false
        window?.makeFirstResponder(self)
    }

    private func endTextEditingIfNeeded() {
        if textEditor != nil {
            commitTextEditing()
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard !isCancellingText else { return }
        commitTextEditing()
    }

    private func trimTrailingWhitespace(_ text: String) -> String {
        var value = text
        while let last = value.last, last.isWhitespace || last.isNewline {
            value.removeLast()
        }
        return value
    }

    private func deleteSelectedTextIfNeeded() -> Bool {
        guard let index = selectedTextIndex else { return false }
        pushUndoSnapshot()
        items.remove(at: index)
        selectedTextIndex = nil
        updateCanvasSizeIfNeeded()
        needsDisplay = true
        return true
    }

    // MARK: - Keyboard & gestures

    override func keyDown(with event: NSEvent) {
        if textEditor != nil {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if isColorPickerOpen {
            if let chars = event.characters, let index = czechKeyToColorIndex[chars] {
                onKeyCommand?(.selectColor(index: index))
                onKeyCommand?(.colorPickerClose)
                return
            }
            switch event.keyCode {
            case 123: // left arrow
                onKeyCommand?(.colorPickerMove(direction: -1))
                return
            case 124: // right arrow
                onKeyCommand?(.colorPickerMove(direction: 1))
                return
            case 36, 76: // enter
                onKeyCommand?(.colorPickerSelect)
                return
            case 53: // escape
                onKeyCommand?(.colorPickerClose)
                return
            default:
                break
            }
        }

        if !flags.contains(.command) && !flags.contains(.control) {
            if !flags.contains(.shift), let chars = event.characters {
                if chars == "k" || chars == "q" {
                    if isColorPickerOpen { return }
                    onKeyCommand?(.toggleColorPicker)
                    return
                }
            }
        }

        if !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) && !flags.contains(.shift) {
            if let chars = event.characters {
                switch chars {
                case "w":
                    onKeyCommand?(.selectTool(.pen))
                    return
                case "a":
                    onKeyCommand?(.selectTool(.arrow))
                    return
                case "r":
                    onKeyCommand?(.selectTool(.rectangle))
                    return
                case "e":
                    onKeyCommand?(.selectTool(.ellipse))
                    return
                case "t":
                    onKeyCommand?(.selectTool(.text))
                    return
                default:
                    break
                }
            }
        }

        if flags.contains(.option) && event.keyCode == 51 {
            onKeyCommand?(.clear)
            return
        }

        if flags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
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
            case "z":
                onKeyCommand?(.undo)
                return
            case "c":
                onKeyCommand?(.copyToClipboard)
                return
            default:
                break
            }
        }

        if let final = interpretFinalActionCommand(from: event, flags: flags) {
            onKeyCommand?(.finalAction(final))
            return
        }

        if event.keyCode == 48 && flags.contains(.shift) { // Shift+Tab
            onKeyCommand?(.backToNote)
            return
        }

        if (event.keyCode == 51 || event.keyCode == 117) && deleteSelectedTextIfNeeded() {
            return
        }

        super.keyDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)

        if event.magnification > 0 {
            onKeyCommand?(.zoomIn)
        } else if event.magnification < 0 {
            onKeyCommand?(.zoomOut)
        }
    }

    private func interpretFinalActionCommand(from event: NSEvent, flags: NSEvent.ModifierFlags) -> FinalActionCommand? {
        switch event.keyCode {
        case 36, 76: // Return / Enter
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

    private var czechKeyToColorIndex: [String: Int] {
        [
            "+": 0,
            "ě": 1,
            "š": 2,
            "č": 3,
            "ř": 4,
            "ž": 5
        ]
    }
}

private final class EditorInlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDidChange: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return / Enter
            if flags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                onCommit?()
            }
        case 53: // Escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        onDidChange?()
    }
}
