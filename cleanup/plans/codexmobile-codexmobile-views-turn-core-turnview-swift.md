# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Core/TurnView.swift`
> ID: CLN-166 | Priority: P0 | Effort: L | Status: in_progress | File type: frontend
> Domain: Turn UI | Current LOC: 1667
> Last updated: 2026-05-11 23:07

## Why This File Is Tracked
- Included in the full Swift/Xcode cleanup scope requested by the user.
- Metrics: 1881 LOC, 53 methods/body entries, 107 stored/computed properties estimate, CC estimate 397, max indentation 8.
- Responsibilities: SwiftUI rendering, turn timeline/composer flow.

## Current Assessment
- This file exceeds cleanup thresholds or sits near a performance-sensitive path.
- Coupling/import count estimate: 3.

## Required End State
- Reduce file complexity toward <500 LOC where practical, keep responsibilities focused, and make high-frequency UI/service paths cheaper to reason about.
- Preserve local-first behavior and existing public APIs unless a file plan explicitly records a migration.

## Ordered Cleanup Tasks
1. Confirm existing tests or characterization coverage before behavior-sensitive changes.
2. Extract stable, meaningful subviews or row/projection helpers instead of adding computed view fragments.
3. Update imports and call sites while preserving public behavior.
4. Record final metrics and validation evidence after the refactor.

## Validation Gate
- Code-only pass for now: inspect call sites and syntax locally.
- Xcode build/tests intentionally deferred per user request.

## Tracker Update Rule
- Before work starts, mark this file IN_PROGRESS in `cleanup/TASK-TRACKER.md`.
- After every material step, update this file plan and the central tracker.
- When complete, record final metrics and validation evidence in both places.

## Progress Notes
- 2026-05-11 20:20: Initial plan created from full Swift metrics scan.

- 2026-05-11 21:12: Marked IN_PROGRESS; extracted support overlays/sheets/value types into `TurnViewSupportViews.swift` so `TurnView` stays focused on orchestration.
- 2026-05-11 23:07: Extracted git action progress/success toast rendering into `TurnGitActionToastOverlay.swift`; static scan confirmed old toast helper definitions were removed from `TurnView.swift`.
- 2026-05-11 23:07: Extracted voice button/recovery presentation mapping into `TurnVoicePresentationBuilders.swift`; static scan confirmed `TurnView` now only routes voice state and actions.
- 2026-05-11 23:07: Extracted footer error-noise filtering into `TurnFooterErrorFilter.swift`; static scan confirmed the old local filter helpers were removed.
