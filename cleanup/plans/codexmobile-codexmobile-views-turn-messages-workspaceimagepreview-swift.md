# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/WorkspaceImagePreview.swift`
> ID: CLN-241 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 272
> Last updated: 2026-05-11 20:31

## Why This File Is Tracked
- Created during CLN-155 while decomposing `TurnMessageComponents.swift`.
- Owns fullscreen assistant workspace image preview, preview loading, downsampling, and image cache coordination.

## Current Assessment
- Focused component/service file with one clear responsibility.
- Current size is acceptable for the extracted subsystem.

## Required End State
- Keep workspace image preview loading/cache/downsampling separate from message row rendering.
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
