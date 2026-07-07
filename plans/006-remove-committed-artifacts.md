# Plan 006: Remove accidentally-committed Electron bundles and scratch artifacts, and fix the .gitignore globs that missed them

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 6f27902..HEAD -- .gitignore`
> and `git status --porcelain` to confirm a clean tree before you start.
> If the tree is dirty or `.gitignore` changed, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `6f27902`, 2026-07-07

## Why this matters

Several files that don't belong in this repo were swept into unrelated commits:

- **5.5 MB of minified Codex Desktop (Electron) bundles** at the repo root —
  `deeplinks-D8FzxbSB.js` (4.8 MB), `main-Bw7nouYH.js` (492 KB), and `preload.js`
  (minified `electron`/`contextBridge`/`ipcRenderer` code). They're unreadable
  third-party build output, referenced by nothing in the repo, and were added in
  commit `76c5c66` ("Persist confirmed file mentions in user messages") — a
  Swift-only feature commit. The `.gitignore` already has a "Minified JS bundles"
  section meant to exclude exactly these, but its globs (`/main.js`, `/links-*.js`)
  don't match the hash-suffixed filenames, so they slipped through and can recur.
- **`tmp-vps-live/`** — copies of a live VPS relay deployment
  (`relay.live.mjs`, `server.live.mjs`, `relay.android-candidate.mjs`), added in
  the unrelated commit `e2cb8aa`. These contradict the repo's stated local-first,
  no-hosted-artifacts guardrail, and they're a **live security liability**: they
  log raw session IDs and lack the rate-limiting the maintained `relay/` code has.
  Removing the directory resolves those two findings; the hardened source of truth
  is `relay/`.
- **`cleanup/`** — a 272-file audit artifact (a dated report plus 270 per-file
  plan stubs) from a prior refactor session (commit `3f865d2` "Huge refactor").

The bundles and `tmp-vps-live/` are unambiguously safe to remove. `cleanup/`
needs a quick check for still-open tracked work before deletion (see Step 4).

## Current state

- Root artifacts (confirm with `ls -la`):
  - `deeplinks-D8FzxbSB.js`, `main-Bw7nouYH.js`, `preload.js`
- `tmp-vps-live/` contains: `relay.live.mjs`, `server.live.mjs`,
  `relay.android-candidate.mjs`.
- `cleanup/` contains: `CLEANUP-AUDIT.md`, `TASK-TRACKER.md`, `plans/` (270 `.md`
  stub files).
- No tracked file references any of these (verified at plan time —
  `grep -rln` for the bundle names and `preload.js`/`tmp-vps-live` across
  `*.js/*.json/*.md/*.sh/*.yml` returns only the artifact files themselves; the
  bundles only reference each other).
- `.gitignore` — the ineffective bundle section is at **lines 35-40**:
  ```
  # Minified JS bundles (not part of this project)
  /main.js
  /links-*.js
  /scheme-*.js
  /initial-route-atom-*.js
  /use-navigate-to-local-conversation-*.js
  ```
  None of these globs match `main-Bw7nouYH.js`, `deeplinks-D8FzxbSB.js`, or
  `preload.js`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Confirm no references (bundles) | `grep -rln "main-Bw7nouYH\|deeplinks-D8FzxbSB" --include="*.js" --include="*.json" --include="*.md" --include="*.sh" --include="*.yml" . \| grep -v node_modules` | only the bundle files themselves (or nothing) |
| Confirm no references (tmp-vps-live) | `grep -rln "tmp-vps-live" --include="*.js" --include="*.json" --include="*.md" --include="*.sh" --include="*.yml" . \| grep -v node_modules` | nothing outside `tmp-vps-live/` |
| Verify removal | `git status --porcelain` | shows the deletions + `.gitignore` mod, nothing else |
| Bridge suite unaffected | `cd phodex-bridge && npm test` | all tests pass |
| Relay suite unaffected | `cd relay && npm test` | all tests pass |

## Scope

**In scope**:
- Delete: `deeplinks-D8FzxbSB.js`, `main-Bw7nouYH.js`, `preload.js`
- Delete: `tmp-vps-live/` (entire directory)
- Delete: `cleanup/` (entire directory) — **only after the Step 4 check passes**
- Modify: `.gitignore` (fix the bundle globs)

**Out of scope** (do NOT touch):
- `relay/` — the maintained relay; `tmp-vps-live/` is the disposable copy, not
  the reverse. Do not delete or edit anything under `relay/`.
- `run-local-remodex.sh`, `MacDano.md` — leave them; they're referenced/intentional
  developer docs and out of this plan's scope.
- Any source under `phodex-bridge/src/` or `CodexMobile/`.

## Git workflow

- Branch: `advisor/006-remove-artifacts`
- Use `git rm` (not plain `rm`) so deletions are staged. Suggested one commit;
  short imperative message, e.g. `Remove accidentally-committed Electron bundles and scratch artifacts`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm nothing references the artifacts

Run the two `grep` reference-check commands from the table above.

**Verify**: neither returns a reference from a non-artifact file. If either does,
STOP (see STOP conditions).

### Step 2: Remove the Electron bundles

```
git rm deeplinks-D8FzxbSB.js main-Bw7nouYH.js preload.js
```

**Verify**: `git status --porcelain` shows these three as deleted (`D`).

### Step 3: Fix the `.gitignore` globs so this can't recur

Update the "Minified JS bundles" section (lines 35-40) to match the actual
hash-suffixed naming. Replace the ineffective globs with patterns that catch the
real filenames while staying scoped to the repo root, e.g.:
```
# Minified JS bundles (not part of this project)
/main-*.js
/main.js
/deeplinks-*.js
/links-*.js
/scheme-*.js
/initial-route-atom-*.js
/use-navigate-to-local-conversation-*.js
/preload.js
```
Keep the existing entries too (they're harmless). The key additions are
`/main-*.js`, `/deeplinks-*.js`, and `/preload.js`.

**Verify**: after Step 2's deletion, `printf '%s\n' 'test' > preload.js && git status --porcelain preload.js` shows **no** untracked `preload.js` (it's ignored); then remove the probe file (`rm preload.js`). Do the same probe for a `main-XYZ.js` name if you want extra confidence. (These probe files must NOT be committed.)

### Step 4: Remove `tmp-vps-live/`

```
git rm -r tmp-vps-live
```

**Verify**: `git status --porcelain` shows the three `tmp-vps-live/*.mjs` files as deleted.

### Step 5: Check, then remove `cleanup/`

**Check first** — `cleanup/TASK-TRACKER.md` may list still-open work. Open it and
scan for unchecked/open action items (unchecked `- [ ]` boxes, "TODO"/"open"/"in
progress" status rows).

- If everything in it is done/historical (or it's clearly a stale one-off audit
  with no actionable open items), proceed: `git rm -r cleanup`.
- If it contains **open, actionable** items that aren't tracked elsewhere, do
  **not** delete it. Leave `cleanup/` in place, note this in your report, and mark
  Step 5 skipped — the rest of the plan (bundles, gitignore, tmp-vps-live) still
  stands.

**Verify**: `git status --porcelain` reflects your decision (either `cleanup/`
deleted, or untouched with a note).

### Step 6: Confirm the test suites are unaffected

**Verify**:
- `cd phodex-bridge && npm test` → all pass.
- `cd relay && npm test` → all pass.

(These deletions touch no source the suites import; the run is a safety net.)

## Test plan

No new tests — this is a deletion/config plan. The verification gate is: the
reference checks return nothing, `git status` shows only the intended deletions
plus the `.gitignore` edit, the `.gitignore` probe proves the new globs match, and
both test suites still pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `ls deeplinks-D8FzxbSB.js main-Bw7nouYH.js preload.js 2>/dev/null` → all three gone (non-zero exit / no output)
- [ ] `ls tmp-vps-live 2>/dev/null` → gone
- [ ] `.gitignore` contains `/main-*.js`, `/deeplinks-*.js`, and `/preload.js`
- [ ] A fresh `preload.js` at repo root is ignored by git (probe from Step 3), and the probe file is not committed
- [ ] `cleanup/` is either deleted or explicitly retained-with-reason in your report
- [ ] `cd phodex-bridge && npm test` and `cd relay && npm test` both exit 0
- [ ] `git status` shows only intended deletions + the `.gitignore` change (no stray probe files)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any reference-check `grep` (Step 1) shows a **non-artifact** file importing or
  loading one of these paths — deletion would break something; report the
  reference.
- `git status` at the start is not clean (uncommitted work present) — don't mix
  it with these deletions.
- `cleanup/TASK-TRACKER.md` has open actionable items (handle per Step 5; don't
  delete on your own judgment if unsure).
- A probe file (`preload.js` / `main-*.js`) shows up as **untracked** after adding
  the globs — the glob didn't take effect; report it rather than force-adding an
  ignore.

## Maintenance notes

- The recurrence guard is the `.gitignore` fix — without it, the next time a Codex
  Desktop bundle lands in the working tree it'll get swept into `git add` again.
- `relay.android-candidate.mjs` (inside the deleted `tmp-vps-live/`) was the only
  in-repo evidence of Android intent. If the maintainer wants to keep that signal,
  it belongs in a tracked design doc, not a `tmp-vps-live/` scratch copy — noted
  as the DIRECTION-01 finding, out of scope here.
- Reviewer should confirm `relay/` (the maintained source) is untouched and that
  the security benefit (no raw session-ID logging, rate-limiting present) is fully
  covered by `relay/` rather than the deleted copies.
