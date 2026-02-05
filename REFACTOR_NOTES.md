# Refactor Notes

## Architecture Snapshot

- **Entry flow / scenes**: `project.godot` starts in a menu scene, then navigates into `new_menu.tscn`, `select_puzzle.tscn`/`random_menu.tscn`, and finally gameplay in `jigsaw_puzzle_1.tscn`.
- **Autoload ownership**:
  - `PuzzleVar` (`assets/scripts/puzzleData.gd`) holds global puzzle/session state (piece arrays, metadata, flags).
  - `NetworkManager` (`assets/scripts/NetworkManager.gd`) owns online/offline transport state and multiplayer signaling.
  - `FireAuth` owns Firebase auth/persistence calls.
  - `GlobalTimer` and `GlobalProgress` provide utility singletons.
- **Main gameplay loop**: `assets/scripts/jigsaw_puzzle_1.gd` orchestrates gameplay scene setup, piece spawning, UI creation, win handling, persistence load/save, and online HUD/chat.
- **Game-state ownership today**: puzzle rules are split between `PuzzleVar`, `Piece_2d`, `jigsaw_puzzle_1.gd`, and some networking callbacks from `NetworkManager`; UI and game logic are mixed heavily in scene scripts.

## Complexity Hotspots (ranked)

1. `assets/scripts/jigsaw_puzzle_1.gd` is a god-script (scene boot, UI, networking callbacks, persistence transitions, input, win flow).
2. Back/leave flow is duplicated in three handlers (`_on_back_pressed`, `_on_no_pressed`, `_on_yes_pressed`) with near-identical disconnect and scene-return logic.
3. Puzzle selection click mapping in `assets/scripts/select_puzzle.gd` depends on button name suffix parsing (fragile and bug-prone on scene/UI rename).
4. State is represented by many booleans spread across autoloads and scenes (`complete`, `completed_on_join`, `is_online_selector`, `joining_online`, etc.) rather than explicit state models.
5. Runtime-built UI in gameplay (chat/status/piece count) increases script size and couples presentation with gameplay state updates.
6. Persistence/network branching is nested and repeated across handlers (online/offline + complete/incomplete paths).
7. Input handling in gameplay intermixes hotkeys, chat focus, mute toggles, debug actions, and global flags.

## Refactor log policy

- This file is part of the refactor workflow and should be updated in each refactor commit.
- Every incremental change should append: before/problem/change, impacted files, validation, and risks/assumptions.

## 3-Phase Refactor Roadmap

### Phase 1 — Low-risk cleanup
- Extract duplicated control flow into helpers (leave/disconnect/scene return).
- Remove brittle UI assumptions (button-name based indexing).
- Add `REFACTOR_NOTES.md` and keep step-by-step rationale/validation.

### Phase 2 — Structural improvements
- Split gameplay UI-building concerns from puzzle orchestration (`jigsaw_puzzle_1.gd` into focused components/services).
- Centralize puzzle completion/progress calculation into pure helper methods.
- Encapsulate persistence decision logic (complete/incomplete + online/offline) behind a small service API.

### Phase 3 — Deeper logic simplification
- Introduce explicit gameplay state machine (Loading, Active, Completed, Exiting).
- Reduce global mutable state dependence from `PuzzleVar`; pass narrower data contracts.
- Add lightweight automated smoke checks (scene load + key transitions) where practical.

---

## Step 1 (implemented): Deduplicate leave/disconnect/scene-return flow

### Before
Three handlers (`_on_back_pressed`, `_on_no_pressed`, `_on_yes_pressed`) repeated online client disconnect checks and delayed return-to-menu transitions.

### Problem
- High duplication increases regression risk when changing leave logic.
- Small behavior tweaks require touching multiple branches.

### Change
- Added `_disconnect_online_client_if_needed()`.
- Added `_return_to_main_menu_with_loading(delay_seconds)`.
- Replaced repeated blocks in all three handlers with helper calls.

### Impacted files
- `assets/scripts/jigsaw_puzzle_1.gd`

### Validation
- Manual:
  1. Enter puzzle offline, use Back flow with each popup path (Yes/No), verify return to menu.
  2. Enter puzzle online as client, leave via Back and verify disconnect + menu transition.
  3. Confirm loading screen still appears before scene change.
- Automated/light checks:
  - GDScript parse via Godot CLI (if available) for modified scripts.

### Risks / assumptions
- Assumes helper call ordering is equivalent to old control flow.
- Assumes `loading` node is valid for all three entry points (same as previous code).

---

## Step 2 (implemented): Make puzzle selection index mapping robust

### Before
`button_pressed` derived selection by parsing the last character of button names (`grid0`, `grid1`, ...).

### Problem
- Fragile coupling to scene-node naming conventions.
- UI rename/reorder can silently select wrong puzzle/size.

### Change
- Resolve selected row/column from actual grid child index (`grid.get_children().find(button)`) and `grid.columns`.
- Map size from selected column, preserving intended design (three columns => 10/100/500).

### Impacted files
- `assets/scripts/select_puzzle.gd`

### Validation
- Manual:
  1. Open Select Puzzle, click each column in first row and verify size label shows 10/100/500 respectively.
  2. Navigate pages and repeat; verify selected thumbnail and size remain correct.
- Automated/light checks:
  - GDScript parse via Godot CLI (if available).

### Risks / assumptions
- Assumes grid keeps one row per puzzle and columns map to size options.
- If grid column count changes from 3 in the future, size mapping should be revisited.
