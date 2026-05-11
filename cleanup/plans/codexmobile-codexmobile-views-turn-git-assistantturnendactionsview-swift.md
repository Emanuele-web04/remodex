# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Git/AssistantTurnEndActionsView.swift`
> ID: CLN-264 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 152
> Last updated: 2026-05-11 23:04

## Why This File Is Tracked
- Extracted from `TurnMessageComponents.swift` during CLN-155 to isolate assistant block-end Diff/Revert/Commit controls.
- Owns the block diff sheet presentation state so `MessageRow` no longer carries that row accessory state directly.

## Current Assessment
- Focused SwiftUI component with explicit inputs and no broad timeline dependencies.
- Keeps behavior parity with the previous inline `MessageRow` button cluster.

## Required End State
- Keep this file focused on block-end actions only.
- Do not move assistant text/rendering concerns into this component.

## Ordered Cleanup Tasks
1. [x] Extract button cluster and local diff sheet state from `TurnMessageComponents.swift`.
2. [x] Preserve existing button labels, haptics, disabled states, diff sheet payloads, and revert target selection.
3. [x] Confirm static reference scan shows a single component call site from `MessageRow`.

## Validation Gate
- Static inspection only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:04: Created during CLN-155 extraction and marked complete.
