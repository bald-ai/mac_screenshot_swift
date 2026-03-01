import Foundation

enum DirectoryPurgeLogic {
    static func purgeContents(of directory: URL,
                              fileManager: FileManager,
                              label: String) {
        do {
            let urls = try fileManager.contentsOfDirectory(at: directory,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
            for url in urls {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    AppLogger.error("Failed removing item while purging \(label): \(url.path)", error: error)
                }
            }
        } catch {
            AppLogger.error("Failed listing directory for \(label): \(directory.path)", error: error)
        }
    }
}
