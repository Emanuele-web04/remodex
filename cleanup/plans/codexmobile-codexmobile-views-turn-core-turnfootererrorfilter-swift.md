# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Core/TurnFooterErrorFilter.swift`
> ID: CLN-268 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 54
> Last updated: 2026-05-11 23:07

## Why This File Is Tracked
- Extracted from `TurnView.swift` during CLN-166 to isolate pure footer error visibility rules.
- Keeps transient reconnect/background/cancellation noise out of the turn screen body.

## Current Assessment
- Pure string filtering helper with no SwiftUI state and no service dependencies.
- Preserves existing message normalization and suppression rules.

## Required End State
- Keep footer-specific filtering here.
- Do not expand this into general error handling or service retry policy.

## Ordered Cleanup Tasks
1. [x] Move footer error-noise filtering out of `TurnView.swift`.
2. [x] Preserve existing reconnect, background retry, unmaterialized thread, and cancellation filters.
3. [x] Confirm static scan shows the new helper call site and no old local helper definitions.

## Validation Gate
- Static inspection only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:07: Created during CLN-166 extraction and marked complete.
