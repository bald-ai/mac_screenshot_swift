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
    }

    private var fileURL: URL
    private let settingsStore: SettingsStore
    private let clipboardService: ClipboardService
    private let backupService: BackupService
    private let sourceScreen: NSScreen?

    private var renameController: RenamePanelController?
    private var noteController: NotePanelController?
    private var editorController: EditorWindowController?

    private var hasCreatedBackup = false

    /// Optional callback invoked once the workflow has fully completed.
    var onFinish: (() -> Void)?

    init(fileURL: URL,
         settingsStore: SettingsStore,
         clipboardService: ClipboardService,
         backupService: BackupService,
         sourceScreen: NSScreen?) {
        self.fileURL = fileURL
        self.settingsStore = settingsStore
        self.clipboardService = clipboardService
        self.backupService = backupService
        self.sourceScreen = sourceScreen
    }

    // MARK: - Public API

    func start() {
        presentRenamePanel()
    }

    // MARK: - Panels

    private func presentRenamePanel() {
        let controller = RenamePanelController(initialFilename: fileURL.lastPathComponent)
        controller.onAction = { [weak self] action in
            self?.handleRenameAction(action)
        }
        renameController = controller
        center(controller.window, on: sourceScreen)
        controller.show()
    }

    private func presentNotePanel(existingText: String = "") {
        let controller = NotePanelController(initialText: existingText)
        controller.onAction = { [weak self] action in
            self?.handleNoteAction(action)
        }
        noteController = controller
        center(controller.window, on: sourceScreen)
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
            guard applyRenameIfNeeded(newName: newName) else { return }
            complete(action: .saveOnly, note: nil)

        case .copyAndSave(let newName):
            guard applyRenameIfNeeded(newName: newName) else { return }
            complete(action: .copyAndSave, note: nil)

        case .copyAndDelete(let newName):
            guard applyRenameIfNeeded(newName: newName) else { return }
            complete(action: .copyAndDelete, note: nil)

        case .delete:
            complete(action: .deleteOnly, note: nil)

        case .goToNote(let newName):
            guard applyRenameIfNeeded(newName: newName) else { return }
            presentNotePanel()
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

        case .backToRename:
            noteController?.close()
            noteController = nil
            presentRenamePanel()

        case .goToEditor(let text):
            openEditor(withNote: text)
        }
    }

    // MARK: - Editor

    private func openEditor(withNote text: String) {
        // Apply the note first so the editor sees the captioned image.
        applyNoteIfNeeded(text)

        // Close the note panel; the rename panel is already closed by this point.
        noteController?.close()
        noteController = nil

        guard let editor = EditorWindowController(imageURL: fileURL) else {
            // If the editor fails to load, fall back to a regular save.
            complete(action: .saveOnly, note: nil)
            return
        }

        editor.onComplete = { [weak self] image, action in
            self?.handleEditorCompletion(editedImage: image, action: action)
        }

        editorController = editor
        editor.show()
    }

    private func handleEditorCompletion(editedImage: NSImage?, action: FinalAction) {
        editorController?.close()
        editorController = nil

        if let image = editedImage {
            saveEditedImage(image)
        }

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
        }

        onFinish?()
    }

    private func saveEditedImage(_ image: NSImage) {
        ensureBackupExists()

        let quality = settingsStore.settings.quality
        guard let data = jpegData(from: image, quality: quality) else {
            presentError(title: "Failed to encode image", message: "Could not encode edited image as JPEG.")
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            presentError(title: "Failed to write image", message: error.localizedDescription)
        }
    }

    private func ensureBackupExists() {
        guard !hasCreatedBackup else { return }
        backupService.createBackup(forOriginalURL: fileURL)
        hasCreatedBackup = true
    }

    // MARK: - Completion

    private func complete(action: FinalAction, note: String?) {
        renameController?.close()
        noteController?.close()
        renameController = nil
        noteController = nil

        if let note = note {
            applyNoteIfNeeded(note)
        }

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
        }

        onFinish?()
    }

    private func deleteFileAndBackup() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
        }
        backupService.removeBackup(forOriginalURL: fileURL)
    }

    // MARK: - Note rendering

    private func applyNoteIfNeeded(_ rawText: String) {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        ensureBackupExists()

        text = String(text.prefix(1000))

        let settings = settingsStore.settings
        if settings.notePrefixEnabled {
            let prefix = settings.notePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                text = prefix + " " + text
            }
        }

        guard let image = NSImage(contentsOf: fileURL) else { return }
        guard let updated = burn(note: text, into: image) else { return }

        guard let data = jpegData(from: updated, quality: settings.quality) else { return }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            presentError(title: "Failed to write note", message: error.localizedDescription)
        }
    }

    private func burn(note text: String, into image: NSImage) -> NSImage? {
        let baseSize = image.size
        let minWidth: CGFloat = 400
        let outputWidth = max(baseSize.width, minWidth)

        let font = NSFont.systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]

        let maxTextWidth = outputWidth - 40
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )

        let textHeight = ceil(bounding.height)
        let noteHeight: CGFloat = textHeight + 20

        let outputSize = NSSize(width: outputWidth, height: baseSize.height + noteHeight)
        let result = NSImage(size: outputSize)

        result.lockFocus()

        // Background
        NSColor.white.setFill()
        NSRect(origin: .zero, size: outputSize).fill()

        // Draw original image centered horizontally.
        let imageX = (outputWidth - baseSize.width) / 2
        image.draw(in: NSRect(x: imageX, y: noteHeight, width: baseSize.width, height: baseSize.height),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0)

        // Draw note bar background.
        let noteRect = NSRect(x: 0, y: 0, width: outputWidth, height: noteHeight)
        NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
        noteRect.fill()

        // Draw text.
        let textRect = NSRect(x: 20, y: 10, width: maxTextWidth, height: textHeight)
        (text as NSString).draw(in: textRect, withAttributes: attributes)

        result.unlockFocus()
        return result
    }

    private func jpegData(from image: NSImage, quality: Int) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let clamped = max(10, min(100, quality))
        let compression = CGFloat(clamped) / 100.0
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
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
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = NSColor.clear
        hasShadow = true
    }
}

// MARK: - Rename Panel

enum RenamePanelAction {
    case save(newName: String)
    case copyAndSave(newName: String)
    case copyAndDelete(newName: String)
    case delete
    case goToNote(newName: String)
}

final class RenamePanelController: NSWindowController {
    var onAction: ((RenamePanelAction) -> Void)?

    private let textField = CommandAwareTextField()
    private let shortcutLabel = NSTextField(labelWithString: "Enter: Save    ⌘↩: Copy+Save    ⌘⌫: Copy+Delete    Esc: Delete    Tab: Note")

    convenience init(initialFilename: String) {
        let contentRect = NSRect(x: 0, y: 0, width: 410, height: 215)
        let panel = FloatingInputPanel(contentRect: contentRect)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        self.init(window: panel)
        configureUI(initialFilename: initialFilename)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI(initialFilename: String) {
        guard let contentView = window?.contentView else { return }

        let container = NSVisualEffectView(frame: contentView.bounds)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let titleLabel = NSTextField(labelWithString: "Filename")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        textField.stringValue = initialFilename
        textField.isBordered = true
        textField.focusRingType = .default
        textField.bezelStyle = .roundedBezel
        textField.font = NSFont.systemFont(ofSize: 13)

        textField.keyCommandHandler = { [weak self] command in
            guard let self = self else { return }
            let value = self.textField.stringValue
            switch command {
            case .enter:
                self.onAction?(.save(newName: value))
            case .commandEnter:
                self.onAction?(.copyAndSave(newName: value))
            case .commandBackspace:
                self.onAction?(.copyAndDelete(newName: value))
            case .escape:
                self.onAction?(.delete)
            case .tab:
                self.onAction?(.goToNote(newName: value))
            case .shiftTab:
                NSSound.beep()
            }
        }

        shortcutLabel.font = NSFont.systemFont(ofSize: 11)
        shortcutLabel.textColor = NSColor.secondaryLabelColor
        shortcutLabel.lineBreakMode = .byWordWrapping

        [titleLabel, textField, shortcutLabel].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            textField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            shortcutLabel.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 12),
            shortcutLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            shortcutLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20)
        ])

        window?.initialFirstResponder = textField
    }

    func show() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Note Panel

enum NotePanelAction {
    case save(text: String)
    case copyAndSave(text: String)
    case copyAndDelete(text: String)
    case delete
    case backToRename(text: String)
    case goToEditor(text: String)
}

final class NotePanelController: NSWindowController {
    var onAction: ((NotePanelAction) -> Void)?

    private let textView = CommandAwareTextView()
    private let shortcutLabel = NSTextField(labelWithString: "Enter: Save    ⌘↩: Copy+Save    ⌘⌫: Copy+Delete    Esc: Delete    Shift+Tab: Rename    Tab: Editor")

    var text: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    convenience init(initialText: String) {
        let contentRect = NSRect(x: 0, y: 0, width: 410, height: 120)
        let panel = FloatingInputPanel(contentRect: contentRect)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        self.init(window: panel)
        configureUI(initialText: initialText)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI(initialText: String) {
        guard let contentView = window?.contentView else { return }

        let container = NSVisualEffectView(frame: contentView.bounds)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let titleLabel = NSTextField(labelWithString: "Note")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = initialText

        textView.keyCommandHandler = { [weak self] command in
            guard let self = self else { return }
            let value = self.textView.string
            switch command {
            case .enter:
                self.onAction?(.save(text: value))
            case .commandEnter:
                self.onAction?(.copyAndSave(text: value))
            case .commandBackspace:
                self.onAction?(.copyAndDelete(text: value))
            case .escape:
                self.onAction?(.delete)
            case .tab:
                self.onAction?(.goToEditor(text: value))
            case .shiftTab:
                self.onAction?(.backToRename(text: value))
            }
        }

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        [titleLabel, scrollView, shortcutLabel].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        shortcutLabel.font = NSFont.systemFont(ofSize: 11)
        shortcutLabel.textColor = NSColor.secondaryLabelColor
        shortcutLabel.lineBreakMode = .byWordWrapping

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            shortcutLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            shortcutLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            shortcutLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            shortcutLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12)
        ])

        window?.initialFirstResponder = textView
    }

    func show() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
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

final class CommandAwareTextField: NSTextField {
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
