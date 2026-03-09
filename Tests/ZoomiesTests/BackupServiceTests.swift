import XCTest
@testable import Zoomies

final class BackupServiceTests: XCTestCase {
    func testCreateBackupCopiesAndReplacesExisting() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)

        let service = BackupService(fileManager: .default, backupsDirectory: backups)
        let original = originals.appendingPathComponent("shot.png")
        try Data("v1".utf8).write(to: original, options: .atomic)

        service.createBackup(forOriginalURL: original)
        let backup = service.backupURL(forOriginalURL: original)
        XCTAssertEqual(try Data(contentsOf: backup), Data("v1".utf8))

        try Data("v2".utf8).write(to: original, options: .atomic)
        service.createBackup(forOriginalURL: original)
        XCTAssertEqual(try Data(contentsOf: backup), Data("v2".utf8))
    }

    func testRemoveBackupDeletesExistingFile() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)

        let service = BackupService(fileManager: .default, backupsDirectory: backups)
        let original = originals.appendingPathComponent("shot.png")
        try Data("v1".utf8).write(to: original, options: .atomic)
        service.createBackup(forOriginalURL: original)

        service.removeBackup(forOriginalURL: original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.backupURL(forOriginalURL: original).path))
    }

    func testPurgeAllBackupsClearsDirectory() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let service = BackupService(fileManager: .default, backupsDirectory: backups)
        try Data("a".utf8).write(to: backups.appendingPathComponent("1.bin"), options: .atomic)
        try Data("b".utf8).write(to: backups.appendingPathComponent("2.bin"), options: .atomic)

        service.purgeAllBackups()

        let remaining = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty)
    }
}
