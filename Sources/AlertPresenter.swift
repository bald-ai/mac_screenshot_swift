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
}
