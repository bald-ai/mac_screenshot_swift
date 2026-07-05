import AppKit

struct WorkflowEncodedImageResult {
    let data: Data
    let outputURL: URL
}

enum WorkflowImagePersistenceLogic {
    typealias UniqueURLResolver = (_ proposedName: String, _ directory: URL) -> URL

    /// Originals larger than this are not embedded, to avoid bloating saved files.
    /// Generous enough that real screenshots (incl. full-screen Retina PNGs)
    /// always round-trip; only pathologically large originals are skipped.
    static let maxEmbeddedOriginalBytes = 50 * 1024 * 1024

    static func encodedImageData(from image: NSImage,
                                 originalURL: URL,
                                 cleanOriginalPNG: Data? = nil,
                                 prompt: String? = nil,
                                 editorState: EditorCanvasState? = nil,
                                 uniqueURL: UniqueURLResolver) -> WorkflowEncodedImageResult? {
        // PNG-only: every image is encoded as PNG regardless of the original
        // file's extension.
        let ext = originalURL.pathExtension.lowercased()

        guard let bitmap = ScreenshotServiceCoreLogic.bitmapRepresentation(from: image) else { return nil }
        guard var data = bitmap.representation(using: .png, properties: [:]) else { return nil }

        // Round-trip metadata: embed the clean original + prompt and/or editable
        // canvas state when present.
        if let prompt, !prompt.isEmpty,
           let cleanOriginalPNG, cleanOriginalPNG.count < maxEmbeddedOriginalBytes,
           let embedded = PNGMetadata.embed(intoPNG: data,
                                            originalPNG: cleanOriginalPNG,
                                            prompt: prompt,
                                            editorState: editorState) {
            data = embedded
        } else if let editorState,
                  editorState.baseImagePNG.count < maxEmbeddedOriginalBytes,
                  let embedded = PNGMetadata.embed(intoPNG: data, editorState: editorState) {
            data = embedded
        }

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
}
