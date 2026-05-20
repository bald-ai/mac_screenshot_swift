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
                }
            }
        } catch {
        }
    }
}
