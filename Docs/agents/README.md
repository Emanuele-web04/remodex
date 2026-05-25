# Agent bootstrap (Remodex)

Read this before picking work. Rules live in [AGENTS.md](../../AGENTS.md). Issue queue: [issue-tracker.md](issue-tracker.md). Domain vocabulary: [domain.md](domain.md).

## Canonical surface

| What | Path | Branch |
|------|------|--------|
| **All multi-agent work** | `/Users/user/Documents/projects/remodex-build` | `feat/multi-agent-runtime` |
| **GitHub fork** | https://github.com/kartikkabadi/remodex | same branch for PRs |
| **Upstream** | https://github.com/Emanuele-web04/remodex | `origin/main` for sync reference only |

## Do not use

| Path | Why |
|------|-----|
| `/Users/user/Documents/projects/remodex` | Stale snapshot on `main` — Codex-only code, no runtime registry/adapters |

## Read order

1. [AGENTS.md](../../AGENTS.md) — guardrails and build policy
2. [CONTEXT.md](../../CONTEXT.md) — glossary
3. [Docs/plans/multi-agent-runtime.md](../plans/multi-agent-runtime.md) — program index
4. [issue-tracker.md](issue-tracker.md) — pick one issue; then `gh issue view <n> --repo kartikkabadi/remodex`

Parent epic: [#16](https://github.com/kartikkabadi/remodex/issues/16)

## Verify before claiming done

```bash
cd phodex-bridge && npm test   # expect 448 pass
cd ../relay && npm test        # expect 39 pass
```

After Swift changes: `xcodebuild` per AGENTS.md.

## Last verified

2026-05-25 — `phodex-bridge` 448/448 pass; `relay` 39/39 pass. Not verified this pass: `xcodebuild`, physical iPhone/iPad smoke.

## Session rules

- One GitHub issue per agent session unless Kartik assigns a bundle.
- Preserve dirty work. Do not `git reset --hard`, `git clean`, or delete worktrees without Kartik's explicit OK.
- Fork-first on this branch; upstream PR prep ([#29](https://github.com/kartikkabadi/remodex/issues/29)) stays blocked until Kartik device proof on #24–#28 / #43.

## Fork vs upstream positioning

This fork adds OpenCode + Cursor on top of Emanuele's Codex remote-control stack. Official Codex-in-ChatGPT mobile is Codex-only; this lane still targets multi-runtime control, self-hosted relay, and optional Telegram (separate branch).
