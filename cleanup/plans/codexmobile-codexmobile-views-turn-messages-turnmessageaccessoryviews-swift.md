# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMessageAccessoryViews.swift`
> ID: CLN-260 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 115
> Last updated: 2026-05-11 22:55

## Why This File Is Tracked
- Extracted from `TurnMessageComponents.swift` during CLN-155 to collect small shared message-row accessory views and visibility policy.

## Current Assessment
- Cohesive shared UI/policy file for diff counts, typing indicator, approval banner, and assistant turn-end action visibility.
- No cleanup action currently required.

## Required End State
- Remain a small shared accessory surface; avoid growing it into unrelated message rendering logic.

## Ordered Cleanup Tasks
- [x] Extract small accessory views and turn-end visibility helper.
- [x] Confirm reference scan shows one definition per symbol and expected existing callers.

## Validation Gate
- Static reference scan only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 22:55: Created during CLN-155 extraction and marked complete.
