import Foundation

enum UniqueFileURLLogic {
    static func uniqueURL(forProposedName name: String,
                          in directory: URL,
                          fileExists: (String) -> Bool) -> URL {
        let baseName = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var attempt = 1
        while true {
            let fileName: String
            if attempt == 1 {
                fileName = name
            } else {
                let suffix = "_\(attempt)"
                if ext.isEmpty {
                    fileName = baseName + suffix
                } else {
                    fileName = baseName + suffix + "." + ext
                }
            }

            let url = directory.appendingPathComponent(fileName)
            if !fileExists(url.path) {
                return url
            }
            attempt += 1
        }
    }
}
