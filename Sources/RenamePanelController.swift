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
        let contentRect = NSRect(x: 0, y: 0, width: 410, height: 215)
        let panel = FloatingInputPanel(contentRect: contentRect)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        self.init(window: panel)
        configureFilenameMetadata(initialFilename: initialFilename)
        configureUI(initialFilename: initialFilename)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
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
            guard let self = self else { return }
            let rawValue = self.textField.stringValue
            let sanitized = self.sanitizedFilename(from: rawValue)
            self.textField.stringValue = sanitized

            switch command {
            case .enter:
                self.onAction?(.save(newName: sanitized))
            case .commandEnter:
                self.onAction?(.copyAndSave(newName: sanitized))
            case .commandBackspace:
                self.onAction?(.copyAndDelete(newName: sanitized))
            case .escape:
                self.onAction?(.delete)
            case .tab:
                self.onAction?(.goToNote(newName: sanitized))
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
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
    }
}
