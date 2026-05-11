# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Timeline/TurnTimelineCacheKeys.swift`
> ID: CLN-269 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 65
> Last updated: 2026-05-11 23:07

## Why This File Is Tracked
- Extracted from `TurnTimelineView.swift` during CLN-164 to isolate timeline render and block accessory cache signatures.
- Keeps hashing rules near the cache model instead of inside the scroll coordinator.

## Current Assessment
- Pure helper with no SwiftUI state or side effects.
- Preserves the streaming-text optimization that hashes live row text by length and finalized rows by full text.

## Required End State
- Keep only timeline cache key/signature construction here.
- Do not add rendering, scrolling, or service orchestration.

## Ordered Cleanup Tasks
1. [x] Move render item cache signature construction out of `TurnTimelineView.swift`.
2. [x] Move block accessory input-key hashing out of `TurnTimelineView.swift`.
3. [x] Preserve live streaming text hash behavior.

## Validation Gate
- Static inspection only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:07: Created during CLN-164 extraction and marked complete.
