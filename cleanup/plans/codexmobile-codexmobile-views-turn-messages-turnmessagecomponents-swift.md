# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMessageComponents.swift`
> ID: CLN-155 | Priority: P0 | Effort: L | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 428
> Last updated: 2026-05-11 23:07

## Why This File Is Tracked
- Included in the full Swift/Xcode cleanup scope requested by the user.
- Metrics: 2595 LOC, 88 methods/body entries, 314 stored/computed properties estimate, CC estimate 522, max indentation 11.
- Responsibilities: SwiftUI rendering, turn timeline/composer flow.

## Current Assessment
- This file exceeds cleanup thresholds or sits near a performance-sensitive path.
- Coupling/import count estimate: 4.

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
- 2026-05-11 20:31: Extracted markdown parser/rendering/formatter logic into `TurnMarkdownTextRendering.swift` and workspace image preview/cache/downsampling logic into `WorkspaceImagePreview.swift`; removed now-unused Textual/UIKit/ImageIO imports from this file.
- 2026-05-11 20:24: Removed unused `ShimmerMask` after repository-wide call-site search found no usages.
- 2026-05-11 20:23: Extracted `CodeCommentFindingCard` into its own focused row-component file.
- 2026-05-11 20:22: Extracted user attachment thumbnail strip and preview resolver into `UserAttachmentViews.swift`; added a small thumbnail image cache to avoid repeated Base64 decode during timeline redraws.
- 2026-05-11 20:20: Started thumbnail decode/cache refactor for timeline scrolling.
- 2026-05-11 20:20: Initial plan created from full Swift metrics scan.

- 2026-05-11 21:05: Extracted assistant image preview button to `WorkspaceImagePreview.swift`, file-change summary views to `TurnFileChangeSummaryViews.swift`, and user bubble collapse state to `UserBubbleTextBlock.swift`; hoisted streaming placeholder set out of the hot display-text path.
- 2026-05-11 22:55: Extracted selectable text sheet, thinking disclosure row, command execution status card, typing/approval/diff accessory views, and turn-end visibility helper into focused files. Static reference scan found single definitions and expected call sites; Xcode build/tests intentionally not run per user request.
- 2026-05-11 22:55: Extracted user prompt bubble rendering, attachment preview state, delivery status, and mention highlighting into `UserMessageBubble.swift`; `MessageRow` now focuses on role dispatch plus assistant/system rendering.
- 2026-05-11 23:04: Extracted assistant block-end Diff/Revert/Commit controls into `AssistantTurnEndActionsView.swift`; static scans confirmed the moved sheet/action state has a single definition and expected call site.
- 2026-05-11 23:07: Extracted system row rendering into `SystemMessageContentView.swift`, reducing `TurnMessageComponents.swift` below 500 LOC. Static scans confirmed no leftover duplicate system helper definitions; build/tests deferred by request.
