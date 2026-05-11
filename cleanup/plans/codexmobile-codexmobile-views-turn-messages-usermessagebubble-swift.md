# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/UserMessageBubble.swift`
> ID: CLN-261 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 247
> Last updated: 2026-05-11 22:55

## Why This File Is Tracked
- Extracted from `TurnMessageComponents.swift` during CLN-155 to isolate user prompt bubble rendering, attachment preview state, mention highlighting, and retry/copy actions.

## Current Assessment
- Focused SwiftUI component with cohesive user-message responsibilities.
- No cleanup action currently required.

## Required End State
- Keep user-bubble-specific state and formatting here, so `MessageRow` does not re-accumulate user prompt rendering details.

## Ordered Cleanup Tasks
- [x] Extract user bubble rendering and state from the message row file.
- [x] Confirm reference scan shows the new component call site and no leftover duplicate helpers in `TurnMessageComponents.swift`.

## Validation Gate
- Static reference scan only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 22:55: Created during CLN-155 extraction and marked complete.
