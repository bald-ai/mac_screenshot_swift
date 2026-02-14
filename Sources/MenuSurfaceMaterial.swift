import AppKit

/// Shared menu-like visual surface so windows and panels use a consistent native background.
enum MenuSurfaceMaterial {
    static func apply(to view: NSVisualEffectView) {
        if #available(macOS 10.14, *) {
            view.material = .menu
        } else {
            view.material = .popover
        }
        view.blendingMode = .withinWindow
        view.state = .active
    }

    static func makeFillingView(frame: NSRect) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: frame)
        apply(to: view)
        view.autoresizingMask = [.width, .height]
        return view
    }
}
