# Remodex Menu Bar and Bridge CLI Deep Audit

Date: 2026-05-22
Scope: macOS Remodex Menu Bar companion, `remodex` bridge CLI, macOS launchd bridge lifecycle, and the bridge RPC surface that should or should not be exposed through the Menu Bar.

## Executive Summary

The Remodex Menu Bar should be a clean macOS control surface over the stable `remodex` CLI, not a second implementation of bridge lifecycle logic. The current direction is good: the Menu Bar now reads `status --json`, controls the daemon, displays pairing state, and avoids direct bridge internals. The main remaining issue is that some responsibilities are still split between Swift and Node in ways that will become costly as the bridge grows.

The strongest recommendation is to make the CLI the single control-plane facade for companion apps:

- Keep lifecycle commands in the CLI.
- Add machine-readable contracts for every Menu Bar action.
- Move npm update/version lookup logic out of Swift and into the CLI/bridge package.
- Keep developer/internal commands out of the Menu Bar.
- Add a diagnostic command so the Menu Bar can show actionable local setup issues without duplicating shell checks.

## Current Public CLI Surface

The CLI currently exposes:

- `remodex up`
- `remodex run`
- `remodex run-service`
- `remodex start`
- `remodex restart`
- `remodex qr`
- `remodex pair`
- `remodex stop`
- `remodex status`
- `remodex reset-pairing`
- `remodex resume`
- `remodex watch [threadId]`
- `remodex --version`

Several commands support `--json`: `start`, `restart`, `pair`/`qr`, `stop`, `status`, `reset-pairing`, `resume`, and `--version`.

## Menu Bar Surface After Alignment

The Menu Bar currently exposes the useful end-user actions:

- Start
- Restart
- Stop
- Pair QR
- Resume
- Refresh
- Reset Pair
- Update, when an update is available
- Open logs folder/stdout/stderr
- Relay override
- Pairing QR display
- CLI availability blocker

This is mostly the correct surface. The commands that should not be shown in the Menu Bar are `run`, `run-service`, and `watch`.

## Findings

### High: Self-update logic is duplicated and should be centralized

The Menu Bar currently runs `npm install -g remodex@latest` from Swift. The bridge already has a more robust update-and-restart path through `desktop/bridge/updateAndRestart`, including timeout handling and delayed restart after the response returns to the client.

Risk:

- Divergent update behavior between iOS and Menu Bar.
- Different timeout/error behavior depending on the entry point.
- Swift must know npm details that belong to the Node package.
- Future package-manager changes would require editing multiple clients.

Recommended fix:

Add `remodex update --json` and make the Menu Bar call that command. The Node CLI should own:

- npm command construction
- shell environment setup
- timeout
- output truncation
- restart scheduling
- JSON response

Suggested JSON result:

```json
{
  "ok": true,
  "currentVersion": "1.5.6",
  "command": "npm install -g remodex@latest",
  "restartScheduled": true,
  "restartDelayMs": 750
}
```

### Medium: `status --json` should expose capabilities

The Menu Bar currently infers availability mostly from installed version and fallback behavior. That is workable, but it makes the app guess what the bridge supports.

Recommended fix:

Add a `capabilities` block to `remodex status --json`.

Suggested shape:

```json
{
  "currentVersion": "1.5.6",
  "capabilities": {
    "statusJson": true,
    "pairJson": true,
    "restart": true,
    "selfUpdate": true,
    "doctorJson": true,
    "logsJson": true
  }
}
```

This lets the Menu Bar show/hide actions without hardcoding version checks or parsing human-readable output.

### Medium: npm latest-version lookup should not live in Swift

The Menu Bar currently calls `npm view remodex version --json`. The bridge already has a cached package version reader for mobile status paths.

Risk:

- Slow network/npm calls can affect Menu Bar refresh.
- Swift duplicates registry lookup behavior.
- Offline/error behavior may diverge from mobile/bridge behavior.

Recommended fix:

Expose latest package version through `status --json` or a dedicated `remodex version --json`, backed by the existing cached package-version reader.

Preferred:

```json
{
  "currentVersion": "1.5.6",
  "latestVersion": "1.5.7",
  "latestVersionCheckedAt": "2026-05-22T18:00:00.000Z"
}
```

### Medium: lifecycle commands need clearer human/API separation

`up`, `start`, `pair`, and `restart` overlap:

- `up`: human flow, start service and print QR.
- `start`: service lifecycle, no guaranteed fresh QR.
- `pair`: pairing flow, starts/restarts enough to publish a fresh QR.
- `restart`: launchd lifecycle, not necessarily a pairing action.

Recommended policy:

- Menu Bar should use `start --json`, `restart --json`, `pair --json`, `stop --json`, and `status --json`.
- Terminal users can keep using `up`.
- Documentation should call `pair` canonical and `qr` an alias.

### Medium: internal commands are publicly visible

`run-service` is required by launchd, but it is not an end-user command. `watch` is diagnostic/development-oriented.

Recommended fix:

Keep both commands for compatibility, but split CLI help into:

- User commands
- Maintenance commands
- Developer/internal commands

`run-service` should not appear in primary usage text.

### Medium: no single diagnostic command exists

The Menu Bar currently checks CLI availability and status, but setup failures can come from many layers:

- `remodex` missing
- Node missing
- npm unavailable
- relay missing
- launchd missing/stale
- state directory unavailable
- stale pid/status files
- pairing file absent/expired
- logs missing

Recommended fix:

Add `remodex doctor --json`.

Suggested checks:

- CLI path
- Node path
- npm path
- package version
- latest known version
- relay config source
- launchd plist path
- launchd loaded/pid
- bridge status file
- pairing session status
- stdout/stderr log paths
- last error

The Menu Bar can then show a compact diagnostic section without duplicating shell logic.

### Low: CLI parser is too permissive

The parser currently recognizes `--json` and otherwise treats tokens as positionals. Unknown flags do not produce structured guidance.

Recommended fix:

Keep the dependency-free parser, but make it explicit:

- `--help`
- unknown flag error
- command-specific allowed flags
- JSON error format when `--json` is passed

### Low: fallback parsing of human status output should be temporary

The Menu Bar has a fallback parser for older human-readable `status` output. That is useful for compatibility, but should not become a long-term contract.

Recommended fix:

Keep fallback only behind a legacy compatibility path and remove it once the minimum supported bridge guarantees `status --json`.

## Recommended Final CLI Taxonomy

### User Commands

- `remodex up`
- `remodex pair`
- `remodex status`
- `remodex stop`
- `remodex resume`

### Menu Bar / Machine Commands

- `remodex status --json`
- `remodex start --json`
- `remodex restart --json`
- `remodex pair --json`
- `remodex stop --json`
- `remodex reset-pairing --json`
- `remodex update --json`
- `remodex doctor --json`
- `remodex logs --json`

### Developer/Internal Commands

- `remodex run`
- `remodex run-service`
- `remodex watch [threadId]`

## Recommended Menu Bar Layout

Use only bordered sections and controls, matching the latest UI direction:

1. Status
   - Daemon
   - Connection
   - PID
   - Relay
   - Installed/latest version

2. Actions
   - Start
   - Restart
   - Stop

3. Pairing
   - Pair QR
   - Reset Pair
   - QR preview

4. Maintenance
   - Update
   - Doctor
   - Logs

5. Utility
   - Resume Last Thread
   - Refresh

Avoid exposing `run`, `run-service`, and `watch` in the Menu Bar.

## Implementation Roadmap

### Phase 1: Stabilize CLI contracts

- Add `update --json`.
- Add `doctor --json`.
- Add `logs --json`.
- Add `capabilities` to `status --json`.
- Add tests for each JSON contract.

### Phase 2: Simplify Menu Bar service

- Replace direct `npm install -g remodex@latest` with `remodex update --json`.
- Replace direct `npm view remodex version --json` with `status --json` latest-version fields.
- Use `capabilities` to enable/disable buttons.
- Keep legacy fallback parser only for old bridge versions.

### Phase 3: Clean CLI help and command taxonomy

- Add `help`.
- Hide `run-service` from primary usage.
- Mark `qr` as alias of `pair`.
- Separate user, maintenance, and developer/internal commands.

## Current Changes Already Applied

The repository already includes these local changes:

- `pair --json` / `qr --json` support in the CLI.
- Menu Bar actions for `Restart` and `Pair QR`.
- Border-only Menu Bar presentation with smaller 8px radii.
- CLI test coverage for `pair --json`.

Bridge test status:

- `npm test` in `phodex-bridge` passes.
- 369 tests passing.

Xcode test status:

- Xcode tests were not run, respecting the repository guardrail.

## Residual Risks

- `Package.resolved` is modified in the worktree and should be reviewed separately before committing.
- Menu Bar build/run should be checked visually on macOS after the Swift package graph has settled.
- The current Menu Bar still performs npm update/version work directly; this should be removed once `update --json` and latest-version status fields exist.
