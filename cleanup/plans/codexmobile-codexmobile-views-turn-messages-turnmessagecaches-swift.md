# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMessageCaches.swift`
> ID: CLN-154 | Priority: P1 | Effort: M | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 337
> Last updated: 2026-05-11 23:01

## Why This File Is Tracked
- Included in the full Swift/Xcode cleanup scope requested by the user.
- Metrics: 1029 LOC, 62 methods/body entries, 165 stored/computed properties estimate, CC estimate 327, max indentation 8.
- Responsibilities: SwiftUI rendering, turn timeline/composer flow.

## Current Assessment
- This file exceeds cleanup thresholds or sits near a performance-sensitive path.
- Coupling/import count estimate: 1.

## Required End State
- Reduce file complexity toward <500 LOC where practical, keep responsibilities focused, and make high-frequency UI/service paths cheaper to reason about.
- Preserve local-first behavior and existing public APIs unless a file plan explicitly records a migration.

## Ordered Cleanup Tasks
1. Confirm existing tests or characterization coverage before behavior-sensitive changes.
2. Extract stable, meaningful subviews or row/projection helpers instead of adding computed view fragments.
3. Update imports and call sites while preserving public behavior.
4. Record final metrics and validation evidence after the refactor.

## Validation Gate
- Code-only pass for now: inspect call sites and syntax locally.
- Xcode build/tests intentionally deferred per user request.

## Tracker Update Rule
- Before work starts, mark this file IN_PROGRESS in `cleanup/TASK-TRACKER.md`.
- After every material step, update this file plan and the central tracker.
- When complete, record final metrics and validation evidence in both places.

## Progress Notes
- 2026-05-11 20:20: Initial plan created from full Swift metrics scan.

- 2026-05-11 21:05: Marked IN_PROGRESS; extracted `TurnMessageCacheCore.swift` and changed `BoundedCache` recency tracking so cache hits no longer scan an access-order array.
- 2026-05-11 23:01: Extracted file-change block aggregation/cache to `TurnFileChangeBlockPresentation.swift` and per-file diff parsing/cache to `TurnPerFileDiffParser.swift`; `TurnMessageCaches.swift` is now below 500 LOC and focused on row render models and lightweight caches. Static reference scan confirmed expected call sites; Xcode build/tests intentionally not run per user request.
