# Remodex Standalone Multi-Provider Architecture

This document explains how Remodex can become a standalone mobile client for
multiple local agent providers, without depending on dpcode.cc and without
requiring a new desktop GUI application.

It is based on a read-only audit of:

- The Remodex local-first architecture.
- The `phodex-bridge` runtime bridge.
- The Remodex iOS JSON-RPC and thread/turn pipeline.
- The local t3code/DP Code repository provider architecture.
- The current OpenCode server, SDK, CLI, and permission model.

The short version:

Remodex is already standalone at the transport and local-hosting layer. It is
not yet natively multi-provider at the runtime protocol layer. Today, the bridge
speaks a Codex-shaped application protocol. To support OpenCode, Claude,
Gemini, Cursor, or other runtimes, Remodex should add a runtime adapter layer
inside the local bridge and gradually introduce a provider-neutral Remodex
contract above JSON-RPC.

## Executive Summary

Remodex does not need to stay attached to dpcode.cc.

It also does not need a full desktop application to become multi-provider.

The existing local bridge can become the provider host:

```text
iPhone Remodex
  -> relay / E2EE / pairing
  -> local Mac bridge
  -> RuntimeAdapter
       -> Codex adapter
       -> OpenCode adapter
       -> Claude adapter
       -> Gemini adapter
       -> future providers
```

The best first implementation path is:

1. Keep Codex as the default runtime.
2. Add OpenCode as a second runtime inside `phodex-bridge`.
3. Make the OpenCode adapter emit the same thread, turn, item, approval, and
   model events that the current iOS app already understands.
4. Add a feature flag such as `REMODEX_PROVIDER=opencode` for the first version.
5. Later add a real provider picker in iOS and a provider-neutral bridge
   contract.

This gives Remodex a practical standalone path without copying all of t3code and
without building a desktop app.

## Current Remodex Architecture

Remodex is already local-first.

The important pieces are:

- iOS app: mobile UI, thread list, turn composer, timeline, approvals, terminal
  surfaces, local connection state.
- Relay: forwards encrypted messages between the phone and the local Mac bridge.
- Secure transport: handles pairing, encrypted application payloads, and trusted
  device state.
- `phodex-bridge`: local Mac process that owns the connection to the runtime.
- Codex runtime: currently launched as `codex app-server` or connected through a
  WebSocket endpoint.

At a high level:

```text
Remodex iOS
  -> Secure JSON-RPC payload
  -> relay
  -> secure transport in phodex-bridge
  -> bridge-owned handlers or Codex transport
  -> codex app-server
```

The relay and encrypted transport are mostly provider-agnostic. They do not need
to know whether the final runtime is Codex, OpenCode, Claude, or something else.

The provider-specific part starts at the bridge/runtime boundary.

Relevant Remodex files:

- `phodex-bridge/src/bridge.js`
- `phodex-bridge/src/codex-transport.js`
- `phodex-bridge/src/git-handler.js`
- `phodex-bridge/src/workspace-handler.js`
- `phodex-bridge/src/project-handler.js`
- `CodexMobile/CodexMobile/Models/RPCMessage.swift`
- `CodexMobile/CodexMobile/Services/CodexService+Transport.swift`
- `CodexMobile/CodexMobile/Services/CodexService+Incoming.swift`
- `CodexMobile/CodexMobile/Services/CodexService+ThreadsTurns.swift`
- `CodexMobile/CodexMobile/Services/CodexService+RuntimeConfig.swift`
- `CodexMobile/CodexMobile/Models/CodexThread.swift`
- `CodexMobile/CodexMobile/Models/CodexModelOption.swift`

## What Is Already Provider-Agnostic

Several parts of Remodex can be reused almost unchanged for a multi-provider
future.

### Relay

The relay forwards application payloads. It should stay dumb and opaque.

It should not learn about providers, models, turns, messages, or tool calls.

That is good architecture. A provider-neutral relay keeps the self-hosted and
local-first model clean.

### Secure Transport

The pairing, trusted device, secure application payload, and reconnect flow are
not inherently Codex-specific.

This means the same phone-to-Mac secure channel can carry:

- Codex protocol messages.
- Remodex canonical messages.
- OpenCode-normalized messages.
- Future provider-normalized messages.

### JSON-RPC Envelope

The iOS `RPCMessage` model is mechanically generic. The envelope can carry any
method and params shape.

The naming is Codex-oriented, but the transport mechanism itself does not force
Codex.

### Local Project, Workspace, and Git Handlers

The bridge-owned handlers for local projects, workspaces, files, and Git are
mostly provider-independent.

Those should remain in the bridge rather than moving into every provider
adapter.

The caveat is the AI-assisted Git helpers. Some of them call `codex exec`
directly today. Those should eventually move behind a small
`StructuredJsonGenerator` abstraction so Codex, OpenCode, or another provider
can generate commit titles, stack titles, and summaries.

## What Is Codex-Specific Today

Remodex is not yet natively multi-provider because many higher-level assumptions
are Codex-shaped.

### Runtime Launch

The current transport creates a Codex runtime by launching or connecting to
Codex:

- `codex app-server`
- bundled Codex desktop app binary fallback
- WebSocket transport compatible with the Codex app server

This lives primarily in `phodex-bridge/src/codex-transport.js`.

### Application Protocol

The bridge forwards most unknown application messages to the Codex runtime.

That means the bridge expects the runtime to understand methods such as:

- `thread/list`
- `thread/read`
- `thread/start`
- `thread/resume`
- `thread/turns/list`
- `turn/start`
- `turn/interrupt`
- `model/list`
- approval and user-input item methods

And it expects notifications shaped like:

- `thread/*`
- `turn/*`
- `item/*`
- `codex/event/*`

OpenCode does not naturally speak this protocol. Claude Code, Gemini CLI, and
other agent runtimes will not naturally speak it either.

### iOS Runtime Defaults

iOS runtime selection is currently model-centric and OpenAI/Codex-biased.

Examples:

- Default model values such as GPT-style model IDs.
- Reasoning effort options shaped around Codex/OpenAI concepts.
- Service tier support.
- Sandbox and approval policy mappings built for Codex semantics.

This does not block an OpenCode MVP if the bridge normalizes OpenCode into
Codex-shaped responses, but it does block a polished multi-provider product.

### Account, Auth, and Voice

Account status and voice transcription are currently OpenAI/ChatGPT-oriented.

For a multi-provider future, auth and voice should be capabilities:

- Codex provider may expose ChatGPT/OpenAI account status.
- OpenCode provider may expose provider auth status through OpenCode.
- Some providers may have no account concept visible to Remodex.
- Voice transcription should be a separate optional capability, not implicitly
  tied to Codex auth.

### History and Storage

Some fallback history behavior is tied to Codex session JSONL files and
`CODEX_HOME`.

This should eventually become a `RuntimeHistoryStore` abstraction:

- Codex can keep using Codex session files.
- OpenCode can use OpenCode sessions/messages.
- Providers without history APIs can use bridge-owned local storage.

## Why dpcode.cc Is Not Required

dpcode/t3code is useful as a reference architecture, not as a required backend.

t3code already solved a broader version of the provider problem:

- It has provider kinds such as Codex, OpenCode, Claude Agent, Gemini, Cursor,
  Kilo, and others.
- It defines provider runtime events.
- It has provider adapters with a common shape.
- It has an OpenCode runtime that starts or connects to `opencode serve`.
- It translates provider-specific events into a canonical event stream.

But Remodex should not import the entire t3code architecture.

What Remodex should borrow:

- The provider adapter seam.
- The OpenCode runtime launch/connect logic.
- The OpenCode event mapping ideas.
- The model/provider discovery flow.
- The permission/user-input mapping.

What Remodex should avoid copying:

- The full web UI.
- The full SQL/read-model/persistence architecture.
- Effect layers and queues if they would make the bridge heavier than needed.
- DP Code server assumptions.
- Hosted-service assumptions.

Remodex already has the local mobile/bridge/relay architecture. It needs a
smaller provider layer, not a second product architecture.

## OpenCode Integration Model

OpenCode is a good first non-Codex provider because it already exposes a
programmatic server and SDK.

According to the current OpenCode documentation:

- `opencode serve` starts a headless HTTP server.
- The server exposes an OpenAPI endpoint.
- The server supports Server-Sent Events for event streaming.
- The JS/TS SDK provides a typed client for controlling the server.
- The server supports sessions, async prompts, message reads, aborts, provider
  listing, provider auth, and permission responses.
- Basic auth can be configured through `OPENCODE_SERVER_PASSWORD`.

Relevant official docs:

- https://opencode.ai/docs/server/
- https://opencode.ai/docs/sdk/
- https://opencode.ai/docs/cli/
- https://opencode.ai/docs/permissions/
- https://opencode.ai/docs/acp/

### Preferred OpenCode Path

Use the OpenCode server plus SDK.

Do not use the TUI as the integration boundary.

Do not make `opencode run` the main long-lived Remodex runtime. It is useful for
batch commands and structured helper tasks, but it is not ideal for Remodex's
interactive mobile thread experience.

The bridge should either:

1. Start `opencode serve` itself on localhost, or
2. Connect to an already-running OpenCode server.

For an MVP, starting a managed local server is simpler for users.

```text
phodex-bridge
  -> start opencode serve
  -> create SDK client
  -> create/reuse OpenCode session
  -> subscribe to OpenCode events
  -> normalize events for iOS
```

### OpenCode API Concepts To Map

OpenCode conceptually provides:

- Providers and models.
- Sessions.
- Messages.
- Async prompts.
- Abort.
- Permission responses.
- Session messages/history.
- Events.

Remodex/Codex-shaped concepts:

- Models.
- Threads.
- Turns.
- Items.
- Approvals.
- User input requests.
- Thread reads/history pages.
- Runtime notifications.

The adapter has to translate between those worlds.

## Proposed RuntimeAdapter Interface

Add a provider-neutral adapter layer inside `phodex-bridge`.

The interface should be intentionally small at first.

```js
/**
 * RuntimeAdapter is the bridge-owned boundary between Remodex and an agent
 * runtime. Codex can be implemented as a mostly pass-through adapter; OpenCode
 * and future providers translate into the Remodex/Codex-compatible event shape.
 */
type RuntimeAdapter = {
  id: string
  displayName: string
  capabilities: RuntimeCapabilities

  start(): Promise<void>
  shutdown(): Promise<void>

  send(rawJsonRpcMessage: string): void
  onMessage(handler: (rawJsonRpcMessage: string) => void): void
  onError(handler: (error: Error) => void): void
  onClose(handler: () => void): void
}
```

This mirrors the shape of the current Codex transport so the bridge can adopt it
without a huge rewrite.

Longer term, the adapter should expose structured methods instead of raw
JSON-RPC strings:

```js
type RuntimeAdapter = {
  listModels(): Promise<ModelListResult>
  startThread(input: StartThreadInput): Promise<ThreadStartResult>
  readThread(input: ReadThreadInput): Promise<ThreadReadResult>
  listThreadTurns(input: ListTurnsInput): Promise<ListTurnsResult>
  startTurn(input: StartTurnInput): Promise<TurnStartResult>
  interruptTurn(input: InterruptTurnInput): Promise<void>
  respondToApproval(input: ApprovalResponseInput): Promise<void>
  respondToUserInput(input: UserInputResponseInput): Promise<void>
  subscribe(handler: (event: RuntimeEvent) => void): () => void
}
```

But the raw transport-compatible interface is the safer migration step.

## Runtime Capability Descriptor

Each provider should declare capabilities so iOS and the bridge do not rely on
hardcoded Codex assumptions.

Example:

```json
{
  "id": "opencode",
  "displayName": "OpenCode",
  "supportsModels": true,
  "supportsReasoningEffort": false,
  "supportsServiceTier": false,
  "supportsApprovals": true,
  "supportsSandboxPolicy": true,
  "supportsThreadFork": true,
  "supportsTurnPagination": true,
  "supportsHistoryRead": true,
  "supportsInterrupt": true,
  "supportsVoiceTranscription": false,
  "supportsProviderAuthStatus": true
}
```

This lets Remodex hide or adapt UI affordances per provider:

- Reasoning controls only where supported.
- Service tier only for Codex/OpenAI-like providers.
- Fork controls only where supported.
- Voice only where configured.
- Approval policy controls mapped per provider.

## MVP OpenCode Adapter

The first real milestone should be an OpenCode adapter that preserves the
existing iOS contract.

The goal is not to rename every `CodexService` type yet.

The goal is:

```text
iOS sends the same methods as today.
Bridge routes to OpenCode adapter.
OpenCode adapter translates.
iOS receives the same kind of events as today.
```

### MVP Method Mapping

| Remodex/Codex-shaped method | OpenCode action |
| --- | --- |
| `model/list` | Read OpenCode providers/models |
| `thread/start` | Create OpenCode session |
| `thread/read` | Read OpenCode session and messages |
| `thread/resume` | Rebind bridge state to OpenCode session |
| `thread/turns/list` | Return paginated OpenCode messages |
| `turn/start` | Send async prompt to OpenCode session |
| `turn/interrupt` | Abort OpenCode session |
| approval response item methods | Reply to OpenCode permission request |
| user input response item methods | Reply to OpenCode question/input request |

### MVP Event Mapping

| OpenCode event/message | Remodex event |
| --- | --- |
| Session created | `thread/started` |
| Async prompt accepted | `turn/started` |
| Assistant text delta | `item/updated` or content delta event normalized to timeline item |
| Tool call started | `item/started` |
| Tool call updated | `item/updated` |
| Tool call completed | `item/completed` |
| Permission requested | `item/commandExecution/requestApproval` or provider-neutral approval item |
| Question/user input requested | `item/tool/requestUserInput` |
| Prompt completed | `turn/completed` |
| Prompt failed | `turn/failed` or normalized error response |
| Session aborted | `turn/interrupted` |

The exact event names should match what iOS currently handles in
`CodexService+Incoming.swift` for the MVP.

### MVP State Mapping

The bridge needs local runtime state:

```json
{
  "threads": {
    "remodex-thread-id": {
      "providerId": "opencode",
      "providerSessionId": "opencode-session-id",
      "cwd": "/Users/example/project",
      "model": {
        "provider": "anthropic",
        "model": "claude-sonnet-4-5"
      },
      "activeTurnId": "remodex-turn-id"
    }
  }
}
```

This should live in bridge-owned local state, not in the relay.

It must not log bearer-like pairing identifiers, session secrets, or provider
tokens.

## Provider Selection Strategy

There are two reasonable stages.

### Stage 1: Bridge Feature Flag

Use an environment variable or local bridge config:

```bash
REMODEX_PROVIDER=opencode remodex up
```

or:

```bash
remodex up --provider opencode
```

At this stage:

- iOS does not need a full provider picker.
- The bridge exposes OpenCode models through `model/list`.
- The current selected model logic can remain mostly intact.
- Codex remains the default.

This is the fastest path to prove the integration.

### Stage 2: Provider-Aware Models

Extend the model list returned to iOS.

Current model objects are mostly model-centric. They should become
provider-aware:

```json
{
  "id": "opencode:anthropic/claude-sonnet-4-5",
  "providerId": "opencode",
  "upstreamProviderId": "anthropic",
  "model": "claude-sonnet-4-5",
  "displayName": "Claude Sonnet 4.5",
  "description": "OpenCode via Anthropic",
  "capabilities": {
    "reasoningEfforts": [],
    "supportsFastMode": false,
    "supportsServiceTier": false
  }
}
```

iOS can then show:

- Provider picker.
- Model picker filtered by provider.
- Runtime capability-aware controls.

### Stage 3: Provider Per Thread

Each thread should store its runtime provider.

Remodex already has a useful `modelProvider` field in `CodexThread`, but a real
multi-provider system should persist:

- `providerId`
- `providerDisplayName`
- `modelId`
- `upstreamProviderId`
- provider session/thread ID
- capability snapshot at creation time

This prevents a thread created with OpenCode from accidentally resuming through
Codex or another runtime.

## Standalone Without a Desktop App

A background desktop GUI is not required.

What Remodex needs is a local background process. It already has one:
`phodex-bridge`.

The product choices are:

### Option A: CLI-managed daemon

This is closest to what Remodex already has.

```bash
remodex up
```

The CLI starts:

- local bridge
- secure pairing state
- runtime adapter
- Codex or OpenCode runtime

Pros:

- Simple.
- Local-first.
- No desktop GUI required.
- Matches the current Remodex mental model.

Cons:

- User must understand that a background process exists.
- Provider status/config UI is limited unless exposed on iOS.

### Option B: launchd background service

The CLI installs a macOS LaunchAgent.

Pros:

- Better reconnect behavior.
- More app-like for users.
- Still no desktop GUI.

Cons:

- More lifecycle edge cases.
- Needs clear logs/status commands.

### Option C: small menu bar app

This is optional, not required.

Pros:

- Friendly provider/account status.
- Easy start/stop/reconnect controls.
- Easier QR pairing access.

Cons:

- More product surface.
- More build/release work.
- Not necessary for the OpenCode MVP.

Recommended path:

1. Keep CLI/daemon as the primary runtime host.
2. Make provider configuration possible through CLI and local config.
3. Add a menu bar app only if users need a friendlier status/config surface.

## Security Model

The multi-provider design should preserve Remodex's local-first guarantees.

### Relay Must Stay Opaque

The relay should not inspect:

- Provider IDs.
- Model IDs.
- Prompt content.
- Tool calls.
- Files.
- Session IDs.

It should only forward encrypted payloads.

### Provider Servers Should Bind Locally

OpenCode should run on localhost by default.

Recommended:

- Bind to `127.0.0.1`.
- Use a random or configured local port.
- Use Basic Auth if exposing beyond localhost.
- Do not expose the OpenCode server to the LAN unless explicitly requested.

### Do Not Log Secrets

Do not log:

- relay session IDs
- pairing secrets
- provider API keys
- OpenCode server passwords
- provider auth tokens
- full prompt payloads unless explicitly in debug mode

### Approval Policy Must Be Conservative

Do not map Remodex "full access" into provider-level "allow everything" without
being explicit.

Suggested mapping:

- Default mode: ask for risky file/shell/network actions.
- Full access mode: allow only the action categories the user explicitly enabled.
- Read-only mode: deny writes and shell mutations.

For OpenCode, permission rules should be generated deliberately from the Remodex
access mode rather than using permissive defaults.

## iOS Impact

The iOS app does not need to be rewritten for the MVP.

### Can Stay Mostly As-Is

- JSON-RPC envelope.
- Secure transport.
- Thread list plumbing.
- Turn start plumbing.
- Incoming event handling, if the bridge normalizes events.
- Approval UI, if OpenCode permission requests are mapped into existing approval
  request items.
- Timeline rendering, if event shape remains compatible.

### Needs Small Changes For MVP Polish

- Avoid hardcoded GPT defaults when provider is OpenCode.
- Display provider labels more clearly.
- Hide unsupported controls such as service tier if the provider does not
  support them.
- Make model IDs provider-qualified to avoid collisions.

### Needs Larger Changes For True Multi-Provider

- Rename or wrap `CodexService` behind a provider-neutral service layer.
- Add provider-aware model selection.
- Add provider capability-driven UI.
- Persist provider identity per thread.
- Support provider-specific auth/status panels.

The important product decision: do not start by renaming every Codex-named type.
That is expensive and risky. Start by adding a bridge adapter and preserving the
current iOS contract.

## Bridge Impact

Most of the real work belongs in `phodex-bridge`.

### New Components

Recommended new files:

- `src/runtime-adapter.js`
- `src/runtime-router.js`
- `src/runtimes/codex-adapter.js`
- `src/runtimes/opencode-adapter.js`
- `src/runtime-state.js`
- `src/runtime-capabilities.js`

The exact names can vary, but the separation matters.

### Runtime Router

The bridge needs a router that decides which adapter owns a message.

For the MVP:

- One active provider per bridge process is acceptable.
- `REMODEX_PROVIDER=codex` remains default.
- `REMODEX_PROVIDER=opencode` routes all runtime calls to OpenCode.

For true multi-provider:

- Route by thread ID.
- Store `threadId -> providerId`.
- New threads use the selected provider/model.
- Existing threads resume through their original provider.

### Codex Adapter

The Codex adapter should initially wrap the current `createCodexTransport`
behavior.

This keeps existing behavior stable while introducing the adapter seam.

### OpenCode Adapter

The OpenCode adapter should:

- Start or connect to `opencode serve`.
- Create an SDK client.
- List providers/models.
- Create sessions.
- Send async prompts.
- Subscribe to events.
- Read session messages.
- Abort sessions.
- Respond to permission requests.
- Normalize events to the existing iOS event protocol.

### Runtime State

Runtime state should include:

- provider ID
- provider session ID
- Remodex thread ID
- cwd
- model selection
- active turn ID
- pending approval IDs
- pending user input IDs

This state should be local to the Mac and should not leak through logs.

## Proposed Remodex Canonical Protocol

The long-term clean architecture is a Remodex protocol between iOS and the
bridge, with provider adapters below it.

Canonical request methods:

- `runtime/list`
- `runtime/capabilities`
- `model/list`
- `thread/list`
- `thread/create`
- `thread/read`
- `thread/resume`
- `thread/delete`
- `turn/start`
- `turn/interrupt`
- `turn/list`
- `approval/respond`
- `input/respond`
- `workspace/list`
- `workspace/read`
- `git/status`
- `git/diff`

Canonical events:

- `runtime/statusChanged`
- `thread/created`
- `thread/updated`
- `turn/started`
- `turn/contentDelta`
- `turn/completed`
- `turn/failed`
- `item/created`
- `item/updated`
- `item/completed`
- `approval/requested`
- `input/requested`
- `tool/started`
- `tool/updated`
- `tool/completed`

Migration strategy:

1. Keep current Codex-shaped methods as compatibility aliases.
2. Add bridge-side canonical events internally.
3. Have Codex and OpenCode adapters emit canonical events.
4. Convert canonical events to legacy iOS events until iOS migrates.
5. Gradually update iOS to consume canonical events directly.

## Implementation Roadmap

### Phase 0: Audit and Contracts

Status: mostly done by this analysis.

Deliverables:

- Identify Codex-specific boundaries.
- Identify provider-agnostic parts.
- Define runtime adapter shape.
- Define OpenCode MVP mapping.

### Phase 1: Adapter Seam With No Behavior Change

Goal: introduce the adapter layer while keeping Codex behavior identical.

Work:

- Wrap existing Codex transport in `CodexRuntimeAdapter`.
- Add `RuntimeRouter`.
- Keep Codex as the only active adapter.
- Preserve all current bridge methods and event forwarding.
- Add focused Node tests around routing/pass-through behavior.

Risk:

- Low if done as a wrapper.

### Phase 2: OpenCode MVP Behind Feature Flag

Goal: Remodex can talk to OpenCode without iOS redesign.

Work:

- Add `@opencode-ai/sdk`.
- Start/connect to `opencode serve`.
- Implement model list.
- Implement thread/session create.
- Implement turn/prompt send.
- Implement event subscription.
- Implement interrupt.
- Implement read/history.
- Map permissions into existing approval UI.
- Gate with `REMODEX_PROVIDER=opencode`.

Risk:

- Medium. Event mapping and permission mapping need careful testing.

### Phase 3: Provider-Aware iOS Model Picker

Goal: user can choose provider and model from the app.

Work:

- Extend model schema with `providerId`.
- Add provider grouping in model picker.
- Hide unsupported runtime controls by capability.
- Persist provider per thread.
- Display provider identity in thread metadata.

Risk:

- Medium. UI state and thread resume behavior must be precise.

### Phase 4: Provider-Neutral Protocol

Goal: Remodex no longer depends on Codex method names as the canonical contract.

Work:

- Add canonical Remodex runtime methods/events.
- Keep backward compatibility aliases.
- Migrate iOS gradually.
- Move Codex-specific account/history/voice behind capabilities.

Risk:

- Medium to high depending on how broad the rename becomes.

### Phase 5: More Providers

Goal: add Claude, Gemini, Cursor, or other runtimes.

Work:

- Add one adapter at a time.
- Avoid broad provider framework changes until OpenCode proves the adapter
  contract.
- Make provider quirks explicit in capabilities.

Risk:

- Depends on provider API quality.

## What To Take From t3code

t3code is valuable because it already expresses provider runtimes as adapters.

Useful concepts to borrow:

- `ProviderKind`
- provider runtime event union
- adapter shape with `startSession`, `sendTurn`, `interruptTurn`, approvals,
  user input, thread reads, model list, and event stream
- OpenCode server process management
- OpenCode SDK client creation
- OpenCode model/provider discovery
- OpenCode permission rule construction
- OpenCode session/message mapping

Do not copy the whole architecture.

Remodex does not need t3code's full server app, web GUI, SQL read model, or
Effect-heavy service graph for the first milestone.

## Risks And Edge Cases

### Event Shape Mismatch

OpenCode event granularity may not match Codex item events exactly.

Mitigation:

- Normalize into the subset iOS already renders reliably.
- Preserve raw provider event metadata for debugging.
- Add tests for text streaming, tool calls, approvals, failures, and aborts.

### Thread Identity

Codex threads and OpenCode sessions are different concepts.

Mitigation:

- Create Remodex-owned thread IDs.
- Store provider session IDs behind them.
- Never infer provider solely from model name.

### Model ID Collisions

Different providers may expose the same model names.

Mitigation:

- Use provider-qualified IDs such as `opencode:anthropic/claude-sonnet-4-5`.

### Approval Semantics

Codex and OpenCode may ask for permissions differently.

Mitigation:

- Normalize approval requests to a provider-neutral approval item.
- Keep provider raw IDs in bridge state.
- Map responses back to provider-specific APIs.

### History Gaps

Some providers may not expose enough history to reconstruct the exact Remodex
timeline.

Mitigation:

- Store normalized event history locally in the bridge.
- Prefer provider history where available.
- Mark unsupported pagination/fork behavior in capabilities.

### Provider Process Lifecycle

The bridge may need to start, stop, and recover provider servers.

Mitigation:

- Health-check provider server.
- Restart only when safe.
- Rehydrate active provider sessions after reconnect.
- Keep lifecycle logs redacted.

### Dependency Format

If the OpenCode SDK is ESM-only and the bridge remains CommonJS, direct imports
may fail.

Mitigation:

- Use dynamic `import("@opencode-ai/sdk")` inside the OpenCode adapter.
- Keep the adapter isolated.

## Recommended First PR Scope

The first implementation PR should be boring and small.

Recommended:

- Add runtime adapter wrapper for Codex.
- Add runtime router.
- Keep existing behavior as default.
- Add tests that prove current Codex routing still works.

Do not include OpenCode in the same PR unless the team wants a larger change.

Recommended second PR:

- Add OpenCode adapter behind `REMODEX_PROVIDER=opencode`.
- Implement model list, session create, prompt send, event stream, interrupt, and
  history.
- Add bridge tests with mocked OpenCode SDK/client.

Recommended third PR:

- Add provider-aware model schema and minimal iOS display improvements.

## Final Recommendation

Build Remodex as a standalone local provider host, not as a dpcode.cc client.

Use the existing bridge as the runtime host.

Use t3code as a reference for the provider adapter pattern.

Use OpenCode as the first non-Codex provider because it has a suitable headless
server and SDK.

Keep Codex as the default runtime while the adapter layer lands.

Normalize OpenCode into the current iOS event shape first, then evolve toward a
proper Remodex canonical protocol.

This path preserves the current local-first product, avoids a desktop app
requirement, and creates a realistic bridge toward OpenCode, Claude, Gemini, and
other providers.
