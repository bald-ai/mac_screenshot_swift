# Screen Recording Permission Popup Bug

## Status: RESOLVED — migrating to ScreenCaptureKit

## Root Cause

The app was shelling out to `/usr/sbin/screencapture` (macOS CLI tool) for all screen capture. This created a hybrid architecture where:

1. `screencapture` (a separate process) performed the actual capture.
2. The app checked `CGPreflightScreenCaptureAccess()` on its own process after failures.
3. TCC tracks permissions per-process, so the app's permission state and `screencapture`'s permission state could disagree.

This caused:
- Misleading "Screen Recording Permission Required" alerts when `screencapture` failed for non-permission reasons (e.g. user cancel).
- Native macOS permission popups triggered by `screencapture` or TCC, not by the app itself.
- On some macOS versions, screenshots worked fine without granting permission (because `screencapture` has its own entitlements), while the app still nagged about it.

## What We Found

- The app originally used `ScreenCaptureKit` (`SCScreenshotManager`) with a `CGDisplayCreateImage` fallback. This was the correct approach.
- At commit `495f959`, an AI recommended replacing it with the `screencapture` CLI. That introduced the permission confusion.
- The old working ScreenCaptureKit implementation is preserved in git at commit `7d99e19`.
- Apple explicitly recommends `ScreenCaptureKit` and has told developers to move away from `screencapture` CLI ([Apple Developer Forums](https://developer.apple.com/forums/thread/760483), [Apple Developer Forums](https://developer.apple.com/forums/thread/760112)).

## Decision

- Target macOS 14 (Sonoma) and later only.
- Use `SCScreenshotManager` for all capture. No fallbacks, no `screencapture` CLI.
- Remove `CGPreflightScreenCaptureAccess()` checks from the post-capture error path.
- Area selection uses the app's own `SelectionOverlay` (transparent fullscreen window with drag-to-select), not `screencapture -i`.

This gives a single in-process permission model: one Screen Recording grant, no ambiguity between processes.

## Previous Investigation (kept for reference)

### How the bug manifested
- On macOS 16.x, the native "Screen Recording" permission dialog appeared repeatedly, even though screenshots worked without granting it.
- On the latest macOS, granting permission resolved it.

### Why `CGPreflightScreenCaptureAccess()` was not the popup source
- The app only called `CGPreflightScreenCaptureAccess()` after `screencapture` exited non-zero.
- SDK docs describe it as a read-only check, not a prompt trigger.
- The native popup was most likely coming from `screencapture` itself or macOS TCC behavior around launching that process.

### The real app-side bug
- Any non-zero `screencapture` exit was treated as a permission problem.
- User cancels, launch failures, and actual capture failures were all lumped together.
- `CGPreflightScreenCaptureAccess()` checked the app's permission, not `screencapture`'s, so the diagnosis was unreliable.
