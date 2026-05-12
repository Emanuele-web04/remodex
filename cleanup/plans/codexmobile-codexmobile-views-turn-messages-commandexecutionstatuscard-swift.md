# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/CommandExecutionStatusCard.swift`
> ID: CLN-259 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 201
> Last updated: 2026-05-11 22:55

## Why This File Is Tracked
- Extracted from `TurnMessageComponents.swift` during CLN-155 to isolate command execution preview loading and detail-sheet state.

## Current Assessment
- Focused component owns command detail presentation, workspace image preview loading, and stale-image hiding.
- No cleanup action currently required.

## Required End State
- Keep command execution row preview behavior isolated from generic message-row rendering.

## Ordered Cleanup Tasks
- [x] Extract command status card without changing call sites.
- [x] Keep command preview loading state owned by the extracted component.
- [x] Confirm reference scan shows one definition and expected use from `MessageRow`.

## Validation Gate
- Static reference scan only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 22:55: Created during CLN-155 extraction and marked complete.
