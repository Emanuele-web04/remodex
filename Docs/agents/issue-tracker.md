# Issue tracker: GitHub (fork)

Issues and PRDs for multi-agent and fork work live on **kartikkabadi/remodex**, not upstream Emanuele-web04/remodex.

Use the `gh` CLI for all operations. **Always pass `--repo kartikkabadi/remodex`** so issues land on the fork.

## Conventions

- **Create an issue**: `gh issue create --repo kartikkabadi/remodex --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --repo kartikkabadi/remodex --comments`
- **List issues**: `gh issue list --repo kartikkabadi/remodex --state open`
- **Comment on an issue**: `gh issue comment <number> --repo kartikkabadi/remodex --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --repo kartikkabadi/remodex --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --repo kartikkabadi/remodex --comment "..."`

## When a skill says "publish to the issue tracker"

Create a GitHub issue on **kartikkabadi/remodex**.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --repo kartikkabadi/remodex --comments`.

## Live queue (2026-05-25)

Confirm labels on GitHub before starting; this table is the operating default.

| Track | Issues | Agent rule |
|-------|--------|------------|
| **Delegable code** | [#39](https://github.com/kartikkabadi/remodex/issues/39) → [#40](https://github.com/kartikkabadi/remodex/issues/40) → [#41](https://github.com/kartikkabadi/remodex/issues/41) → [#42](https://github.com/kartikkabadi/remodex/issues/42) | Default start **#39** unless Kartik assigns another |
| **Device-gated** | [#24](https://github.com/kartikkabadi/remodex/issues/24), [#27](https://github.com/kartikkabadi/remodex/issues/27), [#28](https://github.com/kartikkabadi/remodex/issues/28), [#43](https://github.com/kartikkabadi/remodex/issues/43), [#29](https://github.com/kartikkabadi/remodex/issues/29) | Do **not** close without Kartik physical iPhone/iPad smoke |
| **Closed (do not reopen)** | [#18](https://github.com/kartikkabadi/remodex/issues/18), [#17](https://github.com/kartikkabadi/remodex/issues/17), [#31](https://github.com/kartikkabadi/remodex/issues/31)–[#37](https://github.com/kartikkabadi/remodex/issues/37) | Reopen only if fresh code contradicts closure with proof |

Program index and slice detail: [Docs/plans/multi-agent-runtime.md](../plans/multi-agent-runtime.md). Parent epic: [#16](https://github.com/kartikkabadi/remodex/issues/16).
