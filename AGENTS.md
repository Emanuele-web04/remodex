# AGENTS.md (Local-First)

Keep this file and `CLAUDE.md` aligned.

## Agent bootstrap

Before picking work, read [Docs/agents/README.md](Docs/agents/README.md). Issue queue: [Docs/agents/issue-tracker.md](Docs/agents/issue-tracker.md). Domain: [Docs/agents/domain.md](Docs/agents/domain.md).

This repo is local-first now. Do not reintroduce hosted-service assumptions, remote deployment runbooks, or hardcoded production domains.

## Core guardrails

- Prefer local Mac runtime, local bridge, QR pairing, and daemon workflows.
- Be an intraprendente agent: proactively inspect local code, protocol/schema, and official sources to confirm facts before replying; do not repeatedly stop to ask for confirmation when the next verification step is safe and obvious.
- Keep repo isolation by thread/project metadata and local `cwd`.
- Do not reintroduce filtering by selected repo in sidebar/content.
- Keep cross-repo open/create flow with automatic local context switch.
- Preserve single responsibility: shared logic belongs in services/coordinators, not duplicated in views.
- Treat this repo as open source: avoid junk code, placeholder hacks, noisy one-off workarounds, and low-signal docs.
- If you touch docs, keep them local-only and remove stale hosted-service notes instead of adding compatibility layers.
- Do not create one-off report markdown files in the repo root (security reports, audit notes, scratch summaries, etc.) unless the user explicitly asks for a file. Keep ad-hoc analysis in the chat.
- For open-source/self-hosted safety, do not log live relay `sessionId` values or other bearer-like pairing identifiers in server logs; redact or hash them instead.
- Keep user-facing answers compact by default unless the user explicitly asks for more detail.

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
- Preserve the QR/local-relay pairing path: do not regress the scanner -> saved pairing -> connect flow by letting onboarding/auto-reconnect race manual scan control.
- For local relay recovery, keep resumed desktop-thread live mirroring and rollout fallback logic intact so reopened/running threads still recover state even when the rollout file is older than the recent-candidate window.

## Build guardrails

- After Swift/iOS changes, run **`xcodebuild` compile** for the affected scheme (`CodexMobile`, `RemodexPad` when present) unless the task is docs-only.
- Do not run full XCTest/UI suites or simulator pairing E2E unless the task explicitly requires it.
- Markdown files inside Xcode-synced groups can still produce harmless warnings.

## Multi-agent runtime program

When working on OpenCode, Cursor, canonical events, or `agentRuntime`, read **[Docs/plans/multi-agent-runtime.md](Docs/plans/multi-agent-runtime.md)** after [Docs/agents/README.md](Docs/agents/README.md). Work tickets live as GitHub issues on **kartikkabadi/remodex** — see [Docs/agents/issue-tracker.md](Docs/agents/issue-tracker.md). Do not merge upstream `modelProvider` router branches wholesale.

## Agent skills

### Issue tracker

GitHub issues on fork **kartikkabadi/remodex** (always `--repo kartikkabadi/remodex`). See [Docs/agents/issue-tracker.md](Docs/agents/issue-tracker.md).

### Triage labels

Canonical roles mapped in [Docs/agents/triage-labels.md](Docs/agents/triage-labels.md).

### Domain docs

Single-context: [CONTEXT.md](CONTEXT.md) + [Docs/adr/](Docs/adr/). See [Docs/agents/domain.md](Docs/agents/domain.md).

## Local quick runbook

```bash
./run-local-remodex.sh
```

For bridge-only dev without the launcher script: `cd phodex-bridge && npm start` (does not start local relay for device pairing).
