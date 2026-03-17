# Code Review

## 🚨 Residual dev code

`AppDelegate.swift` — `showWelcomeInfo()` fires a profanity-laden alert on every single launch. This is clearly leftover dev scaffolding and needs to go entirely.

---

## 🔄 A→B→A round-trip (gimmicky)

`EditorWindowController.swift` — `toolTag(for:)` + `toolForTag(_:)` convert `EditorTool → Int` (stored as button `.tag`) → `EditorTool` on every toolbar press. The class already has `toolButtons: [EditorTool: NSButton]` which is the inverse map. The tag round-trip is completely unnecessary — you can just reverse-lookup the sender in `toolButtons`:

```swift
// Instead of tag-based round-trip:
@objc private func toolButtonPressed(_ sender: NSButton) {
    guard let tool = toolButtons.first(where: { $0.value === sender })?.key else { return }
    selectTool(tool)
}
// And drop toolTag(for:) + toolForTag(_:) entirely
```

---

## 🗑️ No-op override

`ScreenshotWorkflowController.swift` — `FloatingInputPanel.keyDown` just calls `super.keyDown`. Dead code:

```swift
override func keyDown(with event: NSEvent) {
    super.keyDown(with: event)  // ← does nothing, remove the whole override
}
```

---

## 📋 Duplicate setup code

`EditorWindowController.swift` — `makeSaveButton()` manually duplicates every line of `makeIconButton()` instead of calling `makeActionButton()`. It should be:

```swift
private func makeSaveButton() -> NSButton {
    makeActionButton(symbol: "tray.and.arrow.down", toolTip: "Save (Enter)", action: #selector(savePressed))
}
```

---

## ⚡ Computed property allocating a new dict on every call

`EditorCanvasView.swift` — `czechKeyToColorIndex` is a `var` computed property that creates a fresh `[String: Int]` dictionary every time it's accessed (called on every keyDown while color picker is open). Should be `static let`:

```swift
private static let czechKeyToColorIndex: [String: Int] = [
    "+": 0, "ě": 1, "š": 2, "č": 3, "ř": 4, "ž": 5
]
```

---

## 🔀 Mixed indentation

`EditorWindowController.swift` — `deletePressed` uses hard tabs while the entire rest of the file uses spaces. Looks like it was pasted from somewhere else.

---

## Redundant main-thread guard

`ScreenshotWorkflowController.swift` — `presentRenamePanel()` has its own `guard Thread.isMainThread` check, but every call site already guarantees main thread (`start()` dispatches to main before calling it, `handleNoteAction` is always on main). The guard is dead in practice.
