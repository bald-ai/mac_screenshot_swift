import AppKit
import Foundation
import ScreenCaptureKit

struct ScreenCaptureRect {
    let pointRect: CGRect
    let pixelRect: CGRect
}

enum ScreenshotServiceCoreLogic {
    static func shouldSuppressCaptureFailureAlert(_ error: NSError) -> Bool {
        error.domain == SCStreamErrorDomain && error.code == Int(SCStreamError.userDeclined.rawValue)
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

    static func pngData(from image: NSImage) -> Data? {
        guard let bitmap = bitmapRepresentation(from: image) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func bitmapRepresentation(from image: NSImage) -> NSBitmapImageRep? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if image.size.width > 0, image.size.height > 0 {
                bitmap.size = image.size
            }
            return bitmap
        }

        let pointSize = image.size
        let pixelSize = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { lhs, rhs in lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh })
            .map { NSSize(width: CGFloat($0.pixelsWide), height: CGFloat($0.pixelsHigh)) }
            ?? pointSize

        let pixelWidth = Int(pixelSize.width.rounded(.up))
        let pixelHeight = Int(pixelSize.height.rounded(.up))
        guard pixelWidth > 0,
              pixelHeight > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: pixelWidth,
                                            pixelsHigh: pixelHeight,
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0,
                                            bitsPerPixel: 0) else {
            return nil
        }

        bitmap.size = pointSize.width > 0 && pointSize.height > 0
            ? pointSize
            : NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: bitmap.size),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        return bitmap
    }

    static func uniqueScreenshotURL(in directory: URL, baseName: String, fileExists: (String) -> Bool) -> URL {
        let name = baseName.isEmpty ? "Screenshot" : baseName
        return UniqueFileURLLogic.uniqueURL(
            forProposedName: "\(name).png",
            in: directory,
            fileExists: fileExists
        )
    }

    static func screenCaptureRect(rectInScreenPoints rect: CGRect,
                                  screenFrame: CGRect,
                                  scale: CGFloat) -> ScreenCaptureRect? {
        guard scale > 0 else {
            return nil
        }

        let localRectPoints = CGRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.width,
            height: rect.height
        )

        let pointBounds = CGRect(origin: .zero, size: screenFrame.size)
        let flippedY = pointBounds.height - (localRectPoints.origin.y + localRectPoints.height)
        let sourceRect = CGRect(x: localRectPoints.origin.x,
                                y: flippedY,
                                width: localRectPoints.width,
                                height: localRectPoints.height)
        let clampedPointRect = sourceRect.integral.intersection(pointBounds)
        guard clampedPointRect.width >= 1, clampedPointRect.height >= 1 else {
            return nil
        }

        let pixelRect = CGRect(x: clampedPointRect.origin.x * scale,
                               y: clampedPointRect.origin.y * scale,
                               width: clampedPointRect.width * scale,
                               height: clampedPointRect.height * scale).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1 else {
            return nil
        }

        return ScreenCaptureRect(pointRect: clampedPointRect, pixelRect: pixelRect)
    }
}
