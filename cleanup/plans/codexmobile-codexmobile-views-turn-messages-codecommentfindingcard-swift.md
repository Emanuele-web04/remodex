# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/CodeCommentFindingCard.swift`
> ID: CLN-239 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 84
> Last updated: 2026-05-11 20:23

## Why This File Is Tracked
- Created during CLN-155 to extract the code-comment directive finding card out of `TurnMessageComponents.swift`.
- Owns one self-contained assistant-message card for parsed code review directives.

## Current Assessment
- Focused component file with one rendering responsibility and local derived labels/colors.
- No further split is needed at the current size.

## Required End State
- Keep code-comment directive presentation here unless it becomes part of a larger review UI module.
- Reopen if this file grows past 300 LOC or starts owning parser/business logic.

## Ordered Cleanup Tasks
1. Reviewed after extraction.
2. No further action required in this pass.

## Validation Gate
- Code-only pass for now: inspect call sites and syntax locally.
- Xcode build/tests intentionally deferred per user request.

## Tracker Update Rule
- Keep this plan and `cleanup/TASK-TRACKER.md` aligned if this component changes.

## Progress Notes
- 2026-05-11 20:23: Extracted from `TurnMessageComponents.swift` and marked reviewed/no-action.
