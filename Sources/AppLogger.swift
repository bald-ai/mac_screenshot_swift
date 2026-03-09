import Foundation

enum AppLogger {
    static func error(_ message: String, error: Error? = nil) {
        if let error {
            NSLog("Zoomies ERROR: %@ (%@)", message, error.localizedDescription)
        } else {
            NSLog("Zoomies ERROR: %@", message)
        }
    }
}
