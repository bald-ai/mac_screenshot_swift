# Agent 1: Rename Panel Implementation

## Objective
Create the `RenamePanelController.swift` file with a Spotlight-style floating panel for filename editing after screenshot capture.

## Context
This is part of the macOS Swift/AppKit screenshot app rebuild. The panel is referenced in `ScreenshotWorkflowController.swift` at lines 51-58 but doesn't exist yet.

## Requirements from Plan

### Panel Specifications:
- Size: 410x215 pixels
- Style: Spotlight-style floating panel (non-activating, key window, doesn't switch Spaces)
- Background: HUD-style blur effect (NSVisualEffectView)
- Title bar: Hidden/transparent

### UI Components:
1. **Title label**: "Filename" (13pt medium weight)
2. **Text field**: 
   - Pre-filled with current filename
   - Rounded bezel style
   - Focus ring enabled
   - Receives initial focus when panel opens
3. **Shortcut hint label**: 
   - Text: "Enter: Save    ⌘↩: Copy+Save    ⌘⌫: Copy+Delete    Esc: Delete    Tab: Note"
   - 11pt, secondary label color, word wrap enabled

### Keyboard Actions (MUST IMPLEMENT):
| Key Combo | Action |
|-----------|--------|
| Enter | `.save(newName:)` |
| Cmd+Enter | `.copyAndSave(newName:)` |
| Cmd+Backspace | `.copyAndDelete(newName:)` |
| Escape | `.delete` |
| Tab | `.goToNote(newName:)` |
| Shift+Tab | Beep (NSSound.beep()) |

### Filename Sanitization:
- Remove `/` and `:` characters
- Preserve file extension
- Trim whitespace
- If empty after sanitization, revert to original filename

### Spotlight Behavior:
```swift
panel.isFloatingPanel = true
panel.level = .statusBar
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.hidesOnDeactivate = false
panel.styleMask = [.nonactivatingPanel]
override var canBecomeKey: Bool { true }
override var canBecomeMain: Bool { false }
```

## Interface Contract

```swift
enum RenamePanelAction {
    case save(newName: String)
    case copyAndSave(newName: String)
    case copyAndDelete(newName: String)
    case delete
    case goToNote(newName: String)
}

final class RenamePanelController: NSWindowController {
    var onAction: ((RenamePanelAction) -> Void)?
    
    convenience init(initialFilename: String)
    func show()
}
```

## Integration Points

1. Called from `ScreenshotWorkflowController.presentRenamePanel()` (line 51-58)
2. Must center on source screen using provided `center(_:on:)` method
3. Must call `onAction` closure with appropriate action when user triggers keyboard shortcut

## File Location
`Sources/RenamePanelController.swift`

## Edge Cases to Handle
1. Panel already open when new screenshot comes in → Show error alert (handled by workflow controller)
2. User types invalid characters → Sanitize on-the-fly
3. User clears entire filename → Use original filename as fallback
4. Multi-monitor setup → Center on correct screen (passed in from workflow)

## Testing Checklist
- [ ] Panel appears centered on correct screen
- [ ] All keyboard shortcuts work
- [ ] Filename sanitizes `/` and `:` characters
- [ ] Extension is preserved
- [ ] Tab transitions to note panel
- [ ] Panel doesn't steal focus from fullscreen apps
- [ ] Panel works on multiple Spaces
- [ ] Close animation is smooth

## Dependencies
- Uses existing `FloatingInputPanel` base class (defined in ScreenshotWorkflowController.swift lines 416-433)
- Uses existing `CommandAwareTextField` (defined in ScreenshotWorkflowController.swift lines 666-705)

## Do Not Modify
- Do not modify ScreenshotWorkflowController.swift
- Do not modify existing panel classes
- Focus only on creating this new file

## Success Criteria
RenamePanelController.swift compiles and integrates seamlessly with ScreenshotWorkflowController without any modifications to existing files.
