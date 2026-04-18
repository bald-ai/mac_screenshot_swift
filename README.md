# Zoomies

> **Requires macOS 14 (Sonoma) or later.**

Small keyboard-first macOS screenshot app I use daily.

If it helps you, awesome.  
If not, no worries.  
Fork it, change it, rebuild it.

Status: **beta (`v0.x`)**

## What It Does

- Fast area capture and full-screen capture on the display under the mouse.
- Saves captures at native pixel resolution, with optional max-width downscaling.
- Quick post-capture flow: rename, note, edit, save/copy/delete.
- Rename field edits the visible filename only; Zoomies keeps the `.jpg` extension automatically.
- Simple annotation editor (pen, arrow, rectangle, ellipse, text).
- Keyboard-driven workflow.

## Quick Start

```bash
cd /Users/michalkrsik/windsurf_project_folder/mac_screenshot_swift
swift build
swift run Zoomies
```

## Default Shortcuts

- `Ctrl+Shift+4` -> area capture
- `Ctrl+Shift+3` -> full-screen capture
- `Ctrl+Shift+2` -> select an image in Finder, press this to edit/rename it with Zoomies

Area capture now shows the overlay immediately on hotkey, without waiting for app activation.

## Rebinding Shortcuts

I recommend rebinding to the default macOS screenshot shortcuts (`Cmd+Shift+3` / `Cmd+Shift+4`) — they are way more comfortable.

1. First, unbind or rebind the default macOS shortcuts: go to `System Settings` -> `Keyboard` -> `Keyboard Shortcuts` -> `Screenshots` and disable them or change them to something else (I use `Option+Shift+3` / `Option+Shift+4` for the macOS ones).
2. Then open the Zoomies menu bar icon -> `Settings` -> `Shortcuts`, and set `Cmd+Shift+3` / `Cmd+Shift+4` / `Cmd+Shift+2` for Zoomies.

## Permissions

The app uses `ScreenCaptureKit` (`SCScreenshotManager`) for all screen capture. macOS will prompt once for Screen Recording permission.

- **Screen Recording** (for screenshots via ScreenCaptureKit)
- **Automation / Finder** (for reopening flow on selected Finder image via `Ctrl+Shift+2`)

## Debug Log

Area capture (`Ctrl+Shift+4`) writes a fresh debug trace to `/Users/michalkrsik/Desktop/zoomies_debug.log` for each attempt.

- The file resets at the start of every area-capture attempt so one run does not mix with the previous one.
- The trace now covers activation, overlay lifecycle, selection conversion, ScreenCaptureKit capture, file save, alerts, and rename-panel handoff.

## Ideas, Issues, PRs

- Bug? Open an issue.
- Idea? Open an issue with `[Idea]` in the title.
- Want to contribute code? Open a PR.

Project is maintainer-led: feedback is welcome, and final merge/product decisions are made by the maintainer.
