import AppKit

final class FloatingInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = NSColor.clear
        hasShadow = true
        isReleasedWhenClosed = false
        AppTheme.apply(to: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased()

        // NSText has no `undo:` action, so drive the first-responder text view's
        // undoManager directly. ⌘Z = undo, ⌘⇧Z = redo.
        if chars == "z", let textView = firstResponder as? NSTextView {
            if flags == [.command] { textView.undoManager?.undo(); return true }
            if flags == [.command, .shift] { textView.undoManager?.redo(); return true }
        }

        if flags == [.command],
           let chars,
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
