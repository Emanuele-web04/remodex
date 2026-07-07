# Plan 003: Bound the `activeThreadIds` set so the Desktop follower can't leak memory in a long-running daemon

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 6f27902..HEAD -- phodex-bridge/src/desktop-ipc-action-follower.js phodex-bridge/test/desktop-ipc-action-follower.test.js`
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

`desktop-ipc-action-follower.js` tracks "phone interest" in Desktop-owned threads
in a `Set` called `activeThreadIds`. Every distinct thread ID ever observed via a
Desktop state-read is `.add()`-ed, but the set is **never** trimmed: there is no
`.delete()` anywhere, and unlike its six sibling per-thread maps it is **not**
cleared in `onDisconnect()`. In a daemon that runs for days/weeks across many
Codex threads, this grows without bound — the classic long-lived-process leak.

There is a real design constraint the fix must respect: `activeThreadIds`
**deliberately survives per-thread release** (`removeDesktopThreadState`, see the
comment at lines 298-302) so that if Desktop picks a released thread back up, its
broadcasts are processed immediately instead of dropped. So the fix is **not** to
delete entries on per-thread release. Two safe bounds that respect that intent:
(a) clear the set on full Desktop **disconnect** (a natural boundary — the six
sibling maps already clear there, and reconnect re-populates via fresh reads),
and (b) cap the set size with FIFO eviction of the oldest entries, mirroring the
existing `MAX_CACHED_THREADS` bound in `desktop-ipc-live-owner.js`.

## Current state

- `phodex-bridge/src/desktop-ipc-action-follower.js:100` — declaration:
  ```js
  const activeThreadIds = new Set();
  ```
- It is added to at `:146` and `:557` (in handlers for `thread/read`,
  `thread/resume`, `thread/turns/list`), and cleared **only** in `stopAll()` at
  `:161` (`activeThreadIds.clear();`). `grep -n "activeThreadIds" <file>` shows
  **zero** `.delete(` calls. Membership is read at `:215` and `:325`
  (`activeThreadIds.has(threadId)`).
- `:263-280` — `onDisconnect()` clears six sibling structures but NOT
  `activeThreadIds`:
  ```js
  function onDisconnect() {
    rawStatesByThreadId.clear();
    rawStateUpdatedAtByThreadId.clear();
    recoveringThreadIds.clear();
    baselineRecoveryStateByThreadId.clear();
    queuedChangesByThreadId.clear();
    pendingOwnershipProbeTokensByThreadId.clear();
    desktopOwnedByProbeThreadIds.clear();
    // ... comments about intentionally-kept state ...
  }
  ```
- `:298-302` — the intent that FORBIDS deleting on per-thread release:
  ```js
  // ... Phone interest (activeThreadIds) deliberately survives the release: if
  // Desktop picks the thread up next, its broadcasts must be processed
  // immediately instead of being dropped until the phone happens to issue
  // another read.
  function removeDesktopThreadState(threadId) { /* does NOT touch activeThreadIds */ }
  ```

Exemplar for the size-cap pattern (read it before writing the bound) —
`phodex-bridge/src/desktop-ipc-live-owner.js:49-50` and the eviction near
`:733-741`:
```js
// ... a small cap keeps long browsing sessions bounded.
const MAX_CACHED_THREADS = 30;
// ... later, on insert:
if (cachedThreadsByThreadId.size <= MAX_CACHED_THREADS) { /* ok */ }
// else evict oldest
```
The follower file also already uses module-level `MAX_*` constants
(`MAX_QUEUED_CHANGES_PER_THREAD = 300` at `:34`, applied via `splice` at `:813`),
so a `MAX_ACTIVE_THREAD_IDS` constant is idiomatic here.

Convention: `activeThreadIds` is a plain `Set`; JS `Set` preserves insertion
order, so `set.values().next().value` is the oldest entry and can be evicted with
`.delete()`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Test file | `cd phodex-bridge && node --test test/desktop-ipc-action-follower.test.js` | all tests pass |
| Full bridge suite | `cd phodex-bridge && npm test` | all tests pass |

## Scope

**In scope** (the only files you should modify):
- `phodex-bridge/src/desktop-ipc-action-follower.js`
- `phodex-bridge/test/desktop-ipc-action-follower.test.js`

**Out of scope** (do NOT touch):
- `removeDesktopThreadState` / `releaseDesktopThreadState` — must NOT delete from
  `activeThreadIds` (see the intent comment at :298-302). Do not "fix" those.
- The six sibling maps' handling — unchanged.
- `desktop-ipc-live-owner.js` — read it as a pattern reference only; do not edit.

## Git workflow

- Branch: `advisor/003-bound-active-thread-ids`
- One commit; short imperative message, e.g. `Bound activeThreadIds to prevent follower memory leak`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Clear `activeThreadIds` on full Desktop disconnect

In `onDisconnect()` (`:263-280`), add `activeThreadIds.clear();` alongside the
existing sibling `.clear()` calls. This is safe: a full disconnect already resets
`rawStatesByThreadId` et al., and on reconnect Desktop re-sends snapshots that
re-populate interest via the existing read handlers at `:146`/`:557`. This is a
different boundary from the per-thread release the intent comment protects.

**Verify**: `cd phodex-bridge && node --test test/desktop-ipc-action-follower.test.js` → all existing tests still pass.

### Step 2: Add a FIFO size cap on insertion

Add a module-level constant near the other `MAX_*` constants (around `:31-43`):
```js
// Phone interest survives per-thread release by design, so cap the set to keep a
// marathon single Desktop connection from accumulating every thread id forever.
const MAX_ACTIVE_THREAD_IDS = 512;
```
Introduce a small helper and use it at **both** add sites (`:146`, `:557`) in
place of the bare `activeThreadIds.add(threadId)`:
```js
function rememberActiveThread(threadId) {
  activeThreadIds.add(threadId);
  while (activeThreadIds.size > MAX_ACTIVE_THREAD_IDS) {
    const oldest = activeThreadIds.values().next().value;
    if (oldest === undefined) break;
    activeThreadIds.delete(oldest);
  }
}
```
Re-adding a still-active thread refreshes nothing (Set keeps original insertion
order), which is acceptable: the cap is generous (512) and any evicted thread
that Desktop still broadcasts for is re-added by the next read. The cap only ever
trims the least-recently-first-seen ids.

**Verify**: `cd phodex-bridge && node --test test/desktop-ipc-action-follower.test.js` → all tests pass.

### Step 3: Add regression tests

See Test plan. Then run the full suite.

**Verify**: `cd phodex-bridge && npm test` → all tests pass, including the new ones.

## Test plan

- New tests in `phodex-bridge/test/desktop-ipc-action-follower.test.js`:
  - **disconnect clears interest**: after observing a thread read (so
    `activeThreadIds` has an entry), trigger `onDisconnect` and assert a
    subsequent Desktop broadcast for that thread is treated as no-longer-active
    until a fresh read re-adds it. (Match how existing tests trigger reads and
    disconnects — study the file's existing setup/harness first.)
  - **size cap holds**: drive more than `MAX_ACTIVE_THREAD_IDS` distinct thread
    reads and assert the set never exceeds the cap and that the most recent
    threads are retained. If the test needs to observe set size, expose it via an
    existing test seam if one exists; otherwise assert behaviorally (oldest thread
    stops being treated as active after enough new ones). If neither is feasible
    without new production surface, note it and cover Step 1's behavior only.
- Structural pattern: model after the existing tests in the same file that set up
  the follower and feed it `thread/read`-style messages.
- Verification: `cd phodex-bridge && npm test` → all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "activeThreadIds.clear()" phodex-bridge/src/desktop-ipc-action-follower.js` shows a match inside `onDisconnect` (in addition to the pre-existing one in `stopAll`)
- [ ] `grep -n "MAX_ACTIVE_THREAD_IDS" phodex-bridge/src/desktop-ipc-action-follower.js` returns a match
- [ ] Both `activeThreadIds.add` call sites route through the capped helper (no bare `activeThreadIds.add(` remains except inside the helper) — verify with `grep -n "activeThreadIds.add(" phodex-bridge/src/desktop-ipc-action-follower.js`
- [ ] `cd phodex-bridge && npm test` exits 0, new tests present and passing
- [ ] `git status` shows only the two in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The current code no longer matches the "Current state" excerpts (e.g.
  `activeThreadIds` is already cleared in `onDisconnect` or already bounded).
- You find a code path that reads `activeThreadIds` expecting it to persist
  across a disconnect (grep all `activeThreadIds` uses first) — clearing it in
  `onDisconnect` would then be a behavior change; report it instead of proceeding.
- Adding the cap breaks a test in a way that reveals some thread must never be
  evicted — report which.

## Maintenance notes

- The cap (512) is deliberately generous; it exists to bound a pathological
  marathon connection, not to shrink normal usage. If real deployments regularly
  exceed it, prefer raising the cap over adding per-thread deletion, which would
  violate the "interest survives release" invariant at :298-302.
- Reviewer should confirm the fix did NOT add any `.delete()` inside
  `removeDesktopThreadState`/`releaseDesktopThreadState`.
