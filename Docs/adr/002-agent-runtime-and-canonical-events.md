# ADR 002: Agent runtime routing and canonical bridge events

**Status:** Accepted (planning)  
**Date:** 2026-05-22  
**Deciders:** Remodex fork (`kartikkabadi/remodex`)

## Context

Remodex today assumes a single Codex app-server transport. Upstream PR #141 added Claude via `modelProvider` on threads, which conflates **LLM vendor** with **agent runtime** and risks mixed-runtime thread lists.

We want OpenCode as the first second agent while keeping Codex as the default. iOS V1 needs plan mode, streaming, stop, permissions, tool rows, session diff parity, and OpenCode custom-agent selection — but Telegram stays Codex-only for OpenCode V1.

## Decision

1. **Thread identity carries `agentRuntime`** (`codex` | `opencode`) and **`agentSessionId`** (runtime-native session id). Do not overload relay `sessionId`, `modelProvider`, or Codex `thread.id` for OpenCode routing.
2. **Bridge owns an `agent-runtime-registry`** that dispatches RPC and notifications per thread runtime. Codex and OpenCode transports are **peers**; OpenCode process failure must not tear down Codex.
3. **Canonical wire vocabulary:** outbound/inbound timeline events use `remodex/event/*` (and `plan.*` for plan mode). Bridge adapters translate Codex JSON-RPC notifications and OpenCode HTTP+SSE into canonical envelopes before iOS sees them.
4. **OpenCode V1 connectivity:** bridge **spawns** secured loopback `opencode serve` only (no `REMODEX_OPENCODE_URL` connect-only). Credentials stay on Mac (`~/.local/share/opencode/auth.json`); iOS receives sanitized `opencodeStatus` only. Never proxy `PUT /auth`.
5. **OpenCode internal agents are distinct from Remodex Agent Runtime.** Remodex stores chosen OpenCode agents as `opencodeBuildAgentName` for normal build/chat turns and `opencodePlanAgentName` for plan-mode turns, then passes the matching value to OpenCode `POST /session` / `prompt_async` as `agent`; it never reuses `agentRuntime`, `agentId`, or `modelProvider` for this.
6. **iOS cutover:** production timeline ingestion goes through **`RemodexEventAdapter` → existing reducers and plan-mode state**. Raw `codex/event/*` and legacy method aliases are supported only in adapter unit tests (ported from `CodexPlanModeTests` and incoming tests), not in production handlers.
7. **Telegram:** remains on raw Codex path until a deliberate follow-up; OpenCode is out of Telegram V1 scope per ADR 001.

## Consequences

### Positive

- Clear seam for future runtimes (`codex-server/`, `opencode-server/` packages later).
- iOS timeline code stops growing runtime `if` branches in `CodexService+Incoming*`.
- Maintainer alignment: explicit runtime field vs PR #141 `modelProvider` router.
- OpenCode power users can choose custom agents without making every custom agent look like a separate Remodex runtime.

### Negative / trade-offs

- Bridge must maintain two adapters and a canonical schema table.
- Big-bang adapter matrix is front-loaded test work before iOS deletes legacy ingress paths.
- OpenCode plan/question shapes may differ from Codex; adapters own normalization.
- UI vocabulary must distinguish Remodex Agent Runtime from OpenCode's internal agent/persona layer.

## Alternatives considered

| Alternative | Why rejected |
|-------------|--------------|
| Extend PR #141 `modelProvider` router | Couples vendor/model with runtime; wrong list/badge semantics |
| Treat each OpenCode custom agent as a Remodex runtime | Explodes the runtime list and confuses transport identity with OpenCode persona/config |
| iOS talks to OpenCode directly | Breaks E2EE relay trust boundary and Mac-only credentials |
| Connect-only to user-run OpenCode in V1 | Support burden; spawn-only keeps one security model |
| Dual thread lists per runtime | Violates single-list + badge UX decision |

## References

- Handoff: `remodex-opencode-handoff-2026-05-22.md`
- Master plan: [Docs/plans/multi-agent-runtime.md](../plans/multi-agent-runtime.md)
- Parent PRD issue: https://github.com/kartikkabadi/remodex/issues/16
- Implementation blueprint: [Docs/plans/multi-agent-runtime-implementation.md](../plans/multi-agent-runtime-implementation.md)
- OpenCode server API: https://opencode.ai/docs/server
- Upstream context: Emanuele-web04/remodex PR #141 (compatibility only)
