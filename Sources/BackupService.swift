import Foundation

/// Manages on-disk backups of original screenshots prior to editing.
///
/// Backups live under `~/Library/Caches/screenshotapp/backups` and are
/// addressed deterministically by the original file's last path component.
/// This keeps the implementation simple while still satisfying the "delete
/// also removes any backups" requirement.
final class BackupService {
    let backupsDirectory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let base = fileManager.homeDirectoryForCurrentUser
        self.backupsDirectory = base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("screenshotapp", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)

        try? fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
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
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: url, to: backupURL)
        } catch {
            print("[BackupService] Failed to create backup:", error)
        }
    }

    /// Removes the backup associated with the given original screenshot, if it
    /// exists. Called when the user deletes a screenshot (with or without
    /// copy+delete).
    func removeBackup(forOriginalURL url: URL) {
        let backupURL = backupURL(forOriginalURL: url)
        if fileManager.fileExists(atPath: backupURL.path) {
            do {
                try fileManager.removeItem(at: backupURL)
            } catch {
                print("[BackupService] Failed to remove backup:", error)
            }
        }
    }
}
