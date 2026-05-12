# Cleanup Plan: `CodexMobile/CodexMobile/Views/Turn/Diff/TurnFileChangeBlockPresentation.swift`
> ID: CLN-262 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: Turn UI | Current LOC: 435
> Last updated: 2026-05-11 23:01

## Why This File Is Tracked
- Extracted from `TurnMessageCaches.swift` during CLN-154 to isolate assistant turn file-change block aggregation and caching.

## Current Assessment
- Cohesive support file for building and caching file-change accessory summaries.
- No cleanup action currently required.

## Required End State
- Keep block-level file-change aggregation here; avoid moving generic message-row cache logic into this file.

## Ordered Cleanup Tasks
- [x] Extract block presentation model, builder, raw diff section parser, and cache.
- [x] Confirm reference scan shows expected call sites from timeline projection/accessories.

## Validation Gate
- Static reference scan only; Xcode build/tests intentionally deferred per user request.

## Progress Notes
- 2026-05-11 23:01: Created during CLN-154 extraction and marked complete.
