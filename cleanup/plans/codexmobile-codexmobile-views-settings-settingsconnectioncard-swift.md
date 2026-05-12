# Cleanup Plan: `CodexMobile/CodexMobile/Views/Settings/SettingsConnectionCard.swift`
> ID: CLN-245 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: SwiftUI | Current LOC: 134
> Last updated: 2026-05-11 20:36

## Why This File Is Tracked
- Created while decomposing `SettingsView.swift` during the repo-wide SwiftUI cleanup pass.
- Owns connection status, keep-awake preference, disconnect/forget actions, and computer rename sheet presentation.

## Current Assessment
- Focused settings component with one responsibility and acceptable size.

## Required End State
- Keep connection-specific settings orchestration here.
- Reopen if unrelated settings sections start accumulating here.

## Ordered Cleanup Tasks
1. Reviewed after extraction.
2. No further action required in this pass.

## Validation Gate
- Code-only pass for now: inspect call sites and syntax locally.
- Xcode build/tests intentionally deferred per user request.

## Tracker Update Rule
- Keep this plan and `cleanup/TASK-TRACKER.md` aligned if this component changes.

## Progress Notes
- 2026-05-11 20:36: Extracted and marked reviewed/no-action.
