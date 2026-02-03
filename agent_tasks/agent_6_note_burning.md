# Agent 6: Wire Note Burning to Workflow

## Objective
Wire up the note burning functionality so that when a user adds a note in the note panel, it actually gets burned into the screenshot image.

## Context
The note burning logic exists in `ScreenshotWorkflowController.swift` (lines 309-392) with method `applyNoteIfNeeded(_:)`, but it's NOT being called during the workflow completion. The workflow currently skips note burning entirely.

## Current State Analysis

In `ScreenshotWorkflowController.swift`:

1. **Note Panel Action Handler** (lines 181-203):
   - Handles save/copy/copy+delete/delete actions
   - Calls `complete(action:note:)` with the note text
   - ✅ This part works

2. **Complete Method** (lines 276-299):
   - Receives the note text
   - Calls `applyNoteIfNeeded(note)` if note exists
   - ✅ This part exists and calls the burning method

3. **ApplyNoteIfNeeded** (lines 309-337):
   - Full implementation exists
   - Trims text to 1000 chars
   - Adds prefix if enabled
   - Burns text into image using CoreGraphics
   - ✅ Implementation is complete

**The Problem**: The workflow only calls `applyNoteIfNeeded` when coming from the note panel, but NOT when:
- User saves directly from rename panel (skipping note panel)
- User goes to editor from note panel
- User takes action in editor

## Requirements from Plan

### Note Burning Behavior:
1. **Text Processing**:
   - Trim whitespace from note text
   - Truncate to 1000 characters max
   - Prepend prefix if `notePrefixEnabled` is true
   - Format: "{prefix} {text}"

2. **Visual Rendering** (already implemented in lines 339-392):
   - Dark bar at bottom of image (calibratedWhite: 0.1, alpha: 0.85)
   - Minimum bar width: 400px
   - White text, 14pt system font
   - 20px padding on sides, 10px top/bottom
   - Word wrap long text
   - Center original image above the note bar

3. **When to Burn**:
   - When completing workflow from note panel with text
   - BEFORE opening editor (if user goes rename → note → editor)
   - BEFORE final save/copy/delete actions

### Workflow Flows:

**Flow 1: Rename only**
```
Screenshot → Rename Panel → Save
(No note, no burning)
```

**Flow 2: Rename + Note**
```
Screenshot → Rename Panel → Note Panel → Save
(Burn note, then save)
```

**Flow 3: Rename + Note + Editor**
```
Screenshot → Rename Panel → Note Panel → Editor → Save
(Burn note BEFORE opening editor, edit annotated image)
```

**Flow 4: Direct to Editor**
```
Editor flow is separate, no note burning
```

## Changes Required

### File to Modify
`Sources/ScreenshotWorkflowController.swift`

### Specific Changes:

1. **In `handleNoteAction`** (around line 200):
   ```swift
   case .goToEditor(let text):
       // BURN NOTE FIRST before opening editor
       applyNoteIfNeeded(text)
       openEditor(withNote: text)  // Or without note since it's burned
   ```

2. **In `handleEditorCompletion`** (around line 229):
   - Currently saves edited image directly
   - This is correct because note is already burned before editor opened
   - No changes needed here

3. **Verify `applyNoteIfNeeded` is called in all paths**:
   - Line 283: Called in `complete(action:note:)` ✅
   - Line 209: Called in `openEditor(withNote:)` - NEEDS TO BE ADDED

### Code Change:

Current code (line 207):
```swift
private func openEditor(withNote text: String) {
    // Apply the note first so the editor sees the captioned image.
    applyNoteIfNeeded(text)  // ✅ This exists!
    
    // Close the note panel...
}
```

Wait, looking at the code again... it seems `applyNoteIfNeeded` IS already called in `openEditor`. Let me re-check the complete method.

Actually, looking at lines 276-299:
```swift
private func complete(action: FinalAction, note: String?) {
    // ...
    if let note = note {
        applyNoteIfNeeded(note)
    }
    // ...
}
```

And lines 181-203 handle note actions calling `complete`.

**So what's actually missing?** 

The issue might be that when user presses:
- "Save" in note panel → calls `complete(action: .saveOnly, note: text)` → burns note ✅
- "Copy+Save" → burns note ✅
- "Copy+Delete" → burns note ✅
- "Delete" → doesn't burn (correct, file deleted)
- "Tab to Editor" → calls `openEditor` → burns note ✅

Actually, looking more carefully at the code, it seems like the burning IS wired up! Let me re-examine...

Oh I see the issue now. Looking at line 209 in the current code:
```swift
private func openEditor(withNote text: String) {
    // Apply the note first so the editor sees the captioned image.
    applyNoteIfNeeded(text)
```

So the note IS being burned when going to editor.

And lines 276-299 handle the other cases.

**Wait**, let me look at the actual workflow more carefully:

From Note Panel:
- `.save(text:)` → calls `complete(action: .saveOnly, note: text)` ✅ burns
- `.copyAndSave(text:)` → calls `complete(action: .copyAndSave, note: text)` ✅ burns
- `.copyAndDelete(text:)` → calls `complete(action: .copyAndDelete, note: text)` ✅ burns
- `.delete` → calls `complete(action: .deleteOnly, note: nil)` (no note to burn) ✅
- `.goToEditor(text:)` → calls `openEditor(withNote: text)` ✅ burns

So actually... **the note burning IS already wired up!**

But wait, the user said it's not working. Let me check if there's a bug in `applyNoteIfNeeded`...

Looking at lines 311-313:
```swift
private func applyNoteIfNeeded(_ rawText: String) {
    var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
```

So if text is empty after trimming, it returns early. That's correct.

Looking at lines 316-324:
```swift
ensureBackupExists()

text = String(text.prefix(1000))

let settings = settingsStore.settings
if settings.notePrefixEnabled {
    let prefix = settings.notePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    if !prefix.isEmpty {
        text = prefix + " " + text
    }
}
```

This adds the prefix. ✅

Lines 327-336:
```swift
guard let image = NSImage(contentsOf: fileURL) else { return }
guard let updated = burn(note: text, into: image) else { return }

guard let data = jpegData(from: updated, quality: settings.quality) else { return }

do {
    try data.write(to: fileURL, options: .atomic)
} catch {
    presentError(title: "Failed to write note", message: error.localizedDescription)
}
```

This burns and saves. ✅

**Conclusion**: The code looks like it's already wired up! 

But wait... let me check if there's an issue with how the note is being passed...

Actually, I think I understand now. The user might be testing and the note isn't appearing. This could be because:

1. The note panel isn't implemented yet (Agent 2 hasn't done their work)
2. Or there's a bug in the burning logic

Since Agent 6 is about wiring, and the wiring appears to exist, maybe this agent's job is to:
1. VERIFY the wiring is correct
2. FIX any bugs in applyNoteIfNeeded or burn()
3. Add any missing connections

Let me rewrite this task to be about verification and bug fixing.

## Revised Objective
Verify and fix the note burning integration in the screenshot workflow. The methods exist but may have bugs or missing connections.

## Verification Checklist

1. **Trace the flow**:
   - [ ] User types note in NotePanel
   - [ ] Note text is passed to workflow controller
   - [ ] `applyNoteIfNeeded` is called
   - [ ] Note text is processed (prefix, truncation)
   - [ ] `burn(note:into:)` is called
   - [ ] Image is modified and saved
   - [ ] Final action (save/copy/delete) uses annotated image

2. **Check edge cases**:
   - [ ] Empty note (should not burn)
   - [ ] Note > 1000 chars (should truncate)
   - [ ] Prefix enabled with empty prefix text
   - [ ] Prefix + note combination
   - [ ] Going from note to editor (note should be burned before editor opens)

3. **Fix bugs if found**:
   - Coordinate system issues
   - Text rendering problems
   - File writing errors
   - Missing error handling

## Testing

Create a test scenario:
1. Take screenshot
2. Add note "Test note"
3. Save
4. Open saved image
5. Verify note appears at bottom

## File to Modify
`Sources/ScreenshotWorkflowController.swift` (only if bugs found)

## Success Criteria
Note burning works correctly in all workflow paths (save, copy+save, copy+delete, editor flow) with and without prefix enabled.
