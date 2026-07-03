import AppKit

enum NotePanelAction {
    case save(text: String)
    case copyAndSave(text: String)
    case copyAndDelete(text: String)
    case delete
    case close
    case backToRename(text: String)
    case goToEditor(text: String)
}

final class NotePanelController: NSWindowController {
    var onAction: ((NotePanelAction) -> Void)?

    private let textView = LockedWhiteNoteTextView(frame: .zero, textContainer: nil)
    private var escapeKeyDeletesFile: Bool = true
    private var showsCopyAndDelete: Bool = true
    private var showsEditorShortcut: Bool = true

    private static let maxLength = 1000

    var text: String {
        get { String(textView.string.prefix(Self.maxLength)) }
        set { textView.setFixedWhiteString(String(newValue.prefix(Self.maxLength))) }
    }

    convenience init(initialText: String,
                     escapeKeyDeletesFile: Bool = true,
                     showsCopyAndDelete: Bool = true,
                     showsEditorShortcut: Bool = true) {
        let contentRect = NSRect(x: 0, y: 0, width: 410, height: 120)
        let panel = FloatingInputPanel(contentRect: contentRect)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        self.init(window: panel)
        self.escapeKeyDeletesFile = escapeKeyDeletesFile
        self.showsCopyAndDelete = showsCopyAndDelete
        self.showsEditorShortcut = showsEditorShortcut
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

        let container = MenuSurfaceMaterial.makeFillingView(frame: contentView.bounds)
        contentView.addSubview(container)

        let titleLabel = NSTextField(labelWithString: "Prompt / Note")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.configureFixedWhiteText()
        textView.setFixedWhiteString(String(initialText.prefix(Self.maxLength)))

        textView.keyCommandHandler = { [weak self] (command: KeyCommand) in
            guard let self = self else { return }
            let value = String(self.textView.string.prefix(Self.maxLength))
            self.textView.setFixedWhiteString(value)
            switch command {
            case .enter:
                self.onAction?(.save(text: value))
            case .commandEnter:
                self.onAction?(.copyAndSave(text: value))
            case .commandShiftEnter:
                break
            case .commandBackspace:
                if self.showsCopyAndDelete {
                    self.onAction?(.copyAndDelete(text: value))
                }
            case .escape:
                if self.escapeKeyDeletesFile {
                    self.onAction?(.delete)
                } else {
                    self.onAction?(.close)
                }
            case .tab:
                if self.showsEditorShortcut {
                    self.onAction?(.goToEditor(text: value))
                }
            case .shiftTab:
                self.onAction?(.backToRename(text: value))
            }
        }

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        [titleLabel, scrollView].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
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

private final class LockedWhiteNoteTextView: NSTextView {
    var keyCommandHandler: ((KeyCommand) -> Void)?
    private var isApplyingFixedTextStyle = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container {
            super.init(frame: frameRect, textContainer: container)
        } else {
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: NSSize(width: frameRect.width, height: .greatestFiniteMagnitude))
            textContainer.widthTracksTextView = true
            textContainer.heightTracksTextView = false
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
            super.init(frame: frameRect, textContainer: textContainer)
        }

        isEditable = true
        isSelectable = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 4, height: 4)
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        textContainer?.containerSize = NSSize(width: frameRect.width, height: .greatestFiniteMagnitude)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSelectionDidChange),
            name: NSTextView.didChangeSelectionNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configureFixedWhiteText() {
        enforceFixedTextStyle()
    }

    func setFixedWhiteString(_ value: String) {
        string = value
        enforceFixedTextStyle()
    }

    override func keyDown(with event: NSEvent) {
        if let command = interpretNoteKeyCommand(from: event) {
            keyCommandHandler?(command)
        } else {
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        enforceFixedTextStyle()
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: flag)
        enforceTypingColor()
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        enforceFixedTextStyle()
        return becameFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enforceFixedTextStyle()
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        enforceFixedTextStyle()
    }

    private func enforceFixedTextStyle() {
        guard !isApplyingFixedTextStyle else { return }
        isApplyingFixedTextStyle = true
        defer { isApplyingFixedTextStyle = false }

        let color = NSColor.white
        textColor = color
        insertionPointColor = color
        enforceTypingColor()

        if let textStorage, textStorage.length > 0 {
            let selected = selectedRange()
            textStorage.beginEditing()
            textStorage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
            super.setSelectedRange(selected, affinity: .downstream, stillSelecting: false)
        }
    }

    private func enforceTypingColor() {
        var attributes = typingAttributes
        if let font {
            attributes[.font] = font
        }
        attributes[.foregroundColor] = NSColor.white
        typingAttributes = attributes
    }

    @objc private func handleSelectionDidChange() {
        enforceTypingColor()
    }
}

private func interpretNoteKeyCommand(from event: NSEvent) -> KeyCommand? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    switch event.keyCode {
    case 36:
        return flags.contains(.command) ? .commandEnter : .enter
    case 51:
        return flags.contains(.command) ? .commandBackspace : nil
    case 53:
        return .escape
    case 48:
        return flags.contains(.shift) ? .shiftTab : .tab
    default:
        return nil
    }
}
