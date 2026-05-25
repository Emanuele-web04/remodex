# Domain Docs

How engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root
- **`Docs/adr/`** — read ADRs that touch the area you're about to work in (especially agent runtime and canonical events)
- **`Docs/plans/multi-agent-runtime.md`** — program index; slice tables link to GitHub issues

This is a single-context repo. There is no `CONTEXT-MAP.md`.

## When you hold issue #N

1. Read the matching slice row in `Docs/plans/multi-agent-runtime.md`
2. Run `gh issue view <N> --repo kartikkabadi/remodex --comments` for acceptance criteria
3. Read ADR 002/003 when the issue touches canonical events, OpenCode, or Cursor

## File structure

```
/
├── CONTEXT.md
├── Docs/adr/
│   ├── 002-agent-runtime-and-canonical-events.md
│   └── 003-cursor-agent-runtime.md
├── Docs/plans/
│   └── multi-agent-runtime.md
└── Docs/agents/          ← bootstrap + queue (start at README.md)
```

## Use the glossary's vocabulary

When your output names a domain concept, use the term as defined in `CONTEXT.md`. Key terms: **Agent Runtime**, **OpenCode Agent**, **Agent Session**, **Environment** (not "runtime" for repo context).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding.
