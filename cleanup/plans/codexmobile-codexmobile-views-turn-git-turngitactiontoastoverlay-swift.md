# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Git/TurnGitActionToastOverlay.swift`
> ID: CLN-266 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 108
> Last updated: 2026-05-11 23:07

## Why This File Is Tracked
- Extracted from `TurnView.swift` during CLN-166 to isolate git action toast presentation and formatting.
- Keeps success/progress banner layout out of the main turn screen orchestration path.

## Current Assessment
- Focused SwiftUI component with explicit success/progress inputs and a single dismiss callback.
- Preserves existing subtitle trimming, PR action, progress phase lines, transitions, and banner styling.

## Required End State
- Keep git toast formatting here unless it becomes shared outside the turn screen.
- Do not add git service orchestration or side effects beyond the existing PR URL open action.

## Ordered Cleanup Tasks
1. [x] Move git progress/success toast rendering and helper formatting out of `TurnView.swift`.
2. [x] Preserve existing toast content, transitions, dismiss behavior, and PR trailing action.
3. [x] Confirm static scan shows no leftover duplicate toast helpers in `TurnView.swift`.

## Validation Gate
- Static inspection only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:07: Created during CLN-166 extraction and marked complete.
