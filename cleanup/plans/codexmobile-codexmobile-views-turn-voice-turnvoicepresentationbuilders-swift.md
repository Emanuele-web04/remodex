# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Voice/TurnVoicePresentationBuilders.swift`
> ID: CLN-267 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 184
> Last updated: 2026-05-11 23:07

## Why This File Is Tracked
- Extracted from `TurnView.swift` during CLN-166 to isolate pure voice UI presentation mapping.
- Keeps microphone button states and voice recovery copy outside the main turn screen orchestration file.

## Current Assessment
- Pure mapping helpers with no async work, service calls, or mutable state.
- Preserves existing voice button colors/labels/progress flags and recovery guidance copy/actions.

## Required End State
- Keep only voice UI presentation mapping here.
- Leave recording, transcription, connection, and action routing in `TurnView`/services.

## Ordered Cleanup Tasks
1. [x] Move microphone button presentation mapping out of `TurnView.swift`.
2. [x] Move voice recovery snapshot/action mapping out of `TurnView.swift`.
3. [x] Confirm static scan shows `TurnView` uses the builders and no old recovery builder remains.

## Validation Gate
- Static inspection only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:07: Created during CLN-166 extraction and marked complete.
