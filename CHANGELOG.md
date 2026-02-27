# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

- Changed default global shortcuts to `Ctrl+Shift+4`, `Ctrl+Shift+3`, and `Ctrl+Shift+2` to reduce conflicts with macOS screenshot defaults.
- Full-screen capture moved from ScreenCaptureKit to `/usr/sbin/screencapture`.
- Legacy `CGDisplayCreateImage` fallback removed.
- Full-screen capture no longer includes the mouse cursor.
- Full-screen now targets the menu-bar monitor (`-m`).
- App now uses one capture backend for both area and full-screen capture.

## [0.1.0] - 2026-02-16

### Added

- Initial public release of `ScreenshotApp` as a macOS menu bar app.
- Global shortcuts for fast workflows:
  - `Cmd+Shift+4` for area capture.
  - `Cmd+Shift+3` for full-screen capture.
  - `Cmd+Shift+2` to reopen the post-capture flow for the current Finder image selection.
- Native-style capture pipeline:
  - Area capture via `/usr/sbin/screencapture -i`.
  - Full-screen capture via ScreenCaptureKit with fallback handling.
- Post-capture workflow with rename, note, and editor steps.
- Editor tools and controls:
  - Drawing/text tools: pen, arrow, rectangle, ellipse, text.
  - Undo stack and zoom controls.
  - Save, copy+save, copy+delete, and delete actions.
- Note burn-in support with optional note prefix.
- Settings window with persisted preferences:
  - JPEG quality.
  - Max width resize.
  - Note prefix controls.
  - Filename template editor (reorder/toggle blocks).
  - Shortcut recorder for all global shortcuts.
- Filename template system with date/time/counter/static-text blocks and collision-safe file naming.
- Clipboard service with cache support for copy+delete flows.
- Backup service for original screenshot recovery during editing sessions.
- Automated tests for settings, hotkeys, capture/save core logic, workflow logic, backups, clipboard, and Finder selection parsing.
