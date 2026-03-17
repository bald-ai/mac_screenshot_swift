# Deferred Task: Workflow / Editor Refactor

## Why this exists

The workflow and editor area is carrying too many unrelated responsibilities in a few oversized files. This is not an immediate bug, but it is the main maintainability issue left from the review pass and should be handled as a deliberate refactor later.

## Current pain points

- `Sources/ScreenshotWorkflowController.swift` mixes workflow state, backup restore logic, note rendering, image encoding/writing, floating panel infrastructure, and text-input command plumbing.
- `Sources/EditorWindowController.swift` is large and still owns a lot of toolbar/setup behavior that could be split into smaller feature-focused pieces.
- `Sources/EditorCanvasView.swift` is very large and acts as both rendering layer and a broad input/state coordinator.

## Refactor goal

Keep behavior the same, but split responsibilities so the main controllers read like orchestration code instead of implementation dumps.

## Good extraction targets

- Extract note rendering / note image composition from `ScreenshotWorkflowController` into a dedicated helper or logic type.
- Extract image encoding / output format decisions from `ScreenshotWorkflowController` into a dedicated persistence helper.
- Move generic floating-panel and command-aware text input types out of `ScreenshotWorkflowController` into their own files.
- Review whether parts of `EditorWindowController` toolbar and color-picker setup should live in a dedicated view/helper.
- Review whether `EditorCanvasView` input handling can be separated from drawing/compositing concerns without making the code harder to follow.

## Constraints

- Do not change user-visible behavior as part of the first pass.
- Prefer moving code into focused files over introducing more abstraction layers.
- Keep the extracted logic testable where practical.
- Avoid broad architecture churn unless the payoff is obvious.

## Validation

After this refactor, run:

- `swift build`
- `swift test`
- `swift run Zoomies`
