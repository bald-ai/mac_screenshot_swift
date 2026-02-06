import AppKit

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

    private var originalBaseName: String = ""
    private var originalExtension: String = ""

    convenience init(initialFilename: String) {
        Logger.shared.info("RenamePanelController: convenience init starting")
        let contentRect = NSRect(x: 0, y: 0, width: 410, height: 215)
        Logger.shared.info("RenamePanelController: Creating FloatingInputPanel")
        let panel = FloatingInputPanel(contentRect: contentRect)
        Logger.shared.info("RenamePanelController: FloatingInputPanel created")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        Logger.shared.info("RenamePanelController: Calling self.init(window:)")
        self.init(window: panel)
        Logger.shared.info("RenamePanelController: self.init(window:) completed")
        Logger.shared.info("RenamePanelController: Configuring filename metadata")
        configureFilenameMetadata(initialFilename: initialFilename)
        Logger.shared.info("RenamePanelController: Filename metadata configured")
        Logger.shared.info("RenamePanelController: Configuring UI")
        configureUI(initialFilename: initialFilename)
        Logger.shared.info("RenamePanelController: UI configured - init complete")
    }

    override init(window: NSWindow?) {
        Logger.shared.info("RenamePanelController: override init(window:) called")
        super.init(window: window)
        Logger.shared.info("RenamePanelController: super.init(window:) completed")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureFilenameMetadata(initialFilename: String) {
        let ns = initialFilename as NSString
        originalExtension = ns.pathExtension
        originalBaseName = ns.deletingPathExtension
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
            Logger.shared.info("RenamePanelController: keyCommandHandler called with command: \(command)")
            guard let self = self else {
                Logger.shared.error("RenamePanelController: keyCommandHandler - self is nil!")
                return
            }
            let rawValue = self.textField.stringValue
            Logger.shared.info("RenamePanelController: Raw filename: '\(rawValue)'")
            let sanitized = self.sanitizedFilename(from: rawValue)
            Logger.shared.info("RenamePanelController: Sanitized filename: '\(sanitized)'")
            self.textField.stringValue = sanitized

            Logger.shared.info("RenamePanelController: Processing command \(command), onAction is nil: \(self.onAction == nil)")
            
            switch command {
            case .enter:
                Logger.shared.info("RenamePanelController: Triggering .save action")
                self.onAction?(.save(newName: sanitized))
                Logger.shared.info("RenamePanelController: .save action completed")
            case .commandEnter:
                Logger.shared.info("RenamePanelController: Triggering .copyAndSave action")
                self.onAction?(.copyAndSave(newName: sanitized))
                Logger.shared.info("RenamePanelController: .copyAndSave action completed")
            case .commandBackspace:
                Logger.shared.info("RenamePanelController: Triggering .copyAndDelete action")
                self.onAction?(.copyAndDelete(newName: sanitized))
                Logger.shared.info("RenamePanelController: .copyAndDelete action completed")
            case .escape:
                Logger.shared.info("RenamePanelController: Triggering .delete action")
                self.onAction?(.delete)
                Logger.shared.info("RenamePanelController: .delete action completed")
            case .tab:
                Logger.shared.info("RenamePanelController: Triggering .goToNote action")
                self.onAction?(.goToNote(newName: sanitized))
                Logger.shared.info("RenamePanelController: .goToNote action completed")
            case .shiftTab:
                Logger.shared.info("RenamePanelController: .shiftTab - no action")
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

    private func sanitizedFilename(from input: String) -> String {
        let ext = originalExtension

        var base = input
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) {
            base = String(base.dropLast(ext.count + 1))
        }

        let forbidden = CharacterSet(charactersIn: "/:")
        let cleaned = base.components(separatedBy: forbidden).joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        let finalBase: String
        if trimmed.isEmpty {
            finalBase = originalBaseName.isEmpty ? "Screenshot" : originalBaseName
        } else {
            finalBase = trimmed
        }

        if ext.isEmpty {
            return finalBase
        } else {
            return "\(finalBase).\(ext)"
        }
    }

    func show() {
        Logger.shared.info("RenamePanelController: show() called")
        guard let window = window else {
            Logger.shared.error("RenamePanelController: show() - window is nil!")
            return
        }
        // Avoid activating the app / switching Spaces; still bring the panel forward.
        Logger.shared.info("RenamePanelController: Ordering window front (regardless), attempting to make key")
        window.orderFrontRegardless()
        window.makeKey()
        Logger.shared.info("RenamePanelController: Setting first responder to text field")
        window.makeFirstResponder(textField)
        textField.selectText(nil)
        Logger.shared.info("RenamePanelController: show() completed")
    }
}
