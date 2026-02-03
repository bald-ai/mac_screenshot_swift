# Agent 5: Selection Overlay Implementation

## Objective
Create the `SelectionOverlay.swift` file with a fullscreen transparent overlay for drag-to-select area screenshot capture.

## Context
The `SelectionOverlay` class is referenced in `ScreenshotService.swift` (line 15, 40-43) but doesn't exist. This is the UI for area selection - user drags to define a rectangle on screen.

## Requirements from Plan

### Overlay Specifications:
- **Type**: Fullscreen transparent NSWindow on active display
- **Level**: Above all windows but allows interaction
- **Background**: Clear/transparent
- **Behavior**: Blocks all other app interaction until dismissed

### Visual Elements:

1. **Dimmed Background**
   - Slightly darkens entire screen
   - Alpha: ~0.3 (adjust for visibility)

2. **Selection Rectangle**
   - White border (2pt)
   - Semi-transparent white fill (alpha ~0.1)
   - Updates in real-time while dragging
   - Shows dimensions in corner (e.g., "1200 x 800")

3. **Instruction Text**
   - Center of screen: "Drag to select area, Esc to cancel"
   - White text with dark shadow for visibility
   - Disappears when user starts dragging

4. **Crosshair Cursor**
   - Standard crosshair cursor when hovering

### Mouse Handling:

| Action | Behavior |
|--------|----------|
| Mouse Down | Start selection at cursor position, hide instruction text |
| Mouse Drag | Update selection rectangle from start to current position |
| Mouse Up | Finalize selection, close overlay, return rect via delegate |
| Right Click | Cancel (same as Esc) |

### Keyboard Handling:
- **Escape**: Cancel selection, close overlay, call delegate with nil
- **Return**: If selection exists, accept it

### Coordinate System:
- Work in screen coordinates (NSScreen.main?.frame)
- Convert to pixel coordinates using screen.backingScaleFactor
- Handle retina displays correctly
- Handle multi-display setups (selection happens on display where mouse is)

## Interface Contract

```swift
protocol SelectionOverlayDelegate: AnyObject {
    func selectionOverlay(_ overlay: SelectionOverlay, didSelect rect: CGRect)
    func selectionOverlayDidCancel(_ overlay: SelectionOverlay)
}

final class SelectionOverlay {
    weak var delegate: SelectionOverlayDelegate?
    
    func beginSelection()
    func cancelSelection()
}
```

## Implementation Details

### Window Setup:
```swift
let window = NSWindow(
    contentRect: screen.frame,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.level = .screenSaver  // Above most windows
window.backgroundColor = NSColor.black.withAlphaComponent(0.3)
window.isOpaque = false
window.ignoresMouseEvents = false
window.acceptsMouseMovedEvents = true
```

### Selection View:
Create custom NSView to draw:
- Darkened background (entire view)
- Clear rectangle (the selection area - punch through darkness)
- White border around selection
- Dimension label

```swift
class SelectionView: NSView {
    var selectionRect: CGRect?
    var startPoint: CGPoint?
    
    override func draw(_ dirtyRect: NSRect) {
        // Fill entire view with dim color
        // Clear the selectionRect area (draw clear color)
        // Draw white border around selectionRect
        // Draw dimension label
    }
}
```

### Coordinate Conversion:
```swift
private func convertToPixels(_ rect: CGRect, on screen: NSScreen) -> CGRect {
    let scale = screen.backingScaleFactor
    return CGRect(
        x: rect.origin.x * scale,
        y: rect.origin.y * scale,
        width: rect.size.width * scale,
        height: rect.size.height * scale
    )
}
```

### Multi-Display Support:
- Get screen where mouse currently is: `NSScreen.screens.first { $0.frame.contains(mouseLocation) }`
- Open overlay only on that screen
- Or open on all screens simultaneously (easier UX)

## Integration Points

1. **ScreenshotService** creates overlay: `SelectionOverlay()`
2. **Delegate**: ScreenshotService sets itself as delegate
3. **Callback**: On selection, overlay calls `delegate.selectionOverlay(_, didSelect:)`
4. **ScreenshotService** then calls `captureRegion(in: rect, on: screen)` (line 110)

Current usage in ScreenshotService:
```swift
func captureArea() {
    guard canStartNewCapture() else { return }
    
    let overlay = SelectionOverlay()
    overlay.delegate = self
    selectionOverlay = overlay
    overlay.beginSelection()
}
```

## Edge Cases

1. **Multi-monitor**: Handle mouse moving between displays
2. **Tiny selection**: Minimum size threshold? (e.g., 10x10 pixels)
3. **Inverted selection**: User drags up/left instead of down/right
4. **Fullscreen apps**: Overlay should appear above fullscreen windows
5. **Screensaver**: Don't activate while selecting
6. **Mission Control**: Prevent activation

## Testing Checklist

- [ ] Overlay appears on correct screen
- [ ] Dragging creates selection rectangle
- [ ] Rectangle updates in real-time
- [ ] Dimensions display correctly
- [ ] Escape cancels selection
- [ ] Right-click cancels
- [ ] Return accepts selection
- [ ] Selection works in all directions (up/down/left/right)
- [ ] Coordinates convert correctly for retina
- [ ] Multi-display setup works
- [ ] Overlay appears above fullscreen apps

## File Location
`Sources/SelectionOverlay.swift`

## Do Not Modify
- Do not modify ScreenshotService.swift
- Do not modify other files
- Work only on SelectionOverlay.swift

## Success Criteria
SelectionOverlay.swift compiles, displays fullscreen overlay, captures drag selection, converts coordinates correctly, and integrates with ScreenshotService without modifying existing code.
