import AppKit

/// Lightweight, non-blocking message panel used instead of `NSAlert.runModal()`.
/// This avoids hidden app-modal sessions that can make other UI feel "stuck".
final class MessagePanelController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "OK", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)

    private var onPrimary: (() -> Void)?
    private var onSecondary: (() -> Void)?

    convenience init(title: String,
                     message: String,
                     primaryTitle: String = "OK",
                     secondaryTitle: String? = nil,
                     onPrimary: (() -> Void)? = nil,
                     onSecondary: (() -> Void)? = nil) {
        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 170)
        let panel = FloatingInputPanel(contentRect: contentRect)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        self.init(window: panel)

        self.onPrimary = onPrimary
        self.onSecondary = onSecondary

        configureUI(title: title,
                    message: message,
                    primaryTitle: primaryTitle,
                    secondaryTitle: secondaryTitle)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI(title: String,
                             message: String,
                             primaryTitle: String,
                             secondaryTitle: String?) {
        guard let contentView = window?.contentView else { return }

        let container = NSVisualEffectView(frame: contentView.bounds)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)

        messageLabel.stringValue = message
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.textColor = NSColor.secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0

        primaryButton.title = primaryTitle
        primaryButton.bezelStyle = .rounded
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)

        secondaryButton.isHidden = secondaryTitle == nil
        if let secondaryTitle = secondaryTitle {
            secondaryButton.title = secondaryTitle
            secondaryButton.bezelStyle = .rounded
            secondaryButton.target = self
            secondaryButton.action = #selector(secondaryTapped)
        }

        [titleLabel, messageLabel, primaryButton, secondaryButton].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            primaryButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            primaryButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            secondaryButton.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),
            secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -10)
        ])

        window?.initialFirstResponder = primaryButton
    }

    func show() {
        guard let window = window else { return }
        window.orderFrontRegardless()
        window.makeKey()
    }

    @objc private func primaryTapped() {
        onPrimary?()
        close()
    }

    @objc private func secondaryTapped() {
        onSecondary?()
        close()
    }
}

