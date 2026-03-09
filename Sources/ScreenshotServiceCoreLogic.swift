import AppKit
import Foundation

enum TemporaryImageResult {
    case loaded(NSImage)
    case missing
    case unreadable
}

struct ScreenCaptureTarget: Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let isMain: Bool
}

enum ScreenshotServiceCoreLogic {
    static func targetDisplay(for mouseLocation: CGPoint,
                              displays: [ScreenCaptureTarget]) -> ScreenCaptureTarget? {
        if let matchingDisplay = displays.first(where: { $0.frame.contains(mouseLocation) }) {
            return matchingDisplay
        }

        if let mainDisplay = displays.first(where: \.isMain) {
            return mainDisplay
        }

        return displays.first
    }

    static func resizedImageIfNeeded(_ image: NSImage, maxWidth: Int) -> NSImage {
        guard maxWidth > 0 else { return image }

        let originalSize = image.size
        guard originalSize.width > CGFloat(maxWidth) else { return image }

        let scale = CGFloat(maxWidth) / originalSize.width
        let newSize = NSSize(width: CGFloat(maxWidth), height: originalSize.height * scale)
        return NSImage(size: newSize, flipped: false) { rect in
            image.draw(in: rect,
                       from: NSRect(origin: .zero, size: originalSize),
                       operation: .copy,
                       fraction: 1.0)
            return true
        }
    }

    static func jpegData(from image: NSImage, quality: Int) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let clamped = max(10, min(100, quality))
        let compression = CGFloat(clamped) / 100.0
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }

    static func uniqueScreenshotURL(in directory: URL, baseName: String, fileExists: (String) -> Bool) -> URL {
        let name = baseName.isEmpty ? "Screenshot" : baseName
        return UniqueFileURLLogic.uniqueURL(
            forProposedName: "\(name).jpg",
            in: directory,
            fileExists: fileExists
        )
    }

    static func loadTemporaryImage(at url: URL,
                                   fileExists: (String) -> Bool,
                                   loadImage: (URL) -> NSImage?) -> TemporaryImageResult {
        guard fileExists(url.path) else {
            return .missing
        }
        guard let image = loadImage(url) else {
            return .unreadable
        }
        return .loaded(image)
    }
}
