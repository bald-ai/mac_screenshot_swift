# Agent 7: Counter Tracking Implementation

## Objective
Implement counter tracking for screenshot filenames so that screenshots get sequential numbering (Screenshot_001, Screenshot_002, etc.) instead of timestamp-only names.

## Context
The `FilenameTemplate` in `Settings.swift` (lines 103-235) supports a `.counter` block type, and `ScreenshotService.swift` has logic to generate filenames using templates. However, the counter value is not being tracked/incremented between screenshots.

## Current State Analysis

### FilenameTemplate (Settings.swift lines 200-234):
```swift
func makeFilenameComponents(date: Date, counter: Int) -> [String] {
    // ...
    case .counter:
        // Only append counter when > 1 so first screenshot is cleaner.
        if counter > 1 {
            components.append(String(counter))
        }
    // ...
}
```

The template accepts a counter parameter, but the counter is not being persisted.

### ScreenshotService (lines 152-177):
```swift
private func uniqueScreenshotURL(in directory: URL, date: Date) -> URL {
    // This generates filenames using the template
    // but counter is always 1 or based on collision detection
}
```

Currently, counter-based uniqueness is handled by collision detection (checking if file exists and adding _2, _3, etc.). But the plan requires:
1. Explicit counter tracking
2. Counter persists across app launches
3. Counter is used in template, not just collision fallback

## Requirements from Plan

### Counter Behavior:

1. **Counter Increment**:
   - Start at 1 on fresh install
   - Increment by 1 for each new screenshot
   - Counter is global (not per-session)

2. **Persistence**:
   - Save counter to disk
   - Load counter on app launch
   - Handle app crashes gracefully

3. **Filename Generation**:
   - Template uses counter value: "Screenshot_001.jpg"
   - Counter format: Plain integer (1, 2, 3...)
   - Optional: Zero-padding (001, 002...)

4. **Collision Handling** (keep existing):
   - If file exists with counter-based name, still use _2, _3 suffix
   - Counter continues incrementing regardless

### Settings Schema:

Add to `Settings.swift`:
```swift
struct Settings: Codable {
    // ... existing fields ...
    
    /// Global screenshot counter for filename generation
    var screenshotCounter: Int
}

extension Settings {
    static let `default` = Settings(
        // ... existing defaults ...
        screenshotCounter: 1
    )
}
```

## Implementation Plan

### Step 1: Update Settings Model

**File**: `Sources/Settings.swift`

Add counter field:
```swift
struct Settings: Codable {
    var quality: Int
    var maxWidth: Int
    var notePrefixEnabled: Bool
    var notePrefix: String
    var filenameTemplate: FilenameTemplate
    var shortcuts: Shortcuts
    
    // NEW
    var screenshotCounter: Int
}
```

Update default:
```swift
static let `default` = Settings(
    quality: 90,
    maxWidth: 0,
    notePrefixEnabled: false,
    notePrefix: "",
    filenameTemplate: .defaultTemplate,
    shortcuts: .default,
    screenshotCounter: 1  // NEW
)
```

Update normalized() if needed:
```swift
func normalized() -> Settings {
    var copy = self
    // ... existing normalization ...
    
    // Ensure counter is positive
    copy.screenshotCounter = max(1, screenshotCounter)
    
    return copy
}
```

### Step 2: Increment Counter on Screenshot

**File**: `Sources/ScreenshotService.swift`

Modify `saveImageToDesktop` (around line 80-98):
```swift
func saveImageToDesktop(_ image: NSImage) throws -> URL {
    let settings = settingsStore.settings
    
    // ... existing image processing ...
    
    // Get current counter and increment
    let currentCounter = settings.screenshotCounter
    let newCounter = currentCounter + 1
    
    // Update settings with new counter
    settingsStore.update { settings in
        settings.screenshotCounter = newCounter
    }
    
    // Generate filename using counter
    let filename = settings.filenameTemplate.makeFilename(
        date: Date(),
        counter: currentCounter
    )
    
    // ... rest of saving logic ...
}
```

### Step 3: Update Filename Generation

**File**: `Sources/Settings.swift`

Ensure counter is always included in filename:

Current logic (lines 218-222):
```swift
case .counter:
    // Only append counter when > 1 so first screenshot is cleaner.
    if counter > 1 {
        components.append(String(counter))
    }
```

Change to ALWAYS include counter when block is enabled:
```swift
case .counter:
    // Always include counter for explicit tracking
    components.append(String(counter))
```

OR if we want to keep "clean" first screenshot:
```swift
case .counter:
    // Always include counter when block is enabled
    // (User can disable counter block in settings if they don't want it)
    components.append(String(counter))
```

Actually, looking at the plan again:
> Counter mode appends `_2`, `_3`, etc when filename exists.

This suggests two modes:
1. **Template counter**: Sequential numbering (Screenshot_001, _002)
2. **Collision counter**: Fallback when file exists (_2, _3)

These should be separate. The template counter is explicit, collision detection is automatic fallback.

### Step 4: Zero-Padding (Optional Enhancement)

Add format support for counter:
```swift
case .counter:
    let format = block.format ?? "%d"  // Default: plain number
    // Or always use 3-digit padding: String(format: "%03d", counter)
    components.append(String(format: "%03d", counter))
```

For now, keep it simple: plain integers.

## Edge Cases

1. **First launch**: Counter starts at 1
2. **App crash**: Counter was persisted, no loss
3. **Counter overflow**: Unlikely (Int max is huge), but wrap to 1 if needed
4. **User resets settings**: Counter resets to 1 (acceptable)
5. **File exists with counter name**: Use collision suffix (_2) but counter still increments

## Testing Checklist

- [ ] First screenshot has counter=1 in filename
- [ ] Second screenshot has counter=2
- [ ] Counter persists after app restart
- [ ] Counter increments even if screenshot fails
- [ ] Collision detection still works (_2 suffix)
- [ ] Settings JSON includes counter field
- [ ] Default template includes counter block

## Files to Modify

1. `Sources/Settings.swift` - Add counter field to model
2. `Sources/ScreenshotService.swift` - Increment counter when saving

## Files to Read (Don't Modify)
- `Sources/SettingsStore.swift` - Understand persistence
- `Sources/FilenameTemplateEditorView.swift` - See how template is edited

## Migration Path

Existing users will have counter default to 1. This is acceptable behavior.

## Success Criteria
- Screenshots get sequential numbering (1, 2, 3...)
- Counter persists across app launches
- Counter appears in filename according to template
- No regressions in collision handling
