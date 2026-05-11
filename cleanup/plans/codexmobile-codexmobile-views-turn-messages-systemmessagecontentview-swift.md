# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/SystemMessageContentView.swift`
> ID: CLN-265 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 222
> Last updated: 2026-05-11 23:07

## Why This File Is Tracked
- Extracted from `TurnMessageComponents.swift` during CLN-155 to isolate thinking/tool/file-change/command/subagent/plan system row rendering.
- Keeps system-row context menus and structured cards out of generic message role dispatch.

## Current Assessment
- Focused SwiftUI component with explicit row inputs and a sheet-selection callback.
- Preserves existing rendering paths for thinking blocks, command status cards, file-change summaries, plan cards, and structured user input prompts.

## Required End State
- Keep system-message rendering here; keep assistant prose and user bubble behavior in their dedicated components.
- Avoid adding broad timeline state to this file.

## Ordered Cleanup Tasks
1. [x] Move system row branch and helpers out of `TurnMessageComponents.swift`.
2. [x] Preserve existing context menu copy/select actions and streaming typing indicators.
3. [x] Confirm static scan shows the expected `SystemMessageContentView` call site and no leftover moved helper definitions.

## Validation Gate
- Static inspection only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:07: Created during CLN-155 extraction and marked complete.
