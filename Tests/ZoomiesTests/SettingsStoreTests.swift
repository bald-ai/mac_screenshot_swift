import XCTest
@testable import Zoomies

final class SettingsStoreTests: XCTestCase {
    func testLoadCreatesDefaultsOnFirstLaunch() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent(".screenshot_app_settings.json")
        let store = SettingsStore(fileManager: .default, fileURL: fileURL)

        store.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(store.settings.quality, Settings.default.quality)
    }

    func testLoadValidFileNormalizesDecodedSettings() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("settings.json")
        var raw = Settings.default
        raw.quality = 99
        raw.maxWidth = -5
        raw.screenshotCounter = 0
        raw.notePrefix = String(repeating: "x", count: 200)
        let data = try JSONEncoder().encode(raw)
        try data.write(to: fileURL, options: .atomic)

        let store = SettingsStore(fileManager: .default, fileURL: fileURL)
        store.load()

        XCTAssertEqual(store.settings.quality, 95)
        XCTAssertEqual(store.settings.maxWidth, 0)
        XCTAssertEqual(store.settings.screenshotCounter, 1)
        XCTAssertEqual(store.settings.notePrefix.count, 50)
    }

    func testLoadCorruptFileFallsBackToDefaultsWithoutOverwrite() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("settings.json")
        let original = Data("{not-json".utf8)
        try original.write(to: fileURL, options: .atomic)

        let store = SettingsStore(fileManager: .default, fileURL: fileURL)
        store.load()

        XCTAssertEqual(store.settings.quality, Settings.default.quality)
        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertEqual(onDisk, original)
    }

    func testUpdateNormalizesAndPersists() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeIfExists(root) }

        let fileURL = root.appendingPathComponent("settings.json")
        let store = SettingsStore(fileManager: .default, fileURL: fileURL)
        store.load()

        store.update { settings in
            settings.quality = 12
            settings.maxWidth = -100
            settings.screenshotCounter = 0
        }

        XCTAssertEqual(store.settings.quality, 10)
        XCTAssertEqual(store.settings.maxWidth, 0)
        XCTAssertEqual(store.settings.screenshotCounter, 1)

        let decoded = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(decoded.quality, 10)
        XCTAssertEqual(decoded.maxWidth, 0)
        XCTAssertEqual(decoded.screenshotCounter, 1)
    }
}
