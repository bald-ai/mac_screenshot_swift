# AGENTS.md

This file defines shared rules for AI coding work in `mac_screenshot_swift`.
Optimize for clarity, fast iteration, and future maintainability.

## General
- Future-AI clarity: make intent obvious, keep logic easy to find, and add short comments only when behavior is not self-evident.
- Feature-first organization: keep code with the feature unless it is truly shared.
- Consistent naming: use stable, descriptive names; avoid old/new/temp/v2/fixed; keep naming patterns uniform within a feature.
- Separation by layer: app entry points wire flows, views render UI, controllers/services orchestrate behavior, models/utilities hold core logic.
- Keep core rules testable without UI framework coupling when practical.
- Name non-obvious or repeated numbers in `Constants.swift`; trivial UI math can stay inline.
- Explicit input validation and clear errors at boundaries (system APIs, external data, user input).
- Avoid `Any` in app code unless required by APIs; prefer concrete types and protocols.
- Stable accessibility identifiers for key controls used by UI automation.
- No new dependencies or tooling changes without approval.
- File size guideline: aim to keep files under ~700 LOC; split/refactor when it improves clarity or testability.

## Testing
- If behavior changes or a bug is fixed, add/update tests to reflect intended behavior.
- Refactors should not weaken tests.
- If a test becomes a false positive/negative or no longer validates intent, update it to assert the correct behavior.
- Prefer adding tests over loosening assertions.
- Never delete/disable tests just to get green; any test change requires a short rationale in handoff.

## Handoff
- Update docs when behavior changes (short note in existing docs).
- Gate before handoff: run `swift build`, `swift test` (if tests exist), plus project validation commands.
- If any step cannot be run, state why and what is missing.

## Project Notes
### Keybinds
IMPORTANT: The app uses Cmd+Shift+3, Cmd+Shift+4, and Cmd+Shift+2 for shortcuts.
These conflict with macOS defaults, and system screenshot shortcuts are already disabled.
Do not suggest changing keybinds; assume they are configured as-is.

### Build & Run
```bash
cd mac_screenshot_swift
swift build
./.build/arm64-apple-macosx/debug/ScreenshotApp
```

### Quick Validation
After coding changes, use:
```bash
swift run ScreenshotApp
```
