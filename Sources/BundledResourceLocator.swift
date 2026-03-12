import Foundation

enum BundledResourceLocator {
    static func resourceURL(
        named resourceName: String,
        withExtension resourceExtension: String,
        mainBundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        if let directURL = mainBundle.url(forResource: resourceName, withExtension: resourceExtension) {
            return directURL
        }

        return resourceURL(
            named: resourceName,
            withExtension: resourceExtension,
            searchDirectories: candidateSearchDirectories(for: mainBundle),
            fileManager: fileManager
        )
    }

    static func resourceURL(
        named resourceName: String,
        withExtension resourceExtension: String,
        searchDirectories: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        for directory in uniqueDirectories(searchDirectories) {
            let directURL = directory
                .appendingPathComponent(resourceName)
                .appendingPathExtension(resourceExtension)
            if fileManager.fileExists(atPath: directURL.path) {
                return directURL
            }

            guard let childURLs = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for childURL in childURLs where childURL.pathExtension == "bundle" {
                guard let bundle = Bundle(url: childURL),
                      let bundledURL = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
                    continue
                }
                return bundledURL
            }
        }

        return nil
    }

    private static func candidateSearchDirectories(for mainBundle: Bundle) -> [URL] {
        var directories: [URL] = []
        directories.append(mainBundle.bundleURL)

        if let resourceURL = mainBundle.resourceURL {
            directories.append(resourceURL)
        }

        directories.append(
            mainBundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
        )

        if let executableURL = mainBundle.executableURL {
            directories.append(executableURL.deletingLastPathComponent())
        }

        return directories
    }

    private static func uniqueDirectories(_ directories: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var unique: [URL] = []

        for directory in directories {
            let standardizedPath = directory.standardizedFileURL.path
            if seenPaths.insert(standardizedPath).inserted {
                unique.append(directory)
            }
        }

        return unique
    }
}
