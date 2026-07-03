import AppKit
import Foundation

enum AppLog {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let fileURL: URL = {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Zoomies", isDirectory: true)
        return logsDirectory.appendingPathComponent("zoomies.log", isDirectory: false)
    }()

    static func event(_ message: String,
                      file: StaticString = #fileID,
                      line: UInt = #line,
                      function: StaticString = #function) {
        let timestamp = formatter.string(from: Date())
        let thread = Thread.isMainThread ? "main" : "background"
        let processID = ProcessInfo.processInfo.processIdentifier
        let entry = "\(timestamp) pid=\(processID) thread=\(thread) \(file):\(line) \(function) - \(message)\n"

        NSLog("[Zoomies] %@", entry.trimmingCharacters(in: .newlines))
        append(entry)
    }

    static func windowState(_ label: String, window: NSWindow?) {
        guard let window else {
            event("\(label): window=nil")
            return
        }

        let screenFrame = window.screen.map { NSStringFromRect($0.frame) } ?? "nil"
        let state = [
            "visible=\(window.isVisible)",
            "key=\(window.isKeyWindow)",
            "main=\(window.isMainWindow)",
            "onActiveSpace=\(window.isOnActiveSpace)",
            "level=\(window.level.rawValue)",
            "frame=\(NSStringFromRect(window.frame))",
            "screenFrame=\(screenFrame)"
        ].joined(separator: " ")

        event("\(label): \(state)")
    }

    private static func append(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            guard let data = entry.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: fileURL, options: [.atomic])
            }
        } catch {
            NSLog("[Zoomies] Failed to write log: %@", error.localizedDescription)
        }
    }
}
