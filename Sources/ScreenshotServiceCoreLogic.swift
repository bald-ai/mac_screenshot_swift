import AppKit
import Foundation

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

    static func captureRects(rectInScreenPoints rect: CGRect,
                             screenFrame: CGRect,
                             scale: CGFloat) -> (pointRect: CGRect, pixelRect: CGRect)? {
        let localRectPoints = CGRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )

        let pointBounds = CGRect(origin: .zero, size: screenFrame.size)
        let flippedY = pointBounds.height - (localRectPoints.origin.y + localRectPoints.height)
        let pointRectTopLeft = CGRect(
            x: localRectPoints.origin.x,
            y: flippedY,
            width: localRectPoints.size.width,
            height: localRectPoints.size.height
        )
        let clampedPoints = pointRectTopLeft.integral.intersection(pointBounds)

        let pixelRect = CGRect(
            x: clampedPoints.origin.x * scale,
            y: clampedPoints.origin.y * scale,
            width: clampedPoints.size.width * scale,
            height: clampedPoints.size.height * scale
        )

        guard clampedPoints.width >= 1, clampedPoints.height >= 1 else { return nil }
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        return (pointRect: clampedPoints, pixelRect: pixelRect.integral)
    }

    static func shouldFallbackToLegacy(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain, nsError.code == -50 {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("invalid") && message.contains("parameter")
    }
}
