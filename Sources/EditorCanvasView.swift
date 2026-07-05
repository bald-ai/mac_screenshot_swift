import AppKit
import Carbon

/// High-level tool selection for the editor canvas.
/// Exposed separately so other parts of the app can talk to the canvas
/// without depending on its internal implementation details.
enum EditorTool: Hashable {
    case pen
    case arrow
    case rectangle
    case ellipse
    case text
    case selection
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
        case closeOnly
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
        case cutSelectionToClipboard
        case pasteSelectionInCanvas
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
    private let escapeFinalAction: FinalActionCommand

    // MARK: - Internal model

    fileprivate enum Item {
        case pen(points: [NSPoint], color: NSColor, lineWidth: CGFloat)
        case arrow(start: NSPoint, end: NSPoint, color: NSColor, lineWidth: CGFloat)
        case rect(rect: NSRect, color: NSColor, lineWidth: CGFloat)
        case ellipse(rect: NSRect, color: NSColor, lineWidth: CGFloat)
        case text(TextItem)
        case image(image: NSImage, rect: NSRect)
        case erase(rect: NSRect)
    }

    fileprivate struct TextItem {
        var text: String
        var origin: NSPoint // top-left in view coordinates
        var color: NSColor
        var fontSize: CGFloat
    }

    private var items: [Item] = []
    private var undoStack: [[Item]] = []
    private let maxUndoLevels = 30
    private let annotationStrokeWidth: CGFloat = 4.0
    private let canvasEdgeInset: CGFloat = 24.0
    private let arrowHeadLength: CGFloat = 14.0
    private let arrowHeadAngle: CGFloat = .pi / 6 // 30°
    private var baseImageOrigin: NSPoint = .zero

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
    // Use the editor's initial zoom so newly created text has a stable on-screen size
    // at open (100% vs 200% default start).
    private var textCreationZoomFactor: CGFloat = 1.0

    // Rectangle selection state.
    private var selectionRect: NSRect?
    private var selectionDragStart: NSPoint?
    private var selectionDragCurrent: NSPoint?
    private var isCutSelectionPreview = false

    // In-canvas pasted-image state for quick repositioning workflow.
    private var selectedImageIndex: Int?
    private var selectedItemIndex: Int?
    private var draggingItemIndex: Int?
    private var lastItemDragPoint: NSPoint?
    private var didPushUndoForItemDrag = false
    private var draggingImageIndex: Int?
    private var imageDragOffset: NSPoint = .zero
    private var didPushUndoForImageDrag = false
    private var copiedSelectionImage: NSImage?
    private var copiedSelectionRect: NSRect?
    private var pasteCascadeCount = 0
    private var lastMousePoint: NSPoint?
    private var trackingArea: NSTrackingArea?

    // MARK: - Init

    init(image: NSImage, escapeFinalAction: FinalActionCommand = .deleteOnly, initialState: EditorCanvasState? = nil) {
        self.baseImage = image
        self.escapeFinalAction = escapeFinalAction
        self.baseImageOrigin = NSPoint(x: canvasEdgeInset, y: canvasEdgeInset)
        let frameSize = NSSize(width: image.size.width + canvasEdgeInset * 2,
                               height: image.size.height + canvasEdgeInset * 2)
        let frame = NSRect(origin: .zero, size: frameSize)
        super.init(frame: frame)
        if let initialState {
            self.items = initialState.items.compactMap(Item.init(stateItem:))
            updateCanvasSizeIfNeeded()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Public API (Agent 3 spec)

    func setTool(_ tool: EditorTool) {
        currentTool = tool
        if tool != .text {
            selectedTextIndex = nil
            endTextEditingIfNeeded()
        }
        if tool != .selection {
            selectionDragStart = nil
            selectionDragCurrent = nil
            selectedImageIndex = nil
            selectedItemIndex = nil
            draggingItemIndex = nil
            lastItemDragPoint = nil
            didPushUndoForItemDrag = false
            draggingImageIndex = nil
            didPushUndoForImageDrag = false
        }
        needsDisplay = true
    }

    func setColor(_ color: NSColor) {
        currentColor = color
    }

    func setInitialTextZoomFactor(_ zoomFactor: CGFloat) {
        guard zoomFactor.isFinite, zoomFactor > 0 else { return }
        textCreationZoomFactor = zoomFactor
    }

    /// Ensure the full visible workspace can receive drawing events.
    func ensureDrawableAreaCoversVisibleSize(_ visibleSize: NSSize) {
        let targetWidth = max(frame.size.width, minimumCanvasSize.width, ceil(visibleSize.width))
        let targetHeight = max(frame.size.height, minimumCanvasSize.height, ceil(visibleSize.height))
        let targetSize = NSSize(width: targetWidth, height: targetHeight)
        guard targetSize != frame.size else { return }

        let dx = (targetSize.width - frame.size.width) / 2
        let dy = (targetSize.height - frame.size.height) / 2
        shiftCanvasContent(byX: dx, byY: dy)
        setFrameSize(targetSize)
        needsDisplay = true
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        items = previous
        updateCanvasSizeIfNeeded()
        selectedTextIndex = nil
        selectedImageIndex = nil
        selectedItemIndex = nil
        draggingItemIndex = nil
        lastItemDragPoint = nil
        didPushUndoForItemDrag = false
        draggingImageIndex = nil
        didPushUndoForImageDrag = false
        clearSelectionState()
        needsDisplay = true
    }

    func clearAll() {
        if items.isEmpty {
            _ = clearSelectionIfNeeded()
            return
        }
        pushUndoSnapshot()
        items.removeAll()
        selectedTextIndex = nil
        selectedImageIndex = nil
        selectedItemIndex = nil
        draggingItemIndex = nil
        lastItemDragPoint = nil
        didPushUndoForItemDrag = false
        draggingImageIndex = nil
        didPushUndoForImageDrag = false
        clearSelectionState()
        endTextEditingIfNeeded()
        baseImageOrigin = NSPoint(x: canvasEdgeInset, y: canvasEdgeInset)
        setFrameSize(minimumCanvasSize)
        needsDisplay = true
    }

    func compositeImage() -> NSImage {
        endTextEditingIfNeeded()
        return renderCompositeImage(croppingTo: exportBounds())
    }

    func editableState() -> EditorCanvasState? {
        endTextEditingIfNeeded()
        guard let basePNG = ScreenshotServiceCoreLogic.pngData(from: baseImage) else { return nil }
        return EditorCanvasState(baseImagePNG: basePNG, items: items.compactMap { $0.stateItem })
    }

    @discardableResult
    func selectEditableItem(at point: NSPoint) -> Bool {
        guard let index = hitTestEditableItem(at: point) else { return false }
        selectedImageIndex = nil
        draggingImageIndex = nil
        selectedItemIndex = index
        selectionRect = nil
        selectionDragStart = nil
        selectionDragCurrent = nil
        isCutSelectionPreview = false
        needsDisplay = true
        return true
    }

    /// Renders the currently selected region from the composited image.
    func renderSelectedRegionImage() -> NSImage? {
        guard let rect = clampedSelectionRect else { return nil }
        return renderCompositeImage(croppingTo: rect)
    }

    func selectedRegionPayload() -> (image: NSImage, rect: NSRect)? {
        guard let rect = clampedSelectionRect,
              let image = renderSelectedRegionImage() else {
            return nil
        }
        copiedSelectionImage = image
        copiedSelectionRect = rect
        pasteCascadeCount = 0
        return (image, rect)
    }

    @discardableResult
    func cutSelectedRegion() -> Bool {
        guard let rect = clampedSelectionRect else { return false }
        pushUndoSnapshot()
        items.append(.erase(rect: rect))
        selectionRect = rect
        selectionDragStart = nil
        selectionDragCurrent = nil
        isCutSelectionPreview = true
        updateCanvasSizeIfNeeded()
        needsDisplay = true
        return true
    }

    @discardableResult
    func pasteCopiedSelection() -> Bool {
        guard let image = copiedSelectionImage,
              let sourceRect = copiedSelectionRect else {
            return false
        }
        let targetRect: NSRect
        if let mousePoint = lastMousePoint {
            let centeredOrigin = NSPoint(x: mousePoint.x - sourceRect.width / 2,
                                         y: mousePoint.y - sourceRect.height / 2)
            let proposed = NSRect(origin: centeredOrigin, size: sourceRect.size)
            targetRect = clampedRectToImageBounds(proposed) ?? sourceRect
        } else {
            let offset = CGFloat(12 * pasteCascadeCount)
            targetRect = sourceRect.offsetBy(dx: offset, dy: offset)
        }
        pushUndoSnapshot()
        items.append(.image(image: image, rect: targetRect))
        selectedImageIndex = items.count - 1
        draggingImageIndex = nil
        didPushUndoForImageDrag = false
        selectionRect = nil
        selectionDragStart = nil
        selectionDragCurrent = nil
        isCutSelectionPreview = false
        pasteCascadeCount += 1
        updateCanvasSizeIfNeeded()
        needsDisplay = true
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if baseImageBounds.intersects(dirtyRect) {
            drawBaseImageEdgeSeparation(in: baseImageBounds)
            baseImage.draw(in: baseImageBounds, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }

        for item in items {
            guard let bounds = boundsForItem(item) else { continue }
            if bounds.intersects(dirtyRect) {
                draw(item: item)
            }
        }

        if let selectionRect, selectionRect.intersects(dirtyRect) {
            drawSelectionOutline(selectionRect)
        }

        if let selectedImageIndex,
           case let .image(_, rect) = items[selectedImageIndex],
           rect.intersects(dirtyRect) {
            drawImageSelectionOutline(rect)
        }

        if let selectedItemIndex,
           selectedItemIndex < items.count,
           let rect = boundsForItem(items[selectedItemIndex])?.insetBy(dx: -3, dy: -3),
           rect.intersects(dirtyRect) {
            drawItemSelectionOutline(rect)
        }

        if let index = selectedTextIndex, textEditor == nil {
            if case let .text(textItem) = items[index] {
                let rect = textBounds(for: textItem).insetBy(dx: -2, dy: -2)
                if rect.intersects(dirtyRect) {
                    let path = NSBezierPath(rect: rect)
                    let dash: [CGFloat] = [4, 3]
                    path.setLineDash(dash, count: dash.count, phase: 0)
                    NSColor.white.withAlphaComponent(0.8).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }

        // In-progress shapes
        if let start = dragStartPoint, let current = dragCurrentPoint {
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            switch currentTool {
            case .pen:
                drawPen(points: currentPoints, color: currentColor, lineWidth: annotationStrokeWidth, isPreview: true)
            case .arrow:
                drawArrow(from: start, to: current, color: currentColor, lineWidth: annotationStrokeWidth, isPreview: true)
            case .rectangle:
                let rect = normalizedRect(from: start, to: current, constrain: shiftHeld)
                drawRect(rect, color: currentColor, lineWidth: annotationStrokeWidth, isPreview: true)
            case .ellipse:
                let rect = normalizedRect(from: start, to: current, constrain: shiftHeld)
                drawEllipse(rect, color: currentColor, lineWidth: annotationStrokeWidth, isPreview: true)
            case .text:
                break
            case .selection:
                break
            }
        } else if let start = selectionDragStart, let current = selectionDragCurrent {
            let rect = normalizedRect(from: start, to: current)
            drawSelectionOutline(rect)
        } else if currentTool == .pen && !currentPoints.isEmpty {
            drawPen(points: currentPoints, color: currentColor, lineWidth: annotationStrokeWidth, isPreview: true)
        }
    }

    /// Keep screenshot edges visible against both light and dark native backgrounds.
    private func drawBaseImageEdgeSeparation(in rect: NSRect) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let borderRect = rect.insetBy(dx: -0.5, dy: -0.5)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        let path = NSBezierPath(rect: borderRect)
        path.lineWidth = 1
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelectionOutline(_ rect: NSRect) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        if isCutSelectionPreview {
            NSColor.white.withAlphaComponent(0.16).setFill()
            rect.fill()
        }
        let path = NSBezierPath(rect: rect)
        let dash: [CGFloat] = [6, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        let strokeColor = isCutSelectionPreview
            ? NSColor.systemOrange.withAlphaComponent(0.95)
            : NSColor.white.withAlphaComponent(0.92)
        strokeColor.setStroke()
        path.lineWidth = 2
        path.stroke()
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
        case .image(let image, let rect):
            drawImage(image, in: rect)
        case .erase(let rect):
            drawErase(rect)
        }
    }

    private func drawImage(_ image: NSImage, in rect: NSRect) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
    }

    private func drawImageSelectionOutline(_ rect: NSRect) {
        drawItemSelectionOutline(rect)
    }

    private func drawItemSelectionOutline(_ rect: NSRect) {
        let outlineRect = rect.insetBy(dx: -2, dy: -2)
        guard outlineRect.width >= 1, outlineRect.height >= 1 else { return }
        let path = NSBezierPath(rect: outlineRect)
        let dash: [CGFloat] = [5, 3]
        path.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.systemOrange.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawErase(_ rect: NSRect) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        // destinationOut uses source alpha; use an opaque source to actually clear.
        NSColor.black.setFill()
        rect.fill(using: .destinationOut)
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

        let tip = end
        let point1 = NSPoint(x: tip.x - arrowHeadLength * cos(angle - arrowHeadAngle),
                             y: tip.y - arrowHeadLength * sin(angle - arrowHeadAngle))
        let point2 = NSPoint(x: tip.x - arrowHeadLength * cos(angle + arrowHeadAngle),
                             y: tip.y - arrowHeadLength * sin(angle + arrowHeadAngle))

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

    private var defaultTextFontSize: CGFloat {
        let targetOnScreenSize: CGFloat = 38.4
        let normalizedZoom = max(0.01, textCreationZoomFactor)
        return round(targetOnScreenSize / normalizedZoom)
    }

    // MARK: - Geometry helpers

    private var baseImageBounds: NSRect {
        NSRect(x: baseImageOrigin.x, y: baseImageOrigin.y, width: baseImage.size.width, height: baseImage.size.height)
    }

    private var minimumCanvasSize: NSSize {
        NSSize(width: baseImage.size.width + canvasEdgeInset * 2,
               height: baseImage.size.height + canvasEdgeInset * 2)
    }

    private func normalizedRect(_ rect: NSRect) -> NSRect {
        let minX = floor(rect.minX)
        let minY = floor(rect.minY)
        let maxX = ceil(rect.maxX)
        let maxY = ceil(rect.maxY)
        return NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func shiftedPoint(_ point: NSPoint, byX dx: CGFloat, byY dy: CGFloat) -> NSPoint {
        NSPoint(x: point.x + dx, y: point.y + dy)
    }

    private func shiftedRect(_ rect: NSRect, byX dx: CGFloat, byY dy: CGFloat) -> NSRect {
        NSRect(x: rect.origin.x + dx, y: rect.origin.y + dy, width: rect.width, height: rect.height)
    }

    private func shiftedItems(_ source: [Item], byX dx: CGFloat, byY dy: CGFloat) -> [Item] {
        source.map { item in
            switch item {
            case .pen(let points, let color, let lineWidth):
                return .pen(points: points.map { shiftedPoint($0, byX: dx, byY: dy) }, color: color, lineWidth: lineWidth)
            case .arrow(let start, let end, let color, let lineWidth):
                return .arrow(start: shiftedPoint(start, byX: dx, byY: dy),
                              end: shiftedPoint(end, byX: dx, byY: dy),
                              color: color,
                              lineWidth: lineWidth)
            case .rect(let rect, let color, let lineWidth):
                return .rect(rect: shiftedRect(rect, byX: dx, byY: dy), color: color, lineWidth: lineWidth)
            case .ellipse(let rect, let color, let lineWidth):
                return .ellipse(rect: shiftedRect(rect, byX: dx, byY: dy), color: color, lineWidth: lineWidth)
            case .text(var textItem):
                textItem.origin = shiftedPoint(textItem.origin, byX: dx, byY: dy)
                return .text(textItem)
            case .image(let image, let rect):
                return .image(image: image, rect: shiftedRect(rect, byX: dx, byY: dy))
            case .erase(let rect):
                return .erase(rect: shiftedRect(rect, byX: dx, byY: dy))
            }
        }
    }

    private func shiftCanvasContent(byX dx: CGFloat, byY dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }

        baseImageOrigin = shiftedPoint(baseImageOrigin, byX: dx, byY: dy)
        items = shiftedItems(items, byX: dx, byY: dy)
        undoStack = undoStack.map { shiftedItems($0, byX: dx, byY: dy) }

        if let point = dragStartPoint {
            dragStartPoint = shiftedPoint(point, byX: dx, byY: dy)
        }
        if let point = dragCurrentPoint {
            dragCurrentPoint = shiftedPoint(point, byX: dx, byY: dy)
        }
        currentPoints = currentPoints.map { shiftedPoint($0, byX: dx, byY: dy) }

        if let point = selectionDragStart {
            selectionDragStart = shiftedPoint(point, byX: dx, byY: dy)
        }
        if let point = selectionDragCurrent {
            selectionDragCurrent = shiftedPoint(point, byX: dx, byY: dy)
        }
        if let rect = selectionRect {
            selectionRect = shiftedRect(rect, byX: dx, byY: dy)
        }

        if let rect = copiedSelectionRect {
            copiedSelectionRect = shiftedRect(rect, byX: dx, byY: dy)
        }
        if let point = lastMousePoint {
            lastMousePoint = shiftedPoint(point, byX: dx, byY: dy)
        }

        if let editor = textEditor {
            editor.frame = shiftedRect(editor.frame, byX: dx, byY: dy)
        }
    }

    private func moveItem(at index: Int, byX dx: CGFloat, byY dy: CGFloat) {
        guard index < items.count, dx != 0 || dy != 0 else { return }

        switch items[index] {
        case .pen(let points, let color, let lineWidth):
            items[index] = .pen(points: points.map { shiftedPoint($0, byX: dx, byY: dy) },
                                color: color,
                                lineWidth: lineWidth)
        case .arrow(let start, let end, let color, let lineWidth):
            items[index] = .arrow(start: shiftedPoint(start, byX: dx, byY: dy),
                                  end: shiftedPoint(end, byX: dx, byY: dy),
                                  color: color,
                                  lineWidth: lineWidth)
        case .rect(let rect, let color, let lineWidth):
            items[index] = .rect(rect: shiftedRect(rect, byX: dx, byY: dy),
                                 color: color,
                                 lineWidth: lineWidth)
        case .ellipse(let rect, let color, let lineWidth):
            items[index] = .ellipse(rect: shiftedRect(rect, byX: dx, byY: dy),
                                    color: color,
                                    lineWidth: lineWidth)
        case .text(var textItem):
            textItem.origin = shiftedPoint(textItem.origin, byX: dx, byY: dy)
            items[index] = .text(textItem)
        case .image(let image, let rect):
            items[index] = .image(image: image, rect: shiftedRect(rect, byX: dx, byY: dy))
        case .erase(let rect):
            items[index] = .erase(rect: shiftedRect(rect, byX: dx, byY: dy))
        }
    }

    private func boundsForPoints(_ points: [NSPoint], padding: CGFloat) -> NSRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return NSRect(x: minX - padding,
                      y: minY - padding,
                      width: (maxX - minX) + (padding * 2),
                      height: (maxY - minY) + (padding * 2))
    }

    private func boundsForArrow(start: NSPoint, end: NSPoint, lineWidth: CGFloat) -> NSRect {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let wing1 = NSPoint(x: end.x - arrowHeadLength * cos(angle - arrowHeadAngle),
                            y: end.y - arrowHeadLength * sin(angle - arrowHeadAngle))
        let wing2 = NSPoint(x: end.x - arrowHeadLength * cos(angle + arrowHeadAngle),
                            y: end.y - arrowHeadLength * sin(angle + arrowHeadAngle))
        let minX = min(start.x, end.x, wing1.x, wing2.x)
        let minY = min(start.y, end.y, wing1.y, wing2.y)
        let maxX = max(start.x, end.x, wing1.x, wing2.x)
        let maxY = max(start.y, end.y, wing1.y, wing2.y)
        let padding = lineWidth / 2
        return NSRect(x: minX - padding,
                      y: minY - padding,
                      width: (maxX - minX) + (padding * 2),
                      height: (maxY - minY) + (padding * 2))
    }

    private func boundsForItem(_ item: Item) -> NSRect? {
        switch item {
        case .pen(let points, _, let lineWidth):
            return boundsForPoints(points, padding: lineWidth / 2)
        case .arrow(let start, let end, _, let lineWidth):
            guard distance(from: start, to: end) >= 2 else { return nil }
            return boundsForArrow(start: start, end: end, lineWidth: lineWidth)
        case .rect(let rect, _, let lineWidth):
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .ellipse(let rect, _, let lineWidth):
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .text(let textItem):
            return textBounds(for: textItem)
        case .image(_, let rect):
            return rect
        case .erase(let rect):
            return rect
        }
    }

    private func exportBounds() -> NSRect {
        var unionRect = baseImageBounds
        for item in items {
            guard let itemBounds = boundsForItem(item) else { continue }
            unionRect = unionRect.union(itemBounds)
        }
        return normalizedRect(unionRect)
    }

    private func renderCompositeImage(croppingTo cropRect: NSRect) -> NSImage {
        let normalizedCrop = normalizedRect(cropRect)

        // Render at the base image's native pixel resolution rather than the
        // screen's backing scale. `NSImage.lockFocus` rasterizes at the current
        // screen scale (2x on Retina), which silently doubled every image that
        // passed through the editor. Drawing into an explicit bitmap keeps the
        // edited image at the same resolution it came in with.
        let pixelScale = baseImagePixelScale()
        let pixelWidth = max(1, Int((normalizedCrop.width * pixelScale).rounded()))
        let pixelHeight = max(1, Int((normalizedCrop.height * pixelScale).rounded()))

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelWidth,
                                         pixelsHigh: pixelHeight,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: normalizedCrop.size)
        }
        // Map the point-sized canvas coordinates onto the pixel-sized backing.
        rep.size = normalizedCrop.size

        // Reproduce the canvas view's flipped (top-left origin) coordinate space
        // so the base image and annotations render exactly as they do on screen.
        let context = NSGraphicsContext(cgContext: bitmapContext.cgContext, flipped: true)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: normalizedCrop.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: normalizedCrop.size).fill()

        let translation = NSAffineTransform()
        translation.translateX(by: -normalizedCrop.minX, yBy: -normalizedCrop.minY)
        translation.concat()

        baseImage.draw(in: baseImageBounds,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0,
                       respectFlipped: true,
                       hints: nil)

        for item in items {
            draw(item: item)
        }

        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: normalizedCrop.size)
        result.addRepresentation(rep)
        return result
    }

    /// Points-to-pixels ratio of the base image, so edited output keeps the
    /// screenshot's native resolution instead of the screen's backing scale.
    private func baseImagePixelScale() -> CGFloat {
        let pointWidth = baseImage.size.width
        guard pointWidth > 0 else { return 1 }
        let scale = baseImagePixelSize().width / pointWidth
        return scale > 0 ? scale : 1
    }

    private func baseImagePixelSize() -> NSSize {
        let largest = baseImage.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        if let largest {
            return NSSize(width: CGFloat(largest.pixelsWide), height: CGFloat(largest.pixelsHigh))
        }
        return baseImage.size
    }

    private var clampedSelectionRect: NSRect? {
        guard let selectionRect else { return nil }
        let clipped = selectionRect.intersection(baseImageBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }

        let minX = max(baseImageBounds.minX, floor(clipped.minX))
        let minY = max(baseImageBounds.minY, floor(clipped.minY))
        let maxX = min(baseImageBounds.maxX, ceil(clipped.maxX))
        let maxY = min(baseImageBounds.maxY, ceil(clipped.maxY))
        guard maxX > minX, maxY > minY else { return nil }

        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clearSelectionState() {
        selectionRect = nil
        selectionDragStart = nil
        selectionDragCurrent = nil
        isCutSelectionPreview = false
    }

    private func clearSelectionIfNeeded() -> Bool {
        guard selectionRect != nil else { return false }
        clearSelectionState()
        needsDisplay = true
        return true
    }

    private func clampedRectToImageBounds(_ rect: NSRect) -> NSRect? {
        let size = rect.size
        guard size.width > 0, size.height > 0 else { return nil }
        guard size.width <= baseImageBounds.width, size.height <= baseImageBounds.height else { return nil }

        let minX = baseImageBounds.minX
        let minY = baseImageBounds.minY
        let maxX = baseImageBounds.maxX - size.width
        let maxY = baseImageBounds.maxY - size.height

        let clampedX = min(max(rect.origin.x, minX), maxX)
        let clampedY = min(max(rect.origin.y, minY), maxY)
        return NSRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
    }

    private func normalizedRect(from p1: NSPoint, to p2: NSPoint, constrain: Bool = false) -> NSRect {
        var dx = p2.x - p1.x
        var dy = p2.y - p1.y
        if constrain {
            let side = max(abs(dx), abs(dy))
            dx = dx >= 0 ? side : -side
            dy = dy >= 0 ? side : -side
        }
        let end = NSPoint(x: p1.x + dx, y: p1.y + dy)
        let minX = min(p1.x, end.x)
        let maxX = max(p1.x, end.x)
        let minY = min(p1.y, end.y)
        let maxY = max(p1.y, end.y)
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func distance(from p1: NSPoint, to p2: NSPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }

    private func distance(from point: NSPoint, toSegmentStart start: NSPoint, end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(from: point, to: start) }

        let progress = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let clampedProgress = max(0, min(1, progress))
        let projection = NSPoint(x: start.x + clampedProgress * dx,
                                 y: start.y + clampedProgress * dy)
        return distance(from: point, to: projection)
    }

    private func pushUndoSnapshot() {
        if undoStack.count >= maxUndoLevels {
            undoStack.removeFirst()
        }
        undoStack.append(items)
    }

    /// Ensure the canvas is large enough to contain the base image and all annotations.
    private func updateCanvasSizeIfNeeded() {
        var unionRect = baseImageBounds

        for item in items {
            guard let itemBounds = boundsForItem(item) else { continue }
            unionRect = unionRect.union(itemBounds)
        }

        let newWidth = max(unionRect.maxX, minimumCanvasSize.width, frame.size.width)
        let newHeight = max(unionRect.maxY, minimumCanvasSize.height, frame.size.height)
        let newSize = NSSize(width: ceil(newWidth), height: ceil(newHeight))

        if newSize != frame.size {
            setFrameSize(newSize)
            needsDisplay = true
        }
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point

        if currentTool == .selection {
            selectedTextIndex = nil
            endTextEditingIfNeeded()
            if let (index, rect) = hitTestImage(at: point) {
                selectedImageIndex = index
                selectedItemIndex = nil
                draggingItemIndex = nil
                lastItemDragPoint = nil
                didPushUndoForItemDrag = false
                draggingImageIndex = index
                imageDragOffset = NSPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
                didPushUndoForImageDrag = false
                selectionRect = nil
                selectionDragStart = nil
                selectionDragCurrent = nil
                isCutSelectionPreview = false
                needsDisplay = true
                return
            }
            selectedImageIndex = nil
            draggingImageIndex = nil
            if selectEditableItem(at: point) {
                draggingItemIndex = selectedItemIndex
                lastItemDragPoint = point
                didPushUndoForItemDrag = false
                return
            }
            selectedItemIndex = nil
            draggingItemIndex = nil
            lastItemDragPoint = nil
            didPushUndoForItemDrag = false
            selectionRect = nil
            selectionDragStart = point
            selectionDragCurrent = point
            isCutSelectionPreview = false
            needsDisplay = true
            return
        }

        if currentTool == .text {
            let clickCount = event.clickCount

            if let (index, rect) = hitTestText(at: point) {
                selectedTextIndex = index
                selectedItemIndex = nil
                draggingItemIndex = nil
                lastItemDragPoint = nil
                didPushUndoForItemDrag = false
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
                selectedItemIndex = nil
                draggingItemIndex = nil
                lastItemDragPoint = nil
                didPushUndoForItemDrag = false
                endTextEditingIfNeeded()

                let item = TextItem(text: "", origin: point, color: currentColor, fontSize: defaultTextFontSize)
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
        selectedItemIndex = nil
        draggingItemIndex = nil
        lastItemDragPoint = nil
        didPushUndoForItemDrag = false
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
        lastMousePoint = point

        if currentTool == .selection {
            if let index = draggingImageIndex {
                if !didPushUndoForImageDrag {
                    pushUndoSnapshot()
                    didPushUndoForImageDrag = true
                }
                if case let .image(image, oldRect) = items[index] {
                    let newOrigin = NSPoint(x: point.x - imageDragOffset.x, y: point.y - imageDragOffset.y)
                    let newRect = NSRect(origin: newOrigin, size: oldRect.size)
                    items[index] = .image(image: image, rect: newRect)
                    needsDisplay = true
                }
                return
            }
            if let index = draggingItemIndex, index < items.count, let lastPoint = lastItemDragPoint {
                if !didPushUndoForItemDrag {
                    pushUndoSnapshot()
                    didPushUndoForItemDrag = true
                }
                moveItem(at: index, byX: point.x - lastPoint.x, byY: point.y - lastPoint.y)
                lastItemDragPoint = point
                needsDisplay = true
                return
            }
            guard selectionDragStart != nil else { return }
            selectionDragCurrent = point
            needsDisplay = true
            return
        }

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

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if dragStartPoint != nil && (currentTool == .rectangle || currentTool == .ellipse) {
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point

        if currentTool == .selection {
            if draggingImageIndex != nil {
                draggingImageIndex = nil
                selectedItemIndex = nil
                didPushUndoForImageDrag = false
                updateCanvasSizeIfNeeded()
                needsDisplay = true
                return
            }
            if draggingItemIndex != nil {
                draggingItemIndex = nil
                lastItemDragPoint = nil
                didPushUndoForItemDrag = false
                updateCanvasSizeIfNeeded()
                needsDisplay = true
                return
            }
            guard let start = selectionDragStart else { return }
            selectionDragCurrent = point
            let rect = normalizedRect(from: start, to: point)
            selectionDragStart = nil
            selectionDragCurrent = nil
            selectionRect = rect.width >= 2 && rect.height >= 2 ? rect : nil
            if let clampedRect = clampedSelectionRect {
                selectionRect = clampedRect
            } else {
                selectionRect = nil
            }
            isCutSelectionPreview = false
            needsDisplay = true
            return
        }

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
                items.append(.pen(points: currentPoints, color: currentColor, lineWidth: annotationStrokeWidth))
                updateCanvasSizeIfNeeded()
            }
        case .arrow:
            if distance(from: start, to: point) >= 2 {
                pushUndoSnapshot()
                items.append(.arrow(start: start, end: point, color: currentColor, lineWidth: annotationStrokeWidth))
                updateCanvasSizeIfNeeded()
            }
        case .rectangle:
            let shiftHeld = event.modifierFlags.contains(.shift)
            let rect = normalizedRect(from: start, to: point, constrain: shiftHeld)
            if rect.width >= 2, rect.height >= 2 {
                pushUndoSnapshot()
                items.append(.rect(rect: rect, color: currentColor, lineWidth: annotationStrokeWidth))
                updateCanvasSizeIfNeeded()
            }
        case .ellipse:
            let shiftHeld = event.modifierFlags.contains(.shift)
            let rect = normalizedRect(from: start, to: point, constrain: shiftHeld)
            if rect.width >= 2, rect.height >= 2 {
                pushUndoSnapshot()
                items.append(.ellipse(rect: rect, color: currentColor, lineWidth: annotationStrokeWidth))
                updateCanvasSizeIfNeeded()
            }
        case .text:
            break
        case .selection:
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

    private func hitTestImage(at point: NSPoint) -> (Int, NSRect)? {
        for index in items.indices.reversed() {
            guard case let .image(_, rect) = items[index] else { continue }
            if rect.insetBy(dx: -3, dy: -3).contains(point) {
                return (index, rect)
            }
        }
        return nil
    }

    private func hitTestEditableItem(at point: NSPoint) -> Int? {
        for index in items.indices.reversed() {
            guard !isImageItem(items[index]),
                  hitTest(item: items[index], at: point) else {
                continue
            }
            return index
        }
        return nil
    }

    private func hitTest(item: Item, at point: NSPoint) -> Bool {
        switch item {
        case .pen(let points, _, let lineWidth):
            return hitTestPolyline(points, at: point, tolerance: selectionTolerance(for: lineWidth))
        case .arrow(let start, let end, _, let lineWidth):
            return hitTestArrow(start: start, end: end, at: point, tolerance: selectionTolerance(for: lineWidth))
        case .rect(let rect, _, let lineWidth):
            return hitTestRectStroke(rect, at: point, tolerance: selectionTolerance(for: lineWidth))
        case .ellipse(let rect, _, let lineWidth):
            return hitTestEllipseStroke(rect, at: point, tolerance: selectionTolerance(for: lineWidth))
        case .text(let textItem):
            return textBounds(for: textItem).insetBy(dx: -4, dy: -4).contains(point)
        case .image(_, let rect):
            return rect.insetBy(dx: -3, dy: -3).contains(point)
        case .erase(let rect):
            return rect.insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    private func selectionTolerance(for lineWidth: CGFloat) -> CGFloat {
        max(8, lineWidth + 4)
    }

    private func hitTestPolyline(_ points: [NSPoint], at point: NSPoint, tolerance: CGFloat) -> Bool {
        guard points.count > 1 else { return false }
        for index in 1..<points.count {
            if distance(from: point, toSegmentStart: points[index - 1], end: points[index]) <= tolerance {
                return true
            }
        }
        return false
    }

    private func hitTestArrow(start: NSPoint, end: NSPoint, at point: NSPoint, tolerance: CGFloat) -> Bool {
        guard distance(from: start, to: end) >= 2 else { return false }
        if distance(from: point, toSegmentStart: start, end: end) <= tolerance {
            return true
        }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)
        let point1 = NSPoint(x: end.x - arrowHeadLength * cos(angle - arrowHeadAngle),
                             y: end.y - arrowHeadLength * sin(angle - arrowHeadAngle))
        let point2 = NSPoint(x: end.x - arrowHeadLength * cos(angle + arrowHeadAngle),
                             y: end.y - arrowHeadLength * sin(angle + arrowHeadAngle))
        return distance(from: point, toSegmentStart: end, end: point1) <= tolerance
            || distance(from: point, toSegmentStart: end, end: point2) <= tolerance
    }

    private func hitTestRectStroke(_ rect: NSRect, at point: NSPoint, tolerance: CGFloat) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard outer.contains(point) else { return false }
        let inner = rect.insetBy(dx: tolerance, dy: tolerance)
        guard inner.width > 0, inner.height > 0 else { return true }
        return !inner.contains(point)
    }

    private func hitTestEllipseStroke(_ rect: NSRect, at point: NSPoint, tolerance: CGFloat) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        guard radiusX > 0, radiusY > 0 else { return false }

        let normalizedX = (point.x - center.x) / radiusX
        let normalizedY = (point.y - center.y) / radiusY
        let value = normalizedX * normalizedX + normalizedY * normalizedY
        let maxRadius = max(radiusX, radiusY)
        let band = max(0.08, tolerance / maxRadius)
        let inner = max(0, 1 - band)
        let outer = 1 + band
        return value >= inner * inner && value <= outer * outer
    }

    private func isImageItem(_ item: Item) -> Bool {
        if case .image = item {
            return true
        }
        return false
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
        let font = editor.font ?? NSFont.systemFont(ofSize: defaultTextFontSize, weight: .regular)
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

    private func deleteSelectedImageIfNeeded() -> Bool {
        guard let index = selectedImageIndex else { return false }
        guard case .image = items[index] else { return false }
        pushUndoSnapshot()
        items.remove(at: index)
        selectedImageIndex = nil
        draggingImageIndex = nil
        didPushUndoForImageDrag = false
        updateCanvasSizeIfNeeded()
        needsDisplay = true
        return true
    }

    private func deleteSelectedItemIfNeeded() -> Bool {
        guard let index = selectedItemIndex, index < items.count else { return false }
        pushUndoSnapshot()
        items.remove(at: index)
        selectedItemIndex = nil
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
            if let index = Self.colorPickerKeyCodeToColorIndex[event.keyCode] {
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
                case "s":
                    onKeyCommand?(.selectTool(.selection))
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
            case "x":
                onKeyCommand?(.cutSelectionToClipboard)
                return
            case "v":
                onKeyCommand?(.pasteSelectionInCanvas)
                return
            default:
                break
            }
        }

        if event.keyCode == 53, clearSelectionIfNeeded() {
            return
        }

        if let final = interpretFinalActionCommand(from: event, flags: flags) {
            onKeyCommand?(.finalAction(final))
            return
        }

        if event.keyCode == 48 && flags.contains(.shift) { // Shift+Tab
            onKeyCommand?(.backToNote)
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            if deleteSelectedImageIfNeeded() { return }
            if deleteSelectedItemIfNeeded() { return }
            if deleteSelectedTextIfNeeded() { return }
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd-based key equivalents can be intercepted by the window/menu before keyDown.
        // Handle copy/cut here so shortcuts work reliably in the canvas.
        if textEditor != nil {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command],
              let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch chars {
        case "c":
            onKeyCommand?(.copyToClipboard)
            return true
        case "x":
            onKeyCommand?(.cutSelectionToClipboard)
            return true
        case "v":
            onKeyCommand?(.pasteSelectionInCanvas)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard textEditor == nil else { return }
        onKeyCommand?(.copyToClipboard)
    }

    @objc func cut(_ sender: Any?) {
        guard textEditor == nil else { return }
        onKeyCommand?(.cutSelectionToClipboard)
    }

    @objc func paste(_ sender: Any?) {
        guard textEditor == nil else { return }
        onKeyCommand?(.pasteSelectionInCanvas)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)

        if event.magnification > 0 {
            onKeyCommand?(.zoomIn)
        } else if event.magnification < 0 {
            onKeyCommand?(.zoomOut)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        lastMousePoint = convert(event.locationInWindow, from: nil)
        super.mouseMoved(with: event)
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
            return escapeFinalAction
        default:
            break
        }

        return nil
    }

    // Use hardware key codes so 1-6 selection works regardless of the active keyboard layout.
    private static let colorPickerKeyCodeToColorIndex: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 0,
        UInt16(kVK_ANSI_2): 1,
        UInt16(kVK_ANSI_3): 2,
        UInt16(kVK_ANSI_4): 3,
        UInt16(kVK_ANSI_5): 4,
        UInt16(kVK_ANSI_6): 5,
        UInt16(kVK_ANSI_Keypad1): 0,
        UInt16(kVK_ANSI_Keypad2): 1,
        UInt16(kVK_ANSI_Keypad3): 2,
        UInt16(kVK_ANSI_Keypad4): 3,
        UInt16(kVK_ANSI_Keypad5): 4,
        UInt16(kVK_ANSI_Keypad6): 5
    ]
}

private extension EditorCanvasView.Item {
    init?(stateItem: EditorCanvasState.Item) {
        switch stateItem {
        case .pen(let points, let color, let lineWidth):
            self = .pen(points: points.map(\.nsPoint), color: color.nsColor, lineWidth: lineWidth)
        case .arrow(let start, let end, let color, let lineWidth):
            self = .arrow(start: start.nsPoint, end: end.nsPoint, color: color.nsColor, lineWidth: lineWidth)
        case .rect(let rect, let color, let lineWidth):
            self = .rect(rect: rect.nsRect, color: color.nsColor, lineWidth: lineWidth)
        case .ellipse(let rect, let color, let lineWidth):
            self = .ellipse(rect: rect.nsRect, color: color.nsColor, lineWidth: lineWidth)
        case .text(let text):
            let item = EditorCanvasView.TextItem(text: text.text,
                                                 origin: text.origin.nsPoint,
                                                 color: text.color.nsColor,
                                                 fontSize: text.fontSize)
            self = .text(item)
        case .image(let pngData, let rect):
            guard let image = NSImage(data: pngData) else { return nil }
            self = .image(image: image, rect: rect.nsRect)
        case .erase(let rect):
            self = .erase(rect: rect.nsRect)
        }
    }

    var stateItem: EditorCanvasState.Item? {
        switch self {
        case .pen(let points, let color, let lineWidth):
            return .pen(points: points.map(EditorCanvasState.Point.init),
                        color: EditorCanvasState.Color(color),
                        lineWidth: lineWidth)
        case .arrow(let start, let end, let color, let lineWidth):
            return .arrow(start: EditorCanvasState.Point(start),
                          end: EditorCanvasState.Point(end),
                          color: EditorCanvasState.Color(color),
                          lineWidth: lineWidth)
        case .rect(let rect, let color, let lineWidth):
            return .rect(rect: EditorCanvasState.Rect(rect),
                         color: EditorCanvasState.Color(color),
                         lineWidth: lineWidth)
        case .ellipse(let rect, let color, let lineWidth):
            return .ellipse(rect: EditorCanvasState.Rect(rect),
                            color: EditorCanvasState.Color(color),
                            lineWidth: lineWidth)
        case .text(let text):
            return .text(EditorCanvasState.Text(text: text.text,
                                                origin: EditorCanvasState.Point(text.origin),
                                                color: EditorCanvasState.Color(text.color),
                                                fontSize: text.fontSize))
        case .image(let image, let rect):
            guard let pngData = ScreenshotServiceCoreLogic.pngData(from: image) else { return nil }
            return .image(pngData: pngData, rect: EditorCanvasState.Rect(rect))
        case .erase(let rect):
            return .erase(rect: EditorCanvasState.Rect(rect))
        }
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
