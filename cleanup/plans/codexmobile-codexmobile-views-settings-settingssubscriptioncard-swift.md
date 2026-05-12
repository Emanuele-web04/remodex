# Cleanup Plan: `CodexMobile/CodexMobile/Views/Settings/SettingsSubscriptionCard.swift`
> ID: CLN-247 | Priority: P3 | Effort: S | Status: done | File type: frontend
> Domain: SwiftUI | Current LOC: 62
> Last updated: 2026-05-11 20:38

## Why This File Is Tracked
- Created while decomposing `SettingsView.swift` during the repo-wide SwiftUI cleanup pass.
- Owns Remodex Pro status, paywall, offer-code redemption, and restore actions.

## Current Assessment
- Focused component file with acceptable size.

## Required End State
- Keep subscription-specific UI and StoreKit/RevenueCat presentation here.
- Reopen if unrelated settings logic starts accumulating here.

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
