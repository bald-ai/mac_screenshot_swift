import AppKit

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

    private static let maxLength = 1000

    var text: String {
        get { String(textView.string.prefix(Self.maxLength)) }
        set { textView.string = String(newValue.prefix(Self.maxLength)) }
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
        textView.string = String(initialText.prefix(Self.maxLength))

        textView.keyCommandHandler = { [weak self] command in
            guard let self = self else { return }
            let value = String(self.textView.string.prefix(Self.maxLength))
            self.textView.string = value
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
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(textView)
        let end = textView.string.count
        textView.setSelectedRange(NSRange(location: end, length: 0))
    }
}
