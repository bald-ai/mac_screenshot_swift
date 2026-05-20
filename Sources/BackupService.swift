import Foundation

/// Manages on-disk backups of original screenshots prior to editing.
///
/// Backups live under `~/Library/Caches/zoomies/backups` and are
/// addressed deterministically by the original file's last path component.
/// This keeps the implementation simple while still satisfying the "delete
/// also removes any backups" requirement.
final class BackupService {
    let backupsDirectory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, backupsDirectory: URL? = nil) {
        self.fileManager = fileManager

        if let backupsDirectory {
            self.backupsDirectory = backupsDirectory
        } else {
            let base = fileManager.homeDirectoryForCurrentUser
            self.backupsDirectory = base
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("zoomies", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
        }

        try? fileManager.createDirectory(at: self.backupsDirectory, withIntermediateDirectories: true)
    }
    
    /// Removes all files under `~/Library/Caches/zoomies/backups`.
    /// Mirrors the legacy app behavior to avoid orphaned backups across dev sessions.
    func purgeAllBackups() {
        DirectoryPurgeLogic.purgeContents(of: backupsDirectory, fileManager: fileManager, label: "backup cache")
    }

    /// Returns the backup URL corresponding to a given original screenshot
    /// file URL.
    func backupURL(forOriginalURL url: URL) -> URL {
        backupsDirectory.appendingPathComponent(url.lastPathComponent)
    }

    /// Creates or replaces a backup for the given original screenshot.
    func createBackup(forOriginalURL url: URL) {
        let backupURL = backupURL(forOriginalURL: url)
        do {
            // Best-effort replacement to avoid fileExists/remove TOCTOU windows.
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: url, to: backupURL)
        } catch {
        }
    }

    /// Removes the backup associated with the given original screenshot, if it
    /// exists. Called when the user deletes a screenshot (with or without
    /// copy+delete).
    func removeBackup(forOriginalURL url: URL) {
        let backupURL = backupURL(forOriginalURL: url)
        do {
            try fileManager.removeItem(at: backupURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
        }
    }
}
