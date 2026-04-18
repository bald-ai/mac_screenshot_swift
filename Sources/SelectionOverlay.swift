import AppKit

protocol SelectionOverlayDelegate: AnyObject {
    func selectionOverlay(_ overlay: SelectionOverlay,
                          didFinishWith rectInScreenCoordinates: CGRect?,
                          onScreen screen: NSScreen)
}

/// Full-screen transparent overlay for drag-to-select area capture.
final class SelectionOverlay: NSObject {
    weak var delegate: SelectionOverlayDelegate?

    private var screen: NSScreen?
    private var window: SelectionOverlayWindow?
    private var selectionView: SelectionOverlayView?
    private var screenParametersObserver: NSObjectProtocol?

    private(set) var isActive = false

    override init() {
        super.init()

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateCachedOverlay()
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func beginSelection() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginSelection()
            }
            return
        }

        guard !isActive else {
            return
        }

        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            return
        }

        let overlayWindow = buildOverlayIfNeeded(for: targetScreen)
        guard let selectionView else {
            return
        }

        screen = targetScreen
        overlayWindow.setFrame(targetScreen.frame, display: false)
        selectionView.frame = CGRect(origin: .zero, size: targetScreen.frame.size)
        selectionView.prepareForSelection(backingScaleFactor: targetScreen.backingScaleFactor)
        selectionView.pushCursorIfNeeded()
        overlayWindow.orderFront(nil)
        overlayWindow.makeKey()
        overlayWindow.makeFirstResponder(selectionView)
        isActive = true
    }

    func cancelSelection() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.cancelSelection()
            }
            return
        }

        finish(with: nil)
    }

    private func buildOverlayIfNeeded(for screen: NSScreen) -> SelectionOverlayWindow {
        if let window {
            return window
        }

        let overlayWindow = SelectionOverlayWindow(contentRect: .zero,
                                                   styleMask: [.borderless],
                                                   backing: .buffered,
                                                   defer: false,
                                                   screen: screen)
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.level = .screenSaver
        overlayWindow.ignoresMouseEvents = false
        overlayWindow.hasShadow = false
        overlayWindow.acceptsMouseMovedEvents = true
        overlayWindow.collectionBehavior = [.fullScreenAuxiliary]

        let overlayView = SelectionOverlayView(frame: .zero)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.onComplete = { [weak self] rectInView in
            self?.finish(with: rectInView)
        }

        overlayWindow.contentView = overlayView
        window = overlayWindow
        selectionView = overlayView
        return overlayWindow
    }

    private func finish(with rectInView: CGRect?) {
        guard let currentScreen = screen else {
            tearDown()
            return
        }

        var rectInScreenCoordinates: CGRect?
        if let rectInView, let window {
            let rectInWindow = selectionView?.convert(rectInView, to: nil) ?? rectInView
            let selectionRect = window.convertToScreen(rectInWindow)
            let minimumSizePoints: CGFloat = 5
            if selectionRect.width >= minimumSizePoints && selectionRect.height >= minimumSizePoints {
                rectInScreenCoordinates = selectionRect
            }
        }

        tearDown()
        delegate?.selectionOverlay(self, didFinishWith: rectInScreenCoordinates, onScreen: currentScreen)
    }

    private func tearDown() {
        selectionView?.releaseCursor()
        window?.orderOut(nil)
        selectionView?.resetSelectionState()
        screen = nil
        isActive = false
    }

    private func invalidateCachedOverlay() {
        selectionView?.releaseCursor()
        window?.orderOut(nil)
        screen = nil
        isActive = false
        window = nil
        selectionView = nil
    }
}

private final class SelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionOverlayView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    var backingScaleFactor: CGFloat = 1

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var cursorPushed = false
    private var hasDrawn = false

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func prepareForSelection(backingScaleFactor: CGFloat) {
        self.backingScaleFactor = backingScaleFactor
        resetSelectionState()
        needsDisplay = true
    }

    func resetSelectionState() {
        startPoint = nil
        currentPoint = nil
        hasDrawn = false
    }

    func pushCursorIfNeeded() {
        guard !cursorPushed else {
            return
        }

        NSCursor.crosshair.push()
        cursorPushed = true
        window?.invalidateCursorRects(for: self)
    }

    func releaseCursor() {
        guard cursorPushed else {
            return
        }

        NSCursor.pop()
        cursorPushed = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        hasDrawn = true

        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()

        if let rect = currentSelectionRect {
            NSColor.clear.setFill()
            rect.fill(using: .destinationOut)

            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()

            drawDimensions(for: rect)
        } else {
            drawInstructions()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else {
            return
        }

        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onComplete?(currentSelectionRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onComplete?(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onComplete?(nil)
        case 36:
            onComplete?(currentSelectionRect)
        default:
            super.keyDown(with: event)
        }
    }

    private var currentSelectionRect: CGRect? {
        guard let startPoint, let currentPoint else {
            return nil
        }

        let minX = min(startPoint.x, currentPoint.x)
        let minY = min(startPoint.y, currentPoint.y)
        let width = abs(currentPoint.x - startPoint.x)
        let height = abs(currentPoint.y - startPoint.y)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private func drawInstructions() {
        let text = "Drag to select area, Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        var fullAttributes = attributes
        fullAttributes[.shadow] = shadow

        let size = (text as NSString).size(withAttributes: fullAttributes)
        let point = CGPoint(x: bounds.midX - size.width / 2,
                            y: bounds.midY - size.height / 2)
        (text as NSString).draw(at: point, withAttributes: fullAttributes)
    }

    private func drawDimensions(for rect: CGRect) {
        let widthPixels = Int((rect.width * backingScaleFactor).rounded())
        let heightPixels = Int((rect.height * backingScaleFactor).rounded())
        guard widthPixels > 0, heightPixels > 0 else {
            return
        }

        let text = "\(widthPixels) x \(heightPixels)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 4
        var origin = CGPoint(x: rect.origin.x + 8,
                             y: rect.maxY - size.height - 8)

        if origin.x + size.width + 2 * padding > bounds.maxX {
            origin.x = bounds.maxX - size.width - 2 * padding
        }
        if origin.y + size.height + 2 * padding > bounds.maxY {
            origin.y = bounds.maxY - size.height - 2 * padding
        }

        let backgroundRect = CGRect(x: origin.x - padding,
                                    y: origin.y - padding,
                                    width: size.width + 2 * padding,
                                    height: size.height + 2 * padding)
        NSColor.black.withAlphaComponent(0.6).setFill()
        backgroundRect.fill()

        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
