import AppKit

/// Handles stitching together multiple images from the current Finder selection.
///
/// This is currently a placeholder implementation to keep the application
/// wired together. The full Finder-integration and image compositing logic
/// will be implemented in a later step.
final class StitchService {
    private let screenshotService: ScreenshotService

    init(screenshotService: ScreenshotService) {
        self.screenshotService = screenshotService
    }

    func stitchFromFinderSelection() {
        let alert = NSAlert()
        alert.messageText = "Stitch not yet implemented"
        alert.informativeText = "Stitching images from Finder selection will be implemented in a subsequent step."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
