# Agent 2: Note Panel Implementation

## Objective
Create the `NotePanelController.swift` file with a Spotlight-style floating panel for adding notes to screenshots.

## Context
Part of macOS Swift/AppKit screenshot app. Panel is referenced in `ScreenshotWorkflowController.swift` at lines 61-68 but doesn't exist. Notes get burned into the image at the bottom.

## Requirements from Plan

### Panel Specifications:
- Size: 410x120 pixels  
- Style: Spotlight-style floating panel (non-activating, key window, doesn't switch Spaces)
- Background: HUD-style blur effect
- Multi-line text input with scrollbar

### UI Components:
1. **Title label**: "Note" (13pt medium weight)
2. **Text view**:
   - Multi-line NSTextView inside NSScrollView
   - Bezel border
   - Vertical scroller
   - No rich text (isRichText = false)
   - Disable smart quotes (isAutomaticQuoteSubstitutionEnabled = false)
   - 4pt content inset
   - Receives initial focus
3. **Shortcut hint label**:
   - Text: "Enter: Save    ⌘↩: Copy+Save    ⌘⌫: Copy+Delete    Esc: Delete    Shift+Tab: Rename    Tab: Editor"
   - 11pt, secondary label color

### Keyboard Actions (MUST IMPLEMENT):
| Key Combo | Action |
|-----------|--------|
| Enter | `.save(text:)` |
| Cmd+Enter | `.copyAndSave(text:)` |
| Cmd+Backspace | `.copyAndDelete(text:)` |
| Escape | `.delete` |
| Tab | `.goToEditor(text:)` |
| Shift+Tab | `.backToRename(text:)` |

### Spotlight Behavior:
Same as RenamePanel:
```swift
panel.isFloatingPanel = true
panel.level = .statusBar
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
override var canBecomeKey: Bool { true }
```

## Interface Contract

```swift
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
    var text: String { get set }
    
    convenience init(initialText: String)
    func show()
}
```

## Integration Points

1. Called from `ScreenshotWorkflowController.presentNotePanel()` (line 61-68)
2. Must center on source screen
3. Preserves text when transitioning back to rename (Shift+Tab)
4. Passes text to editor when going forward (Tab)

## File Location
`Sources/NotePanelController.swift`

## Edge Cases to Handle
1. **Max length**: Truncate to 1000 characters (enforced by workflow controller when burning)
2. **Multi-monitor**: Center on correct screen
3. **Empty note**: Valid - just means no note text
4. **Long text**: Scroll view handles overflow

## Testing Checklist
- [ ] Panel appears centered on screen
- [ ] Multi-line text input works
- [ ] Scrollbar appears when text overflows
- [ ] All keyboard shortcuts work
- [ ] Shift+Tab returns to rename panel with text preserved
- [ ] Tab proceeds to editor with text preserved
- [ ] Smart quotes disabled
- [ ] Panel doesn't switch Spaces
- [ ] Works in fullscreen apps

## Dependencies
- Uses existing `FloatingInputPanel` base class
- Uses existing `CommandAwareTextView` (defined in ScreenshotWorkflowController.swift lines 707-746)

## Note on Text View
Create a `CommandAwareTextView` subclass of NSTextView (similar to CommandAwareTextField) that intercepts key commands before they go to the text system.

## Do Not Modify
- Do not modify ScreenshotWorkflowController.swift
- Only create new file

## Success Criteria
NotePanelController.swift compiles and integrates seamlessly without modifying existing files.
