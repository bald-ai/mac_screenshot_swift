import AppKit

enum RenamePanelAction {
    case save(newName: String)
    case copyAndSave(newName: String)
    case copyAndDelete(newName: String)
    case delete
    case close
    case goToNote(newName: String)
}

final class RenamePanelController: NSWindowController {
    var onAction: ((RenamePanelAction) -> Void)?

    private let textField = CommandAwareTextField()
    private var escapeKeyDeletesFile: Bool = true
    private var showsCopyAndDiscard: Bool = true

    private var originalBaseName: String = ""
    private var originalExtension: String = ""

    convenience init(initialFilename: String,
                     escapeKeyDeletesFile: Bool = true,
                     showsCopyAndDiscard: Bool = true) {
        let contentRect = NSRect(x: 0, y: 0, width: 410, height: 96)
        let panel = FloatingInputPanel(contentRect: contentRect)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        self.init(window: panel)
        self.escapeKeyDeletesFile = escapeKeyDeletesFile
        self.showsCopyAndDiscard = showsCopyAndDiscard
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

        let container = MenuSurfaceMaterial.makeFillingView(frame: contentView.bounds)
        contentView.addSubview(container)

        let titleLabel = NSTextField(labelWithString: "Rename")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        textField.stringValue = WorkflowFilenameLogic.editableFilename(initialFilename)
        textField.isBordered = true
        textField.focusRingType = .default
        textField.bezelStyle = .roundedBezel
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.textColor = .textColor

        textField.keyCommandHandler = { [weak self] command in
            guard let self = self else {
                return
            }
            let rawValue = self.textField.stringValue
            let sanitized = self.sanitizedFilename(from: rawValue)
            self.textField.stringValue = WorkflowFilenameLogic.editableFilename(sanitized)

            switch command {
            case .enter:
                self.onAction?(.save(newName: self.textField.stringValue))
            case .commandEnter, .commandShiftEnter:
                self.onAction?(.copyAndSave(newName: self.textField.stringValue))
            case .commandBackspace:
                if self.showsCopyAndDiscard {
                    self.onAction?(.copyAndDelete(newName: self.textField.stringValue))
                }
            case .escape:
                if self.escapeKeyDeletesFile {
                    self.onAction?(.delete)
                } else {
                    self.onAction?(.close)
                }
            case .tab:
                self.onAction?(.goToNote(newName: self.textField.stringValue))
            case .shiftTab:
                break
            }
        }

        [titleLabel, textField].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            textField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            textField.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18)
        ])

        window?.initialFirstResponder = textField
    }

    private func sanitizedFilename(from input: String) -> String {
        let fallbackBase = originalBaseName.isEmpty ? "Screenshot" : originalBaseName
        let fallbackName = originalExtension.isEmpty ? fallbackBase : "\(fallbackBase).\(originalExtension)"
        let fallbackURL = URL(fileURLWithPath: "/tmp/\(fallbackName)")
        return WorkflowFilenameLogic.sanitizeFilename(input, preservingExtensionOf: fallbackURL)
    }

    func show() {
        guard let window = window else {
            return
        }
        // Avoid activating the app / switching Spaces; still bring the panel forward.
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(textField)
        textField.selectText(nil)
    }
}
