import AppKit
import Foundation

enum TemporaryImageResult {
    case loaded(NSImage)
    case missing
    case unreadable
}

enum ScreenshotServiceCoreLogic {
    static func resizedImageIfNeeded(_ image: NSImage, maxWidth: Int) -> NSImage {
        guard maxWidth > 0 else { return image }

        let originalSize = image.size
        guard originalSize.width > CGFloat(maxWidth) else { return image }

        let scale = CGFloat(maxWidth) / originalSize.width
        let newSize = NSSize(width: CGFloat(maxWidth), height: originalSize.height * scale)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()

        return newImage
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
        var url = directory.appendingPathComponent(name).appendingPathExtension("jpg")
        if !fileExists(url.path) {
            return url
        }

        var suffix = 2
        while true {
            let suffixedName = "\(name)_\(suffix)"
            url = directory.appendingPathComponent(suffixedName).appendingPathExtension("jpg")
            if !fileExists(url.path) {
                return url
            }
            suffix += 1
        }
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
