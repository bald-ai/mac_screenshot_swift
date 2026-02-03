# Agent 4: Settings Window UI Implementation

## Objective
Extend `SettingsWindowController.swift` to add the full settings UI beyond just shortcuts.

## Context
SettingsWindowController exists (lines 33-34 of AppDelegate.swift) but currently only shows shortcut configuration. Need to add quality slider, max width dropdown, note prefix controls, and filename template editor.

## Current State
- Settings model exists in `Settings.swift` with all fields
- SettingsStore handles persistence to `~/.screenshot_app_settings.json`
- ShortcutRecorderView exists for shortcut configuration
- FilenameTemplateEditorView exists for template editing

## Requirements from Plan

### Settings to Add:

#### 1. Quality Slider
- **Range**: 10-100
- **Step**: 5 (quantized)
- **Label**: "JPEG Quality"
- **Display**: Show current value (e.g., "90")
- **Default**: 90
- **Model field**: `settings.quality`

#### 2. Max Width Dropdown
- **Label**: "Max Width"
- **Options**:
  - "Original" (value: 0)
  - "800px" (value: 800)
  - "1200px" (value: 1200)
  - "1600px" (value: 1600)
  - "1920px" (value: 1920)
  - "2400px" (value: 2400)
- **Default**: "Original"
- **Model field**: `settings.maxWidth`

#### 3. Note Prefix Section
- **Toggle**: "Enable Note Prefix" (checkbox)
  - Model field: `settings.notePrefixEnabled`
  - Default: false
- **Text Field**: "Prefix Text"
  - Max length: 50 characters
  - Disabled when toggle is off
  - Model field: `settings.notePrefix`
  - Default: ""
  - Show character count: "0/50"

#### 4. Filename Template Editor
- **Integration**: Use existing `FilenameTemplateEditorView`
- **Features**:
  - Drag to reorder blocks
  - Toggle blocks on/off
  - Preview resulting filename
  - Reset to defaults button
  - Enforce: at least one of Time or Counter must be enabled
- **Model field**: `settings.filenameTemplate`

### Layout:

Organize into sections with visual separation:

```
┌─────────────────────────────────────┐
│ General                             │
│   [Quality: [========●===] 90]      │
│   [Max Width: [Original ▼]]         │
├─────────────────────────────────────┤
│ Note Settings                       │
│   [✓] Enable Note Prefix            │
│   Prefix: [Screenshot           ]   │
│                               10/50 │
├─────────────────────────────────────┤
│ Filename Template                   │
│   [Template Editor View]            │
├─────────────────────────────────────┤
│ Shortcuts                           │
│   [Existing Shortcut Recorder]      │
└─────────────────────────────────────┘
```

## Implementation Details

### File to Modify
`Sources/SettingsWindowController.swift`

### Current Window Configuration (KEEP):
- Min size: 600x400
- Title: "Settings"
- Set frame autosave name
- Center on screen

### New UI Structure:
```swift
private func configureContent() {
    // Create NSScrollView as root
    // Add vertical NSStackView inside
    // Add sections as subviews
}

private func createGeneralSection() -> NSView
private func createNoteSection() -> NSView  
private func createTemplateSection() -> NSView
private func createShortcutsSection() -> NSView
```

### Data Binding:
- Use `settingsStore.update { }` to mutate settings
- Changes persist automatically via SettingsStore
- Update UI controls when settings change

### Validation:
- Quality: Clamp 10-100, quantize to step 5
- Note prefix: Max 50 chars, truncate if longer
- Template: Enforce time/counter invariant (FilenameTemplate.ensureTimeOrCounterEnabled)

### Keyboard Handling:
- Tab navigation between controls
- Return to save/close
- Esc to close without saving (optional)

## Integration Points

1. **Initialization**: SettingsWindowController receives `settingsStore: SettingsStore` (already done)
2. **HotKeyService**: Shortcut updates call `hotKeyService.updateShortcuts(settings:)` (already done)
3. **Persistence**: SettingsStore automatically saves to JSON

## Edge Cases

1. **Invalid settings file**: SettingsStore falls back to defaults
2. **Concurrent modification**: SettingsStore handles this
3. **Empty prefix text**: Valid when disabled
4. **Template constraint**: If user disables both time and counter, auto-enable counter

## Testing Checklist

- [ ] Quality slider updates value (in steps of 5)
- [ ] Max width dropdown updates setting
- [ ] Note prefix toggle enables/disables text field
- [ ] Note prefix text enforces 50 char limit
- [ ] Template editor integrates properly
- [ ] Shortcuts section still works
- [ ] Settings persist across app launches
- [ ] Window size and position restore correctly
- [ ] All values save to JSON correctly

## Do Not Modify
- Do not modify Settings.swift (model is complete)
- Do not modify SettingsStore.swift (persistence is complete)
- Do not modify FilenameTemplateEditorView.swift (already exists)
- Do not modify ShortcutRecorderView.swift (already exists)

## Success Criteria
Settings window shows all controls, updates settings correctly, persists changes, and maintains existing shortcut functionality.
