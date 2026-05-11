# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/ThinkingSystemBlock.swift`
> ID: CLN-258 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 266
> Last updated: 2026-05-11 22:55

## Why This File Is Tracked
- Extracted from `TurnMessageComponents.swift` during CLN-155 to isolate reasoning disclosure UI from generic message-row branching.

## Current Assessment
- Cohesive SwiftUI component for compact reasoning rows, disclosure state, and focused previews.
- No cleanup action currently required.

## Required End State
- Keep reasoning-specific presentation local here and avoid pushing disclosure state back into `MessageRow`.

## Ordered Cleanup Tasks
- [x] Extract reasoning row and disclosure view from the message row file.
- [x] Keep previews colocated with the extracted component.
- [x] Confirm reference scan shows one definition and expected use from `MessageRow`.

## Validation Gate
- Static reference scan only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 22:55: Created during CLN-155 extraction and marked complete.
