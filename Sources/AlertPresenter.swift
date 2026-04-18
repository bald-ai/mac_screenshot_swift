import AppKit

enum AlertPresenter {
    static func presentWarning(title: String, message: String) {
        let showAlert = {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        if Thread.isMainThread {
            showAlert()
        } else {
            DispatchQueue.main.async(execute: showAlert)
        }
    }

    static func presentWarningWithSettingsButton(title: String, message: String,
                                                  settingsURL: String = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        let showAlert = {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: settingsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        if Thread.isMainThread {
            showAlert()
        } else {
            DispatchQueue.main.async(execute: showAlert)
        }
    }
}
