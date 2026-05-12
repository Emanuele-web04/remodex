# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Core/TurnViewSupportViews.swift`
> ID: CLN-256 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 154
> Last updated: 2026-05-11 21:12

## Why This File Is Tracked
- Extracted from `TurnView.swift` during the SwiftUI turn-screen cleanup pass.

## Current Assessment
- Focused support file for small overlays, sheets, alerts, and voice recovery value types.

## Required End State
- Keep presentational support out of the main turn orchestration view.

## Validation Gate
- Code-only pass for now: `git diff --check` passed after extraction.
- Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 21:12: Extracted support overlays/sheets/value types from `TurnView.swift`.
