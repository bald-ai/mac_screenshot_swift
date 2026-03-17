# Code Review — 2026-03-17

## 🔴 Critical / Must Fix

**1. Profanity in welcome dialog (AppDelegate.swift:46-47)**
```swift
alert.messageText = "🚨🚨🚨 READ THIS YOU DUMFUS OR YOU WILL BE CONFUSED AS FUCK 🚨🚨🚨"
```
Dev-time residual. Rewrite or remove before any release.

---

## 🟠 Residual / Dead Code

**2. `FloatingInputPanel.keyDown` is a no-op override (ScreenshotWorkflowController.swift)**
```swift
override func keyDown(with event: NSEvent) {
    super.keyDown(with: event)
}
```
Does nothing. Remove it.

**3. `.tmp_cache/` and `.tmp_home/` are committed to git**
Compiler cache artifacts (`.pcm`, `.swiftmodule` files). Should be in `.gitignore` and removed from tracking.

**4. `agent_tasks/` directory committed to git**
AI agent task specs used during development. Not useful in the repo.

**5. `RELEASE_TODO.md` committed to git**
Dev planning artifact.

**6. Unnecessary `#available(macOS 10.14, *)` check (MenuSurfaceMaterial.swift:7)**
```swift
if #available(macOS 10.14, *) {
    view.material = .menu
} else {
    view.material = .popover
}
```
Package minimum is macOS 14. The `else` branch is dead code — it can never execute.

---

## 🟡 Gimmicky / Redundant Patterns

**7. `TrayService.statusItemClicked` — both branches do the same thing**
```swift
switch event.type {
case .rightMouseUp:
    showMenu()
case .leftMouseUp:
    showMenu()
default:
    break
}
```
Left click and right click both show the menu. The switch is pointless. Either collapse to a single case, or make left-click do something different (e.g. trigger the primary action directly).

**8. Double extension-stripping in `WorkflowFilenameLogic.sanitizeFilename`**
```swift
// First strip:
if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) {
    base = String(base.dropLast(ext.count + 1))
}
// ... clean forbidden chars ...
// Second strip (same check again):
if !ext.isEmpty, normalizedBase.lowercased().hasSuffix("." + ext.lowercased()) {
    normalizedBase = String(normalizedBase.dropLast(ext.count + 1))
}
```
The second strip is there "just in case" the cleaning somehow re-introduced the extension, which can't happen since it only removes `/` and `:`. Classic "turn A into B and back to A" defensive pattern. The second check is dead logic.

**9. `WorkflowFilenameLogic.uniqueURL` is a pure passthrough**
```swift
static func uniqueURL(forProposedName name: String, in directory: URL, fileExists: (String) -> Bool) -> URL {
    UniqueFileURLLogic.uniqueURL(forProposedName: name, in: directory, fileExists: fileExists)
}
```
Adds zero value. Callers should use `UniqueFileURLLogic` directly.

**10. Thin private wrappers in `ScreenshotService` that just forward to `ScreenshotServiceCoreLogic`**
```swift
private func resizedImageIfNeeded(_ image: NSImage, maxWidth: Int) -> NSImage {
    ScreenshotServiceCoreLogic.resizedImageIfNeeded(image, maxWidth: maxWidth)
}
private func jpegData(from image: NSImage, quality: Int) -> Data? {
    ScreenshotServiceCoreLogic.jpegData(from: image, quality: quality)
}
```
These exist for "readability" but they're just noise. The core logic type names are already clear.

---

## 🟡 Code Quality Issues

**11. Tab characters in comments (Settings.swift:5, :38)**
```
/// JPEG quality 10	100, step 5.
```
Those `10	100` have a literal tab character between them. Should be `10–100` (en-dash) or `10-100`.

**12. `@unchecked Sendable` on `ScreenshotService`**
```swift
extension ScreenshotService: @unchecked Sendable {}
```
The class has mutable state (`selectionOverlay`, `activeWorkflow`, `isCaptureInProgress`) that isn't protected by any lock. The `@unchecked Sendable` conformance is lying to the compiler. It works because everything is dispatched to main, but it's a ticking time bomb if someone calls from a background thread without the main-dispatch guards.

**13. Hardcoded Czech keyboard mapping (EditorCanvasView.swift)**
```swift
private var czechKeyToColorIndex: [String: Int] {
    ["+": 0, "ě": 1, "š": 2, "č": 3, "ř": 4, "ž": 5]
}
```
Only works on Czech keyboard layouts. For other users, number keys 1-6 aren't mapped at all for color selection (only the Czech characters are). Should either be removed or generalized to use key codes instead of characters.

**14. Inconsistent indentation on `deletePressed` (EditorWindowController.swift:~618)**
```swift
	    @objc private func deletePressed() {
	        // ...
	    }
```
Uses tabs while the rest of the file uses spaces.

**15. `RenamePanelController` window height is 215pt but content is ~80pt tall**
The panel has a title label, a text field, and a shortcut label. 215pt is way too tall — there's a big empty gap at the bottom. Compare with `NotePanelController` which uses 120pt for similar content.

---

## 💡 Minor / Suggestions

**16. `CommandAwareTextField.control(_:textView:doCommandBy:)` has redundant fallback**
It first tries `interpretKeyCommand(from: event)`, then falls through to a `commandSelector` switch that handles the same keys (enter, tab, escape). The `commandSelector` path is only reachable if `NSApp.currentEvent` is nil, which is extremely unlikely during a text field action. Not harmful, but the fallback is essentially dead code.

**17. `ScreenshotSoundPlayer` stores `playerURL` to detect URL changes, but the URL never changes at runtime** (it's always the same bundled resource). The `playerURL != url` check is unnecessary complexity.

**18. `AppLogger` uses `NSLog` instead of `os.Logger`/`os_log`**
`NSLog` is the legacy approach. Since the minimum target is macOS 14, `Logger` from the `os` framework would be more appropriate and performant.

---

## Summary

The codebase is generally well-structured with good separation of concerns (core logic extracted for testability, clear ownership boundaries). The main issues are:
- Dev-time residual artifacts (profanity, committed cache files, agent task docs)
- A few "just in case" defensive patterns that are actually dead code
- The Czech keyboard hardcoding is a real usability bug for non-Czech users
- The `@unchecked Sendable` is a correctness risk
