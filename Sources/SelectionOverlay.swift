import AppKit

protocol SelectionOverlayDelegate: AnyObject {
    /// Called when the user finishes an area selection.
    /// - Parameters:
    ///   - overlay: The overlay instance.
    ///   - rectInScreenCoordinates: The selected rectangle in global screen coordinates (points).
    ///     `nil` indicates the user cancelled the operation.
    ///   - screen: The `NSScreen` on which the selection occurred.
    func selectionOverlay(_ overlay: SelectionOverlay, didFinishWith rectInScreenCoordinates: CGRect?, onScreen screen: NSScreen)
}

/// Full-screen transparent overlay that lets the user drag to select a rectangle.
///
/// This window is confined to a single Space (no `.canJoinAllSpaces`) and lives on
/// the screen where the cursor is when capture starts. It respects Retina scaling
/// by reporting the selection in screen coordinates (points); callers are
/// responsible for converting to pixels.
final class SelectionOverlay: NSObject {
    weak var delegate: SelectionOverlayDelegate?

    private var window: NSWindow?
    private var screen: NSScreen?
    private var selectionView: SelectionOverlayView?

    func beginSelection() {
        guard window == nil else { return }

        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return
        }

        screen = targetScreen

        let style: NSWindow.StyleMask = [.borderless]
        let window = NSWindow(contentRect: targetScreen.frame,
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

        let view = SelectionOverlayView(frame: window.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        view.onComplete = { [weak self] rect in
            guard let self = self, let screen = self.screen else { return }
            self.finish(with: rect, on: screen)
        }

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        self.window = window
        self.selectionView = view
    }

    private func finish(with rectInWindow: CGRect?, on screen: NSScreen) {
        defer {
            window?.orderOut(nil)
            window = nil
            selectionView = nil
            self.screen = nil
        }

        guard let window = window else { return }

        guard let rectInWindow = rectInWindow, rectInWindow.width >= 2, rectInWindow.height >= 2 else {
            delegate?.selectionOverlay(self, didFinishWith: nil, onScreen: screen)
            return
        }

        // Convert window coordinates (origin at bottom-left in global space) to
        // global screen coordinates.
        let rectInScreen = window.convertToScreen(rectInWindow)
        delegate?.selectionOverlay(self, didFinishWith: rectInScreen, onScreen: screen)
    }
}

private final class SelectionOverlayView: NSView {
    var onComplete: ((CGRect?) -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let bounds = window?.contentView?.bounds else { return }

        // Dim the entire screen slightly.
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        if let start = startPoint, let current = currentPoint {
            let rect = normalizedRect(from: start, to: current)

            // Clear the selected area by drawing using destinationOut compositing.
            NSColor.clear.setFill()
            rect.fill(using: .destinationOut)

            // Stroke the selection rectangle.
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
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
        guard let start = startPoint, let end = currentPoint else {
            onComplete?(nil)
            return
        }
        let rect = normalizedRect(from: start, to: end)
        onComplete?(rect)
    }

    override func keyDown(with event: NSEvent) {
        // Escape cancels selection.
        if event.keyCode == 53 { // kVK_Escape
            onComplete?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> CGRect {
        let minX = min(p1.x, p2.x)
        let maxX = max(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        let maxY = max(p1.y, p2.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
