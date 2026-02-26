import AppKit

enum AppTheme {
    private static var forcedAppearance: NSAppearance {
        NSAppearance(named: .darkAqua) ?? NSAppearance(named: .aqua) ?? NSAppearance()
    }

    static func applyGlobalAppearance() {
        NSApp.appearance = forcedAppearance
    }

    static func apply(to window: NSWindow?) {
        window?.appearance = forcedAppearance
    }

    static func apply(to menu: NSMenu?) {
        menu?.appearance = forcedAppearance
    }
}
