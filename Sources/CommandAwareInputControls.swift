import AppKit

enum KeyCommand {
    case enter
    case commandEnter
    case commandShiftEnter
    case commandBackspace
    case escape
    case tab
    case shiftTab
}

func interpretKeyCommand(from event: NSEvent) -> KeyCommand? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    switch event.keyCode {
    case 36:
        if flags.contains(.command) && flags.contains(.shift) { return .commandShiftEnter }
        if flags.contains(.command) { return .commandEnter }
        return .enter
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
