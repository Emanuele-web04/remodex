# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/UserAttachmentViews.swift`
> ID: CLN-238 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 98
> Last updated: 2026-05-11 20:22

## Why This File Is Tracked
- Created during CLN-155 to extract user attachment rendering out of `TurnMessageComponents.swift`.
- Owns thumbnail rendering, thumbnail cache lookup, strip layout, and preview image resolution for user attachments.

## Current Assessment
- Focused component file with one responsibility and low complexity.
- Thumbnail decode is cached by attachment id plus stable thumbnail fingerprint to reduce repeated work during timeline scrolling.

## Required End State
- Keep attachment-specific rendering and image resolution here instead of moving it back into `TurnMessageComponents.swift`.
- Reopen only if this file grows past 300 LOC or starts owning unrelated message row behavior.

## Ordered Cleanup Tasks
1. Reviewed after extraction.
2. No further action required in this pass.

## Validation Gate
- Code-only pass for now: inspect call sites and syntax locally.
- Xcode build/tests intentionally deferred per user request.

## Tracker Update Rule
- Keep this plan and `cleanup/TASK-TRACKER.md` aligned if attachment rendering changes.

## Progress Notes
- 2026-05-11 20:22: Extracted from `TurnMessageComponents.swift` and marked reviewed/no-action.
