# Agent Task Assignments - mac_screenshot_swift

## Overview
The remaining work has been split into 7 parallel tasks. Each agent can work independently without merge conflicts.

## Task List

### Phase 1: Parallel Implementation (Agents 1-5)
These can all run simultaneously:

| Agent | Task | File(s) | Status |
|-------|------|---------|--------|
| **Agent 1** | Rename Panel | Create `Sources/RenamePanelController.swift` | 🔵 Ready |
| **Agent 2** | Note Panel | Create `Sources/NotePanelController.swift` | 🔵 Ready |
| **Agent 3** | Editor Canvas | Create `Sources/EditorCanvasView.swift` | 🔵 Ready |
| **Agent 4** | Settings UI | Modify `Sources/SettingsWindowController.swift` | 🔵 Ready |
| **Agent 5** | Selection Overlay | Create `Sources/SelectionOverlay.swift` | 🔵 Ready |

### Phase 2: Integration (Agents 6-7)
Run after Phase 1 completes:

| Agent | Task | File(s) | Dependencies |
|-------|------|---------|--------------|
| **Agent 6** | Wire Note Burning | Modify `Sources/ScreenshotWorkflowController.swift` | Needs Agent 2 (Note Panel) |
| **Agent 7** | Counter Tracking | Modify `Sources/Settings.swift`, `Sources/ScreenshotService.swift` | None (can run anytime) |

## How to Assign Tasks

### Option 1: Using GitHub PRs
1. Create 7 feature branches from main
2. Assign each branch to a different agent
3. Agents work on their branch
4. Merge PRs in order (1-5 can merge in any order, 6-7 after)

### Option 2: Using Different Workspaces
1. Clone the repo 7 times
2. Each agent works in their own clone
3. Submit PRs from each clone
4. Merge sequentially

### Option 3: Direct File Assignment
1. Give each agent the full codebase
2. Tell them to ONLY modify/create their assigned file(s)
3. Review and merge their PR

## Task Prompts Location

All detailed prompts are in `agent_tasks/` directory:
- `agent_1_rename_panel.md`
- `agent_2_note_panel.md`
- `agent_3_editor_canvas.md`
- `agent_4_settings_ui.md`
- `agent_5_selection_overlay.md`
- `agent_6_note_burning.md`
- `agent_7_counter_tracking.md`

## Key Rules for All Agents

1. **Independent Files**: Agents 1, 2, 3, 5 create NEW files only
2. **Modification Limits**: Agent 4 and 7 modify specific files
3. **No Cross-Dependencies**: Phase 1 agents don't depend on each other
4. **Integration Order**: Agent 6 needs Agent 2's work first
5. **Shared Utilities**: All can use existing helper classes (FloatingInputPanel, CommandAwareTextField, etc.)

## Existing Infrastructure (Don't Duplicate)

These exist and should be used:
- `FloatingInputPanel` (base class for floating panels)
- `CommandAwareTextField` (text field with command interception)
- `FilenameTemplateEditorView` (template editing UI)
- `ShortcutRecorderView` (shortcut recording UI)
- All service classes (ScreenshotService, etc.)
- Settings model and persistence

## Testing Strategy

Each agent should verify:
1. Their code compiles
2. It integrates with existing code
3. It follows the Spotlight behavior requirements
4. It handles edge cases listed in their prompt

## Expected Timeline

- **Phase 1**: Can complete in parallel (estimate 2-4 hours per agent)
- **Phase 2**: Agent 6 needs to wait for Agent 2 (1-2 hours)
- **Agent 7**: Can run anytime, even during Phase 1 (1-2 hours)

## Questions?

Each agent prompt includes:
- Clear objective
- Context from the codebase
- Detailed requirements
- Interface contracts
- Edge cases
- Testing checklist
- File locations
- Do-not-modify list
