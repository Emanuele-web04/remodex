# Cleanup Plan: `CodexMobile/CodexMobile/Views/Settings/SettingsSupportCards.swift`
> ID: CLN-243 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: SwiftUI | Current LOC: 262
> Last updated: 2026-05-11 20:34

## Why This File Is Tracked
- Created during the repo-wide cleanup pass while decomposing a larger SwiftUI file.
- Owns About/support rows plus trusted-computer display and rename sheet for Settings.

## Current Assessment
- Focused file with one clear responsibility and acceptable size.

## Required End State
- Keep support/connection presentation here instead of growing SettingsView.
- Reopen if unrelated view or service logic starts accumulating here.

## Ordered Cleanup Tasks
1. Reviewed after extraction.
2. No further action required in this pass.

## Validation Gate
- Code-only pass for now: inspect call sites and syntax locally.
- Xcode build/tests intentionally deferred per user request.

## Tracker Update Rule
- Keep this plan and `cleanup/TASK-TRACKER.md` aligned if this subsystem changes.

## Progress Notes
- 2026-05-11 20:34: Extracted and marked reviewed/no-action.
