import AppKit
import Carbon

/// Handles stitching together multiple images from the current Finder selection.
///
/// The service reads the Finder selection (subject to automation permission),
/// filters it down to PNG/JPG/JPEG files, and stitches 2–8 images vertically
/// with a divider bar between each image. The resulting composite is saved via
/// `ScreenshotService` and then passed into the standard rename/note flow.
final class StitchService {
    private let screenshotService: ScreenshotService
    private let fileManager: FileManager

    init(screenshotService: ScreenshotService, fileManager: FileManager = .default) {
        self.screenshotService = screenshotService
        self.fileManager = fileManager
    }

    func stitchFromFinderSelection() {
        let urls = finderSelectionURLs()
        let imageURLs = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ["png", "jpg", "jpeg"].contains(ext)
        }

        if imageURLs.count < 2 {
            presentAlert(title: "Need at least 2 images",
                         message: "Select 2–8 PNG/JPG/JPEG images in Finder before invoking Stitch.")
            return
        }

        if imageURLs.count > 8 {
            presentAlert(title: "Too many images",
                         message: "Stitch supports at most 8 images at once.")
            return
        }

        let images: [NSImage] = imageURLs.compactMap { NSImage(contentsOf: $0) }
        if images.count != imageURLs.count || images.isEmpty {
            presentAlert(title: "Unable to read images",
                         message: "One or more selected files could not be opened as images.")
            return
        }

        guard let stitched = stitchImages(images) else {
            presentAlert(title: "Stitch failed",
                         message: "Failed to compose the stitched image.")
            return
        }

        do {
            let url = try screenshotService.saveImageToDesktop(stitched)
            screenshotService.beginPostCaptureFlow(forExistingFileAt: url)
        } catch {
            presentAlert(title: "Failed to save",
                         message: error.localizedDescription)
        }
    }

    // MARK: - Finder integration

    private func finderSelectionURLs() -> [URL] {
        let scriptSource = """
        tell application "Finder"
            if not (exists window 1) then return {}
            set theSelection to selection
            if theSelection is {} then return {}
            set output to {}
            repeat with anItem in theSelection
                set end of output to POSIX path of (anItem as alias)
            end repeat
            return output
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return []
        }

        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)

        if let errorDict = errorDict {
            print("[StitchService] AppleScript error: \(errorDict)")
            return []
        }

        var urls: [URL] = []

        if result.descriptorType == typeAEList {
            let count = result.numberOfItems
            for index in 1...count {
                if let item = result.atIndex(index), let path = item.stringValue {
                    urls.append(URL(fileURLWithPath: path))
                }
            }
        } else if let path = result.stringValue {
            urls.append(URL(fileURLWithPath: path))
        }

        return urls
    }

    // MARK: - Image stitching

    private func stitchImages(_ images: [NSImage]) -> NSImage? {
        guard !images.isEmpty else { return nil }

        let maxWidth = images.map { $0.size.width }.max() ?? 0
        let dividerHeight: CGFloat = 30
        let totalHeight = images.reduce(0) { $0 + $1.size.height } + dividerHeight * CGFloat(max(images.count - 1, 0))

        let size = NSSize(width: maxWidth, height: totalHeight)
        let result = NSImage(size: size)

        result.lockFocus()

        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        var currentY = totalHeight

        for (index, image) in images.enumerated() {
            let imageSize = image.size
            currentY -= imageSize.height
            let originX = (maxWidth - imageSize.width) / 2
            let imageRect = NSRect(x: originX, y: currentY, width: imageSize.width, height: imageSize.height)
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            if index < images.count - 1 {
                currentY -= dividerHeight
                let dividerRect = NSRect(x: 0, y: currentY, width: maxWidth, height: dividerHeight)
                drawDivider(in: dividerRect)
            }
        }

        result.unlockFocus()
        return result
    }

    private func drawDivider(in rect: NSRect) {
        NSColor.white.setFill()
        rect.fill()

        let barHeight: CGFloat = 12
        let barRect = NSRect(x: 0,
                             y: rect.midY - barHeight / 2,
                             width: rect.width,
                             height: barHeight)
        NSColor(calibratedWhite: 0.82, alpha: 1.0).setFill()
        barRect.fill()
    }

    // MARK: - Alerts

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
