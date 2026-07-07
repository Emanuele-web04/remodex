# Plan 004: Handle spawn errors on the post-update self-restart so a failed restart can't crash the daemon

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 6f27902..HEAD -- phodex-bridge/src/bridge.js phodex-bridge/test/bridge.test.js`
> If either changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as
> a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `6f27902`, 2026-07-07

## Why this matters

After the bridge self-updates its npm package, `scheduleBridgeServiceRestartAfterUpdate`
spawns `remodex restart` in a detached child. That `spawn(...)` call has **no**
`error` listener. If the spawn fails asynchronously (the CLI path briefly missing
mid-update, `EMFILE`, a permission error), Node emits an `'error'` event on the
ChildProcess with no listener — which becomes an uncaught exception and crashes
the process. That is the worst possible moment for the daemon to die uncleanly:
right after an update, when the user expects it to come back. Every other
`spawn()` in this codebase already guards this exact case — the `caffeinate`
wake-assertion a few lines below (`bridge.js:1626`) and the `taskkill` spawn in
`codex-transport.js:239` both attach `.on("error", ...)` immediately. This makes
the restart spawn consistent with them.

## Current state

- `phodex-bridge/src/bridge.js:1563-1575` — the unguarded spawn:
  ```js
  // Restarts after the RPC response has crossed the encrypted phone channel.
  function scheduleBridgeServiceRestartAfterUpdate() {
    const restartTimer = setTimeout(() => {
      const cliPath = path.join(__dirname, "..", "bin", "remodex.js");
      const child = spawn(process.execPath, [cliPath, "restart"], {
        detached: true,
        stdio: "ignore",
        env: process.env,
      });
      child.unref?.();                    // <-- no child.on("error", ...) before this
    }, BRIDGE_RESTART_AFTER_UPDATE_DELAY_MS);
    restartTimer.unref?.();
  }
  ```
- The exemplar to match — `phodex-bridge/src/bridge.js:1621-1628`
  (`createMacOSBridgeWakeAssertion`):
  ```js
  const nextChild = spawnImpl("/usr/bin/caffeinate", ["-i", "-w", String(pid)], {
    stdio: "ignore",
  });

  nextChild.on?.("error", (error) => {
    consoleImpl.warn(`[remodex] Failed to hold the Mac awake while the bridge is active: ${error.message}`);
  });
  ```
- Same pattern also in `phodex-bridge/src/codex-transport.js:239-243`.

Convention: this repo logs warnings with a `[remodex]` prefix via `console.warn`.
Match that. A failed restart is a degraded-but-recoverable state (the old process
keeps running / launchd can restart it) — log and no-op; do **not** re-throw.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Test file | `cd phodex-bridge && node --test test/bridge.test.js` | all tests pass |
| Full bridge suite | `cd phodex-bridge && npm test` | all tests pass |

## Scope

**In scope** (the only files you should modify):
- `phodex-bridge/src/bridge.js`
- `phodex-bridge/test/bridge.test.js`

**Out of scope** (do NOT touch):
- `codex-transport.js` and the `caffeinate` block — reference exemplars only.
- The update-download logic that precedes the restart — unrelated.
- The restart delay / RPC-response ordering — unchanged.

## Git workflow

- Branch: `advisor/004-restart-spawn-error`
- One commit; short imperative message, e.g. `Handle self-restart spawn errors instead of crashing the daemon`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Attach an `error` handler to the restart child

In `scheduleBridgeServiceRestartAfterUpdate`, add the listener immediately after
the `spawn(...)` and before `child.unref?.()`:
```js
const child = spawn(process.execPath, [cliPath, "restart"], {
  detached: true,
  stdio: "ignore",
  env: process.env,
});
child.on?.("error", (error) => {
  console.warn(`[remodex] Failed to schedule the post-update bridge restart: ${error?.message || error}`);
});
child.unref?.();
```
Use the `.on?.(` optional-call form to match the exemplar (guards against a stub
child without `.on`).

**Verify**: `cd phodex-bridge && node --test test/bridge.test.js` → all existing tests still pass.

### Step 2: Add a regression test

Add a test to `phodex-bridge/test/bridge.test.js` that exercises
`scheduleBridgeServiceRestartAfterUpdate` (or whatever public seam invokes it)
with an injected/stubbed `spawn` that returns a child which emits `'error'`, and
asserts the process does **not** throw — the error is swallowed and logged.

Before writing this, check how `bridge.js` exposes `spawn` for injection: grep
the file for how `spawn` is imported and whether the factory accepts a
`spawnImpl`-style override (the `caffeinate` code uses `spawnImpl`). If the
restart path does not currently accept an injectable `spawn`, and injecting one
would require production API changes beyond this fix, do NOT add production
surface just for the test — instead assert behaviorally via the timer path if a
seam exists, or note in your report that the regression test needs a seam that
isn't present (Step 1's fix still stands and is the primary deliverable).

**Verify**: `cd phodex-bridge && node --test test/bridge.test.js` → all tests pass, including the new one (or a note if no seam exists).

## Test plan

- New test in `phodex-bridge/test/bridge.test.js`:
  - **restart spawn error is swallowed**: stub child emits `'error'` → no uncaught
    exception; a `[remodex]` warning is logged (assert via a captured console or
    the injected logger if the seam exists).
- Structural pattern: model after existing `bridge.test.js` tests that stub
  child-process behavior (search the test file for `spawn` usage to find the
  established injection style).
- Verification: `cd phodex-bridge && npm test` → all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n 'child.on?.("error"' phodex-bridge/src/bridge.js` returns a match inside `scheduleBridgeServiceRestartAfterUpdate`
- [ ] `cd phodex-bridge && npm test` exits 0
- [ ] A regression test exists for the spawn-error path, OR your report explains why no injection seam is available (with the Step 1 fix still applied)
- [ ] `git status` shows only the two in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The current code already attaches an `error` handler to the restart child (bug
  already fixed).
- Adding a test seam would require changing the function's public signature or
  exports in a way that ripples into callers — apply the Step 1 fix, skip the
  seam, and report.

## Maintenance notes

- If the restart mechanism ever moves off `spawn(... "restart")` (e.g. to a
  launchd/systemd trigger), this handler moves with it.
- Reviewer: confirm the handler logs and returns; it must not re-throw or call
  `process.exit`, which would reintroduce the crash it's meant to prevent.
