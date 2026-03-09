# AGENTS.md (Local-First)

Keep this file and `CLAUDE.md` aligned.

This repo is local-first now. Do not reintroduce hosted-service assumptions, remote deployment runbooks, or hardcoded production domains.

## Core guardrails

- Prefer local Mac runtime, local bridge, QR pairing, and daemon workflows.
- Keep repo isolation by thread/project metadata and local `cwd`.
- Do not reintroduce filtering by selected repo in sidebar/content.
- Keep cross-repo open/create flow with automatic local context switch.
- Preserve single responsibility: shared logic belongs in services/coordinators, not duplicated in views.
- Treat this repo as open source: avoid junk code, placeholder hacks, noisy one-off workarounds, and low-signal docs.
- If you touch docs, keep them local-only and remove stale hosted-service notes instead of adding compatibility layers.

## iOS runtime + timeline guardrails

- `turn/started` may not include a usable `turnId`: keep the per-thread running fallback.
- If Stop is tapped and `activeTurnIdByThread` is missing, resolve via `thread/read` before interrupting.
- On reconnect/background recover, rehydrate active turn state so Stop remains visible.
- Suppress benign background disconnect noise (`NWError.posix(.ECONNABORTED)`) and retry on foreground.
- Keep assistant rows item-scoped to avoid timeline flattening/reordering.
- Merge late reasoning deltas into existing rows; do not spawn fake extra "Thinking..." rows.
- Ignore late turn-less activity events when the turn is already inactive.
- Preserve item-aware history reconciliation instead of falling back to `turnId`-only matching.

## Local connection guardrails

- Prefer saved relay pairing and local connection state as the source of truth.
- Avoid hardcoded remote domains; default to local values or explicit user config.
- Keep pairing/auth UX stable: do not clear saved relay info too early during reconnect flows.
- Preserve reconnect behavior across relaunch when the local host session is still valid.

## Build guardrails

- Do not run Xcode builds/tests unless the user explicitly asks.
- Markdown files inside Xcode-synced groups can still produce harmless warnings.
- For small iOS/mobile fixes, prefer inspection and targeted edits over simulator runs by default.

## Local quick runbook

```bash
cd phodex-bridge
npm start
```
