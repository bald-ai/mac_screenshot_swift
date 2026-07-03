import AppKit

/// Runs the plain-text note flow using the same filename and note panels as the
/// screenshot workflow. Scratchpad saves the note text as a `.md` file.
final class ScratchpadService {
    private let clipboardService: ClipboardService
    private let noteWriter: ScratchpadNoteWriter

    private var renamePanelController: RenamePanelController?
    private var notePanelController: NotePanelController?
    private var currentBaseName: String = ""
    private var cachedText: String = ""

    init(fileManager: FileManager = .default,
         clipboardService: ClipboardService,
         desktopDirectory: URL? = nil) {
        self.clipboardService = clipboardService
        let resolvedDesktopDirectory = desktopDirectory
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        self.noteWriter = ScratchpadNoteWriter(fileManager: fileManager, directory: resolvedDesktopDirectory)
    }

    func open() {
        AppLog.event("ScratchpadService.open requested")
        DispatchQueue.main.async { [weak self] in
            AppLog.event("ScratchpadService.open deferred")
            self?.openOnMain()
        }
    }

    private func openOnMain() {
        AppLog.event("ScratchpadService.openOnMain renameOpen=\(renamePanelController != nil) noteOpen=\(notePanelController != nil)")

        if let notePanelController {
            AppLog.windowState("scratchpad note existing before show", window: notePanelController.window)
            notePanelController.show()
            AppLog.windowState("scratchpad note existing after show", window: notePanelController.window)
            return
        }

        if let renamePanelController {
            AppLog.windowState("scratchpad rename existing before show", window: renamePanelController.window)
            renamePanelController.show()
            AppLog.windowState("scratchpad rename existing after show", window: renamePanelController.window)
            return
        }

        currentBaseName = ScratchpadFilenameLogic.defaultBaseName(date: Date())
        cachedText = ""
        presentRenamePanel()
    }

    // MARK: - Rename

    private func presentRenamePanel() {
        AppLog.event("ScratchpadService presenting filename baseName=\(currentBaseName)")
        let controller = RenamePanelController(
            initialFilename: currentBaseName + ".md",
            escapeKeyDeletesFile: false,
            returnTargetLabel: "Note",
            showsCopyAndDiscard: false
        )
        controller.onAction = { [weak self] action in self?.handleRenameAction(action) }
        renamePanelController = controller
        centerOnActiveScreen(controller.window)
        AppLog.windowState("scratchpad rename before show", window: controller.window)
        controller.show()
        AppLog.windowState("scratchpad rename after show", window: controller.window)
    }

    private func handleRenameAction(_ action: RenamePanelAction) {
        AppLog.event("ScratchpadService rename action=\(action.logLabel)")
        switch action {
        case .save(let newName):
            saveAndClose(text: cachedText, newName: newName, copy: false)
        case .copyAndSave(let newName):
            saveAndClose(text: cachedText, newName: newName, copy: true)
        case .copyAndDelete:
            break
        case .delete, .close:
            closeFlow()
        case .goToNote(let newName):
            currentBaseName = ScratchpadFilenameLogic.resolveBaseName(userInput: newName, fallback: currentBaseName)
            presentNotePanel()
            renamePanelController?.close()
            renamePanelController = nil
        }
    }

    // MARK: - Note

    private func presentNotePanel() {
        AppLog.event("ScratchpadService presenting note textLength=\(cachedText.count)")
        let controller = NotePanelController(
            initialText: cachedText,
            escapeKeyDeletesFile: false,
            showsCopyAndDelete: false,
            showsEditorShortcut: false
        )
        controller.onAction = { [weak self] action in self?.handleNoteAction(action) }
        notePanelController = controller
        centerOnActiveScreen(controller.window)
        AppLog.windowState("scratchpad note before show", window: controller.window)
        controller.show()
        AppLog.windowState("scratchpad note after show", window: controller.window)
    }

    private func handleNoteAction(_ action: NotePanelAction) {
        AppLog.event("ScratchpadService note action=\(action.logLabel)")
        switch action {
        case .save(let text):
            saveAndClose(text: text, newName: currentBaseName, copy: false)
        case .copyAndSave(let text):
            saveAndClose(text: text, newName: currentBaseName, copy: true)
        case .copyAndDelete, .delete, .goToEditor:
            break
        case .close:
            closeFlow()
        case .backToRename(let text):
            cachedText = text
            presentRenamePanel()
            notePanelController?.close()
            notePanelController = nil
        }
    }

    // MARK: - Completion

    private func saveAndClose(text: String, newName: String, copy: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLog.event("ScratchpadService save blocked: empty text copy=\(copy)")
            NSSound.beep()
            return
        }

        currentBaseName = ScratchpadFilenameLogic.resolveBaseName(userInput: newName, fallback: currentBaseName)
        do {
            let url = try noteWriter.write(text: text, baseName: currentBaseName)
            AppLog.event("ScratchpadService saved note url=\(url.path) copy=\(copy)")
            if copy {
                clipboardService.copyFile(at: url, useCache: false)
            }
            closeFlow()
        } catch {
            AppLog.event("ScratchpadService save failed error=\(error.localizedDescription)")
            AlertPresenter.presentWarning(title: "Couldn't save note", message: error.localizedDescription)
        }
    }

    private func closeFlow() {
        AppLog.event("ScratchpadService closeFlow")
        renamePanelController?.close()
        notePanelController?.close()
        renamePanelController = nil
        notePanelController = nil
        currentBaseName = ""
        cachedText = ""
    }

    private func centerOnActiveScreen(_ window: NSWindow?) {
        guard let window else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }

        let origin = FloatingPanelPositionLogic.centeredOrigin(
            windowSize: window.frame.size,
            in: screen.visibleFrame
        )
        window.setFrameOrigin(origin)
    }

}

struct ScratchpadNoteWriter {
    private let fileManager: FileManager
    private let directory: URL

    init(fileManager: FileManager = .default, directory: URL) {
        self.fileManager = fileManager
        self.directory = directory
    }

    @discardableResult
    func write(text: String, baseName: String) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = UniqueFileURLLogic.uniqueURL(
            forProposedName: "\(baseName).md",
            in: directory,
            fileExists: { [fileManager] path in fileManager.fileExists(atPath: path) }
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private extension RenamePanelAction {
    var logLabel: String {
        switch self {
        case .save(let newName):
            return "save name=\(newName)"
        case .copyAndSave(let newName):
            return "copyAndSave name=\(newName)"
        case .copyAndDelete(let newName):
            return "copyAndDelete name=\(newName)"
        case .delete:
            return "delete"
        case .close:
            return "close"
        case .goToNote(let newName):
            return "goToNote name=\(newName)"
        }
    }
}

private extension NotePanelAction {
    var logLabel: String {
        switch self {
        case .save(let text):
            return "save length=\(text.count)"
        case .copyAndSave(let text):
            return "copyAndSave length=\(text.count)"
        case .copyAndDelete(let text):
            return "copyAndDelete length=\(text.count)"
        case .delete:
            return "delete"
        case .close:
            return "close"
        case .backToRename(let text):
            return "backToRename length=\(text.count)"
        case .goToEditor(let text):
            return "goToEditor length=\(text.count)"
        }
    }
}
