import Foundation

enum AppLogger {
    static func error(_ message: String, error: Error? = nil) {
        if let error {
            NSLog("ScreenshotApp ERROR: %@ (%@)", message, error.localizedDescription)
        } else {
            NSLog("ScreenshotApp ERROR: %@", message)
        }
    }
}
