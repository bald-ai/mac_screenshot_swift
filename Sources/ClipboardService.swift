import AppKit

/// Manages interactions with the NSPasteboard and on-disk clipboard cache.
///
/// Responsibilities:
/// - Copy images to the pasteboard for editor actions.
/// - Copy files to the pasteboard for rename/note/editor flows.
/// - For "Copy+Delete", cache a copy of the file under
///   `~/Library/Caches/screenshotapp/clipboard` so paste still works after
///   the original file is removed.
final class ClipboardService {
    private let cacheDirectory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let base = fileManager.homeDirectoryForCurrentUser
        self.cacheDirectory = base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("screenshotapp", isDirectory: true)
            .appendingPathComponent("clipboard", isDirectory: true)

        // Best-effort directory creation.
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    /// Removes all cached files under `~/Library/Caches/screenshotapp/clipboard`.
    /// This keeps paste behavior correct while preventing unbounded growth during frequent use.
    func purgeAllCachedFiles() {
        do {
            let urls = try fileManager.contentsOfDirectory(at: cacheDirectory,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
            for url in urls {
                try? fileManager.removeItem(at: url)
            }
        } catch {
            // Best-effort.
            print("[ClipboardService] Failed to purge cache:", error)
        }
    }

    /// Places an image on the general pasteboard. Used by the editor's Copy
    /// action where only image data (not a file URL) is required.
    func writeImage(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
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
                // Replace any existing cached file with the same name.
                if fileManager.fileExists(atPath: cachedURL.path) {
                    try fileManager.removeItem(at: cachedURL)
                }
                try fileManager.copyItem(at: url, to: cachedURL)
                sourceURL = cachedURL
            } catch {
                print("[ClipboardService] Failed to cache file:", error)
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

    // MARK: - Helpers

    private func uniqueCachedURL(for fileName: String) -> URL {
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        var attempt = 1
        while true {
            let candidateName: String
            if attempt == 1 {
                candidateName = fileName
            } else {
                let suffix = "_\(attempt)"
                if ext.isEmpty {
                    candidateName = baseName + suffix
                } else {
                    candidateName = baseName + suffix + "." + ext
                }
            }

            let url = cacheDirectory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }

            attempt += 1
        }
    }
}
