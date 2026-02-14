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
        editorController?.close()
        renameController = nil
        noteController = nil
        editorController = nil
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
        let ext = url.pathExtension

        var base = input
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) {
            base = String(base.dropLast(ext.count + 1))
        }

        let forbidden = CharacterSet(charactersIn: "/:")
        let cleaned = base.components(separatedBy: forbidden).joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBase = trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed

        if ext.isEmpty {
            return finalBase
        } else {
            return "\(finalBase).\(ext)"
        }
    }

    private func uniqueURL(forProposedName name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let baseName = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var attempt = 1
        while true {
            let fileName: String
            if attempt == 1 {
                fileName = name
            } else {
                let suffix = "_\(attempt)"
                if ext.isEmpty {
                    fileName = baseName + suffix
                } else {
                    fileName = baseName + suffix + "." + ext
                }
            }

            let url = directory.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: url.path) {
                return url
            }
            attempt += 1
        }
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

        guard let editor = EditorWindowController(imageURL: fileURL,
                                                  settingsStore: settingsStore,
                                                  notePreview: text,
                                                  escapeKeyDeletesFile: escapeKeyDeletesFile) else {
            // If the editor fails to load, fall back to a regular save.
            complete(action: .saveOnly, note: nil)
            return
        }

        editor.onComplete = { [weak self] image, action in
            self?.handleEditorCompletion(editedImage: image, action: action)
        }
        editor.onBackToNote = { [weak self] image in
            self?.returnToNoteFromEditor(editedImage: image)
        }

        editorController = editor
        editor.show()
    }

    private func returnToNoteFromEditor(editedImage: NSImage) {
        editorController?.close()
        editorController = nil
        saveEditedImage(editedImage)
        presentNotePanel(existingText: pendingNoteText)
    }

    private func handleEditorCompletion(editedImage: NSImage?, action: FinalAction) {
        editorController?.close()
        editorController = nil

        if let image = editedImage {
            // Editor returns a flattened image. If there's a pending note, burn it once
            // right before saving/copying so it never stacks/duplicates.
            let trimmedNote = pendingNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalImage: NSImage
            if !trimmedNote.isEmpty, let noted = notedImage(base: image, rawNote: trimmedNote) {
                finalImage = noted
                burnedNoteText = String(trimmedNote.prefix(1000))
            } else {
                finalImage = image
                burnedNoteText = ""
            }

            switch action {
            case .saveOnly, .copyAndSave:
                // Save the final (possibly noted) image to disk.
                saveEditedImage(finalImage)
                // Workflow finished normally: remove backup if one was created.
                removeBackupIfNeeded()
            case .copyAndDelete, .deleteOnly:
                break
            case .closeOnly:
                // Cancel/close: do not write to disk; restore original if needed.
                if restoreOriginalFromBackupIfAvailable() {
                    removeBackupIfNeeded()
                }
            }

            switch action {
            case .saveOnly:
                break
            case .copyAndSave:
                clipboardService.writeImage(finalImage)
            case .copyAndDelete:
                clipboardService.writeImage(finalImage)
                deleteFileAndBackup()
            case .deleteOnly:
                deleteFileAndBackup()
            case .closeOnly:
                break
            }
        } else {
            switch action {
            case .saveOnly:
                break
            case .copyAndSave:
                clipboardService.copyFile(at: fileURL, useCache: false)
            case .copyAndDelete:
                clipboardService.copyFile(at: fileURL, useCache: true)
                deleteFileAndBackup()
            case .deleteOnly:
                deleteFileAndBackup()
            case .closeOnly:
                if restoreOriginalFromBackupIfAvailable() {
                    removeBackupIfNeeded()
                }
            }
        }

        onFinish?()
    }

    private func saveEditedImage(_ image: NSImage) {
        ensureBackupExists()

        let quality = settingsStore.settings.quality
        guard let (data, outputURL) = encodedImageData(from: image, originalURL: fileURL, quality: quality) else {
            presentError(title: "Failed to encode image", message: "Could not encode the edited image.")
            return
        }

        do {
            try writeEncodedImageData(data, to: outputURL, originalURL: fileURL)
        } catch {
            presentError(title: "Failed to write image", message: error.localizedDescription)
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
        if let note = note {
            guard applyNoteIfNeeded(note) else { return }
        }

        renameController?.close()
        noteController?.close()
        renameController = nil
        noteController = nil

        switch action {
        case .saveOnly:
            // Mirror legacy behavior: if we created a backup during note/editor work,
            // drop it on successful completion to avoid orphaned backups.
            removeBackupIfNeeded()
        case .copyAndSave:
            clipboardService.copyFile(at: fileURL, useCache: false)
            removeBackupIfNeeded()
        case .copyAndDelete:
            clipboardService.copyFile(at: fileURL, useCache: true)
            deleteFileAndBackup()
        case .deleteOnly:
            deleteFileAndBackup()
        case .closeOnly:
            closeWorkflowWithoutDeleting()
            return
        }

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
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        if text == burnedNoteText {
            return true
        }

        ensureBackupExists()

        text = String(text.prefix(1000))
        let rawNote = text

        let settings = settingsStore.settings
        if settings.notePrefixEnabled {
            let prefix = settings.notePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                text = prefix + " " + text
            }
        }

        guard let image = NSImage(contentsOf: fileURL) else {
            presentError(title: "Failed to apply note", message: "Could not read the screenshot image.")
            return false
        }
        guard let updated = burn(note: text, into: image) else {
            presentError(title: "Failed to apply note", message: "Could not render the note text.")
            return false
        }

        guard let (data, outputURL) = encodedImageData(from: updated, originalURL: fileURL, quality: settings.quality) else {
            presentError(title: "Failed to apply note", message: "Could not encode the noted image.")
            return false
        }

        do {
            try writeEncodedImageData(data, to: outputURL, originalURL: fileURL)
        } catch {
            presentError(title: "Failed to write note", message: error.localizedDescription)
            return false
        }
        burnedNoteText = rawNote
        return true
    }

    private func notedImage(base image: NSImage, rawNote: String) -> NSImage? {
        var text = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = String(text.prefix(1000))

        let settings = settingsStore.settings
        if settings.notePrefixEnabled {
            let prefix = settings.notePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                text = prefix + " " + text
            }
        }

        return burn(note: text, into: image)
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
        editorController?.close()
        renameController = nil
        noteController = nil
        editorController = nil
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [""] }

        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return [""] }

        func measure(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: attributes).width
        }

        var lines: [String] = []
        var currentLine = ""

        func splitLongWord(_ word: String) -> String {
            var segment = ""
            for char in word {
                let candidate = segment + String(char)
                if measure(candidate) <= maxWidth {
                    segment = candidate
                } else {
                    if !segment.isEmpty {
                        lines.append(segment)
                    }
                    segment = String(char)
                }
            }
            return segment
        }

        for word in words {
            let nextLine = currentLine.isEmpty ? word : "\(currentLine) \(word)"
            if measure(nextLine) <= maxWidth {
                currentLine = nextLine
                continue
            }

            if !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = ""
            }

            if measure(word) <= maxWidth {
                currentLine = word
            } else {
                currentLine = splitLongWord(word)
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines.isEmpty ? [""] : lines
    }

    private func jpegData(from image: NSImage, quality: Int) -> Data? {
        // Kept for backwards-compat calls; prefer `encodedImageData(...)`.
        let sourceImage = flattenedToEditorBackgroundIfNeeded(image, for: .jpeg)
        guard let tiff = sourceImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let clamped = max(10, min(100, quality))
        let compression = CGFloat(clamped) / 100.0
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
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
        guard let tiff = sourceImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

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
        let flattened = NSImage(size: size)
        flattened.lockFocusFlipped(true)
        // Match editor canvas background color (#1f6b6f) so cut transparency
        // appears visually identical after JPEG flattening.
        NSColor(calibratedRed: 31.0 / 255.0,
                green: 107.0 / 255.0,
                blue: 111.0 / 255.0,
                alpha: 1.0).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0,
                   respectFlipped: true,
                   hints: nil)
        flattened.unlockFocus()
        return flattened
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Floating panel base class

final class FloatingInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        // Ensure we're on main thread for window creation
        if !Thread.isMainThread {
        }
        
        // Try creating the panel - if this crashes, it's likely a macOS window server issue
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)  // Changed to defer: true for safety

        isFloatingPanel = true
        level = .statusBar
        // Show in the current Space and over fullscreen apps (Spotlight-like behavior).
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = NSColor.clear
        hasShadow = true
        
        // Ensure window is properly initialized
        self.isReleasedWhenClosed = false
        
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
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
        if let command = interpret(event: event) {
            keyCommandHandler?(command)
        } else {
            super.keyDown(with: event)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if let event = NSApp.currentEvent,
           let command = interpret(event: event) {
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

    private func interpret(event: NSEvent) -> KeyCommand? {
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
}

final class CommandAwareTextView: NSTextView {
    var keyCommandHandler: ((KeyCommand) -> Void)?

    override func keyDown(with event: NSEvent) {
        if let command = interpret(event: event) {
            keyCommandHandler?(command)
        } else {
            super.keyDown(with: event)
        }
    }

    private func interpret(event: NSEvent) -> KeyCommand? {
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
}
