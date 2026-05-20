import AppKit

/// Manages interactions with the NSPasteboard and on-disk clipboard cache.
///
/// Responsibilities:
/// - Copy images to the pasteboard for editor actions.
/// - Copy files to the pasteboard for rename/note/editor flows.
/// - For "Copy+Delete", cache a copy of the file under
///   `~/Library/Caches/zoomies/clipboard` so paste still works after
///   the original file is removed.
final class ClipboardService {
    private let cacheDirectory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, cacheDirectory: URL? = nil) {
        self.fileManager = fileManager

        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let base = fileManager.homeDirectoryForCurrentUser
            self.cacheDirectory = base
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("zoomies", isDirectory: true)
                .appendingPathComponent("clipboard", isDirectory: true)
        }

        // Best-effort directory creation.
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }
    
    /// Removes all cached files under `~/Library/Caches/zoomies/clipboard`.
    /// This keeps paste behavior correct while preventing unbounded growth during frequent use.
    func purgeAllCachedFiles() {
        DirectoryPurgeLogic.purgeContents(of: cacheDirectory, fileManager: fileManager, label: "clipboard cache")
    }

    /// Places an image on the general pasteboard. Used by the editor's Copy
    /// action where only image data (not a file URL) is required.
    func writeImage(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([image]) {
            return
        }

        // Fallback for targets that expect explicit TIFF data.
        if let tiffData = image.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }

    /// Copies a file to the pasteboard.
    ///
    /// - Parameters:
    ///   - url: The source file URL.
    ///   - useCache: When true, the method copies the file into the
    ///     clipboard cache directory and publishes that cached URL on the
    ///     pasteboard. This is used for "Copy+Delete" so that paste continues
    ///     to work after the original file is deleted.
    func copyFile(at url: URL, useCache: Bool) {
        let sourceURL: URL

        if useCache {
            let cachedURL = uniqueCachedURL(for: url.lastPathComponent)
            do {
                // Best-effort replacement to avoid fileExists/remove TOCTOU windows.
                try? fileManager.removeItem(at: cachedURL)
                try fileManager.copyItem(at: url, to: cachedURL)
                sourceURL = cachedURL
            } catch {
                // Fall back to using the original URL.
                sourceURL = url
            }
        } else {
            sourceURL = url
        }

        guard let image = NSImage(contentsOf: sourceURL) else {
            // Even if we can't build an NSImage, still publish the file URL so
            // Finder-style pastes work.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([sourceURL as NSURL])
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Publish both the file URL and image data so both file-paste and
        // image-paste targets can consume the clipboard contents.
        pasteboard.writeObjects([sourceURL as NSURL, image])
    }

    /// Writes an in-memory image to the clipboard cache as a file and publishes
    /// the cached file URL on the pasteboard. Used for "Copy+Delete" from the
    /// editor where the edited image was never saved to disk.
    func copyImageAsFile(_ image: NSImage, fileName: String) {
        // PNG-only: always cache the clipboard file as PNG.
        let pngFileName = (fileName as NSString).deletingPathExtension + ".png"
        let cachedURL = uniqueCachedURL(for: pngFileName)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            // Can't encode — fall back to image-only clipboard.
            writeImage(image)
            return
        }

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            writeImage(image)
            return
        }

        do {
            try data.write(to: cachedURL, options: .atomic)
        } catch {
            writeImage(image)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([cachedURL as NSURL, image])
    }

    // MARK: - Helpers

    private func uniqueCachedURL(for fileName: String) -> URL {
        UniqueFileURLLogic.uniqueURL(
            forProposedName: fileName,
            in: cacheDirectory,
            fileExists: { [fileManager] path in fileManager.fileExists(atPath: path) }
        )
    }
}
