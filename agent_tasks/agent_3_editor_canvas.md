# Agent 3: Editor Canvas Implementation

## Objective
Create the `EditorCanvasView.swift` file - the main drawing canvas for the screenshot annotation editor.

## Context
The editor window exists (`EditorWindowController.swift`) but lacks the actual drawing canvas. The canvas is referenced at line 21: `private let canvasView: EditorCanvasView`. This is the core annotation engine.

## Requirements from Plan

### Canvas Specifications:
- Custom NSView subclass
- Displays base image
- Layer-based drawing for annotations
- Supports zoom (0.5x - 3.0x)
- Minimum window enforcement (580px width)

### Tools to Implement:

1. **Pen** (freehand drawing)
   - Variable width path following mouse/touch
   - Smooth curves using bezier paths

2. **Arrow**
   - Click and drag to create
   - Arrowhead at end point
   - Line connects start to end

3. **Rectangle**
   - Click and drag to define rect
   - Stroke only (no fill)

4. **Ellipse/Oval**
   - Click and drag to define bounds
   - Stroke only

5. **Text**
   - Click to place text cursor
   - Type text directly on canvas
   - Text objects are movable (drag to reposition)
   - Double-click to edit text
   - Text persists until cleared/saved

### Color Picker:
- 6 colors: Red, Yellow, Green, Blue, Orange, Purple
- Default: Red
- Keyboard shortcuts: Cmd+1 to Cmd+6
- Visual color buttons in toolbar (already in EditorWindowController)

### Undo System:
- Stack limit: 30 actions
- Each stroke/shape/text = one action
- Cmd+Z to undo
- Maintain undo stack across tool changes

### Zoom:
- Cmd++ : Zoom in (max 3x)
- Cmd+- : Zoom out (min 0.5x)
- Cmd+0 : Reset to 100%
- Pinch gesture support (trackpad)
- Canvas scales around center

### Canvas Operations:
```swift
final class EditorCanvasView: NSView {
    // Init
    init(image: NSImage)
    
    // Tool selection
    func setTool(_ tool: EditorTool)
    func setColor(_ color: NSColor)
    
    // Actions
    func undo()
    func clear()
    func zoomIn()
    func zoomOut()
    func resetZoom()
    
    // Export
    func renderFinalImage() -> NSImage
}

enum EditorTool {
    case pen
    case arrow
    case rectangle
    case ellipse
    case text
}
```

## Architecture

### Layers:
```
CanvasView
├── Base Image Layer (bottom)
├── Annotations Layer (shapes/text)
└── Active Drawing Layer (preview while dragging)
```

### Data Model:
```swift
protocol Annotation {
    var color: NSColor { get }
    func render(in context: CGContext, scale: CGFloat)
}

struct PenStroke: Annotation {
    let points: [CGPoint]
    let color: NSColor
}

struct Arrow: Annotation {
    let start: CGPoint
    let end: CGPoint
    let color: NSColor
}

struct RectAnnotation: Annotation {
    let rect: CGRect
    let color: NSColor
}

struct EllipseAnnotation: Annotation {
    let rect: CGRect
    let color: NSColor
}

struct TextAnnotation: Annotation {
    let text: String
    let position: CGPoint
    let color: NSColor
    var isEditing: Bool
}
```

### Undo Stack:
```swift
private var annotations: [Annotation] = []
private var undoStack: [[Annotation]] = []
private let maxUndoLevels = 30

func pushUndoState() {
    undoStack.append(annotations)
    if undoStack.count > maxUndoLevels {
        undoStack.removeFirst()
    }
}
```

## Mouse/Trackpad Handling:

| Action | Behavior |
|--------|----------|
| Mouse Down | Start drawing shape or place text cursor |
| Mouse Dragged | Update shape preview (rect/ellipse/arrow) or continue pen stroke |
| Mouse Up | Finalize shape, add to annotations |
| Double Click | Edit existing text annotation |
| Click on text | Start dragging to move |

## Text Editing:
- Click on canvas with text tool → Create new text annotation at that point
- Type characters → Append to text
- Return/Enter → Finish text editing
- Click away → Finish editing
- Double-click existing text → Enter edit mode
- Drag text box → Reposition

## Keyboard Shortcuts (Canvas Level):
- Cmd+Z : Undo
- Cmd+1-6 : Select color
- Cmd++ : Zoom in
- Cmd+- : Zoom out
- Cmd+0 : Reset zoom
- Delete/Backspace : Delete selected text annotation

## Integration Points

1. EditorWindowController creates canvas: `EditorCanvasView(image: image)` (line 57)
2. Tool selection: `canvasView.setTool(_:)` called by toolbar (already wired)
3. Color selection: `canvasView.setColor(_:)` called by color buttons
4. Undo button: `canvasView.undo()`
5. Clear button: `canvasView.clear()`
6. Final export: `canvasView.renderFinalImage()` returns NSImage for saving

## File Location
`Sources/EditorCanvasView.swift`

## Edge Cases

1. **Very large images**: Handle images up to 8000x8000 gracefully
2. **Zoom at extremes**: Maintain quality at 3x zoom
3. **Text overflow**: Canvas extends if text goes beyond image bounds
4. **Empty canvas**: renderFinalImage returns original image
5. **Memory**: Don't store full bitmap for each undo state (store commands instead)

## Testing Checklist

- [ ] All 5 tools work correctly
- [ ] Pen draws smooth curves
- [ ] Arrow has proper arrowhead
- [ ] Rect and ellipse draw correctly
- [ ] Text can be added, edited, and moved
- [ ] Undo works (up to 30 levels)
- [ ] Zoom in/out/reset works
- [ ] Color selection changes drawing color
- [ ] Export produces correct image with annotations
- [ ] Performance is smooth with many annotations

## Do Not Modify
- Do not modify EditorWindowController.swift
- Work only on EditorCanvasView.swift

## Success Criteria
EditorCanvasView.swift compiles, renders images, supports all tools, and integrates with EditorWindowController without modifying existing code.
