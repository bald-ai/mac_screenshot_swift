import AppKit

struct WorkflowEncodedImageResult {
    let data: Data
    let outputURL: URL
}

enum WorkflowImagePersistenceLogic {
    typealias UniqueURLResolver = (_ proposedName: String, _ directory: URL) -> URL

    static func encodedImageData(from image: NSImage,
                                 originalURL: URL,
                                 quality: Int,
                                 uniqueURL: UniqueURLResolver) -> WorkflowEncodedImageResult? {
        // PNG-only: every image is encoded as PNG regardless of the original
        // file's extension. PNG is lossless, so `quality` is unused.
        let ext = originalURL.pathExtension.lowercased()

        guard let bitmap = ScreenshotServiceCoreLogic.bitmapRepresentation(from: image) else { return nil }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let outputURL: URL
        if ext != "png" && !ext.isEmpty {
            // Original wasn't a PNG (e.g. an opened JPEG/HEIC). Rewrite as .png.
            let proposedName = originalURL.deletingPathExtension().lastPathComponent + ".png"
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
