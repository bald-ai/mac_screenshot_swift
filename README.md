# Zoomies

> **⚠️ NOTE: On some macOS versions, the Screen Recording permission popup appears even though it is NOT actually required. If your screenshots work fine after dismissing the popup, YOU CAN SAFELY IGNORE IT.** On other macOS versions the permission is enforced and must be granted — the app will guide you to the correct settings if that happens.

Small keyboard-first macOS screenshot app I use daily.

If it helps you, awesome.  
If not, no worries.  
Fork it, change it, rebuild it.

Status: **beta (`v0.x`)**

## What It Does

- Fast area capture and full-screen capture on the display under the mouse.
- Quick post-capture flow: rename, note, edit, save/copy/delete.
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
- `Ctrl+Shift+2` -> reopen flow for selected Finder image

## Rebinding Shortcuts

I recommend rebinding Zoomies to use the default macOS screenshot shortcuts (`Cmd+Shift+3` / `Cmd+Shift+4`) — they are way more comfortable to use.

- Open the app menu bar icon -> `Settings`.
- In `Shortcuts`, click a shortcut recorder and press the new key combo.
- Repeat for all actions you want to customize.
- In macOS `System Settings` -> `Keyboard` -> `Keyboard Shortcuts` -> `Screenshots`, disable or change the system screenshot shortcuts so they do not conflict.

## Permissions

The app may request macOS permissions for:

- **Screen Recording** (for screenshots)
- **Automation / Finder** (for reopening flow on selected Finder image via `Ctrl+Shift+2`)

## Ideas, Issues, PRs

- Bug? Open an issue.
- Idea? Open an issue with `[Idea]` in the title.
- Want to contribute code? Open a PR.

Project is maintainer-led: feedback is welcome, and final merge/product decisions are made by the maintainer.
