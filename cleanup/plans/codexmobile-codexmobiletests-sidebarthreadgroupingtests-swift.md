# Cleanup Plan: `CodexMobile/CodexMobileTests/SidebarThreadGroupingTests.swift`
> ID: CLN-207 | Priority: P2 | Effort: S | Status: planned | File type: test
> Domain: Tests | Current LOC: 465
> Last updated: 2026-05-11 20:20

## Why This File Is Tracked
- Included in the full Swift/Xcode cleanup scope requested by the user.
- Metrics: 465 LOC, 26 methods/body entries, 79 stored/computed properties estimate, CC estimate 51, max indentation 4.
- Responsibilities: test coverage, sidebar navigation.

## Current Assessment
- This file exceeds cleanup thresholds or sits near a performance-sensitive path.
- Coupling/import count estimate: 1.

## Required End State
- Reduce file complexity toward <500 LOC where practical, keep responsibilities focused, and make high-frequency UI/service paths cheaper to reason about.
- Preserve local-first behavior and existing public APIs unless a file plan explicitly records a migration.

## Ordered Cleanup Tasks
1. Confirm existing tests or characterization coverage before behavior-sensitive changes.
2. Extract cohesive helper types/functions for repeated or high-branch logic.
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
