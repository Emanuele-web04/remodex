# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMessageCacheCore.swift`
> ID: CLN-255 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 177
> Last updated: 2026-05-11 21:05

## Why This File Is Tracked
- Extracted from a larger cleanup target during the SwiftUI performance/refactor pass.

## Current Assessment
- Focused component/support file with a single responsibility.

## Required End State
- Keep focused and avoid backsliding into a mixed-responsibility file.

## Validation Gate
- Code-only pass for now: `git diff --check` passed after extraction.
- Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 21:05: Extracted cache core; recency update no longer scans on every hit.
