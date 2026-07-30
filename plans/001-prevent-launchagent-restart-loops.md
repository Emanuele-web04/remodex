# Plan 001: Prevent orphaned macOS LaunchAgent restart loops and add clean service removal

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan in
> `plans/README.md` unless a reviewer explicitly says they maintain the index.
>
> **Drift check (run first)**:
>
> ```sh
> git diff --stat 7c8f28e..HEAD -- \
>   phodex-bridge/src/macos-launch-agent.js \
>   phodex-bridge/src/index.js \
>   phodex-bridge/bin/remodex.js \
>   phodex-bridge/test/macos-launch-agent.test.js \
>   phodex-bridge/test/remodex-cli.test.js \
>   README.md
> ```
>
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. If the
> lifecycle behavior no longer matches, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — the change affects macOS service launch, restart, and removal
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `7c8f28e`, 2026-07-30

## Why this matters

The installed LaunchAgent directly executes the saved Node binary and
`remodex.js`, with `KeepAlive.SuccessfulExit=false`. If either installed path
is removed, launchd repeatedly schedules the failing job; when Node remains
but the CLI disappears, every attempt writes a `MODULE_NOT_FOUND` stack to the
unbounded stderr log. The fix must stop that loop without losing recovery from
real non-zero daemon failures.

The same change must provide a supported, idempotent way to unload the job and
remove its plist before users uninstall the npm package or delete a local
checkout. Existing installed plists must be migrated when users run
`remodex restart`; merely changing future plist generation is insufficient.

## Current state

Relevant files:

- `phodex-bridge/src/macos-launch-agent.js` owns plist generation and all
  launchctl lifecycle operations.
- `phodex-bridge/src/index.js` exposes lifecycle helpers to the CLI.
- `phodex-bridge/bin/remodex.js` implements public commands and JSON output.
- `phodex-bridge/test/macos-launch-agent.test.js` uses injected filesystem,
  process, and launchctl dependencies for service tests.
- `phodex-bridge/test/remodex-cli.test.js` invokes `main` with a dependency
  table and asserts public CLI behavior.
- `README.md` documents installation, updates, and macOS commands.

The plist directly invokes paths that may disappear:

```js
// phodex-bridge/src/macos-launch-agent.js:360-372
<key>ProgramArguments</key>
<array>
  <string>${escapeXml(nodePath)}</string>
  <string>${escapeXml(cliPath)}</string>
  <string>run-service</string>
</array>
<key>RunAtLoad</key>
<true/>
<key>KeepAlive</key>
<dict>
  <key>SuccessfulExit</key>
  <false/>
</dict>
```

The missing-config path intentionally exits successfully. A `PathState`-only
policy would turn this into another restart loop while the CLI remains:

```js
// phodex-bridge/src/macos-launch-agent.js:39-51
const config = readDaemonConfig({ env });
if (!config?.relayUrl) {
  // Persist an actionable error, then return normally.
  console.error(`[remodex] ${message}`);
  return;
}
```

An existing plist is currently kickstarted without being regenerated, so
`remodex restart` would leave the legacy launch policy installed:

```js
// phodex-bridge/src/macos-launch-agent.js:139-163
const plistPath = resolveLaunchAgentPlistPath({ env, osImpl });
if (!fsImpl.existsSync(plistPath)) {
  return startMacOSBridgeService({ /* ... */ });
}
// ...
kickstartLaunchAgent({ env, execFileSyncImpl, plistPath });
```

Stopping unloads the job and clears transient state but intentionally does not
remove the plist:

```js
// phodex-bridge/src/macos-launch-agent.js:185-205
function stopMacOSBridgeService(/* ... */) {
  // ...
  bootoutLaunchAgent({ env, execFileSyncImpl, ignoreMissing: true });
  terminateRecordedBridgeProcess(previousStatus, { /* ... */ });
  clearPairingSession({ env, fsImpl });
  clearBridgeStatus({ env, fsImpl });
}
```

Applicable repository conventions:

- Bridge code is dependency-injected CommonJS with no transpilation. Match the
  option-object pattern in `stopMacOSBridgeService`.
- Tests use `node:test`, `node:assert/strict`, temporary directories, and
  injected command implementations. Match
  `phodex-bridge/test/macos-launch-agent.test.js:62-179`.
- CLI commands use `assertMacOSCommand` and `emitResult`; match the existing
  `stop` branch at `phodex-bridge/bin/remodex.js:173-190`.
- Preserve saved daemon configuration, device trust, logs, and pairing
  identity when removing only the service definition.
- Do not run Xcode tests for this bridge-only change.

The focused baseline is currently green:

```text
node --test test/macos-launch-agent.test.js test/remodex-cli.test.js
tests 25, pass 25, fail 0
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `cd phodex-bridge && node --test test/macos-launch-agent.test.js test/remodex-cli.test.js` | exit 0; all focused tests pass |
| Full bridge suite | `cd phodex-bridge && npm test` | exit 0; no failed tests |
| Entrypoint exports | `cd phodex-bridge && node -e "const api=require('./src'); if(typeof api.uninstallMacOSBridgeService!=='function') process.exit(1)"` | exit 0, no output |
| Patch hygiene | `git diff --check` | exit 0, no output |
| Scope check | `git status --short` | only the six in-scope product files and existing `plans/**` artifacts are listed |

Reference documentation:

- `man launchd.plist`, especially `KeepAlive`, `SuccessfulExit`, and the rule
  that multiple conditions are ORed.
- `man launchctl`, especially `bootstrap`, `bootout`, and `kickstart`.
- npm scripts documentation, section "A Note on a lack of npm uninstall
  scripts"; do not add a non-functional uninstall lifecycle hook.

## Scope

**In scope** — the only product files to modify:

- `phodex-bridge/src/macos-launch-agent.js`
- `phodex-bridge/src/index.js`
- `phodex-bridge/bin/remodex.js`
- `phodex-bridge/test/macos-launch-agent.test.js`
- `phodex-bridge/test/remodex-cli.test.js`
- `README.md`
- `plans/README.md` only for the final status update

**Out of scope** — do not touch:

- `CodexMobile/**`, including the menu bar app. Its package updater already
  calls `start`, which rewrites the plist.
- `phodex-bridge/package.json`; modern npm has no usable uninstall lifecycle.
- Relay code, iOS behavior, Xcode project files, or Xcode tests.
- Deletion of `~/.remodex`, daemon config, logs, saved device trust, or pairing
  identity. This plan removes the service definition, not user data.
- Log rotation, SMAppService migration, or unrelated daemon refactoring.
- `PathState`, `SuccessfulExit=true`, or `Crashed=true`.

## Git workflow

- Suggested branch: `fix/macos-launchagent-restart-loop`
- Use one focused commit. Match the repository's imperative commit style, for
  example: `Prevent LaunchAgent restart loops`.
- Do not push or open a pull request unless the operator explicitly requests
  it.

## Steps

### Step 1: Add regression tests that define the launch and removal contract

In `phodex-bridge/test/macos-launch-agent.test.js`, add coverage for all of the
following before changing production behavior:

1. The generated program arguments launch `/bin/sh -c` with a constant guard
   script and pass `nodePath` and `cliPath` as positional arguments. Paths must
   never be interpolated into shell source.
2. Executing the guard with a missing Node path exits `0` without launching
   anything.
3. Executing the guard with an existing Node path but a missing CLI path exits
   `0`.
4. Executing the guard with valid paths forwards `run-service` to the CLI and
   preserves a deliberate non-zero exit code from Node. Use a temporary JS
   fixture whose path contains a space and which exits with a distinctive code
   only when it receives `run-service`.
5. The plist still contains `SuccessfulExit=false` and does not contain
   `PathState`.
6. Restarting an existing service rewrites its plist with the current
   `nodePath` and `cliPath`, then performs bootout, bootstrap, and kickstart,
   without requiring or rewriting relay config.
7. Service removal unloads first, terminates only a verified orphan through
   the existing stop helper, clears transient status/pairing state, then
   removes the plist.
8. Service removal is idempotent when the job and plist are already absent.
9. If bootout fails with a non-missing-service error, removal throws and leaves
   the plist intact.

Prefer a small exported `buildLaunchAgentProgramArguments({ nodePath,
cliPath })` helper from `macos-launch-agent.js` so the behavioral shell tests
exercise the exact arguments written into the plist. Export it only from that
module for focused tests; it does not need to become public CLI API.

In `phodex-bridge/test/remodex-cli.test.js`, add tests proving:

1. `remodex uninstall-service` calls the injected macOS removal dependency and
   emits the intended human-readable success message.
2. `remodex uninstall-service --json` returns `ok`, `currentVersion`,
   `plistPath`, and whether a plist was actually removed.
3. The command uses the existing macOS-only guard.

**Verify**:

```sh
cd phodex-bridge
node --test test/macos-launch-agent.test.js test/remodex-cli.test.js
```

Expected at this red-test stage: exit non-zero only because the newly named
guard, restart-migration, removal, and CLI behaviors do not exist yet. Existing
tests must not acquire unrelated failures.

### Step 2: Guard launchd execution without weakening real failure recovery

In `phodex-bridge/src/macos-launch-agent.js`:

1. Add a constant shell guard and a pure
   `buildLaunchAgentProgramArguments({ nodePath, cliPath })` helper.
2. Produce this argument structure:

   ```js
   [
     "/bin/sh",
     "-c",
     'if [ ! -x "$1" ] || [ ! -f "$2" ]; then exit 0; fi; exec "$1" "$2" run-service',
     "com.remodex.bridge",
     nodePath,
     cliPath,
   ]
   ```

   The label occupies shell `$0`; the two paths become `$1` and `$2`. Do not
   interpolate either dynamic path into the script string.
3. Render every returned argument through the existing `escapeXml` helper when
   building the plist.
4. Retain `RunAtLoad=true` and `KeepAlive.SuccessfulExit=false` exactly. Do not
   add any other `KeepAlive` condition.
5. Add a concise code comment explaining the required semantics: absent
   installed paths produce a clean exit so launchd stops retrying, while
   genuine daemon failures remain non-zero and are restarted.
6. Export the argument builder from `macos-launch-agent.js` for its focused
   behavioral tests, but not from `src/index.js`.

This guard is the load-bearing fix. It must use `exec` so launchd observes
Node's actual exit status and signals rather than the status of a lingering
shell parent.

**Verify**:

```sh
cd phodex-bridge
node --test test/macos-launch-agent.test.js
```

Expected: the missing-path, forwarding, and plist-policy tests pass. Any test
showing a missing path exits non-zero is a blocker.

### Step 3: Regenerate legacy plists during restart

Update `restartMacOSBridgeService` in
`phodex-bridge/src/macos-launch-agent.js`:

1. Preserve the current fallback to `startMacOSBridgeService` when no plist
   exists.
2. When a plist exists, ensure the state and log directories exist, regenerate
   the plist with the current process's `nodePath` and current package's
   `cliPath`, and call `restartLaunchAgent` so launchd receives the new
   definition.
3. Continue to avoid rewriting daemon/relay configuration. A restart with an
   existing plist must still be callable when no relay environment override is
   present.
4. Accept explicit `nodePath` and `cliPath` options following the defaults and
   dependency-injection style already used by `startMacOSBridgeService`.
5. Remove `kickstartLaunchAgent` if this leaves it with no callers; do not keep
   dead lifecycle code.
6. Update the existing restart tests and names to describe regeneration and
   re-bootstrap rather than kickstart-only behavior.

This is the migration path for already-installed legacy plists. `start`,
`up`, and the menu bar updater already rewrite the plist; no Swift changes are
needed.

**Verify**:

```sh
cd phodex-bridge
node --test test/macos-launch-agent.test.js
```

Expected: all LaunchAgent tests pass, including an assertion that an existing
legacy plist was replaced and launchctl received bootout → bootstrap →
kickstart in order.

### Step 4: Add an idempotent service-uninstall operation

In `phodex-bridge/src/macos-launch-agent.js`, add
`uninstallMacOSBridgeService` using the same injected dependency pattern as
the other lifecycle functions:

1. Resolve the exact user plist path.
2. Record whether it existed for the return payload.
3. Call `stopMacOSBridgeService` first, reusing its bootout, verified-orphan
   termination, and transient-state cleanup.
4. Only after stop succeeds or reports an already-missing service, remove the
   exact plist path with the injected filesystem implementation and `force`
   semantics.
5. Return `{ plistPath, removed }`.
6. If bootout fails for any reason other than an already-missing service,
   propagate the error and leave the plist on disk.
7. Preserve daemon config, logs, device trust, and pairing identity.

Export this operation from both `macos-launch-agent.js` and
`phodex-bridge/src/index.js`. Update the file-header export descriptions if
needed.

**Verify**:

```sh
cd phodex-bridge
node --test test/macos-launch-agent.test.js
```

Expected: removal ordering, idempotency, preservation boundaries, and
failure-before-deletion tests all pass.

### Step 5: Expose `remodex uninstall-service`

In `phodex-bridge/bin/remodex.js`:

1. Import `uninstallMacOSBridgeService` and add it to `defaultDeps`.
2. Add a macOS-only `uninstall-service` command beside `stop`.
3. Emit the helper's `plistPath` and `removed` values with:

   ```js
   {
     ok: true,
     currentVersion: version,
     plistPath: result.plistPath,
     removed: result.removed,
   }
   ```

4. Use a concise human message that says the macOS bridge service was removed
   and the npm package can now be uninstalled.
5. Add `uninstall-service` to the usage text and to the list of commands that
   support `--json`.
6. Do not make `stop` remove the plist; stopping temporarily and uninstalling
   the service remain distinct operations.

Match the existing `stop` branch's `assertMacOSCommand` and `emitResult`
structure rather than introducing a new CLI abstraction.

**Verify**:

```sh
cd phodex-bridge
node --test test/remodex-cli.test.js
```

Expected: all CLI tests pass, including human, JSON, and macOS-only behavior.

### Step 6: Document upgrade migration and clean removal

Update `README.md` only in the existing install/update and command sections:

1. After the global update command, tell users with an installed macOS
   background service to run `remodex restart`. Explain briefly that restart
   refreshes the saved Node/CLI paths and LaunchAgent policy without replacing
   pairing state.
2. Clarify that `remodex restart` refreshes and re-bootstraps the plist but
   does not rewrite the saved relay configuration.
3. Add a `remodex uninstall-service` command section after `remodex stop`.
4. Document the safe full package-removal sequence:

   ```sh
   remodex uninstall-service
   npm uninstall -g remodex
   ```

5. State that this removes the LaunchAgent definition but preserves
   `~/.remodex` configuration, logs, and trusted-device data for a future
   reinstall. Do not suggest deleting that directory in this fix.
6. Do not claim Finder/app deletion can run cleanup automatically and do not
   add hosted-service instructions.

**Verify**:

```sh
rg -n "uninstall-service|npm uninstall -g remodex|remodex restart" README.md
```

Expected: the update flow, command reference, and removal sequence are all
present, with no npm uninstall lifecycle-hook claim.

### Step 7: Run the complete bridge verification and inspect scope

Run:

```sh
cd phodex-bridge
node --test test/macos-launch-agent.test.js test/remodex-cli.test.js
npm test
node -e "const api=require('./src'); if(typeof api.uninstallMacOSBridgeService!=='function') process.exit(1)"
cd ..
git diff --check
git status --short
```

Expected:

- Both focused test files pass with zero failures.
- The full bridge suite passes with zero failures.
- The public lifecycle export check exits 0 with no output.
- `git diff --check` prints nothing.
- Only the six in-scope product files plus the existing `plans/**` planning
  artifacts are listed.
- No Xcode tests or simulator runs were performed.

## Test plan

Add tests to `phodex-bridge/test/macos-launch-agent.test.js`, following its
existing temporary-environment and injected-launchctl patterns:

- Missing Node executable → guard exits 0.
- Missing CLI entrypoint → guard exits 0.
- Valid Node and a CLI fixture in a path with spaces → `run-service` is
  forwarded and the fixture's non-zero exit reaches launchd unchanged.
- Generated plist → `/bin/sh` guard arguments, XML escaping,
  `SuccessfulExit=false`, and no `PathState`.
- Existing legacy plist restart → file regenerated with current paths and
  launchctl called in bootout/bootstrap/kickstart order without relay config.
- Uninstall with installed service → unload before exact plist deletion and
  transient state cleared.
- Uninstall with missing service/plist → succeeds with `removed=false`.
- Uninstall with real bootout error → throws and preserves plist.

Add tests to `phodex-bridge/test/remodex-cli.test.js`, following the existing
`main({ argv, platform, deps })` tests:

- Human uninstall output.
- JSON uninstall payload.
- macOS-only rejection.

Do not add a real LaunchAgent to the user's login domain as part of automated
tests. The pure guard execution plus injected launchctl sequence provides the
repeatable regression coverage without disturbing a developer's live bridge.

## Done criteria

All must hold:

- [ ] Missing saved Node or CLI paths cause the exact generated launch guard
      to exit 0 without writing an error.
- [ ] A real non-zero Node/bridge exit remains non-zero through shell `exec`.
- [ ] Generated plists retain `SuccessfulExit=false` and contain no
      `PathState`, `SuccessfulExit=true`, or `Crashed=true`.
- [ ] `remodex restart` regenerates and re-bootstraps existing legacy plists
      without rewriting relay configuration.
- [ ] `remodex uninstall-service` unloads before deletion, is idempotent, and
      never deletes the plist after a real bootout failure.
- [ ] Service removal preserves daemon config, logs, device trust, and pairing
      identity.
- [ ] README documents restart-after-update and the two-command safe uninstall
      sequence.
- [ ] Focused tests and the full `phodex-bridge` test suite exit 0.
- [ ] `git diff --check` exits 0.
- [ ] No product files outside the six-file scope are modified.
- [ ] `plans/README.md` status is updated.

## STOP conditions

Stop and report back instead of improvising if:

- The drift check shows the relevant lifecycle functions or CLI command
  structure changed materially after commit `7c8f28e`.
- Preserving non-zero child exit status would require interpolating dynamic
  paths into shell source.
- Regenerating an existing plist during restart would require overwriting
  daemon/relay configuration.
- Correct service removal appears to require deleting `~/.remodex`, logs,
  pairing identity, or trusted-device state.
- The implementation would need an npm uninstall lifecycle hook.
- A step appears to require modifying Swift, the menu bar UI, relay code, or
  Xcode project files.
- A focused verification fails twice after a reasonable correction.
- A real launchctl integration test would require replacing or unloading the
  developer's live `com.remodex.bridge` service; do not do that without
  explicit operator approval.

## Maintenance notes

- The shell guard is deliberately constant. Future changes to the CLI
  entrypoint or service arguments must keep installed paths positional and
  extend the guard tests.
- Keep `SuccessfulExit=false`: it is what preserves restart-on-failure after
  the guard uses `exec`. Do not add another `KeepAlive` condition without
  revisiting launchd's OR semantics.
- `uninstall-service` removes only launchd ownership. A separate, explicitly
  destructive data-purge command would require its own product decision and
  confirmation UX.
- If Remodex later adopts `SMAppService` or bundles its runtime inside a signed
  macOS app, replace this legacy-plist design rather than layering compatibility
  branches onto it.
- Reviewers should scrutinize bootout-before-delete ordering, path handling
  with spaces, and whether restart genuinely replaces the loaded definition.
