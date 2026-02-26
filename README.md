# ScreenshotApp

Small keyboard-first macOS screenshot app I use daily.

If it helps you, awesome.  
If not, no worries.  
Fork it, change it, rebuild it.

Status: **beta (`v0.x`)**

## What It Does

- Fast area and full-screen capture.
- Quick post-capture flow: rename, note, edit, save/copy/delete.
- Simple annotation editor (pen, arrow, rectangle, ellipse, text).
- Keyboard-driven workflow.

## Quick Start

```bash
cd /Users/michalkrsik/windsurf_project_folder/mac_screenshot_swift
swift build
swift run ScreenshotApp
```

## Default Shortcuts

- `Ctrl+Shift+4` -> area capture
- `Ctrl+Shift+3` -> full-screen capture
- `Ctrl+Shift+2` -> reopen flow for selected Finder image

## Rebinding Shortcuts

- Open the app menu bar icon -> `Settings`.
- In `Shortcuts`, click a shortcut recorder and press the new key combo.
- Repeat for all actions you want to customize.

If you want to use macOS-style screenshot shortcuts (`Cmd+Shift+3` / `Cmd+Shift+4`) for this app:

- Rebind those shortcuts in app settings.
- In macOS `System Settings` -> `Keyboard` -> `Keyboard Shortcuts` -> `Screenshots`, disable or change the system screenshot shortcuts so they do not conflict.

## Permissions

The app may request macOS permissions for:

- Screen capture / screen recording (for screenshots)
- Finder automation (for reopening flow on selected Finder image)

## Ideas, Issues, PRs

- Bug? Open an issue.
- Idea? Open an issue with `[Idea]` in the title.
- Want to contribute code? Open a PR.

Project is maintainer-led: feedback is welcome, and final merge/product decisions are made by the maintainer.

## Contributing

See `/Users/michalkrsik/windsurf_project_folder/mac_screenshot_swift/CONTRIBUTING.md`.

## Changelog

See `/Users/michalkrsik/windsurf_project_folder/mac_screenshot_swift/CHANGELOG.md`.

## Support

If this app is useful to you, you can support it with a donation:

- Donation link placeholder: `https://ko-fi.com/<your-name>`
- You can also use: `https://www.buymeacoffee.com/<your-name>`
