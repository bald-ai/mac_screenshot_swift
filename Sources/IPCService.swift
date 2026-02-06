import Foundation
import AppKit

/// IPC service that allows CLI tools to control the running app
final class IPCService {
    private var socket: Int32 = -1
    private var serverTask: Task<Void, Never>?
    private let socketPath: String
    private weak var appDelegate: AppDelegate?
    
    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.socketPath = home.appendingPathComponent(".screenshot_app_ipc.sock").path
        
        // Clean up old socket
        try? FileManager.default.removeItem(atPath: socketPath)
    }
    
    func start() {
        Logger.shared.info("IPCService: Starting IPC server at \(socketPath)")
        
        serverTask = Task { [weak self] in
            await self?.runServer()
        }
    }
    
    func stop() {
        Logger.shared.info("IPCService: Stopping IPC server")
        serverTask?.cancel()
        if socket >= 0 {
            close(socket)
            socket = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }
    
    private func runServer() async {
        // Create socket
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            Logger.shared.error("IPCService: Failed to create socket")
            return
        }
        
        // Bind to address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        strncpy(&addr.sun_path.0, socketPath, Int(strlen(socketPath)))
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard bindResult >= 0 else {
            Logger.shared.error("IPCService: Failed to bind socket")
            close(socket)
            socket = -1
            return
        }
        
        // Listen
        guard Darwin.listen(socket, 5) >= 0 else {
            Logger.shared.error("IPCService: Failed to listen on socket")
            close(socket)
            socket = -1
            return
        }
        
        Logger.shared.info("IPCService: Server listening on \(socketPath)")
        
        // Accept connections
        while !Task.isCancelled {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(socket, sockaddrPtr, &addrLen)
                }
            }
            
            guard clientSocket >= 0 else {
                if !Task.isCancelled {
                    Logger.shared.error("IPCService: Failed to accept connection")
                }
                continue
            }
            
            Task { [weak self] in
                await self?.handleClient(socket: clientSocket)
            }
        }
    }
    
    private func handleClient(socket clientSocket: Int32) async {
        defer { close(clientSocket) }
        
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientSocket, &buffer, buffer.count)
        
        guard bytesRead > 0 else {
            Logger.shared.warning("IPCService: No data received from client")
            return
        }
        
        guard let command = String(bytes: buffer[0..<bytesRead], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            Logger.shared.error("IPCService: Failed to decode command")
            sendResponse(socket: clientSocket, "ERROR: Invalid command encoding")
            return
        }
        
        Logger.shared.info("IPCService: Received command: \(command)")
        
        let response = await executeCommand(command)
        sendResponse(socket: clientSocket, response)
    }
    
    private func sendResponse(socket: Int32, _ response: String) {
        let data = response.data(using: .utf8)!
        _ = data.withUnsafeBytes { ptr in
            write(socket, ptr.baseAddress!, ptr.count)
        }
    }
    
    @MainActor
    private func executeCommand(_ command: String) async -> String {
        Logger.shared.info("IPCService: Executing command: \(command)")
        
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let action = parts[0]
        let args = parts.count > 1 ? parts[1] : ""
        
        switch action {
        case "STATUS":
            return await getStatus()
            
        case "CLOSE_RENAME":
            return await closeRenameWindow()
            
        case "CLOSE_NOTE":
            return await closeNoteWindow()
            
        case "GET_RENAME_STATE":
            return await getRenameWindowState()
            
        case "TRIGGER_RENAME_ACTION":
            return await triggerRenameAction(args)
            
        case "PING":
            return "PONG"
            
        case "QUIT":
            NSApp.terminate(nil)
            return "OK: Quitting"

        case "CANCEL_WORKFLOW":
            return await cancelWorkflow()

        case "DISMISS_ALERTS":
            return await dismissAlerts()

        case "TRIGGER_FULL":
            return await triggerFullscreenCapture()
            
        default:
            return "ERROR: Unknown command '\(action)'"
        }
    }
    
    @MainActor
    private func getStatus() async -> String {
        Logger.shared.info("IPCService: Getting app status")
        
        var status: [String: Any] = [
            "running": true,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        // Check for rename window (FloatingInputPanel or window controller with "Rename" in type)
        let renameWindow = NSApp.windows.first { window in
            let windowType = String(describing: type(of: window))
            let wc = window.windowController
            let wcType = wc != nil ? String(describing: type(of: wc!)) : ""
            return windowType.contains("FloatingInputPanel") || wcType.contains("Rename")
        }
        
        if let renameWindow = renameWindow {
            status["renameWindowOpen"] = true
            status["renameWindowVisible"] = renameWindow.isVisible
            status["renameWindowKey"] = renameWindow.isKeyWindow
            status["renameWindowMain"] = renameWindow.isMainWindow
        } else {
            status["renameWindowOpen"] = false
        }
        
        // Check for note window
        let noteWindow = NSApp.windows.first { window in
            let windowType = String(describing: type(of: window))
            let wc = window.windowController
            let wcType = wc != nil ? String(describing: type(of: wc!)) : ""
            return windowType.contains("FloatingInputPanel") || wcType.contains("Note")
        }
        
        if let noteWindow = noteWindow {
            status["noteWindowOpen"] = true
            status["noteWindowVisible"] = noteWindow.isVisible
        } else {
            status["noteWindowOpen"] = false
        }
        
        // Convert to JSON
        if let jsonData = try? JSONSerialization.data(withJSONObject: status, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        
        return "ERROR: Failed to encode status"
    }
    
    @MainActor
    private func closeRenameWindow() async -> String {
        Logger.shared.info("IPCService: Closing rename window via IPC")
        
        // Try to find and close the rename window
        for window in NSApp.windows {
            let windowType = String(describing: type(of: window))
            let title = window.title
            let wc = window.windowController
            let wcType = wc != nil ? String(describing: type(of: wc!)) : "nil"
            
            Logger.shared.info("IPCService: Checking window: \(windowType), wc: \(wcType), title: '\(title)'")
            
            let isRenameWindow = windowType.contains("FloatingInputPanel") || 
                                wcType.contains("Rename") || 
                                title.contains("Rename")
            
            if isRenameWindow {
                Logger.shared.info("IPCService: Found rename window, closing it")
                window.close()
                
                // Cancel the workflow to reset activeWorkflow state
                Logger.shared.info("IPCService: Cancelling workflow after closing rename window")
                await cancelWorkflow()
                
                return "OK: Rename window closed and workflow cancelled"
            }
        }
        
        // Also check window controllers
        for wc in NSApp.windows.compactMap({ $0.windowController }) {
            let wcType = String(describing: type(of: wc))
            Logger.shared.info("IPCService: Checking window controller: \(wcType)")

            if wcType.contains("Rename") {
                Logger.shared.info("IPCService: Found rename window controller, closing it")
                wc.close()

                // Cancel the workflow to reset activeWorkflow state
                Logger.shared.info("IPCService: Cancelling workflow after closing rename window")
                await cancelWorkflow()

                return "OK: Rename window controller closed and workflow cancelled"
            }
        }

        return "WARNING: No rename window found to close"
    }
    
    @MainActor
    private func closeNoteWindow() async -> String {
        Logger.shared.info("IPCService: Closing note window via IPC")
        
        for window in NSApp.windows {
            let windowType = String(describing: type(of: window))
            let title = window.title
            let wc = window.windowController
            let wcType = wc != nil ? String(describing: type(of: wc!)) : "nil"
            
            let isNoteWindow = windowType.contains("FloatingInputPanel") || 
                              wcType.contains("Note") || 
                              title.contains("Note")
            
            if isNoteWindow {
                Logger.shared.info("IPCService: Found note window, closing it")
                window.close()
                return "OK: Note window closed"
            }
        }
        
        for wc in NSApp.windows.compactMap({ $0.windowController }) {
            let wcType = String(describing: type(of: wc))
            if wcType.contains("Note") {
                Logger.shared.info("IPCService: Found note window controller, closing it")
                wc.close()
                return "OK: Note window controller closed"
            }
        }
        
        return "WARNING: No note window found to close"
    }
    
    @MainActor
    private func getRenameWindowState() async -> String {
        Logger.shared.info("IPCService: Getting rename window state")
        
        var state: [String: Any] = [
            "found": false
        ]
        
        // Check all windows
        for (index, window) in NSApp.windows.enumerated() {
            let windowType = String(describing: type(of: window))
            let title = window.title
            let wc = window.windowController
            let wcType = wc != nil ? String(describing: type(of: wc!)) : "nil"
            
            Logger.shared.info("IPCService: Window \(index): type=\(windowType), wc=\(wcType), title='\(title)', visible=\(window.isVisible), key=\(window.isKeyWindow)")
            
            // Check window type, window controller type, or title for rename indicators
            let isRenameWindow = windowType.contains("FloatingInputPanel") || 
                                wcType.contains("Rename") || 
                                title.contains("Rename")
            
            if isRenameWindow {
                state["found"] = true
                state["index"] = index
                state["windowType"] = windowType
                state["windowControllerType"] = wcType
                state["title"] = title
                state["isVisible"] = window.isVisible
                state["isKeyWindow"] = window.isKeyWindow
                state["isMainWindow"] = window.isMainWindow
                state["canBecomeKey"] = window.canBecomeKey
                state["canBecomeMain"] = window.canBecomeMain
                state["level"] = window.level.rawValue
                state["frame"] = NSStringFromRect(window.frame)
                
                // Check first responder
                if let firstResponder = window.firstResponder {
                    state["firstResponder"] = String(describing: type(of: firstResponder))
                }
                
                // Check content view
                if let contentView = window.contentView {
                    state["contentView"] = String(describing: type(of: contentView))
                }
            }
        }
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        
        return "ERROR: Failed to encode state"
    }
    
    @MainActor
    private func triggerRenameAction(_ action: String) async -> String {
        Logger.shared.info("IPCService: Triggering rename action: \(action)")
        
        // This will need access to the ScreenshotWorkflowController
        // For now, just log that we received it
        return "OK: Action '\(action)' received (implementation pending)"
    }
    
    @MainActor
    private func triggerFullscreenCapture() async -> String {
        Logger.shared.info("IPCService: Triggering fullscreen capture via IPC")

        guard let appDelegate = appDelegate else {
            Logger.shared.error("IPCService: appDelegate is nil")
            return "ERROR: appDelegate is nil"
        }

        appDelegate.triggerFullScreenshotFromIPC()
        return "OK: Fullscreen capture triggered"
    }

    @MainActor
    private func cancelWorkflow() async -> String {
        Logger.shared.info("IPCService: Cancelling workflow via IPC")
        
        guard let appDelegate = appDelegate else {
            Logger.shared.error("IPCService: appDelegate is nil")
            return "ERROR: appDelegate is nil"
        }
        
        appDelegate.cancelActiveWorkflowFromIPC()
        return "OK: Workflow cancelled"
    }

    @MainActor
    private func dismissAlerts() async -> String {
        Logger.shared.info("IPCService: Dismissing alerts via IPC")
        
        // Find and dismiss any NSAlert windows
        var dismissedCount = 0
        for window in NSApp.windows {
            let windowType = String(describing: type(of: window))
            // NSAlert windows are typically NSPanel or NSWindow with specific styling
            if windowType.contains("NSPanel") || window.isModalPanel {
                Logger.shared.info("IPCService: Found potential alert window: \(windowType), closing it")
                window.close()
                dismissedCount += 1
            }
        }
        
        // Also try to abort any modal sessions
        if NSApp.modalWindow != nil {
            Logger.shared.info("IPCService: Stopping modal session")
            NSApp.stopModal()
            dismissedCount += 1
        }
        
        // Cancel any active workflows that might be causing the alert
        await cancelWorkflow()
        
        if dismissedCount > 0 {
            return "OK: Dismissed \(dismissedCount) alert(s) and cancelled workflow"
        } else {
            return "OK: No alerts found, workflow cancelled"
        }
    }
}

// MARK: - CLI Client

enum IPCClient {
    static func send(command: String) async -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let socketPath = home.appendingPathComponent(".screenshot_app_ipc.sock").path
        
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return "ERROR: App not running (socket not found at \(socketPath))"
        }
        
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            return "ERROR: Failed to create socket"
        }
        defer { close(socket) }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        strncpy(&addr.sun_path.0, socketPath, Int(strlen(socketPath)))
        
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard connectResult >= 0 else {
            return "ERROR: Failed to connect to app"
        }
        
        // Send command
        let commandData = (command + "\n").data(using: .utf8)!
        _ = commandData.withUnsafeBytes { ptr in
            write(socket, ptr.baseAddress!, ptr.count)
        }
        
        // Read response
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(socket, &buffer, buffer.count)
        
        guard bytesRead > 0 else {
            return "ERROR: No response from app"
        }
        
        return String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? "ERROR: Invalid response"
    }
}