import Foundation
import Carbon

/// Manages global shortcuts.
///
/// For now this is a very small shell that exposes the right surface area but
/// does not yet hook into Carbon. That work will come as part of the dedicated
/// "Global Shortcuts" step. Keeping this stub simple ensures the rest of the
/// app can be exercised without crashing or leaking event handlers.
final class HotKeyService {
    typealias Handler = () -> Void

    init() {}

    /// Registers the three primary shortcuts. In the stub implementation we
    /// simply store the closures so unit tests or future code can invoke them
    /// directly, but we do not yet bind global hotkeys.
    func registerShortcuts(settings: Settings, areaHandler: @escaping Handler, fullHandler: @escaping Handler, stitchHandler: @escaping Handler) {
        // TODO: Implement real RegisterEventHotKey-based registration.
        // For now, no-op to avoid partial, fragile Carbon integration.
        _ = settings
        _ = areaHandler
        _ = fullHandler
        _ = stitchHandler
    }
}
