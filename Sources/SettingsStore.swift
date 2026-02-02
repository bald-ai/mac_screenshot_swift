import Foundation

/// Simple in-memory settings store backed by a JSON file on disk.
///
/// The file is located at `~/.screenshot_app_settings.json` to remain
/// compatible with the existing app's configuration.
final class SettingsStore {
    private(set) var settings: Settings

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let home = fileManager.homeDirectoryForCurrentUser
        self.fileURL = home.appendingPathComponent(".screenshot_app_settings.json", isDirectory: false)

        self.settings = .default
    }

    /// Loads settings from disk if possible, otherwise keeps defaults.
    ///
    /// On any decoding error, the file is ignored and defaults are used.
    func load() {
        do {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                // First launch – write out defaults so future loads succeed.
                settings = .default
                try persist(settings)
                return
            }

            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(Settings.self, from: data)
            settings = decoded.normalized()
        } catch {
            // Fall back to defaults but do not overwrite the possibly-bad file.
            // This mirrors many macOS apps' behavior.
            print("[SettingsStore] Failed to load settings: \(error)")
            settings = .default
        }
    }

    /// Saves the current settings to disk.
    func save() {
        do {
            try persist(settings)
        } catch {
            print("[SettingsStore] Failed to save settings: \(error)")
        }
    }

    /// Applies a mutation to settings and persists the result.
    func update(_ block: (inout Settings) -> Void) {
        block(&settings)
        settings = settings.normalized()
        save()
    }

    // MARK: - Private

    private func persist(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings.normalized())

        // Ensure parent directory exists (it should, but be defensive).
        let directoryURL = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        try data.write(to: fileURL, options: [.atomic])
    }
}
