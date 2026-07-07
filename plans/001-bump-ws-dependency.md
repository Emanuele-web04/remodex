# Plan 001: Upgrade `ws` to a release that fixes the high-severity DoS advisory

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 6f27902..HEAD -- phodex-bridge/package.json relay/package.json phodex-bridge/package-lock.json relay/package-lock.json`
> If any of these changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `6f27902`, 2026-07-07

## Why this matters

Both the internet-facing relay (`relay/server.js`, `relay/relay.js`) and the Mac
bridge parse untrusted WebSocket frames with `ws@8.19.0`. That version is subject
to **GHSA-96hv-2xvq-fx4p** — "Memory exhaustion DoS from tiny fragments and data
chunks" (CVSS 7.5, high), plus the moderate uninitialized-memory advisory
GHSA-58qx-3vcg-4xpx. On the relay these frames are parsed **before** any
application-level pairing/session check runs, so the DoS is reachable
pre-authentication. `npm audit` confirms the fix is available in `ws@8.21.0`.
This is a one-line dependency bump per package plus a lockfile regen.

## Current state

- `phodex-bridge/package.json:32` — bridge dependency:
  ```json
  "dependencies": {
    "qrcode-terminal": "^0.12.0",
    "ws": "^8.19.0"
  }
  ```
- `relay/package.json:11` — relay dependency:
  ```json
  "dependencies": {
    "ws": "^8.19.0"
  }
  ```
- Both lockfiles currently resolve `ws` to `8.19.0` (`relay/package-lock.json:14`).
- Latest `ws` at plan time is `8.21.0` (`npm view ws version`), which patches both advisories.
- These are the **only two** `package.json` files that depend on `ws`
  (`grep -rl '"ws"' --include=package.json . | grep -v node_modules`).

Convention: this repo commits lockfiles (`package-lock.json` present in both
packages, `lockfileVersion: 3`). CI runs `npm ci` (see
`.github/workflows/bridge-check.yml`), which requires the lockfile to match the
manifest — so the lockfile MUST be regenerated, not hand-edited.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Bump bridge | `cd phodex-bridge && npm install ws@^8.21.0 --ignore-scripts` | exit 0, updates package.json + lock |
| Bump relay | `cd relay && npm install ws@^8.21.0 --ignore-scripts` | exit 0, updates package.json + lock |
| Audit bridge | `cd phodex-bridge && npm audit` | `found 0 vulnerabilities` |
| Audit relay | `cd relay && npm audit` | `found 0 vulnerabilities` |
| Test bridge | `cd phodex-bridge && npm test` | all tests pass |
| Test relay | `cd relay && npm test` | all tests pass |

Note: use `--ignore-scripts` on install (the bridge has a `postinstall` that
bootstraps the Codex CLI — not needed here and it writes outside the repo).

## Scope

**In scope** (the only files you should modify):
- `phodex-bridge/package.json`
- `phodex-bridge/package-lock.json`
- `relay/package.json`
- `relay/package-lock.json`

**Out of scope** (do NOT touch):
- Any `.js` source file — this is a dependency bump only; no code changes.
- The `qrcode-terminal` dependency — leave it as is.

## Git workflow

- Branch: `advisor/001-bump-ws`
- One commit; message style matches repo (short imperative, e.g. commit `6f27902`
  "Bump bridge version to 2.1.9"). Suggested: `Bump ws to 8.21.0 to fix DoS advisory`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Bump `ws` in the bridge package

Run `cd phodex-bridge && npm install ws@^8.21.0 --ignore-scripts`. This rewrites
`phodex-bridge/package.json`'s `ws` entry to `^8.21.0` and updates
`phodex-bridge/package-lock.json`.

**Verify**: `cd phodex-bridge && npm audit` → output contains `found 0 vulnerabilities`.

### Step 2: Bump `ws` in the relay package

Run `cd relay && npm install ws@^8.21.0 --ignore-scripts`.

**Verify**: `cd relay && npm audit` → output contains `found 0 vulnerabilities`.

### Step 3: Confirm both test suites still pass

**Verify**:
- `cd phodex-bridge && npm test` → all tests pass, exit 0.
- `cd relay && npm test` → all tests pass, exit 0.

## Test plan

No new tests. `ws` is an internal transport dependency; the existing bridge and
relay suites exercise the WebSocket paths that use it. The verification gate is
`npm audit` reporting zero vulnerabilities plus both suites green.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep '"ws"' phodex-bridge/package.json` shows `^8.21.0` (or higher)
- [ ] `grep '"ws"' relay/package.json` shows `^8.21.0` (or higher)
- [ ] `cd phodex-bridge && npm audit` → `found 0 vulnerabilities`
- [ ] `cd relay && npm audit` → `found 0 vulnerabilities`
- [ ] `cd phodex-bridge && npm test` exits 0
- [ ] `cd relay && npm test` exits 0
- [ ] `git status` shows only the four in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `npm audit` still reports a `ws` vulnerability after bumping to `^8.21.0` (a
  newer advisory may exist — report the advisory ID rather than chasing it).
- Either test suite fails after the bump (a real behavior change in `ws` —
  report the failing test; do not edit source to make it pass).
- `npm install` wants to change dependencies other than `ws` and its transitive
  tree — report the unexpected diff.

## Maintenance notes

- Re-run `npm audit` in CI ideally (see the separate DX plan for adding a lint/audit
  step) so future `ws` advisories surface automatically.
- Both packages independently pin `ws`; keep them on the same major to avoid
  protocol-level drift between the bridge and relay ends of the same socket.
