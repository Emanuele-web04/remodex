# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/SelectableMessageTextSheet.swift`
> ID: CLN-257 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 62
> Last updated: 2026-05-11 22:55

## Why This File Is Tracked
- Extracted from `TurnMessageComponents.swift` during CLN-155 to keep selectable text presentation out of the scrolling message row file.

## Current Assessment
- Focused SwiftUI sheet with one state value and one presentation view.
- No cleanup action currently required.

## Required End State
- Stay focused on selectable message text presentation only.

## Ordered Cleanup Tasks
- [x] Extract from the message row file without behavior changes.
- [x] Confirm call-site references are still singular and expected.

## Validation Gate
- Static reference scan only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 22:55: Created during CLN-155 extraction and marked complete.
