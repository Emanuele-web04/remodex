# Gemini Backend in Remodex

This document describes the current Gemini backend integration in Remodex: what it is, how it works, how to run it locally, what behavior the bridge exposes to the iPhone client, and which parts are still under validation.

## Purpose

Remodex can operate against two backend families:

- Codex
- Gemini CLI

The Gemini backend allows the iPhone client to drive a local Gemini CLI session through the same high-level Remodex bridge concepts used elsewhere in the app: threads, turns, tool activity, git flows, and session pairing.

This document is intentionally specific about what is implemented versus what is only partially validated.

## High-Level Architecture

The current architecture intentionally keeps the Gemini path separate from the Codex path.

### Relay split

The bridge currently uses different relay stacks depending on the selected backend:

- Codex uses the full `relay/server.js` path
- Gemini uses the bundled `phodex-bridge/src/local-relay.js` path

This split is intentional. Gemini support should not silently replace the existing Codex relay behavior.

### Transport split

The transport model is also different:

- Codex transport can connect to an existing endpoint or use a spawned local runtime
- Gemini transport is stdio-only and spawns `gemini --acp` as a child process

Gemini does not currently use a WebSocket transport for model interaction inside the bridge.

### Adapter role

The iPhone client still speaks the bridge-facing Codex-style JSON-RPC protocol.

The Gemini adapter translates between:

- mobile client requests -> Gemini ACP requests
- Gemini ACP updates -> Remodex bridge events

This allows the iPhone client to continue using the same high-level UI model while the actual backend runtime is Gemini CLI.

## What Is Implemented

At the current project state, the Gemini backend includes the following implemented pieces:

- backend selection through `remodex up --switch`
- saved backend preference for future runs
- Gemini CLI preflight before QR pairing
- bundled Gemini relay startup when no explicit relay URL is provided
- Gemini ACP stdio transport through `gemini --acp`
- Gemini adapter startup and handshake
- Gemini-backed thread creation and restoration
- per-thread `backendType: gemini` metadata
- per-thread working directory support from the iPhone client
- model exposure to the mobile client
- mode exposure to the mobile client
- runtime model switching
- runtime mode switching
- multimodal prompt item handling
- persisted thread history with Gemini metadata
- auto-title derivation from the first user message
- git draft generation through Gemini when the bridge backend is Gemini

These items exist in code and are part of the intended Gemini feature set.

## What Is Not Yet Safe To Call Stable

Some behaviors exist in code but are not yet validated strongly enough to document as fully reliable.

These areas should be treated as under active validation:

- prompt queueing through `isGenerating` and `promptQueue`
- Stop button behavior in live Gemini sessions
- command name rendering in the iPhone UI
- full reasoning lifecycle reliability in real sessions
- full command execution lifecycle reliability in real sessions
- Gemini mobile commit flow in repositories without an initial commit

In particular, prompt queueing should not be described as a guaranteed feature. The adapter contains logic intended to serialize concurrent prompts per thread, but that behavior still needs stronger runtime confirmation on the real client.

## Startup Flow

When Gemini is selected as the active backend, the startup path is:

1. resolve the selected backend
2. print the selected backend in the terminal
3. run Gemini CLI preflight
4. start the Gemini relay path if no explicit `REMODEX_RELAY` is set
5. start the bridge with `backendType: gemini`
6. spawn `gemini --acp`
7. initialize the Gemini adapter
8. continue into the normal Remodex pairing and phone connection flow

If no saved backend exists and the session is non-interactive, the CLI falls back to Codex.

## Gemini CLI Preflight

Before QR pairing is shown, the Gemini path verifies that the local Gemini runtime is actually usable.

The preflight checks that:

- `gemini` is available in `PATH`
- the installed CLI supports `--acp`
- the ACP path is usable enough to continue startup

If preflight fails, Remodex stops before relay startup and before QR pairing.

That behavior is important because it prevents the phone from pairing into a broken Gemini runtime.

## How To Run Gemini Locally

### Requirements

You need:

- a local Remodex checkout
- Node.js 18 or newer
- Gemini CLI installed and available in `PATH`
- a Gemini CLI version with ACP support
- Gemini CLI already authenticated

### Switching to Gemini

Run:

```sh
remodex up --switch
```

Then choose the Gemini option when prompted.

After the backend is saved, later `remodex up` runs will continue to use Gemini until the backend is switched again.

### Source-checkout local runbook

For local development from source, the typical runbook is:

```sh
cd phodex-bridge
npm start
```

Or from the repository root:

```sh
./run-local-remodex.sh
```

## Pairing Model

Pairing stays local-first.

The iPhone connects to the bridge using the standard Remodex QR bootstrap flow. The QR still carries the connection information needed for trust bootstrap and encrypted pairing.

After trust is established:

- the iPhone stores the trusted Mac record in Keychain
- the bridge persists local device trust state on the Mac
- later reconnects can resume without requiring a fresh QR unless trust or session state changes

## Thread and Session Behavior

Gemini sessions are tracked with Gemini-specific metadata.

Current behavior includes:

- threads are marked with `backendType: gemini`
- threads can carry a per-thread working directory
- the adapter persists Gemini thread history
- the adapter restores Gemini thread metadata after restart
- a new thread title defaults to `Gemini Session` until enough user text exists to derive a better title
- the bridge emits `thread/name/updated` when that title is refined

This is important for reconnect, thread listing, thread reading, and session continuity.

## Prompt Handling

The adapter accepts prompt payloads from the mobile client and translates them into Gemini ACP prompt items.

Supported input shapes currently include:

- plain text prompts
- structured prompt items
- image inputs
- file-like inputs when provided in supported payload forms

If the active collaboration mode is plan mode, the adapter currently prepends a system-like planning instruction before the user prompt.

## Models, Modes, and Reported Capabilities

The Gemini adapter reports Gemini runtime information back to the client, including:

- available Gemini models
- the currently selected Gemini model
- available Gemini modes
- the currently selected Gemini mode
- Gemini agent metadata when provided by the CLI

The adapter currently reports these capabilities as present:

- model switching
- multimodal input
- agent support

These are bridge-reported capabilities. Live UX around them should still be judged by real client behavior, not by capability advertisement alone.

## Turn, Tool, and Reasoning Mapping

The mobile client expects Codex-style lifecycle events. The Gemini adapter maps Gemini ACP activity onto those concepts.

Current mapping logic covers:

- thread start
- turn start
- assistant message streaming
- reasoning item lifecycle
- command execution lifecycle
- permission and approval requests
- turn completion and turn cancellation

There is active work around stable item identifiers for reasoning and command execution items so the mobile client can reconcile rows correctly.

However, live behavior around Stop, reasoning visibility, and command labels still needs further runtime debugging.

## Git Behavior Under Gemini

Git execution remains bridge-owned, but Gemini can be used as the drafting backend when the active bridge backend is Gemini.

This currently applies to tasks such as:

- generating commit messages
- generating pull request drafts

That means Gemini contributes drafting output, while the bridge still owns the surrounding Git workflow.

One known weak area remains repositories without an initial commit, where some mobile commit flows still need better `HEAD`-safe handling.

## Security and Safety Notes

The Gemini backend follows the repository's local-first guardrails.

Important safety properties of the current design:

- Gemini runs locally through `gemini --acp` and stdio
- source checkouts do not require hosted-service assumptions
- hardcoded production domains are not required for the Gemini backend flow
- pairing and bridge state remain local-first
- live relay `sessionId` values and other bearer-like pairing identifiers should not be logged in the clear
- Codex and Gemini are intentionally separated by relay path so Gemini changes do not silently break Codex behavior

At the architecture level, the current Gemini design follows the project's local-first recommendations and safety expectations.

## Known Limitations and Follow-Up Areas

The following issues are still considered open:

- Stop button behavior is not yet reliable enough in real Gemini sessions
- command names may still fail to render correctly in the iPhone UI
- reasoning and command activity events still need live runtime validation beyond code inspection
- prompt queue behavior is present in code but should not yet be described as proven stable
- Gemini commit flow still needs stronger handling for unborn `HEAD` / no-initial-commit repositories
- foreground lifecycle cleanup still needs explicit validation:
  - relay port release on shutdown
  - `gemini --acp` child termination on shutdown
  - repeated start/stop hygiene

Because of these gaps, the Gemini backend should be described as implemented and actively evolving, but not yet fully production-stable in every live iPhone workflow.

## Recommended Validation Path

The most useful manual validation path is:

```sh
remodex up --switch
```

Then:

1. choose Gemini
2. scan the QR with the iPhone client
3. send a normal chat message
4. verify thread creation
5. verify thread restore after reconnect
6. verify working-directory-sensitive behavior in a known repository
7. verify multimodal input if needed
8. test git draft flows carefully
9. explicitly test Stop behavior
10. explicitly test command activity rendering

## Implementation Pointers

Relevant files:

- `phodex-bridge/bin/remodex.js`
- `phodex-bridge/src/bridge.js`
- `phodex-bridge/src/gemini-transport.js`
- `phodex-bridge/src/gemini-protocol-adapter.js`
- `phodex-bridge/src/local-relay.js`
- `phodex-bridge/src/git-handler.js`

## Status Summary

At the current state of the project, the Gemini backend is real, substantial, and useful, but still not fully closed out.

The repository already contains:

- backend selection
- Gemini preflight
- Gemini relay split
- Gemini ACP transport
- thread persistence and restore
- per-thread cwd support
- model and mode switching
- multimodal input handling
- Gemini git drafting integration

The remaining work is mostly around live runtime correctness, UI/event reliability, and shutdown hygiene rather than around basic backend existence.
