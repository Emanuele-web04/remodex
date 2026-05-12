# Cleanup Plan: `CodexMobile/CodexMobile/Views/Sidebar/SidebarThreadListState.swift`
> ID: CLN-242 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Sidebar UI | Current LOC: 171
> Last updated: 2026-05-11 20:34

## Why This File Is Tracked
- Created during the repo-wide cleanup pass while decomposing a larger SwiftUI file.
- Owns pure sidebar project preview, hierarchy, and expansion state helpers used by SidebarThreadListView and tests.

## Current Assessment
- Focused file with one clear responsibility and acceptable size.

## Required End State
- Keep pure sidebar state algorithms here instead of mixing them into SwiftUI rendering.
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
