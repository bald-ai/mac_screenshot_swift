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
    private var window: NSWindow?
    private var selectionView: SelectionOverlayView?

    func beginSelection() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginSelection()
            }
            return
        }

        ScreenshotService.dbg("beginSelection: START — window=\(window != nil) NSApp.isActive=\(NSApp.isActive)")

        guard window == nil else {
            ScreenshotService.dbg("beginSelection: BAIL — window already exists")
            return
        }

        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            ScreenshotService.dbg("beginSelection: BAIL — no screen found")
            return
        }

        screen = targetScreen
        ScreenshotService.dbg("beginSelection: target screen: \(targetScreen.frame)")

        let overlayWindow = SelectionOverlayWindow(contentRect: targetScreen.frame,
                                                   styleMask: [.borderless],
                                                   backing: .buffered,
                                                   defer: false,
                                                   screen: targetScreen)
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.level = .screenSaver
        overlayWindow.ignoresMouseEvents = false
        overlayWindow.hasShadow = false
        overlayWindow.acceptsMouseMovedEvents = true
        overlayWindow.collectionBehavior = [.fullScreenAuxiliary]

        let overlayView = SelectionOverlayView(frame: overlayWindow.contentView?.bounds ?? .zero)
        overlayView.autoresizingMask = [.width, .height]
        overlayView.backingScaleFactor = targetScreen.backingScaleFactor
        overlayView.onComplete = { [weak self] rectInView in
            self?.finish(with: rectInView)
        }

        ScreenshotService.dbg("beginSelection: BEFORE makeKeyAndOrderFront")
        overlayWindow.contentView = overlayView
        overlayWindow.makeKeyAndOrderFront(nil)
        ScreenshotService.dbg("beginSelection: AFTER makeKeyAndOrderFront — window.isVisible=\(overlayWindow.isVisible) window.isKeyWindow=\(overlayWindow.isKeyWindow)")
        overlayWindow.makeFirstResponder(overlayView)
        ScreenshotService.dbg("beginSelection: firstResponder set — isFirstResponder=\(overlayWindow.firstResponder === overlayView)")

        window = overlayWindow
        selectionView = overlayView

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAppDeactivation),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)
        ScreenshotService.dbg("beginSelection: DONE — deactivation observer registered")
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

    private func finish(with rectInView: CGRect?) {
        guard let screen else {
            ScreenshotService.dbg("finishSelection: no screen available during finish")
            tearDown()
            return
        }

        var rectInScreenCoordinates: CGRect?
        if let rectInView, let window {
            ScreenshotService.dbg("finishSelection: rectInView=\(ScreenshotService.describe(rect: rectInView))")
            let rectInWindow = selectionView?.convert(rectInView, to: nil) ?? rectInView
            let selectionRect = window.convertToScreen(rectInWindow)
            let minimumSizePoints: CGFloat = 5
            ScreenshotService.dbg("finishSelection: converted rectInWindow=\(ScreenshotService.describe(rect: rectInWindow)) rectInScreen=\(ScreenshotService.describe(rect: selectionRect)) minimumSizePoints=\(minimumSizePoints)")
            if selectionRect.width >= minimumSizePoints && selectionRect.height >= minimumSizePoints {
                rectInScreenCoordinates = selectionRect
                ScreenshotService.dbg("finishSelection: ACCEPTED selection rect")
            } else {
                ScreenshotService.dbg("finishSelection: REJECTED selection rect — below minimum size")
            }
        } else {
            ScreenshotService.dbg("finishSelection: rectInView=nil or window missing")
        }

        tearDown()
        delegate?.selectionOverlay(self, didFinishWith: rectInScreenCoordinates, onScreen: screen)
    }

    private func tearDown() {
        ScreenshotService.dbg("tearDown: tearing down overlay windowExists=\(window != nil) selectionViewExists=\(selectionView != nil) screenExists=\(screen != nil)")
        NotificationCenter.default.removeObserver(self,
                                                   name: NSApplication.didResignActiveNotification,
                                                   object: nil)
        selectionView?.releaseCursor()
        window?.orderOut(nil)
        window = nil
        selectionView = nil
        screen = nil
    }

    @objc private func handleAppDeactivation() {
        ScreenshotService.dbg("deactivation: app deactivated — cancelling overlay. NSApp.isActive=\(NSApp.isActive)")
        cancelSelection()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ScreenshotService.dbg("view: viewDidMoveToWindow — window=\(window != nil) cursorPushed=\(cursorPushed)")
        guard window != nil, !cursorPushed else {
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
        let wasFirst = !hasDrawn
        hasDrawn = true
        if wasFirst {
            ScreenshotService.dbg("view: draw() FIRST CALL — window.isVisible=\(window?.isVisible ?? false) window.isKeyWindow=\(window?.isKeyWindow ?? false)")
        }

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
        ScreenshotService.dbg("view: mouseDown — hasDrawn=\(hasDrawn) window.isKey=\(window?.isKeyWindow ?? false)")
        guard hasDrawn else { return }
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
        ScreenshotService.dbg("view: mouseUp — hasDrawn=\(hasDrawn) startPoint=\(startPoint != nil)")
        guard hasDrawn else { return }
        if let currentSelectionRect {
            ScreenshotService.dbg("view: mouseUp — currentSelectionRect=\(ScreenshotService.describe(rect: currentSelectionRect))")
        } else {
            ScreenshotService.dbg("view: mouseUp — currentSelectionRect=nil")
        }
        onComplete?(currentSelectionRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        ScreenshotService.dbg("view: rightMouseDown — hasDrawn=\(hasDrawn)")
        guard hasDrawn else { return }
        onComplete?(nil)
    }

    override func keyDown(with event: NSEvent) {
        ScreenshotService.dbg("view: keyDown — keyCode=\(event.keyCode)")
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
