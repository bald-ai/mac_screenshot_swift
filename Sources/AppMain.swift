import AppKit
import ScreenCaptureKit
import CoreGraphics

@main
struct MainApplication {
    static func main() {
        let args = CommandLine.arguments
        
        // Check for diagnostic/control CLI commands first
        if let response = handleDiagnosticCommand(args) {
            print(response)
            return
        }
        
        // Check for standalone CLI commands
        if args.contains("--capture-fullscreen") {
            runCLIFullscreenCapture()
            return
        }
        
        // Otherwise run the GUI app
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
    
    private static func handleDiagnosticCommand(_ args: [String]) -> String? {
        // These commands require the app to be running - they use IPC
        guard args.count > 1 else { return nil }
        
        let command = args[1]
        
        switch command {
        case "status", "--status":
            return runIPCSync(command: "STATUS")
            
        case "close-rename", "--close-rename":
            return runIPCSync(command: "CLOSE_RENAME")
            
        case "close-note", "--close-note":
            return runIPCSync(command: "CLOSE_NOTE")
            
        case "rename-state", "--rename-state":
            return runIPCSync(command: "GET_RENAME_STATE")
            
        case "ping", "--ping":
            return runIPCSync(command: "PING")
            
        case "quit", "--quit":
            return runIPCSync(command: "QUIT")

        case "trigger-full", "--trigger-full":
            return runIPCSync(command: "TRIGGER_FULL")

        case "dismiss-alerts", "--dismiss-alerts":
            return runIPCSync(command: "DISMISS_ALERTS")

        case "help", "--help", "-h":
            return diagnosticHelp()
            
        default:
            return nil
        }
    }
    
    private static func runIPCSync(command: String) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = "ERROR: Timeout"
        
        Task {
            result = await IPCClient.send(command: command)
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 5.0)
        return result
    }
    
    private static func diagnosticHelp() -> String {
        return """
        ScreenshotApp Diagnostic CLI
        
        Usage: ScreenshotApp <command>
        
        Commands:
          status          - Get app status and window state
          close-rename    - Force close the rename window
          close-note      - Force close the note window
          rename-state    - Get detailed rename window diagnostics
          ping            - Check if app is responsive
          quit            - Gracefully quit the app
          trigger-full    - Trigger fullscreen capture (shows rename window)
          dismiss-alerts  - Dismiss any blocking alerts and cancel workflow
          help            - Show this help
        
        Note: These commands require the ScreenshotApp to be running.
        """
    }
    
    @MainActor
    private static func runCLIFullscreenCapture() {
        print("ScreenshotApp CLI: Capturing fullscreen...")
        
        // Create minimal AppKit environment for ScreenCaptureKit
        let app = NSApplication.shared
        
        Task {
            do {
                let url = try await captureFullscreenCLI()
                print("Screenshot saved to: \(url.path)")
                await MainActor.run {
                    app.terminate(nil)
                }
            } catch {
                print("Error: \(error)")
                await MainActor.run {
                    app.terminate(1)
                }
            }
        }
        
        // Run briefly to allow the async task to complete
        app.run()
    }
    
    private static func captureFullscreenCLI() async throws -> URL {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "No screen found"])
        }
        
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = "Screenshot_\(dateFormatter.string(from: Date()))"
        var url = desktop.appendingPathComponent(baseName).appendingPathExtension("jpg")
        
        // Ensure unique filename
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("\(baseName)_\(suffix)").appendingPathExtension("jpg")
            suffix += 1
        }
        
        if #available(macOS 14.0, *) {
            // Use ScreenCaptureKit
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw NSError(domain: "CLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
            }
            
            let configuration = SCStreamConfiguration()
            configuration.width = Int(display.width)
            configuration.height = Int(display.height)
            configuration.showsCursor = true
            
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            
            let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let image = image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: NSError(domain: "CLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "No image captured"]))
                    }
                }
            }
            
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpegData = bitmap.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.9]) else {
                throw NSError(domain: "CLI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
            }
            
            try jpegData.write(to: url, options: Data.WritingOptions.atomic)
        } else {
            // Fallback to legacy API
            guard let displayID = screen.displayID else {
                throw NSError(domain: "CLI", code: 5, userInfo: [NSLocalizedDescriptionKey: "No display ID"])
            }
            
            guard let cgImage = CGDisplayCreateImage(displayID) else {
                throw NSError(domain: "CLI", code: 6, userInfo: [NSLocalizedDescriptionKey: "CGDisplayCreateImage failed"])
            }
            
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpegData = bitmap.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.9]) else {
                throw NSError(domain: "CLI", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
            }
            
            try jpegData.write(to: url, options: Data.WritingOptions.atomic)
        }
        
        return url
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
