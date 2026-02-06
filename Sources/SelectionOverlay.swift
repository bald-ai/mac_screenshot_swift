import AppKit

protocol SelectionOverlayDelegate: AnyObject {
    /// Called when the user has made a selection.
    /// - Parameters:
    ///   - overlay: The overlay instance.
    ///   - rect: The selected rectangle in global screen coordinates, in pixels.
    func selectionOverlay(_ overlay: SelectionOverlay, didSelect rect: CGRect)

    /// Called when the user cancels selection (Esc, right-click, tiny drag, or programmatic cancel).
    func selectionOverlayDidCancel(_ overlay: SelectionOverlay)

    /// Legacy callback used by existing code.
    /// - Parameters:
    ///   - overlay: The overlay instance.
    ///   - rectInScreenCoordinates: The selected rectangle in global screen coordinates (points).
    ///     `nil` indicates the user cancelled the operation.
    ///   - screen: The `NSScreen` on which the selection occurred.
    func selectionOverlay(_ overlay: SelectionOverlay, didFinishWith rectInScreenCoordinates: CGRect?, onScreen screen: NSScreen)
}

extension SelectionOverlayDelegate {
    func selectionOverlay(_ overlay: SelectionOverlay, didSelect rect: CGRect) {
        // Default implementation forwards pixel coordinates to the legacy API
        // after converting to points.
        guard let screen = overlay.screen else { return }
        let scale = screen.backingScaleFactor
        let rectInPoints = CGRect(
            x: rect.origin.x / scale,
            y: rect.origin.y / scale,
            width: rect.size.width / scale,
            height: rect.size.height / scale
        )
        selectionOverlay(overlay, didFinishWith: rectInPoints, onScreen: screen)
    }

    func selectionOverlayDidCancel(_ overlay: SelectionOverlay) {
        guard let screen = overlay.screen else { return }
        selectionOverlay(overlay, didFinishWith: nil, onScreen: screen)
    }

    // Provide a no-op default so conformers only need to implement the modern API.
    func selectionOverlay(_ overlay: SelectionOverlay, didFinishWith rectInScreenCoordinates: CGRect?, onScreen screen: NSScreen) {}
}

/// Full-screen transparent overlay that lets the user drag to select a rectangle.
///
/// This window is confined to a single Space (no `.canJoinAllSpaces`) and lives on
/// the screen where the cursor is when capture starts. It reports the selection in
/// global screen coordinates in pixels; callers that rely on the older
/// `selectionOverlay(_:didFinishWith:onScreen:)` API receive the equivalent rect
/// in points via the compatibility adapter above.
final class SelectionOverlay: NSObject {
    weak var delegate: SelectionOverlayDelegate?

    fileprivate var screen: NSScreen?

    private var window: NSWindow?
    private var selectionView: SelectionOverlayView?

    /// Begins an area selection on the display that currently contains the mouse.
    func beginSelection() {
        Logger.shared.info("SelectionOverlay: beginSelection called")
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginSelection()
            }
            return
        }
        guard window == nil else {
            Logger.shared.info("SelectionOverlay: Window already exists, returning")
            return
        }

        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            Logger.shared.error("SelectionOverlay: No target screen found")
            return
        }
        Logger.shared.info("SelectionOverlay: Target screen: \(targetScreen.frame)")

        screen = targetScreen

        let style: NSWindow.StyleMask = [.borderless]
        let window = SelectionOverlayWindow(contentRect: targetScreen.frame,
                                            styleMask: style,
                                            backing: .buffered,
                                            defer: false,
                                            screen: targetScreen)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true

        let view = SelectionOverlayView(frame: window.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        view.backingScaleFactor = targetScreen.backingScaleFactor
        view.onComplete = { [weak self] rectInView in
            guard let self = self else {
                Logger.shared.error("SelectionOverlay: onComplete - self is nil")
                return
            }
            Logger.shared.info("SelectionOverlay: onComplete with rect: \(String(describing: rectInView))")
            self.finish(with: rectInView)
        }

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        self.window = window
        self.selectionView = view
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAppDeactivation),
                                               name: NSApplication.didResignActiveNotification,
                                               object: nil)
        Logger.shared.info("SelectionOverlay: Window created and shown")
    }

    /// Cancels the current selection, if any.
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
        Logger.shared.info("SelectionOverlay: finish called with rect: \(String(describing: rectInView))")
        guard let screen = screen else {
            Logger.shared.error("SelectionOverlay: finish - no screen, tearing down")
            tearDown()
            return
        }

        defer { 
            Logger.shared.info("SelectionOverlay: finish - tearing down in defer")
            tearDown() 
        }

        guard let window = window else { 
            Logger.shared.error("SelectionOverlay: finish - no window")
            return 
        }

        // Treat missing or tiny selections as cancellation.
        guard let rectInView = rectInView else {
            delegate?.selectionOverlayDidCancel(self)
            return
        }

        let rectInWindow: CGRect
        if let selectionView = selectionView {
            rectInWindow = selectionView.convert(rectInView, to: nil)
        } else {
            rectInWindow = rectInView
        }

        // Convert window coordinates (origin at bottom-left in global space) to
        // global screen coordinates in points.
        let rectInScreenPoints = window.convertToScreen(rectInWindow)

        let scale = screen.backingScaleFactor
        let widthPixels = rectInScreenPoints.width * scale
        let heightPixels = rectInScreenPoints.height * scale

        let minimumSizePixels: CGFloat = 10
        guard widthPixels >= minimumSizePixels, heightPixels >= minimumSizePixels else {
            delegate?.selectionOverlayDidCancel(self)
            return
        }

        // Convert to pixel coordinates in the global screen space.
        let rectInScreenPixels = CGRect(
            x: rectInScreenPoints.origin.x * scale,
            y: rectInScreenPoints.origin.y * scale,
            width: rectInScreenPoints.size.width * scale,
            height: rectInScreenPoints.size.height * scale
        )

        Logger.shared.info("SelectionOverlay: Calling delegate with selected rect")
        delegate?.selectionOverlay(self, didSelect: rectInScreenPixels)
    }

    private func tearDown() {
        Logger.shared.info("SelectionOverlay: tearDown called")
        NotificationCenter.default.removeObserver(self,
                                                  name: NSApplication.didResignActiveNotification,
                                                  object: nil)
        window?.orderOut(nil)
        window = nil
        selectionView = nil
        screen = nil
        Logger.shared.info("SelectionOverlay: tearDown completed")
    }
}

private extension SelectionOverlay {
    @objc func handleAppDeactivation() {
        Logger.shared.info("SelectionOverlay: App resigned active, cancelling selection")
        cancelSelection()
    }
}

private final class SelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionOverlayView: NSView {
    var onComplete: ((CGRect?) -> Void)?

    var backingScaleFactor: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds

        // Dim the entire screen slightly.
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        if let rect = currentSelectionRect {
            // Clear the selected area by drawing using destinationOut compositing.
            NSColor.clear.setFill()
            rect.fill(using: .destinationOut)

            // Stroke the selection rectangle.
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()

            drawDimensions(for: rect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        startPoint = location
        currentPoint = location
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = currentSelectionRect else {
            onComplete?(nil)
            return
        }
        onComplete?(rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onComplete?(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onComplete?(nil)
        case 36: // Return
            if let rect = currentSelectionRect {
                onComplete?(rect)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private var currentSelectionRect: CGRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        return normalizedRect(from: start, to: current)
    }

    private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> CGRect {
        let minX = min(p1.x, p2.x)
        let maxX = max(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        let maxY = max(p1.y, p2.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func drawDimensions(for rect: CGRect) {
        let widthPixels = Int(rect.width * backingScaleFactor)
        let heightPixels = Int(rect.height * backingScaleFactor)
        guard widthPixels > 0, heightPixels > 0 else { return }

        let text = "\(widthPixels) × \(heightPixels)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        let textSize = (text as NSString).size(withAttributes: attributes)

        let padding: CGFloat = 4
        var textOrigin = CGPoint(
            x: rect.origin.x + 8,
            y: rect.origin.y + rect.height - textSize.height - 8
        )

        // Ensure the label stays within the view bounds.
        if textOrigin.x + textSize.width + 2 * padding > bounds.maxX {
            textOrigin.x = bounds.maxX - textSize.width - 2 * padding
        }
        if textOrigin.y + textSize.height + 2 * padding > bounds.maxY {
            textOrigin.y = bounds.maxY - textSize.height - 2 * padding
        }

        let backgroundRect = CGRect(
            x: textOrigin.x - padding,
            y: textOrigin.y - padding,
            width: textSize.width + 2 * padding,
            height: textSize.height + 2 * padding
        )

        NSColor.black.withAlphaComponent(0.6).setFill()
        backgroundRect.fill()

        (text as NSString).draw(at: textOrigin, withAttributes: attributes)
    }
}
