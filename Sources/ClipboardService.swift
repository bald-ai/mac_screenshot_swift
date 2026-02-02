import AppKit

/// Manages interactions with the NSPasteboard and on-disk clipboard cache.
///
/// This is a minimal shell; the detailed copy+delete semantics described in the
/// plan will be implemented later.
final class ClipboardService {
    private let cacheDirectory: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.homeDirectoryForCurrentUser
        self.cacheDirectory = base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("screenshotapp", isDirectory: true)
            .appendingPathComponent("clipboard", isDirectory: true)

        // Best-effort directory creation.
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Places an image on the general pasteboard.
    func writeImage(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// In a later step this will also cache the data under `cacheDirectory` so
    /// that copy+delete semantics work even after the source file is removed.
}
