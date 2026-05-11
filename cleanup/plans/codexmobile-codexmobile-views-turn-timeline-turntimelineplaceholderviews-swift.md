# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Timeline/TurnTimelinePlaceholderViews.swift`
> ID: CLN-270 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 45
> Last updated: 2026-05-11 23:07

## Why This File Is Tracked
- Extracted from `TurnTimelineView.swift` during CLN-164 to isolate timeline loading and running-empty placeholder chrome.
- Keeps static placeholder UI out of scroll coordination logic.

## Current Assessment
- Focused SwiftUI placeholder components with no local state.
- Preserves the existing loading/running copy, typography, and background behavior.

## Required End State
- Keep this file limited to timeline placeholder views.
- Avoid adding timeline scroll state or message rendering here.

## Ordered Cleanup Tasks
1. [x] Extract running empty state chrome from `TurnTimelineView.swift`.
2. [x] Extract full timeline loading overlay from `TurnTimelineView.swift`.
3. [x] Preserve existing layout and copy.

## Validation Gate
- Static inspection only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:07: Created during CLN-164 extraction and marked complete.
