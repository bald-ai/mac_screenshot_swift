import Foundation

/// Manages on-disk backups of original screenshots prior to editing.
///
/// The full backup lifecycle (creation, cleanup, delete integration) will be
/// implemented when the editor is added. For now this simply prepares the
/// directory structure.
final class BackupService {
    let backupsDirectory: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.homeDirectoryForCurrentUser
        self.backupsDirectory = base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("screenshotapp", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)

        try? fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
    }
}
