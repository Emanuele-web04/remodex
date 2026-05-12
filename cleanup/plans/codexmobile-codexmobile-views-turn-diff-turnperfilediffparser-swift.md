# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Diff/TurnPerFileDiffParser.swift`
> ID: CLN-263 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 294
> Last updated: 2026-05-11 23:01

## Why This File Is Tracked
- Extracted from `TurnMessageCaches.swift` during CLN-154 to isolate per-file diff chunk parsing, path identity, and cache behavior.

## Current Assessment
- Focused parser/cache file with existing characterization coverage in `TurnMessageCachesTests.swift`.
- No cleanup action currently required.

## Required End State
- Keep per-file diff parsing and path-identity behavior local here, with tests remaining the safety net for future changes.

## Ordered Cleanup Tasks
- [x] Extract per-file diff chunk model, path identity, parser, and cache.
- [x] Confirm reference scan shows expected call sites from diff sheet and tests.

## Validation Gate
- Static reference scan only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:01: Created during CLN-154 extraction and marked complete.
