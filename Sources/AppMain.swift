import AppKit

@main
struct MainApplication {
    static func main() {
        let app = NSApplication.shared
        AppTheme.applyGlobalAppearance()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
