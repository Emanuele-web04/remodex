# Cleanup Plan: `CodexMobile/CodexMobile/Views/Sidebar/SidebarProjectShowMoreButton.swift`
> ID: CLN-248 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Sidebar UI | Current LOC: 31
> Last updated: 2026-05-11 20:38

## Why This File Is Tracked
- Created while decomposing `SidebarThreadListView.swift` during the repo-wide SwiftUI cleanup pass.
- Owns the project-section show-more button and its local chevron animation state.

## Current Assessment
- Focused component with one responsibility and isolated state.

## Required End State
- Keep show-more button UI and animation state here instead of sharing it across the parent list view.
- Reopen if unrelated sidebar row behavior starts accumulating here.

## Ordered Cleanup Tasks
1. Reviewed after extraction.
2. No further action required in this pass.

## Validation Gate
- Code-only pass for now: inspect call sites and syntax locally.
- Xcode build/tests intentionally deferred per user request.

## Tracker Update Rule
- Keep this plan and `cleanup/TASK-TRACKER.md` aligned if this component changes.

## Progress Notes
- 2026-05-11 20:38: Extracted and marked reviewed/no-action.
