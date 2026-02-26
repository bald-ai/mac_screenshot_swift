# Release TODO

Use this checklist before each public release.

## Before Release

- [ ] Run local validation:
  - [ ] `swift build`
  - [ ] `swift test`
- [ ] Test the app flow end-to-end (capture -> rename/note/edit -> save/copy/delete).
- [ ] Verify permission prompts on a clean machine or fresh app install:
  - [ ] Screen Recording
  - [ ] Automation (Finder)
- [ ] Verify shortcut defaults and docs:
  - [ ] Fresh/default settings use `Ctrl+Shift+4`, `Ctrl+Shift+3`, `Ctrl+Shift+2`.
  - [ ] Rebinding works from app `Settings` -> `Shortcuts`.
  - [ ] README rebinding instructions match actual app behavior.
- [ ] Update `CHANGELOG.md`:
  - [ ] Move important items from `Unreleased` into next version section.
  - [ ] Set release date.
- [ ] Confirm docs look good:
  - [ ] `README.md`
  - [ ] `CONTRIBUTING.md`
  - [ ] `LICENSE`
- [ ] Update donation link in `README.md` if needed.
- [ ] Create release tag (example: `v0.1.0`) and publish GitHub release.

## Donation Link Reminder

- [ ] Set your real donation URL in `README.md`:
  - `https://ko-fi.com/<your-name>`
  - or `https://www.buymeacoffee.com/<your-name>`
