# Multi-agent runtime — index

**Status:** Active (verified 2026-05-25)  
**Branch:** `feat/multi-agent-runtime` on [kartikkabadi/remodex](https://github.com/kartikkabadi/remodex) from `origin/main`  
**Parent issue:** https://github.com/kartikkabadi/remodex/issues/16  
**Implementation blueprint:** [multi-agent-runtime-implementation.md](multi-agent-runtime-implementation.md)
**Domain language:** [CONTEXT.md](../../CONTEXT.md)  
**Architecture:** [ADR 002](../adr/002-agent-runtime-and-canonical-events.md), [ADR 003](../adr/003-cursor-agent-runtime.md)  
**Agent bootstrap:** [Docs/agents/README.md](../agents/README.md) · **Agent config:** [Docs/agents/](../agents/)

Execution detail lives in **GitHub issues on the fork** (not local `.scratch/`).

---

## Current Reality (verified 2026-05-25)

**Canonical local surface:** `/Users/user/Documents/projects/remodex-build` on
`feat/multi-agent-runtime`. Treat `/Users/user/Documents/projects/remodex` as a
historical/stale snapshot for this lane unless Kartik explicitly asks to inspect
it. Session bootstrap: [Docs/agents/README.md](../agents/README.md).

**Live tracker state:** Parent epic #16 is open. #17 is closed via PR #30.
#18 is closed as completed after 2026-05-25 reconciliation and bridge/relay
test proof. Foundational follow-ups #19-#29 remain open/gated, and the static
model-catalog pass #31-#37 is closed/superseded by dynamic provider/model issues
#38-#43.

**Verification run 2026-05-25:**
- `cd phodex-bridge && npm test` -> 448 pass, 0 fail.
- `cd relay && npm test` -> 39 pass, 0 fail.
- Not run in this audit: `xcodebuild`, physical iPhone smoke, physical iPad
  smoke.

**Immediate operating note:** the registry blocker has been reconciled and #18
is closed. The next delegable track is dynamic provider/model discovery in order:
#39 -> #40 -> #41 -> #42, with #43 kept human/device-gated until physical iPad
proof exists. Do not unblock upstream PR prep #29 without fresh iPhone/iPad
runtime proof.

## Brownfield gaps (still accurate)

Foundation is in place (#18 closed). Remaining work is tracked on GitHub #19–#29 (canonical cutover, E2E) and #39–#43 (dynamic models). See [Docs/agents/issue-tracker.md](../agents/issue-tracker.md) for the live queue.

Do not merge upstream `modelProvider` router branches wholesale. Mine patterns; implement ADR shape.

---

## Goal

Remodex hosts multiple **agent runtimes** on the Mac (Codex, OpenCode, Cursor; Grok later). Each thread picks one runtime at creation. The bridge translates all runtimes into **one Remodex event vocabulary**; iOS uses **one** timeline pipeline.

Do not merge upstream `modelProvider` router branches wholesale. Mine patterns; implement ADR shape.

---

## Locked decisions (2026-05-23 grill)

| Topic | Decision |
|-------|----------|
| Routing | `agentRuntime` + `agentSessionId` — not `modelProvider` |
| Wire to phone | `remodex/event/*`, `plan.*`, permission RPC only in production |
| OpenCode | Spawn-only `opencode serve` on loopback |
| Cursor PR2 | **Core only** — hide queue, steer, photos on Cursor threads |
| PR1 Stretch | Hide controls if fixture tests fail; Core must work |
| OpenCode handoff | `desktop/continueOnOpenCode` via `opencode attach` |
| iOS cutover | Big-bang canonical in PR1 (bridge 03 + iOS 06 together) |
| Delivery | Three stacked upstream PRs: PR1 OpenCode → PR2 Cursor → PR3 iPad |
| QA | PR1/PR2 = iPhone (`CodexMobile`); PR3 = iPad (`RemodexPad`) |
| Telegram / Grok | Out of multi-agent V1 |
| Merge gate | `#17` CI must run real bridge + relay tests before merging `#18+` |
| Initialize contract | Warm reconnect returns full runtime payload, not `{ bridgeManaged: true }` only |
| iOS naming | **Agent Runtime** (transport) vs existing **Codex model runtime** types stay separate |
| Thread sync | Bridge `thread-agent-state.json` is source of truth; `thread/list` projects agent fields |
| Runtime models | Provider/model identity belongs to runtime-owned model discovery, not a static app catalog |

---

## Upstream PR map

| PR | Scope | Device QA |
|----|--------|-----------|
| **PR1 — OpenCode** | Registry, canonical, OpenCode path, iOS UX + cutover, iPhone E2E | Kartik iPhone |
| **PR2 — Cursor** | Cursor ACP + adapter, iPhone E2E (Core only) | Kartik iPhone |
| **PR3 — iPad** | RemodexPad cherry-pick, re-smoke 07 + 07b | Kartik iPad |

---

## Issue index (fork)

| Slice | GitHub issue |
|-------|----------------|
| **Epic** | [#16](https://github.com/kartikkabadi/remodex/issues/16) |
| Wave 0 — hygiene | [#17](https://github.com/kartikkabadi/remodex/issues/17) |
| 01 — bridge registry | [#18](https://github.com/kartikkabadi/remodex/issues/18) |
| 03 — canonical + Codex adapter | [#19](https://github.com/kartikkabadi/remodex/issues/19) |
| 02 — OpenCode spawn | [#20](https://github.com/kartikkabadi/remodex/issues/20) |
| 04 — OpenCode adapter | [#22](https://github.com/kartikkabadi/remodex/issues/22) |
| 05 — iOS agent UX | [#21](https://github.com/kartikkabadi/remodex/issues/21) |
| 06 — iOS RemodexEventAdapter | [#23](https://github.com/kartikkabadi/remodex/issues/23) |
| 07 — OpenCode E2E iPhone | [#24](https://github.com/kartikkabadi/remodex/issues/24) |
| 10 — Cursor ACP | [#25](https://github.com/kartikkabadi/remodex/issues/25) |
| 11 — Cursor canonical | [#26](https://github.com/kartikkabadi/remodex/issues/26) |
| 07b — Cursor E2E iPhone | [#27](https://github.com/kartikkabadi/remodex/issues/27) |
| 12 — RemodexPad | [#28](https://github.com/kartikkabadi/remodex/issues/28) |
| 09 — upstream PR prep | [#29](https://github.com/kartikkabadi/remodex/issues/29) |

## Runtime model discovery addendum (2026-05-25)

Physical iPad smoke proved the first runtime-scoped model catalog pass was a useful tracer bullet but not the final product shape. OpenCode cannot be represented by two hardcoded model entries. Remodex must discover provider/model choices from the user's actual OpenCode setup, keep provider identity separate from model identity, and keep iPad turn state stable through OpenCode response gaps.

The superseded model-catalog issues are #31-#37. Replacement plan:

| Slice | GitHub issue |
|-------|----------------|
| Dynamic provider/model PRD | [#38](https://github.com/kartikkabadi/remodex/issues/38) |
| Runtime Model Discovery contract | [#39](https://github.com/kartikkabadi/remodex/issues/39) |
| OpenCode dynamic discovery + dispatch | [#40](https://github.com/kartikkabadi/remodex/issues/40) |
| Native provider/model picker | [#41](https://github.com/kartikkabadi/remodex/issues/41) |
| OpenCode Running Turn lifecycle stability | [#42](https://github.com/kartikkabadi/remodex/issues/42) |
| Physical iPad dynamic model smoke | [#43](https://github.com/kartikkabadi/remodex/issues/43) |

### Open issue reality (2026-05-25, for agents)

| Issue | Code reality | Blocker |
|-------|--------------|---------|
| #19, #23 | Partial — canonical layer exists; Codex paths still emit raw `codex/event/*` in places | Big-bang cutover not finished |
| #20, #22 | Partial — OpenCode spawn + adapter landed; dynamic models not wired | #39–#42 track |
| #21 | Partial — runtime pill + gating in iOS | E2E proof |
| #24, #27 | Not proven E2E | Kartik iPhone smoke |
| #25, #26 | Partial — Cursor ACP + adapter in bridge | E2E proof |
| #28, #43 | Not proven on iPad | Kartik iPad smoke |
| #29 | Not started for upstream PR | #24–#28 proof |
| #39–#42 | Not started / early | Delegable code track after #18 |
| #38 | PRD only | Parent for #39–#43 |

---

## Verification (agents)

- `cd phodex-bridge && npm test`
- `cd relay && npm test` (CI when added)
- `./run-local-remodex.sh` Mac smoke
- `xcodebuild` compile after iOS changes
- Kartik: physical iPhone (PR1/PR2) and iPad (PR3) smoke

Not required for agent "done": simulator QR E2E, full XCTest suite every commit.
