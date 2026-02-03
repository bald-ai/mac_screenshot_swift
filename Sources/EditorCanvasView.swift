import AppKit

/// High-level tool selection for the editor canvas.
/// Exposed separately so other parts of the app can talk to the canvas
/// without depending on its internal implementation details.
enum EditorTool {
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
final class EditorCanvasView: NSView, NSTextFieldDelegate {
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
    }

    /// Type used by EditorWindowController when switching tools.
    typealias Tool = EditorTool

    /// Callback for key-level commands (zoom, undo, final actions, color).
    var onKeyCommand: ((KeyCommand) -> Void)?

    // MARK: - Public state

    let baseImage: NSImage
    var currentTool: Tool = .pen
    var currentColor: NSColor = .systemRed

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
    private var textEditor: NSTextField?
    private var draggingTextIndex: Int?
    private var textDragOffset: NSPoint = .zero
    private var shouldPushUndoOnTextEnd = false

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
    }

    func setColor(_ color: NSColor) {
        currentColor = color
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        items = previous
        updateCanvasSizeIfNeeded()
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
                if clickCount >= 2 {
                    // Double-click: edit existing text
                    endTextEditingIfNeeded()
                    beginEditingText(at: index, pushUndoOnEnd: true)
                } else {
                    // Single click on text: begin dragging
                    endTextEditingIfNeeded()
                    pushUndoSnapshot()
                    draggingTextIndex = index
                    textDragOffset = NSPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
                }
                return
            } else {
                // Click on empty area: create a new text item and start editing
                endTextEditingIfNeeded()

                let item = TextItem(text: "", origin: point, color: currentColor, fontSize: 16)
                pushUndoSnapshot()
                items.append(.text(item))
                let index = items.count - 1
                beginEditingText(at: index, pushUndoOnEnd: false)
                updateCanvasSizeIfNeeded()
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
            updateCanvasSizeIfNeeded()
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

    private func beginEditingText(at index: Int, pushUndoOnEnd: Bool) {
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
        shouldPushUndoOnTextEnd = pushUndoOnEnd
    }

    private func endTextEditingIfNeeded() {
        guard let index = editingTextIndex, let editor = textEditor else { return }
        let newText = editor.stringValue

        if case var .text(item) = items[index] {
            if item.text != newText {
                if shouldPushUndoOnTextEnd {
                    pushUndoSnapshot()
                }
                item.text = newText
                items[index] = .text(item)
            }
        }

        editor.removeFromSuperview()
        editingTextIndex = nil
        textEditor = nil
        shouldPushUndoOnTextEnd = false
        updateCanvasSizeIfNeeded()
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endTextEditingIfNeeded()
    }

    // MARK: - Keyboard & gestures

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if let final = interpretFinalActionCommand(from: event, flags: flags) {
            onKeyCommand?(.finalAction(final))
            return
        }

        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            if flags.contains(.command) {
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
                case "1", "2", "3", "4", "5", "6":
                    if let digit = Int(chars), (1...6).contains(digit) {
                        onKeyCommand?(.selectColor(index: digit - 1))
                        return
                    }
                default:
                    break
                }
            }
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
