import AppKit

struct WorkflowEncodedImageResult {
    let data: Data
    let outputURL: URL
}

enum WorkflowImagePersistenceLogic {
    typealias UniqueURLResolver = (_ proposedName: String, _ directory: URL) -> URL

    /// Originals larger than this are not embedded, to avoid bloating saved files.
    static let maxEmbeddedOriginalBytes = 5 * 1024 * 1024

    static func encodedImageData(from image: NSImage,
                                 originalURL: URL,
                                 quality: Int,
                                 cleanOriginalPNG: Data? = nil,
                                 prompt: String? = nil,
                                 uniqueURL: UniqueURLResolver) -> WorkflowEncodedImageResult? {
        let ext = originalURL.pathExtension.lowercased()

        let (fileType, outputExtension, shouldChangeExtensionOnWrite): (NSBitmapImageRep.FileType, String, Bool) = {
            switch ext {
            case "png":
                return (.png, "png", false)
            case "tif", "tiff":
                return (.tiff, ext, false)
            case "bmp":
                return (.bmp, "bmp", false)
            case "gif":
                return (.gif, "gif", false)
            case "jpg", "jpeg":
                return (.jpeg, ext, false)
            case "heic", "heif":
                return (.jpeg, "jpg", true)
            default:
                return (.jpeg, "jpg", false)
            }
        }()

        let sourceImage = flattenedToEditorBackgroundIfNeeded(image, for: fileType)
        guard let bitmap = ScreenshotServiceCoreLogic.bitmapRepresentation(from: sourceImage) else { return nil }

        let properties: [NSBitmapImageRep.PropertyKey: Any]
        if fileType == .jpeg {
            let clamped = max(10, min(100, quality))
            properties = [.compressionFactor: CGFloat(clamped) / 100.0]
        } else {
            properties = [:]
        }

        guard var data = bitmap.representation(using: fileType, properties: properties) else { return nil }

        // Round-trip metadata is PNG-only; other formats silently skip embedding.
        if fileType == .png,
           let prompt, !prompt.isEmpty,
           let cleanOriginalPNG, cleanOriginalPNG.count < maxEmbeddedOriginalBytes,
           let embedded = PNGMetadata.embed(intoPNG: data, originalPNG: cleanOriginalPNG, prompt: prompt) {
            data = embedded
        }

        let outputURL: URL
        if shouldChangeExtensionOnWrite && !ext.isEmpty && outputExtension != ext {
            let proposedName = originalURL.deletingPathExtension().lastPathComponent + "." + outputExtension
            outputURL = uniqueURL(proposedName, originalURL.deletingLastPathComponent())
        } else {
            outputURL = originalURL
        }

        return WorkflowEncodedImageResult(data: data, outputURL: outputURL)
    }

    static func writeEncodedImageData(_ data: Data,
                                      to outputURL: URL,
                                      originalURL: URL,
                                      fileManager: FileManager = .default) throws -> URL {
        try data.write(to: outputURL, options: .atomic)

        if outputURL != originalURL, fileManager.fileExists(atPath: originalURL.path) {
            try? fileManager.removeItem(at: originalURL)
        }

        return outputURL
    }

    private static func flattenedToEditorBackgroundIfNeeded(_ image: NSImage,
                                                            for fileType: NSBitmapImageRep.FileType) -> NSImage {
        guard fileType == .jpeg else { return image }

        let size = image.size
        return NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
            rect.fill()
            image.draw(in: rect,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0,
                       respectFlipped: true,
                       hints: nil)
            return true
        }
    }
}
