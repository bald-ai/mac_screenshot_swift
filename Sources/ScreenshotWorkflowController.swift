import AppKit

/// Coordinates the post-capture flow for a single screenshot:
/// rename popup, optional note popup, and final actions
/// (save, copy+save, copy+delete, delete).
///
/// One instance exists per screenshot and is owned by `ScreenshotService`.
final class ScreenshotWorkflowController {
    enum FinalAction {
        case saveOnly
        case copyAndSave
        case copyAndDelete
        case deleteOnly
        case closeOnly
    }

    private var fileURL: URL
    private var initialImage: NSImage?
    private var initialFilePersistence: Task<URL, Error>?
    private var initialFileReadyURL: URL?
    private let settingsStore: SettingsStore
    private let clipboardService: ClipboardService
    private let backupService: BackupService
    private let sourceScreen: NSScreen?
    private let escapeKeyDeletesFile: Bool

    /// The clean (pre-note) original used to round-trip prompt edits when a saved
    /// PNG is reopened. For a fresh capture this is the in-memory image; for a
    /// reopened Zoomies PNG it is the original recovered from embedded metadata,
    /// so repeated re-edits never bake a note on top of an already-burned image.
    private let cleanOriginalPNG: Data?
    private let initialEditorState: EditorCanvasState?

    private var renameController: RenamePanelController?
    private var noteController: NotePanelController?
    private var editorController: EditorWindowController?

    var pendingNoteText: String = ""
    private var pendingEditedImage: NSImage?
    private var pendingEditorState: EditorCanvasState?
    private var burnedNoteText: String = ""
    private var hasCreatedBackup = false
    private var backupOriginalURL: URL?

    /// Optional callback invoked once the workflow has fully completed.
    var onFinish: (() -> Void)?

    init(fileURL: URL,
         initialImage: NSImage? = nil,
         initialFilePersistence: Task<URL, Error>? = nil,
         settingsStore: SettingsStore,
         clipboardService: ClipboardService,
         backupService: BackupService,
         sourceScreen: NSScreen?,
         escapeKeyDeletesFile: Bool) {
        self.fileURL = fileURL
        self.initialFilePersistence = initialFilePersistence
        self.settingsStore = settingsStore
        self.clipboardService = clipboardService
        self.backupService = backupService
        self.sourceScreen = sourceScreen
        self.escapeKeyDeletesFile = escapeKeyDeletesFile

        let reopen = Self.resolveReopenMetadata(fileURL: fileURL, initialImage: initialImage)
        self.cleanOriginalPNG = reopen.cleanOriginalPNG
        self.initialEditorState = reopen.editorState
        // Swap the burned-on-disk image for the recovered clean original and
        // pre-fill the prompt the user previously typed.
        self.initialImage = reopen.image ?? initialImage
        if let prompt = reopen.prompt {
            self.pendingNoteText = prompt
        }
    }

    /// Resolves the clean baseline image, in-memory image, and pre-filled prompt
    /// for a workflow, recovering embedded round-trip metadata on reopen.
    private static func resolveReopenMetadata(fileURL: URL, initialImage: NSImage?)
        -> (cleanOriginalPNG: Data?, image: NSImage?, prompt: String?, editorState: EditorCanvasState?) {
        // Fresh capture: the in-memory image is already the clean original.
        // Snapshot it as PNG so it can be embedded as the round-trip baseline.
        if let initialImage {
            return (ScreenshotServiceCoreLogic.pngData(from: initialImage), nil, nil, nil)
        }
        // Reopen: inspect the existing file for embedded round-trip metadata.
        guard let fileData = try? Data(contentsOf: fileURL) else {
            return (nil, nil, nil, nil)
        }
        let editorState = PNGMetadata.extractEditorState(fromPNG: fileData)
        if let extracted = PNGMetadata.extract(fromPNG: fileData) {
            let image = editorState.flatMap { NSImage(data: $0.baseImagePNG) } ?? NSImage(data: extracted.originalPNG)
            return (extracted.originalPNG, image, extracted.prompt, editorState)
        }
        if let editorState {
            return (nil, NSImage(data: editorState.baseImagePNG), nil, editorState)
        }
        // Plain PNG with no metadata: the file itself is the clean baseline.
        if PNGMetadata.isPNG(fileData) {
            return (fileData, nil, nil, nil)
        }
        return (nil, nil, nil, nil)
    }

    // MARK: - Public API

    func start() {
        // Ensure UI operations happen on main thread
        if Thread.isMainThread {
            presentRenamePanel()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.presentRenamePanel()
            }
        }
    }

    func cancel() {
        // Close any open panels
        renameController?.close()
        noteController?.close()
        editorController?.dismissWithoutCompletion()
        renameController = nil
        noteController = nil
        editorController = nil
        pendingEditedImage = nil
        pendingEditorState = nil
    }

    // MARK: - Panels

    private func presentRenamePanel() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.presentRenamePanel()
            }
            return
        }
        let controller = RenamePanelController(initialFilename: fileURL.lastPathComponent,
                                               escapeKeyDeletesFile: escapeKeyDeletesFile)
        controller.onAction = { [weak self] action in
            self?.handleRenameAction(action)
        }
        renameController = controller
        center(controller.window, on: sourceScreen)
        // Do NOT activate or change activation policy here.
        // Activating the app can yank the user out of their current Space/fullscreen app
        // (it often looks like being “sent to Desktop”). We want a Spotlight-like panel.
        controller.show()
    }

    private func presentNotePanel(existingText: String = "") {
        let initialText = existingText.isEmpty ? pendingNoteText : existingText
        let controller = NotePanelController(initialText: initialText,
                                             escapeKeyDeletesFile: escapeKeyDeletesFile)
        controller.onAction = { [weak self] action in
            self?.handleNoteAction(action)
        }
        noteController = controller
        center(controller.window, on: sourceScreen)
        // Same rationale as rename: avoid activating the app (Space/Desktop jump).
        controller.show()
    }

    private func center(_ window: NSWindow?, on screen: NSScreen?) {
        guard let window = window else { return }

        if let screen = screen {
            let frame = screen.visibleFrame
            let size = window.frame.size
            let origin = NSPoint(x: frame.midX - size.width / 2,
                                 y: frame.midY - size.height / 2)
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
    }

    // MARK: - Rename handling

    func handleRenameAction(_ action: RenamePanelAction) {
        // Carry any text typed in the Note panel across a Shift+Tab return to Rename,
        // so saving from Rename still burns the pending note onto the screenshot.
        let carriedNote = pendingNoteText.isEmpty ? nil : pendingNoteText

        switch action {
        case .save(let newName):
            guard applyRenameIfNeeded(newName: newName) else {
                return
            }
            complete(action: .saveOnly, note: carriedNote)

        case .copyAndSave(let newName):
            guard applyRenameIfNeeded(newName: newName) else {
                return
            }
            complete(action: .copyAndSave, note: carriedNote)

        case .copyAndDelete(let newName):
            guard applyRenameIfNeeded(newName: newName) else {
                return
            }
            complete(action: .copyAndDelete, note: carriedNote)

        case .delete:
            complete(action: .deleteOnly, note: nil)

        case .close:
            closeWorkflowWithoutDeleting()

        case .goToNote(let newName):
            guard applyRenameIfNeeded(newName: newName) else {
                return
            }
            presentNotePanel(existingText: pendingNoteText)
            renameController?.close()
            renameController = nil
        }
    }

    private func applyRenameIfNeeded(newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }

        if WorkflowFilenameLogic.isSameFilename(trimmed, as: fileURL) {
            return true
        }

        let sanitizedFullName = sanitizeFilename(trimmed, preservingExtensionOf: fileURL)
        let targetURL = uniqueURL(forProposedName: sanitizedFullName, in: fileURL.deletingLastPathComponent())

        if isWaitingForInitialFilePersistence {
            fileURL = targetURL
            return true
        }

        do {
            try FileManager.default.moveItem(at: fileURL, to: targetURL)
            fileURL = targetURL
            return true
        } catch {
            presentError(title: "Rename failed", message: error.localizedDescription)
            return false
        }
    }

    private func sanitizeFilename(_ input: String, preservingExtensionOf url: URL) -> String {
        WorkflowFilenameLogic.sanitizeFilename(input, preservingExtensionOf: url)
    }

    private func uniqueURL(forProposedName name: String, in directory: URL) -> URL {
        WorkflowFilenameLogic.uniqueURL(
            forProposedName: name,
            in: directory,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    // MARK: - Note handling

    func handleNoteAction(_ action: NotePanelAction) {
        switch action {
        case .save(let text):
            complete(action: .saveOnly, note: text)

        case .copyAndSave(let text):
            complete(action: .copyAndSave, note: text)

        case .copyAndDelete(let text):
            complete(action: .copyAndDelete, note: text)

        case .delete:
            complete(action: .deleteOnly, note: nil)

        case .close:
            closeWorkflowWithoutDeleting()

        case .backToRename(let text):
            pendingNoteText = text
            // Open the destination panel first, then close the source panel.
            // This avoids focus arbitration delays and "no key window" glitches.
            presentRenamePanel()
            noteController?.close()
            noteController = nil

        case .goToEditor(let text):
            pendingNoteText = text
            openEditor(withNote: text)
        }
    }

    // MARK: - Editor

    private func openEditor(withNote text: String) {
        // Close the note panel; the rename panel is already closed by this point.
        noteController?.close()
        noteController = nil

        if let existing = editorController {
            // Rebuild the editor from the current composite image so a changed note
            // preview is reflected when returning Note -> Editor.
            pendingEditedImage = existing.currentCompositeImage()
            pendingEditorState = existing.currentEditableState()
            existing.dismissWithoutCompletion()
            editorController = nil
        }

        let editor: EditorWindowController?
        if let pendingEditedImage {
            editor = EditorWindowController(image: pendingEditedImage,
                                            settingsStore: settingsStore,
                                            notePreview: text,
                                            targetScreen: sourceScreen,
                                            escapeKeyDeletesFile: escapeKeyDeletesFile,
                                            initialState: pendingEditorState)
        } else if let initialImage {
            editor = EditorWindowController(image: initialImage,
                                            settingsStore: settingsStore,
                                            notePreview: text,
                                            targetScreen: sourceScreen,
                                            escapeKeyDeletesFile: escapeKeyDeletesFile,
                                            initialState: initialEditorState)
        } else {
            editor = EditorWindowController(imageURL: fileURL,
                                            settingsStore: settingsStore,
                                            notePreview: text,
                                            targetScreen: sourceScreen,
                                            escapeKeyDeletesFile: escapeKeyDeletesFile)
        }

        guard let editor else {
            // If the editor fails to load, fall back to a regular save.
            complete(action: .saveOnly, note: nil)
            return
        }

        editor.onComplete = { [weak self] image, action, editorState in
            self?.handleEditorCompletion(editedImage: image, action: action, editorState: editorState)
        }
        editor.onBackToNote = { [weak self] in
            self?.returnToNoteFromEditor()
        }

        editorController = editor
        editor.show()
    }

    private func returnToNoteFromEditor() {
        if let editor = editorController {
            pendingEditedImage = editor.currentCompositeImage()
            pendingEditorState = editor.currentEditableState()
            editor.dismissWithoutCompletion()
            editorController = nil
        }
        presentNotePanel(existingText: pendingNoteText)
    }

    func handleEditorCompletion(editedImage: NSImage?, action: FinalAction, editorState: EditorCanvasState? = nil) {
        if action != .closeOnly && isWaitingForInitialFilePersistence {
            waitForInitialFilePersistence { [weak self] ready in
                guard let self, ready else { return }
                self.handleEditorCompletion(editedImage: editedImage, action: action, editorState: editorState)
            }
            return
        }

        editorController?.dismissWithoutCompletion()
        editorController = nil
        pendingEditedImage = nil
        pendingEditorState = nil

        var finalImage: NSImage?
        var baselinePNG: Data?
        var embedPrompt: String?
        var embedEditorState: EditorCanvasState?
        if let image = editedImage {
            // Editor returns a flattened image. If there's a pending note, burn it once
            // right before saving/copying so it never stacks/duplicates.
            if let preparedNote = prepareNoteText(pendingNoteText),
               let noted = burn(note: preparedNote.rendered, into: image) {
                finalImage = noted
                burnedNoteText = preparedNote.identity
                // Editor edits become the new clean baseline; only the note is round-tripped.
                baselinePNG = baselinePNGForEmbedding(preNoteImage: image)
                embedPrompt = preparedNote.identity
                embedEditorState = editorState
            } else {
                finalImage = image
                burnedNoteText = ""
                embedEditorState = editorState
            }
        }

        if action == .closeOnly {
            // Cancel/close: do not write to disk; restore original if needed.
            if restoreOriginalFromBackupIfAvailable() {
                removeBackupIfNeeded()
            }
            onFinish?()
            return
        }

        if let finalImage,
           (action == .saveOnly || action == .copyAndSave) {
            // Save the final (possibly noted) image to disk.
            guard saveEditedImage(finalImage,
                                  baselinePNG: baselinePNG,
                                  prompt: embedPrompt,
                                  editorState: embedEditorState) else { return }
            // Workflow finished normally: remove backup if one was created.
            removeBackupIfNeeded()
        }

        guard performFinalActionEffects(action, copyAndDeleteImage: finalImage) else { return }
        onFinish?()
    }

    private func saveEditedImage(_ image: NSImage,
                                 baselinePNG: Data?,
                                 prompt: String?,
                                 editorState: EditorCanvasState?) -> Bool {
        ensureBackupExists()
        return encodeAndWriteImage(image,
                                   baselinePNG: baselinePNG,
                                   prompt: prompt,
                                   editorState: editorState,
                                   errorTitle: "Failed to save image")
    }

    /// Returns the PNG bytes to embed as the round-trip original for an image the
    /// note will be burned onto, or nil when the output is not a PNG.
    private func baselinePNGForEmbedding(preNoteImage: NSImage) -> Data? {
        guard fileURL.pathExtension.lowercased() == "png" else { return nil }
        return ScreenshotServiceCoreLogic.pngData(from: preNoteImage)
    }

    private func encodeAndWriteImage(_ image: NSImage,
                                     baselinePNG: Data?,
                                     prompt: String?,
                                     editorState: EditorCanvasState?,
                                     errorTitle: String) -> Bool {
        guard let encoded = WorkflowImagePersistenceLogic.encodedImageData(
            from: image,
            originalURL: fileURL,
            cleanOriginalPNG: baselinePNG,
            prompt: prompt,
            editorState: editorState,
            uniqueURL: { name, directory in
                WorkflowFilenameLogic.uniqueURL(forProposedName: name,
                                                in: directory,
                                                fileExists: { FileManager.default.fileExists(atPath: $0) })
            }
        ) else {
            presentError(title: errorTitle, message: "Could not encode the image.")
            return false
        }

        do {
            let finalURL = try WorkflowImagePersistenceLogic.writeEncodedImageData(encoded.data,
                                                                                   to: encoded.outputURL,
                                                                                   originalURL: fileURL)
            if finalURL != fileURL {
                fileURL = finalURL
            }
            return true
        } catch {
            presentError(title: errorTitle, message: error.localizedDescription)
            return false
        }
    }

    private func ensureBackupExists() {
        guard !hasCreatedBackup else { return }
        backupService.createBackup(forOriginalURL: fileURL)
        hasCreatedBackup = true
        backupOriginalURL = fileURL
    }

    private func removeBackupIfNeeded() {
        guard hasCreatedBackup else { return }
        backupService.removeBackup(forOriginalURL: backupOriginalURL ?? fileURL)
        hasCreatedBackup = false
        backupOriginalURL = nil
    }

    private var isWaitingForInitialFilePersistence: Bool {
        initialFileReadyURL == nil && initialFilePersistence != nil
    }

    private func waitForInitialFilePersistence(completion: @escaping (Bool) -> Void) {
        if let initialFileReadyURL {
            fileURL = initialFileReadyURL
            completion(true)
            return
        }

        guard let initialFilePersistence else {
            completion(true)
            return
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                let writtenURL = try await initialFilePersistence.value
                await MainActor.run {
                    do {
                        try self.reconcileInitialFileWriteIfNeeded(writtenURL: writtenURL)
                        completion(true)
                    } catch {
                        self.presentError(title: "Failed to save image", message: error.localizedDescription)
                        completion(false)
                    }
                }
            } catch {
                await MainActor.run {
                    self.initialFilePersistence = nil
                    self.presentError(title: "Failed to save image", message: error.localizedDescription)
                    completion(false)
                }
            }
        }
    }

    private func reconcileInitialFileWriteIfNeeded(writtenURL: URL) throws {
        if let initialFileReadyURL {
            fileURL = initialFileReadyURL
            return
        }

        if writtenURL != fileURL {
            try FileManager.default.moveItem(at: writtenURL, to: fileURL)
        } else {
            fileURL = writtenURL
        }

        initialFileReadyURL = fileURL
        initialFilePersistence = nil
        initialImage = nil
    }

    // MARK: - Completion

    private func complete(action: FinalAction, note: String?) {
        if action != .closeOnly && isWaitingForInitialFilePersistence {
            waitForInitialFilePersistence { [weak self] ready in
                guard let self, ready else { return }
                self.complete(action: action, note: note)
            }
            return
        }

        renameController?.close()
        noteController?.close()
        renameController = nil
        noteController = nil

        let pendingImage: NSImage? = {
            if let editor = editorController {
                let image = editor.currentCompositeImage()
                pendingEditorState = editor.currentEditableState()
                editor.dismissWithoutCompletion()
                editorController = nil
                return image
            }
            return pendingEditedImage
        }()

        let imageToPersist: NSImage?
        var baselinePNG: Data?
        var embedPrompt: String?
        var embedEditorState: EditorCanvasState?
        if let pendingImage {
            var finalImage = pendingImage
            if let note,
               let preparedNote = prepareNoteText(note) {
                guard let noted = burn(note: preparedNote.rendered, into: finalImage) else {
                    presentError(title: "Failed to apply note", message: "Could not render the note text.")
                    return
                }
                finalImage = noted
                burnedNoteText = preparedNote.identity
                // Carried editor edits become the new baseline; only the note round-trips.
                baselinePNG = baselinePNGForEmbedding(preNoteImage: pendingImage)
                embedPrompt = preparedNote.identity
                embedEditorState = pendingEditorState
            } else {
                burnedNoteText = ""
                embedEditorState = pendingEditorState
            }
            imageToPersist = finalImage
        } else {
            imageToPersist = nil
            if let note {
                guard applyNoteIfNeeded(note) else { return }
            }
        }

        guard persistImageIfNeeded(imageToPersist,
                                   for: action,
                                   baselinePNG: baselinePNG,
                                   prompt: embedPrompt,
                                   editorState: embedEditorState) else { return }
        guard performFinalActionEffects(action, copyAndDeleteImage: nil) else { return }
        if action == .saveOnly || action == .copyAndSave {
            removeBackupIfNeeded()
        }

        pendingEditedImage = nil
        pendingEditorState = nil
        burnedNoteText = ""
        onFinish?()
    }

    private func deleteFileAndBackup() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
        }
        backupService.removeBackup(forOriginalURL: backupOriginalURL ?? fileURL)
        hasCreatedBackup = false
        backupOriginalURL = nil
    }

    // MARK: - Note rendering

    @discardableResult
    private func applyNoteIfNeeded(_ rawText: String) -> Bool {
        guard let preparedNote = prepareNoteText(rawText) else { return true }

        if preparedNote.identity == burnedNoteText {
            return true
        }

        ensureBackupExists()

        // Prefer the recovered clean original so re-saving a reopened Zoomies PNG
        // never bakes a note on top of an already-burned image.
        guard let image = initialImage ?? NSImage(contentsOf: fileURL) else {
            presentError(title: "Failed to apply note", message: "Could not read the screenshot image.")
            return false
        }
        guard let updated = burn(note: preparedNote.rendered, into: image) else {
            presentError(title: "Failed to apply note", message: "Could not render the note text.")
            return false
        }

        guard encodeAndWriteImage(updated,
                                  baselinePNG: cleanOriginalPNG,
                                  prompt: preparedNote.identity,
                                  editorState: initialEditorState,
                                  errorTitle: "Failed to apply note") else {
            return false
        }
        burnedNoteText = preparedNote.identity
        return true
    }

    private func prepareNoteText(_ rawText: String) -> (identity: String, rendered: String)? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let identity = String(trimmed.prefix(1000))
        var rendered = identity

        let settings = settingsStore.settings
        if settings.notePrefixEnabled {
            let prefix = settings.notePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                rendered = prefix + " " + identity
            }
        }

        return (identity, rendered)
    }

    private func persistImageIfNeeded(_ image: NSImage?,
                                      for action: FinalAction,
                                      baselinePNG: Data?,
                                      prompt: String?,
                                      editorState: EditorCanvasState?) -> Bool {
        guard let image else { return true }

        switch action {
        case .saveOnly, .copyAndSave, .copyAndDelete:
            return saveEditedImage(image, baselinePNG: baselinePNG, prompt: prompt, editorState: editorState)
        case .deleteOnly, .closeOnly:
            return true
        }
    }

    private func performFinalActionEffects(_ action: FinalAction, copyAndDeleteImage: NSImage?) -> Bool {
        switch action {
        case .saveOnly:
            break
        case .copyAndSave:
            clipboardService.copyFile(at: fileURL, useCache: false)
        case .copyAndDelete:
            if let copyAndDeleteImage {
                clipboardService.copyImageAsFile(copyAndDeleteImage, fileName: fileURL.lastPathComponent)
            } else {
                clipboardService.copyFile(at: fileURL, useCache: true)
            }
            deleteFileAndBackup()
        case .deleteOnly:
            deleteFileAndBackup()
        case .closeOnly:
            closeWorkflowWithoutDeleting()
            return false
        }
        return true
    }

    private func restoreOriginalFromBackupIfAvailable() -> Bool {
        let originalURL = backupOriginalURL ?? fileURL
        let backupURL = backupService.backupURL(forOriginalURL: originalURL)
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path) else { return true }

        do {
            if fm.fileExists(atPath: fileURL.path), fileURL != originalURL {
                // If format conversion changed the output URL (e.g. a non-PNG
                // original rewritten to .png), remove the converted file before
                // restoring the original.
                try? fm.removeItem(at: fileURL)
            }
            if fm.fileExists(atPath: originalURL.path) {
                try fm.removeItem(at: originalURL)
            }
            try fm.copyItem(at: backupURL, to: originalURL)
            fileURL = originalURL
            return true
        } catch {
            presentError(title: "Failed to restore original", message: error.localizedDescription)
            return false
        }
    }

    private func closeWorkflowWithoutDeleting() {
        // Cancel/close semantics for "reopen" flow: close panels without deleting the file.
        // If we have a backup (note/editor touched disk), restore it first.
        if !restoreOriginalFromBackupIfAvailable() { return }
        removeBackupIfNeeded()

        renameController?.close()
        noteController?.close()
        editorController?.dismissWithoutCompletion()
        renameController = nil
        noteController = nil
        editorController = nil
        pendingEditedImage = nil
        pendingEditorState = nil
        burnedNoteText = ""
        onFinish?()
    }

    private func burn(note text: String, into image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let baseWidth = CGFloat(cgImage.width)
        let baseHeight = CGFloat(cgImage.height)
        let minWidth: CGFloat = 400
        let effectiveWidth = max(baseWidth, minWidth)

        let scale = min(2.0, max(1.0, baseWidth / 1280.0))
        let fontSizeBase = max(12, min(20, baseWidth * 0.02))
        let paddingBase = max(8, min(16, baseWidth * 0.015))
        let fontSize = fontSizeBase * scale
        let padding = paddingBase * scale
        let lineHeight = fontSize * 1.4

        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]

        let availableTextWidth = effectiveWidth - padding * 2
        let lines = wrapText(text, maxWidth: availableTextWidth, attributes: attributes)
        let noteHeight = ceil(CGFloat(lines.count) * lineHeight + padding * 2)

        let outputSize = NSSize(width: effectiveWidth, height: baseHeight + noteHeight)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(effectiveWidth),
                                         pixelsHigh: Int(baseHeight + noteHeight),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            return nil
        }
        rep.size = outputSize

        let result = NSImage(size: outputSize)
        result.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high

            if effectiveWidth > baseWidth {
                NSColor(calibratedWhite: 0.95, alpha: 1.0).setFill()
                NSRect(origin: .zero, size: outputSize).fill()
            }

            let imageX = (effectiveWidth - baseWidth) / 2
            let baseImage = NSImage(cgImage: cgImage, size: NSSize(width: baseWidth, height: baseHeight))
            baseImage.draw(in: NSRect(x: imageX, y: noteHeight, width: baseWidth, height: baseHeight),
                           from: .zero,
                           operation: .sourceOver,
                           fraction: 1.0)

            let noteRect = NSRect(x: 0, y: 0, width: effectiveWidth, height: noteHeight)
            NSColor.white.setFill()
            noteRect.fill()

            for (index, line) in lines.enumerated() {
                let topY = noteHeight - padding - CGFloat(index) * lineHeight
                let lineRect = NSRect(x: padding,
                                      y: topY - lineHeight,
                                      width: availableTextWidth,
                                      height: lineHeight)
                (line as NSString).draw(with: lineRect,
                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        return result
    }

    private func wrapText(_ text: String,
                          maxWidth: CGFloat,
                          attributes: [NSAttributedString.Key: Any]) -> [String] {
        WorkflowTextWrapLogic.wrapText(text, maxWidth: maxWidth) { value in
            (value as NSString).size(withAttributes: attributes).width
        }
    }

    // MARK: - Errors

    private func presentError(title: String, message: String) {
        AlertPresenter.presentWarning(title: title, message: message)
    }
}
