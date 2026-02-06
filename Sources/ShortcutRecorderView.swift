import AppKit
import Carbon

/// Simple keyboard shortcut recorder used in the Settings window.
///
/// It displays the currently configured shortcut as text (for example,
/// "⌘⇧6") and, when clicked, captures the next key press (with modifiers)
/// to update the value. Validation of duplicates is handled by the
/// settings controller.
final class ShortcutRecorderView: NSControl {
    struct RecordedShortcut {
        var keyCode: UInt32
        var carbonFlags: UInt32
    }

    /// Current shortcut value shown in the control.
    var recordedShortcut: RecordedShortcut? {
        didSet {
            needsDisplay = true
        }
    }

    /// Called whenever the user successfully records a new shortcut.
    var onChange: ((RecordedShortcut) -> Void)?

    private var isRecording = false
    
    /// Exposed so other parts of the app can ignore global hotkeys while the
    /// user is actively recording a shortcut.
    var isRecordingShortcut: Bool { isRecording }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 24)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Allow Escape to cancel recording without changing the shortcut.
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }

        let carbonFlags = HotKeyService.carbonModifierFlags(from: event.modifierFlags)

        // Require at least one standard modifier (cmd/opt/ctrl/shift/caps).
        if carbonFlags == 0 {
            NSSound.beep()
            return
        }

        let keyCode = UInt16(event.keyCode)

        // Only accept keys from the supported set.
        guard HotKeyService.isAllowedKeyCode(keyCode) else {
            NSSound.beep()
            return
        }

        let newValue = RecordedShortcut(keyCode: UInt32(keyCode), carbonFlags: carbonFlags)
        recordedShortcut = newValue
        onChange?(newValue)

        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)

        let backgroundColor: NSColor = isRecording
            ? NSColor.selectedControlColor
            : NSColor.controlBackgroundColor

        backgroundColor.setFill()
        path.fill()

        NSColor.gridColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        if isRecording {
            text = "Type shortcut…"
        } else if let shortcut = recordedShortcut {
            text = HotKeyService.describeShortcut(
                keyCode: shortcut.keyCode,
                carbonFlags: shortcut.carbonFlags
            )
        } else {
            text = "Click to record"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]

        let size = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: bounds.midX - size.width / 2.0,
            y: bounds.midY - size.height / 2.0,
            width: size.width,
            height: size.height
        )

        text.draw(in: textRect, withAttributes: attributes)
    }
}
