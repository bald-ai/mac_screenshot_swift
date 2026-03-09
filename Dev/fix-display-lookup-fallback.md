# Plan: Use macOS `screencapture` for All Capture Paths

## Decision

Use `/usr/sbin/screencapture` for both:

- area capture
- full-screen capture

Remove ScreenCaptureKit and `CGDisplayCreateImage` capture paths entirely.

## Why

Current code is mixed:

- area capture already uses `screencapture`
- full-screen still uses ScreenCaptureKit (+ legacy fallback)

The display-lookup bug exists only in the ScreenCaptureKit full-screen path. The
cleanest fix is a single native macOS capture backend.

## Display Targeting

`screencapture -m` captures the main monitor (the one with the menu bar).
Current full-screen code uses `NSScreen.main ?? NSScreen.screens.first`, which
is usually the same display but not guaranteed. We are standardizing on the
menu-bar monitor via `-m`.

Multi-monitor note: this plan intentionally does **not** add multi-monitor
full-screen capture. The app captures the menu-bar monitor only.

`-m` does **not** follow the mouse cursor. If the user is working on a secondary
monitor and triggers full-screen capture, it still grabs the menu-bar monitor.
Capturing the mouse-cursor monitor is a separate feature, not in scope here.

## Target Behavior

- `captureArea`: keep current interactive flow (`screencapture -i -x`).
- `captureFullScreen`: use non-interactive `screencapture -x -m <path>`.
- Cursor is intentionally excluded from captures. The old ScreenCaptureKit path
  had `showsCursor = true`; this is a deliberate change.
- Post-capture flow unchanged (save, sound, rename/note workflow).

## Error Handling

For both capture paths:

- **Non-zero exit, area capture:** treat as user cancel (no error shown). Clean
  up temp file silently.
- **Non-zero exit, full-screen capture:** show error alert
  ("Screenshot failed" / "System capture exited with status \(code)").
  Clean up temp file.
- **Temp file missing after exit 0, area capture:** treat as user cancel (no
  error shown). This matches current behavior where some no-file outcomes are
  normal cancels.
- **Temp file missing after exit 0, full-screen capture:** show error alert
  ("Screenshot failed" / "Captured image file not found.").
- **Temp file not loadable as NSImage:** show error alert
  ("Screenshot failed" / "Could not read captured image."). Clean up temp file.
  Note: for area capture this is a small behavior change — current code silently
  ignores unreadable files. Showing an error here is intentional since exit 0
  with a corrupt file is unexpected and worth surfacing.

## Implementation Plan

### 1. Add shared system-capture helpers and switch full-screen to CLI

**File:** `Sources/ScreenshotService.swift`

Add these helpers to replace duplicated process logic:

- `makeTemporaryScreenshotURL() -> URL`
  Returns a unique temp path with `.png` extension.

- `runScreencapture(arguments: [String], completion: @escaping (Int32) -> Void)`
  Creates a `Process` pointing at `/usr/sbin/screencapture`, sets arguments,
  wires `terminationHandler` to call `completion` on the main queue, and starts
  the process. On launch failure, calls `completion(-1)`.
  Sets `systemCaptureProcess` before launch and clears it in the completion.

- `loadTemporaryImage(at url: URL) -> TemporaryImageResult`
  Uses `ScreenshotServiceCoreLogic.loadTemporaryImage(at:fileExists:loadImage:)`
  for the decision, then deletes the temp file regardless of outcome.
  Returns `.loaded(NSImage)`, `.missing`, or `.unreadable` so the caller can
  show the correct error message.

Replace the full-screen path:

- `captureFullScreen()` calls `runScreencapture` with `["-x", "-m", tempURL.path]`.
- On completion, applies the error-handling rules above.
- Reuses `saveImageToDesktop` → `playCaptureSound` → `beginPostCaptureFlow`
  same as area capture.

Refactor `beginSystemAreaCapture` / `finishSystemAreaCapture` to use the same
helpers.

Rename as part of this step:

- `isSystemAreaCaptureInProgress` → `isSystemCaptureInProgress`
- `systemAreaCaptureProcess` → `systemCaptureProcess`

### 2. Remove ScreenCaptureKit and legacy capture code

**Files:** `Sources/ScreenshotService.swift`,
`Sources/ScreenshotServiceCoreLogic.swift`

Delete from `ScreenshotService.swift`:

- `import ScreenCaptureKit`
- `ScreenSnapshot` struct
- `captureRegion(...)`
- `captureCGImage(...)`
- `captureWithScreenshotManager(...)`
- `captureWithLegacyAPI(...)`
- `captureRects(rectInScreenPoints:screen:)` (private wrapper)
- `shouldFallbackToLegacy(_:)` (private wrapper)
- `screenForDisplayID(_:)` helper
- `NSScreen.displayID` extension

Delete from `ScreenshotServiceCoreLogic.swift`:

- `captureRects(rectInScreenPoints:screenFrame:scale:)`
- `shouldFallbackToLegacy(_:)`

Keep in `ScreenshotServiceCoreLogic.swift` (still used):

- `resizedImageIfNeeded(_:maxWidth:)`
- `jpegData(from:quality:)`
- `uniqueScreenshotURL(in:baseName:fileExists:)`

Add to `ScreenshotServiceCoreLogic.swift`:

- `TemporaryImageResult` enum: `.loaded(NSImage)`, `.missing`, `.unreadable`
- `loadTemporaryImage(at:fileExists:loadImage:) -> TemporaryImageResult`
  Pure decision function. Takes injected closures (same pattern as
  `uniqueScreenshotURL`). `ScreenshotService` calls it with real I/O and
  handles file cleanup separately.

### 3. Update tests

**Files:** `Tests/ZoomiesTests/*`

Per repo rules (AGENTS.md): behavior changes require test updates.

- Remove tests for deleted fallback logic (`shouldFallbackToLegacy`,
  `captureRects`).
- Test `ScreenshotServiceCoreLogic.loadTemporaryImage` happy path (file exists
  and loads → `.loaded`) and edge cases (file missing → `.missing`, file exists
  but not an image → `.unreadable`). This is a pure function with injected
  closures, so it's directly testable.
- Do not add integration tests for `Process` execution.
- Provide short rationale for any removed test in the handoff notes.

### 4. Update docs

**Files:** `CHANGELOG.md`

Add under `Unreleased`:

- Full-screen capture moved from ScreenCaptureKit to `/usr/sbin/screencapture`.
- Legacy `CGDisplayCreateImage` fallback removed.
- Full-screen capture no longer includes the mouse cursor (was included before).
- Full-screen now always targets the menu-bar monitor (`-m`).
- App now uses one capture backend for both actions.

`README.md` does not describe the capture pipeline and is not affected.

## Validation

Run:

```bash
swift build
swift test
swift run Zoomies
```

Verify no old references remain:

```bash
rg "ScreenCaptureKit|SCShareableContent|SCScreenshotManager|CGDisplayCreateImage|captureWithLegacyAPI|shouldFallbackToLegacy" Sources
```

Manual checks:

- Area capture works; cancel behaves as before.
- Full-screen capture works and captures the menu-bar monitor.
- Post-capture workflow still opens on successful captures.
- Full-screen failure shows an error alert (test by temporarily breaking the
  command).

## Expected Result

- One capture backend: `/usr/sbin/screencapture`.
- Display lookup bug removed at the root (ScreenCaptureKit path gone).
- Simpler capture code with fewer failure branches.
