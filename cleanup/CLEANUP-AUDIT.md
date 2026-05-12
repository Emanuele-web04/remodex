# Codebase Audit Report
> Generated: 2026-05-11 20:38 | Project: Remodex | Scope: Swift/Xcode files | Total source files: 248 | Total LOC: 84239

## Executive Summary

**Overall health**: C - The app is well-modularized by feature folders, but several service extensions and SwiftUI timeline files remain high-coupling hotspots.

**Critical findings**: 12 P0 hotspots, 45 files over 500 LOC, 5 high-complexity files.

**Top 3 priorities**:
1. Split message normalization and timeline mutation logic out of `CodexMobile/CodexMobile/Services/CodexService+Messages.swift`.
2. Continue shrinking turn timeline rendering by extracting row-specific components/data shaping from `TurnTimelineView.swift` and `TurnView.swift`.
3. Reduce repeated connection/recovery branching across CodexService incoming, history, and threads/turns extensions.

## Project Orientation

- **Stack**: Swift, SwiftUI, Observation/Combine-style app state, Xcode project, Node.js local bridge outside this Swift cleanup scope.
- **Architecture**: Local-first iOS app with service extensions, SwiftUI views, domain models, and unit/UI tests under the Xcode project.
- **Test runner**: Xcode test schemes exist, but tests were not run because the user explicitly requested no build/test execution.
- **Linter**: No dedicated Swift linter config found during orientation.
- **Build**: Xcode project at `CodexMobile/CodexMobile.xcodeproj`; not invoked in this pass.

## God Objects & Bloated Files

| # | File | LOC | Methods | Fields | Max CC Estimate | Deps | Responsibilities | Severity |
|---|------|-----|---------|--------|-----------------|------|------------------|----------|
| 1 | `CodexMobile/CodexMobile/Services/CodexService+Messages.swift` | 4449 | 167 | 439 | 1497 | 2 | service orchestration | P0 |
| 2 | `CodexMobile/CodexMobileTests/TurnTimelineReducerTests.swift` | 3647 | 109 | 308 | 309 | 2 | SwiftUI rendering, test coverage, turn timeline/composer flow | P0 |
| 3 | `CodexMobile/CodexMobile/Services/CodexService+Incoming.swift` | 2815 | 104 | 284 | 1404 | 1 | service orchestration | P0 |
| 4 | `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMessageComponents.swift` | 2431 | 83 | 291 | 497 | 4 | SwiftUI rendering, turn timeline/composer flow | P0 |
| 5 | `CodexMobile/CodexMobile/Views/Turn/Core/TurnViewModel.swift` | 2405 | 134 | 323 | 693 | 3 | SwiftUI rendering, domain/value modeling, turn timeline/composer flow | P0 |
| 6 | `CodexMobile/CodexMobile/Services/CodexService+ThreadsTurns.swift` | 2314 | 107 | 212 | 825 | 1 | service orchestration, turn timeline/composer flow | P0 |
| 7 | `CodexMobile/CodexMobile/Services/CodexService+History.swift` | 2272 | 88 | 278 | 800 | 2 | service orchestration | P0 |
| 8 | `CodexMobile/CodexMobileTests/CodexServiceIncomingCommandExecutionTests.swift` | 1995 | 55 | 339 | 153 | 1 | service orchestration, test coverage | P0 |
| 9 | `CodexMobile/CodexMobileTests/CodexServiceIncomingRunIndicatorTests.swift` | 1976 | 93 | 342 | 306 | 2 | service orchestration, test coverage | P0 |
| 10 | `CodexMobile/CodexMobile/Views/Turn/Core/TurnView.swift` | 1881 | 53 | 107 | 397 | 3 | SwiftUI rendering, turn timeline/composer flow | P0 |
| 11 | `CodexMobile/CodexMobileTests/CodexPlanModeTests.swift` | 1579 | 55 | 157 | 336 | 1 | test coverage | P0 |
| 12 | `CodexMobile/CodexMobile/Views/Turn/Timeline/TurnTimelineView.swift` | 1554 | 48 | 210 | 344 | 2 | SwiftUI rendering, turn timeline/composer flow | P0 |
| 13 | `CodexMobile/CodexMobile/ContentView.swift` | 1259 | 53 | 69 | 307 | 2 | SwiftUI rendering | P1 |
| 14 | `CodexMobile/CodexMobile/Views/Settings/SettingsView.swift` | 1117 | 26 | 66 | 146 | 3 | SwiftUI rendering | P1 |
| 15 | `CodexMobile/CodexMobile/Services/CodexService+Account.swift` | 1073 | 57 | 94 | 361 | 1 | service orchestration | P1 |
| 16 | `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMessageCaches.swift` | 1029 | 62 | 165 | 327 | 1 | SwiftUI rendering, turn timeline/composer flow | P1 |
| 17 | `CodexMobile/CodexMobile/Services/CodexService+Connection.swift` | 980 | 54 | 72 | 403 | 3 | service orchestration | P1 |
| 18 | `CodexMobile/CodexMobile/Services/CodexService+SecureTransport.swift` | 900 | 35 | 91 | 246 | 3 | service orchestration | P1 |
| 19 | `CodexMobile/CodexMobile/Views/Turn/Plan/TurnPlanModeComponents.swift` | 857 | 33 | 122 | 208 | 1 | SwiftUI rendering, turn timeline/composer flow | P1 |
| 20 | `CodexMobile/CodexMobile/Services/CodexService+Sync.swift` | 851 | 47 | 85 | 284 | 2 | service orchestration | P1 |

## Completed Cleanup Changes

- Extracted user attachment thumbnail rendering and preview resolution from `TurnMessageComponents.swift` into `UserAttachmentViews.swift`.
- Added a small in-memory thumbnail cache keyed by attachment id plus stable thumbnail fingerprint to avoid repeated Base64 decode during row redraws.
- Extracted `CodeCommentFindingCard` into its own focused SwiftUI component file.
- Removed unused `ShimmerMask` after repository-wide call-site search found no usages.
- Extracted markdown rendering/formatting into `TurnMarkdownTextRendering.swift`.
- Extracted workspace image preview/cache/downsampling into `WorkspaceImagePreview.swift`.
- Extracted sidebar preview/hierarchy/expansion state into `SidebarThreadListState.swift`.
- Extracted sidebar project show-more button state into `SidebarProjectShowMoreButton.swift`.
- Extracted settings support/about/trusted-computer components into `SettingsSupportCards.swift`.
- Extracted settings runtime defaults into `SettingsRuntimeDefaultsCard.swift`.
- Extracted settings connection controls into `SettingsConnectionCard.swift`.
- Extracted settings shared primitives into `SettingsBaseComponents.swift`.
- Extracted subscription UI into `SettingsSubscriptionCard.swift`.
- Extracted selectable text sheet, thinking disclosure rows, command execution status card, and small message accessory views from `TurnMessageComponents.swift`.
- Extracted user prompt bubble rendering and mention highlighting from `TurnMessageComponents.swift` into `UserMessageBubble.swift`.
- Extracted assistant block-end Diff/Revert/Commit controls into `AssistantTurnEndActionsView.swift`.
- Extracted system row rendering from `TurnMessageComponents.swift` into `SystemMessageContentView.swift`, reducing `TurnMessageComponents.swift` below 500 LOC.
- Extracted bounded-cache primitives plus file-change block/diff parsing out of `TurnMessageCaches.swift`, reducing it below the cleanup threshold.
- Extracted git action progress/success toast rendering from `TurnView.swift` into `TurnGitActionToastOverlay.swift`.
- Extracted voice button/recovery presentation mapping from `TurnView.swift` into `TurnVoicePresentationBuilders.swift`.
- Extracted footer error-noise filtering from `TurnView.swift` into `TurnFooterErrorFilter.swift`.
- Extracted timeline cache-key hashing and placeholder chrome from `TurnTimelineView.swift`; moved bottom geometry mapping into scroll support.
- Cached `AppEnvironment` feedback timestamp formatting to avoid repeated formatter construction.
- Reorganized Turn Swift files into focused subfolders (`Core`, `Timeline`, `Messages`, `Composer`, `Plan`, `Git`, `Diff`, `Voice`, `Support`) and moved Settings components under `Views/Settings`.

## Complexity Hotspots

| File | LOC | Methods | CC Estimate | Nesting | Issue |
|------|-----|---------|-------------|---------|-------|
| `CodexMobile/CodexMobile/Services/CodexService+Messages.swift` | 4449 | 167 | 1497 | 9 | Large file; high branch density; deep nesting; needs focused split |
| `CodexMobile/CodexMobileTests/TurnTimelineReducerTests.swift` | 3647 | 109 | 309 | 4 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Services/CodexService+Incoming.swift` | 2815 | 104 | 1404 | 7 | Large file; high branch density; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMessageComponents.swift` | 2431 | 83 | 497 | 11 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Core/TurnViewModel.swift` | 2405 | 134 | 693 | 8 | Large file; high branch density; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/Services/CodexService+ThreadsTurns.swift` | 2314 | 107 | 825 | 8 | Large file; high branch density; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/Services/CodexService+History.swift` | 2272 | 88 | 800 | 7 | Large file; high branch density; needs focused split |
| `CodexMobile/CodexMobileTests/CodexServiceIncomingCommandExecutionTests.swift` | 1995 | 55 | 153 | 10 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobileTests/CodexServiceIncomingRunIndicatorTests.swift` | 1976 | 93 | 306 | 10 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Core/TurnView.swift` | 1881 | 53 | 397 | 8 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobileTests/CodexPlanModeTests.swift` | 1579 | 55 | 336 | 10 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Timeline/TurnTimelineView.swift` | 1554 | 48 | 344 | 8 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/ContentView.swift` | 1259 | 53 | 307 | 7 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Views/Settings/SettingsView.swift` | 1117 | 26 | 146 | 9 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/Services/CodexService+Account.swift` | 1073 | 57 | 361 | 5 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMessageCaches.swift` | 1029 | 62 | 327 | 8 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/Services/CodexService+Connection.swift` | 980 | 54 | 403 | 6 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Services/CodexService+SecureTransport.swift` | 900 | 35 | 246 | 6 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Plan/TurnPlanModeComponents.swift` | 857 | 33 | 208 | 8 | Large file; deep nesting; needs focused split |
| `CodexMobile/CodexMobile/Services/CodexService+Sync.swift` | 851 | 47 | 284 | 7 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Services/CodexService.swift` | 844 | 7 | 219 | 5 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Timeline/TurnTimelineReducer.swift` | 838 | 43 | 279 | 6 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Messages/TurnMermaidRenderer.swift` | 836 | 40 | 166 | 6 | Large file; needs focused split |
| `CodexMobile/CodexMobile/Views/Turn/Core/TurnViewModel+GitBranchWorktree.swift` | 817 | 30 | 218 | 7 | Large file; needs focused split |
| `CodexMobile/CodexMobileTests/TurnViewModelQueueTests.swift` | 817 | 33 | 155 | 9 | Large file; deep nesting; needs focused split |

## Anti-Pattern Findings

### P0 - Blocks maintainability; fix first

1. `CodexService+Messages.swift`: message mutation, grouping, projection, persistence, and transport reconciliation are co-located. Extract focused collaborators before adding behavior.
2. `CodexService+Incoming.swift`: incoming event dispatch has high branch density and should delegate per event family.
3. `TurnTimelineView.swift`: still owns timeline layout orchestration, scroll state wiring, and presentation triggers; continue extracting focused subviews/coordinators where safe.
4. `TurnView.swift`: screen orchestration, sheet state, toolbar state, and lifecycle wiring are still large enough to make focused performance changes risky.

### P1 - Significant technical debt

- Large service extensions over 500 LOC should be split along persisted-state, network, and UI-projection boundaries.
- Large SwiftUI view files should prefer dedicated subview files for reusable/independently meaningful sections.
- Tests contain several very large files; keep them as characterization safety nets, then split by behavior area when implementation stabilizes.

### P2 - Moderate issues; schedule for cleanup

- Files in the 300-500 LOC range are acceptable only when cohesion is high; many Turn UI files should be watched for row/rendering drift.
- Repeated state labels, button styling, and status presentation patterns can move into shared components when there are 3+ genuine conceptual duplicates.

### P3 - Minor; fix opportunistically

- Add small navigation comments only in touched files; avoid broad comment churn.
- Remove unused imports only when local inspection confirms they are unused.

## DRY Violations

| Code Block Description | Locations | Lines Duplicated |
|------------------------|-----------|------------------|
| Status/action row styling and button chrome | Turn composer, toolbar, plan/status components | Needs targeted pass |
| Thread/turn recovery predicates | CodexService incoming, history, threads/turns extensions | Needs targeted pass |
| Sidebar/thread metadata formatting | Sidebar row/list/header helpers | Needs targeted pass |

## Dependency Issues

- Circular dependencies found: not fully resolved by static regex scan; no direct Swift import cycles surfaced because files share module scope.
- Most-depended-on files by module role: `CodexService.swift`, `CodexMessage.swift`, `CodexThread.swift`, turn timeline models.
- Tightly coupled pairs: CodexService extensions with TurnViewModel/Turn UI projection via shared mutable service state.

## Metrics Summary

| Metric | Current | Target | Status |
|--------|---------|--------|--------|
| Max file LOC | 4449 | <500 | Needs work |
| Avg file LOC | 352 | <300 | Needs work |
| Files >500 LOC | 45 | 0 | Needs work |
| Files >300 LOC | 77 | Review individually | Needs work |
| P0 hotspots | 12 | 0 | Needs work |
| Circular deps | Unknown direct Swift cycles | 0 | Needs deeper compiler-aware check |
| DRY violations | 3 candidate families | 0 verified 3+ duplicates | Needs targeted validation |
| Dead code blocks | Not fully enumerated | 0 | Needs per-file plan execution |
