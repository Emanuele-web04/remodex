# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMarkdownTextRendering.swift`
> ID: CLN-240 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 448
> Last updated: 2026-05-11 20:31

## Why This File Is Tracked
- Created during CLN-155 while decomposing `TurnMessageComponents.swift`.
- Owns markdown parsing, bounded markdown cache reset, streaming markdown chunking, and file-reference linkification.

## Current Assessment
- Focused component/service file with one clear responsibility.
- Current size is acceptable for the extracted subsystem.

## Required End State
- Keep markdown parsing/rendering and text formatting here instead of mixing it back into message row UI.
- Reopen if unrelated message-row responsibilities start accumulating here.

## Ordered Cleanup Tasks
1. Reviewed after extraction.
2. No further action required in this pass.

## Validation Gate
- Code-only pass for now: inspect call sites and syntax locally.
- Xcode build/tests intentionally deferred per user request.

## Tracker Update Rule
- Keep this plan and `cleanup/TASK-TRACKER.md` aligned if this subsystem changes.

## Progress Notes
- 2026-05-11 20:31: Extracted from `TurnMessageComponents.swift` and marked reviewed/no-action.
