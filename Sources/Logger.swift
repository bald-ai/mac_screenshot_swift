import Foundation
import os.log

/// Unified logging service for debugging
final class Logger {
    static let shared = Logger()
    
    private let osLog: OSLog
    private let logFileURL: URL
    private let fileManager = FileManager.default
    private let isDebugMode: Bool
    
    private init() {
        // Check for debug mode
        isDebugMode = ProcessInfo.processInfo.environment["SCREENSHOT_APP_DEBUG"] == "1"
        
        // Setup OSLog
        osLog = OSLog(subsystem: "com.screenshotapp", category: "main")
        
        // Setup file logging
        let logsDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ScreenshotApp", isDirectory: true)
        logFileURL = logsDir.appendingPathComponent("ScreenshotApp.log")
        
        // Create logs directory
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        // Write startup marker
        logToFile("=" * 50)
        logToFile("App started at \(Date())")
        logToFile("Debug mode: \(isDebugMode)")
        logToFile("=" * 50)
    }
    
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let entry = formatLogEntry(level: "DEBUG", message: message, file: file, function: function, line: line)
        os_log("%{public}@", log: osLog, type: .debug, entry)
        if isDebugMode {
            logToFile(entry)
        }
    }
    
    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let entry = formatLogEntry(level: "INFO", message: message, file: file, function: function, line: line)
        os_log("%{public}@", log: osLog, type: .info, entry)
        logToFile(entry)
    }

    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let entry = formatLogEntry(level: "WARNING", message: message, file: file, function: function, line: line)
        os_log("%{public}@", log: osLog, type: .default, entry)
        logToFile(entry)
    }
    
    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let entry = formatLogEntry(level: "ERROR", message: message, file: file, function: function, line: line)
        os_log("%{public}@", log: osLog, type: .error, entry)
        logToFile(entry)
    }
    
    func critical(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let entry = formatLogEntry(level: "CRITICAL", message: message, file: file, function: function, line: line)
        os_log("%{public}@", log: osLog, type: .fault, entry)
        logToFile(entry)
    }
    
    private func formatLogEntry(level: String, message: String, file: String, function: String, line: Int) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = (file as NSString).lastPathComponent
        return "[\(timestamp)] [\(level)] [\(filename):\(line)] \(function) - \(message)"
    }
    
    private func logToFile(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        
        if fileManager.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }
}

// String multiplication helper
private extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}