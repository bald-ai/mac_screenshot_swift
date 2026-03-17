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
    private let settingsStore: SettingsStore
    private let clipboardService: ClipboardService
    private let backupService: BackupService
    private let sourceScreen: NSScreen?
    private let escapeKeyDeletesFile: Bool

    private var renameController: RenamePanelController?
    private var noteController: NotePanelController?
    private var editorController: EditorWindowController?

    private var pendingNoteText: String = ""
    private var pendingEditedImage: NSImage?
    private var burnedNoteText: String = ""
    private var hasCreatedBackup = false
    private var backupOriginalURL: URL?

    /// Optional callback invoked once the workflow has fully completed.
    var onFinish: (() -> Void)?

    init(fileURL: URL,
         settingsStore: SettingsStore,
         clipboardService: ClipboardService,
         backupService: BackupService,
         sourceScreen: NSScreen?,
         escapeKeyDeletesFile: Bool) {
        self.fileURL = fileURL
        self.settingsStore = settingsStore
        self.clipboardService = clipboardService
        self.backupService = backupService
        self.sourceScreen = sourceScreen
        self.escapeKeyDeletesFile = escapeKeyDeletesFile
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

    private func handleRenameAction(_ action: RenamePanelAction) {
        switch action {
        case .save(let newName):
            guard applyRenameIfNeeded(newName: newName) else {
                return
            }
            complete(action: .saveOnly, note: nil)

        case .copyAndSave(let newName):
            guard applyRenameIfNeeded(newName: newName) else {
                return
            }
            complete(action: .copyAndSave, note: nil)

        case .copyAndDelete(let newName):
            guard applyRenameIfNeeded(newName: newName) else {
                return
            }
            complete(action: .copyAndDelete, note: nil)

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
        let currentName = fileURL.lastPathComponent
        if trimmed.isEmpty || trimmed == currentName {
            return true
        }

        let sanitizedFullName = sanitizeFilename(trimmed, preservingExtensionOf: fileURL)
        let targetURL = uniqueURL(forProposedName: sanitizedFullName, in: fileURL.deletingLastPathComponent())

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

    private func handleNoteAction(_ action: NotePanelAction) {
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
            existing.dismissWithoutCompletion()
            editorController = nil
        }

        let editor: EditorWindowController?
        if let pendingEditedImage {
            editor = EditorWindowController(image: pendingEditedImage,
                                            settingsStore: settingsStore,
                                            notePreview: text,
                                            targetScreen: sourceScreen,
                                            escapeKeyDeletesFile: escapeKeyDeletesFile)
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

        editor.onComplete = { [weak self] image, action in
            self?.handleEditorCompletion(editedImage: image, action: action)
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
            editor.dismissWithoutCompletion()
            editorController = nil
        }
        presentNotePanel(existingText: pendingNoteText)
    }

    func handleEditorCompletion(editedImage: NSImage?, action: FinalAction) {
        editorController?.dismissWithoutCompletion()
        editorController = nil
        pendingEditedImage = nil

        var finalImage: NSImage?
        if let image = editedImage {
            // Editor returns a flattened image. If there's a pending note, burn it once
            // right before saving/copying so it never stacks/duplicates.
            if let preparedNote = prepareNoteText(pendingNoteText),
               let noted = burn(note: preparedNote.rendered, into: image) {
                finalImage = noted
                burnedNoteText = preparedNote.identity
            } else {
                finalImage = image
                burnedNoteText = ""
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
            guard saveEditedImage(finalImage) else { return }
            // Workflow finished normally: remove backup if one was created.
            removeBackupIfNeeded()
        }

        guard performFinalActionEffects(action, copyAndDeleteImage: finalImage) else { return }
        onFinish?()
    }

    private func saveEditedImage(_ image: NSImage) -> Bool {
        ensureBackupExists()

        let quality = settingsStore.settings.quality
        guard let (data, outputURL) = encodedImageData(from: image, originalURL: fileURL, quality: quality) else {
            presentError(title: "Failed to encode image", message: "Could not encode the edited image.")
            return false
        }

        do {
            try writeEncodedImageData(data, to: outputURL, originalURL: fileURL)
            return true
        } catch {
            presentError(title: "Failed to write image", message: error.localizedDescription)
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

    // MARK: - Completion

    private func complete(action: FinalAction, note: String?) {
        renameController?.close()
        noteController?.close()
        renameController = nil
        noteController = nil

        let pendingImage: NSImage? = {
            if let editor = editorController {
                let image = editor.currentCompositeImage()
                editor.dismissWithoutCompletion()
                editorController = nil
                return image
            }
            return pendingEditedImage
        }()

        let imageToPersist: NSImage?
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
            } else {
                burnedNoteText = ""
            }
            imageToPersist = finalImage
        } else {
            imageToPersist = nil
            if let note {
                guard applyNoteIfNeeded(note) else { return }
            }
        }

        guard persistImageIfNeeded(imageToPersist, for: action) else { return }
        guard performFinalActionEffects(action, copyAndDeleteImage: nil) else { return }
        if action == .saveOnly || action == .copyAndSave {
            removeBackupIfNeeded()
        }

        pendingEditedImage = nil
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

        guard let image = NSImage(contentsOf: fileURL) else {
            presentError(title: "Failed to apply note", message: "Could not read the screenshot image.")
            return false
        }
        guard let updated = burn(note: preparedNote.rendered, into: image) else {
            presentError(title: "Failed to apply note", message: "Could not render the note text.")
            return false
        }

        let quality = settingsStore.settings.quality
        guard let (data, outputURL) = encodedImageData(from: updated, originalURL: fileURL, quality: quality) else {
            presentError(title: "Failed to apply note", message: "Could not encode the noted image.")
            return false
        }

        do {
            try writeEncodedImageData(data, to: outputURL, originalURL: fileURL)
        } catch {
            presentError(title: "Failed to write note", message: error.localizedDescription)
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

    private func persistImageIfNeeded(_ image: NSImage?, for action: FinalAction) -> Bool {
        guard let image else { return true }

        switch action {
        case .saveOnly, .copyAndSave, .copyAndDelete:
            return saveEditedImage(image)
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
                // If format conversion changed the output URL (e.g. HEIC -> JPG),
                // remove the converted file before restoring the original.
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

    private func encodedImageData(from image: NSImage, originalURL: URL, quality: Int) -> (data: Data, outputURL: URL)? {
        let ext = originalURL.pathExtension.lowercased()

        let (fileType, outputExtension, shouldChangeExtensionOnWrite): (NSBitmapImageRep.FileType, String, Bool) = {
            switch ext {
            case "png":
                return (.png, "png", false)
            case "tif", "tiff":
                return (.tiff, ext, false) // preserve tif vs tiff spelling
            case "bmp":
                return (.bmp, "bmp", false)
            case "gif":
                return (.gif, "gif", false)
            case "jpg", "jpeg":
                return (.jpeg, ext, false) // preserve jpg vs jpeg spelling
            case "heic", "heif":
                // NSBitmapImageRep cannot encode HEIC. Fall back to JPEG.
                return (.jpeg, "jpg", true)
            default:
                // Unknown extension; safest default is JPEG.
                return (.jpeg, "jpg", false)
            }
        }()

        let sourceImage = flattenedToEditorBackgroundIfNeeded(image, for: fileType)
        guard let bitmap = ScreenshotServiceCoreLogic.bitmapRepresentation(from: sourceImage) else { return nil }

        let properties: [NSBitmapImageRep.PropertyKey: Any]
        if fileType == .jpeg {
            let clamped = max(10, min(100, quality))
            let compression = CGFloat(clamped) / 100.0
            properties = [.compressionFactor: compression]
        } else {
            properties = [:]
        }

        guard let data = bitmap.representation(using: fileType, properties: properties) else { return nil }

        let outputURL: URL
        if shouldChangeExtensionOnWrite && !ext.isEmpty && outputExtension != ext {
            // Extension changed (e.g. HEIC -> JPG). Pick a non-colliding target name.
            let proposedName = originalURL.deletingPathExtension().lastPathComponent + "." + outputExtension
            outputURL = uniqueURL(forProposedName: proposedName, in: originalURL.deletingLastPathComponent())
        } else {
            outputURL = originalURL
        }

        return (data, outputURL)
    }

    private func flattenedToEditorBackgroundIfNeeded(_ image: NSImage,
                                                     for fileType: NSBitmapImageRep.FileType) -> NSImage {
        guard fileType == .jpeg else { return image }

        let size = image.size
        return NSImage(size: size, flipped: true) { rect in
            // JPEG can't keep transparency. Use a neutral non-themed background color.
            NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
            rect.fill()
            image.draw(in: rect,
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0,
                       respectFlipped: true,
                       hints: nil)
            return true
        }
    }

    private func writeEncodedImageData(_ data: Data, to outputURL: URL, originalURL: URL) throws {
        try data.write(to: outputURL, options: .atomic)

        if outputURL != originalURL {
            // We wrote a new file with a new extension (e.g. HEIC -> JPG). Remove the old one.
            let fm = FileManager.default
            if fm.fileExists(atPath: originalURL.path) {
                try? fm.removeItem(at: originalURL)
            }
            fileURL = outputURL
        }
    }

    // MARK: - Errors

    private func presentError(title: String, message: String) {
        AlertPresenter.presentWarning(title: title, message: message)
    }
}

// MARK: - Floating panel base class

final class FloatingInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)

        isFloatingPanel = true
        level = .statusBar
        // Show in the current Space and over fullscreen apps (Spotlight-like behavior).
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = NSColor.clear
        hasShadow = true
        AppTheme.apply(to: self)

        // Ensure window is properly initialized
        self.isReleasedWhenClosed = false
        
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Non-activating panels often don't get the standard Edit menu key equivalents
        // wired up (Cmd+C/V/X/A). Route them through the responder chain explicitly so
        // copy/paste works in our rename/note fields without activating the app.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command],
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars.count == 1 {
            switch chars {
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }

        return super.performKeyEquivalent(with: event)
    }
}





// MARK: - Command-aware text input controls

enum KeyCommand {
    case enter
    case commandEnter
    case commandBackspace
    case escape
    case tab
    case shiftTab
}

private func interpretKeyCommand(from event: NSEvent) -> KeyCommand? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    switch event.keyCode {
    case 36: // Return
        if flags.contains(.command) {
            return .commandEnter
        } else {
            return .enter
        }
    case 51: // Delete / Backspace
        if flags.contains(.command) {
            return .commandBackspace
        }
    case 53: // Escape
        return .escape
    case 48: // Tab
        if flags.contains(.shift) {
            return .shiftTab
        } else {
            return .tab
        }
    default:
        break
    }

    return nil
}

final class CommandAwareTextField: NSTextField, NSTextFieldDelegate {
    var keyCommandHandler: ((KeyCommand) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
        isEditable = true
        isSelectable = true
    }

    override func keyDown(with event: NSEvent) {
        if let command = interpretKeyCommand(from: event) {
            keyCommandHandler?(command)
        } else {
            super.keyDown(with: event)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if let event = NSApp.currentEvent,
           let command = interpretKeyCommand(from: event) {
            keyCommandHandler?(command)
            return true
        }

        switch commandSelector {
        case #selector(insertNewline(_:)):
            keyCommandHandler?(.enter)
            return true
        case #selector(insertTab(_:)):
            keyCommandHandler?(.tab)
            return true
        case #selector(insertBacktab(_:)):
            keyCommandHandler?(.shiftTab)
            return true
        case #selector(cancelOperation(_:)):
            keyCommandHandler?(.escape)
            return true
        default:
            return false
        }
    }

}

final class CommandAwareTextView: NSTextView {
    var keyCommandHandler: ((KeyCommand) -> Void)?

    override func keyDown(with event: NSEvent) {
        if let command = interpretKeyCommand(from: event) {
            keyCommandHandler?(command)
        } else {
            super.keyDown(with: event)
        }
    }
}
