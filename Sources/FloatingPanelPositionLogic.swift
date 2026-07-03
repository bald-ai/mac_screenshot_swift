import AppKit

enum FloatingPanelPositionLogic {
    static func centeredOrigin(windowSize: NSSize, in visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2
        )
    }
}
