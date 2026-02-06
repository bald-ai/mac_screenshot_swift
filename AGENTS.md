## ScreenshotApp (mac_screenshot_swift) Notes

## Keybinds

IMPORTANT: The app uses Cmd+Shift+3, 4, and 2 for shortcuts. These conflict with macOS defaults, so the user has already disabled the system's screenshot shortcuts in System Settings > Keyboard > Keyboard Shortcuts > Screenshots.

Do not suggest changing keybinds; assume they are properly configured as-is.

## Build & Run

```bash
cd mac_screenshot_swift
swift build
./.build/arm64-apple-macosx/debug/ScreenshotApp
```

## Quick Validation

After coding changes, use this command to build and run the app for validation:

```bash
swift run ScreenshotApp
```

