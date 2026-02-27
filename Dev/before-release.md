# Before Release

## Editor window scaling: use screen-relative sizing

The editor window max size is hardcoded to `1400×900` points (`sizeWindowToImage()` in `EditorWindowController.swift`). After switching to native `screencapture`, full-screen captures on Retina displays exceed this cap (e.g. 3024×1964 px → 1512×982 pt), forcing the image to scale down just to fit.

**Fix:** Replace the fixed `maxW`/`maxH` with a percentage of the current screen's visible frame (e.g. 85–90%), so the editor window and image scale appropriately on any monitor size.

**Affected code:**
- `EditorWindowController.sizeWindowToImage()` — `maxW`, `maxH` constants
- `calculateEditorPadding()` — references the same 1400/900 values
