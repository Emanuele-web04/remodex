# Cursor CLI, SDK, ACP, and Provider Integration Notes

This document explains how Remodex can integrate Cursor as another runtime
provider alongside Codex and OpenCode.

It follows the same local-first provider-adapter thinking used in
`Docs/multi-provider-standalone-architecture.md`, but focuses only on Cursor's
available integration surfaces:

- Cursor CLI / `cursor-agent`.
- Cursor TypeScript SDK / `@cursor/sdk`.
- Cursor Background Agents API.
- Cursor MCP support.
- Agent Client Protocol, or ACP, as a possible adapter boundary.

The short version:

Cursor is useful for Remodex, but it is not shaped like OpenCode.

OpenCode gives us a local server plus SDK that naturally behaves like a
headless runtime. Cursor gives us multiple surfaces with different tradeoffs:

- The **Cursor SDK** is the best long-term integration surface if we want a
  programmatic provider adapter.
- The **Cursor CLI** is the fastest MVP path because it can run a prompt from a
  local checkout and stream JSON.
- The **Background Agents API** is powerful but cloud/GitHub-oriented, so it is
  not the right default for Remodex's local-first bridge.
- **ACP** is worth watching or supporting opportunistically, but it should not
  be the first Cursor integration unless Cursor's ACP surface is proven stable
  enough for our needs.

## Source Audit

This audit is based on:

- The existing Remodex multi-provider architecture document.
- The local Remodex bridge and iOS protocol assumptions described there.
- Cursor's official CLI documentation.
- Cursor's official TypeScript SDK documentation.
- Cursor's official Background Agents API documentation.
- Cursor's official MCP documentation.
- Cursor's official docs for rules, memories, privacy, and enterprise setup.
- The current npm package metadata for `@cursor/sdk`.
- The public Cursor SDK skill bundle from Cursor's marketplace/plugin repo.
- The public Agent Client Protocol specification and Zed ACP documentation.

Relevant links:

- https://cursor.com/docs/cli/overview
- https://cursor.com/docs/cli/reference
- https://cursor.com/docs/cli/installation
- https://cursor.com/docs/cli/authentication
- https://cursor.com/docs/cli/using
- https://cursor.com/docs/cli/configuration
- https://cursor.com/docs/cli/headless
- https://cursor.com/docs/cli/output-format
- https://cursor.com/docs/cli/mcp
- https://cursor.com/docs/cli/hooks
- https://cursor.com/docs/api/sdk/typescript
- https://cursor.com/docs/background-agent/api
- https://cursor.com/docs/context/mcp
- https://cursor.com/docs/context/rules
- https://cursor.com/docs/context/memories
- https://cursor.com/docs/account/privacy
- https://cursor.com/docs/enterprise/cli
- https://www.npmjs.com/package/@cursor/sdk
- https://github.com/cursor/plugins
- https://github.com/cursor/cookbook
- https://agentclientprotocol.com/overview/introduction
- https://zed.dev/docs/assistant/model-context-protocol
- https://zed.dev/docs/extensions/agent-client-protocol

## Executive Summary

Cursor should be treated as a separate provider adapter, not as a drop-in
replacement for Codex app-server or OpenCode serve.

The recommended architecture is:

```text
Remodex iOS
  -> relay / E2EE / pairing
  -> phodex-bridge
  -> RuntimeAdapter
       -> Codex adapter
       -> OpenCode adapter
       -> Cursor adapter
            -> SDK path, preferred long term
            -> CLI path, fastest MVP
            -> Background Agents API path, optional cloud mode
```

The Cursor adapter should normalize Cursor sessions, prompts, events, command
execution, and model metadata into the same Remodex runtime contract used by the
OpenCode adapter.

Do not wire Cursor directly into iOS.

Do not make the relay understand Cursor.

Do not make Cursor the owner of Remodex local project/workspace metadata.

Keep Cursor behind the bridge adapter boundary.

## Cursor Is Not OpenCode

OpenCode is a clean fit for Remodex because it has:

- A local headless server.
- An HTTP API.
- Server-Sent Events.
- A typed SDK against that server.
- Provider/model APIs.
- Permission APIs.

Cursor has a different shape:

- A CLI that can run headless prompts.
- A TypeScript SDK for Cursor agents.
- A cloud Background Agents API for GitHub-backed tasks.
- MCP support for tools and external context.
- Rules and memories as context layers.
- Privacy modes and enterprise controls.

This means the Cursor adapter has to choose a primary surface.

The best default is:

1. Use the Cursor SDK when possible.
2. Fall back to the Cursor CLI for an MVP or where the SDK does not expose the
   needed stream/control surface.
3. Keep Background Agents API as a separate optional remote provider mode.
4. Treat ACP as an interoperability path, not the default Cursor path.

## Cursor Integration Surfaces

### Surface 1: Cursor CLI

Cursor ships a CLI that can run an agent from the terminal.

Cursor's docs describe:

- Installation through Cursor itself, npm, curl, Homebrew, or Linux package
  managers.
- `cursor-agent` as the agent command.
- `cursor` and `cursor-agent` command names, with a documented migration toward
  `agent` as the preferred invocation in newer CLI docs.
- Interactive and non-interactive prompt execution.
- Output formats including text, JSON, and stream JSON.
- MCP configuration and inspection.
- Hooks.
- Authentication through browser login or API key.

The CLI is a good MVP because the bridge can spawn it like it spawns Codex
today.

Example conceptual call:

```bash
cursor-agent -p "Implement the requested change" --output-format stream-json
```

or, depending on installed CLI version:

```bash
agent -p "Implement the requested change" --output-format stream-json
```

For Remodex, the bridge should discover the installed command in this order:

1. Explicit bridge config, such as `REMODEX_CURSOR_BIN`.
2. `agent`.
3. `cursor-agent`.
4. `cursor` subcommand path, if the installed CLI supports it.

Do not hardcode a single binary name.

### Surface 2: Cursor TypeScript SDK

Cursor publishes `@cursor/sdk`, described by npm as "TypeScript SDK for Cursor
agents." At audit time, npm reports:

```json
{
  "package": "@cursor/sdk",
  "version": "1.0.13",
  "description": "TypeScript SDK for Cursor agents",
  "types": "./dist/esm/index.d.ts",
  "main": "./dist/cjs/index.js"
}
```

The SDK documentation and package README show concepts such as:

- `Agent`.
- `Cursor`.
- `Cursor.models.list()`.
- `Agent.create(...)`.
- model aliases such as `composer-latest`.
- local agents.
- cloud agents.
- resuming agents.
- prompting agents.
- disposing agents.

Conceptual example:

```ts
import { Agent, Cursor } from "@cursor/sdk"

const models = await Cursor.models.list()
const agent = await Agent.create({
  model: { id: "composer-latest" },
})

const response = await agent.prompt("Summarize this repository")
await agent.dispose()
```

The exact method signatures should be verified against the installed SDK types
when implementation starts, but the important architectural point is clear:

The SDK is a real programmatic boundary. It is a better long-term Remodex
adapter target than scraping CLI text output.

### Surface 3: Cursor Background Agents API

Cursor exposes a Background Agents API for creating and controlling background
agents remotely.

This is not the same thing as a local Cursor runtime.

The Background Agents API is useful when:

- The task is GitHub-backed.
- The user wants Cursor's cloud/background agent infrastructure.
- Remodex is allowed to send the task to Cursor's remote service.
- A local-first guarantee is not required for that task.

It is not ideal as the default Remodex provider because:

- It is remote.
- It depends on Cursor account/API auth.
- It is oriented around GitHub repository state.
- It does not naturally share Remodex's local bridge lifecycle.

Treat it as:

```text
providerId = "cursor-background"
executionEnvironment = "cloud"
```

not as:

```text
providerId = "cursor-local"
executionEnvironment = "local"
```

### Surface 4: Cursor MCP

Cursor supports MCP servers.

MCP is not the Cursor agent protocol itself. It is a way to give Cursor tools
and context.

For Remodex:

- Do not use MCP as the primary Remodex-to-Cursor transport.
- Do use MCP config awareness so Cursor agents have the same local tools the
  user expects.
- Expose MCP status in provider diagnostics where possible.
- Avoid duplicating MCP config logic in iOS.

The bridge should own any MCP config discovery or validation needed for the
provider card.

### Surface 5: ACP

ACP usually means Agent Client Protocol.

ACP is a JSON-RPC-style protocol intended to connect editors/clients to agent
servers in a standardized way. Zed documents ACP as the bridge used by its
assistant panel to communicate with external coding agents.

ACP is interesting for Remodex because it resembles the thing we want:

```text
client UI
  -> common agent protocol
  -> arbitrary coding agent runtime
```

But for Cursor specifically, ACP should be treated carefully:

- Cursor's strongly documented public surfaces today are CLI, SDK, Background
  Agents API, and MCP.
- ACP may be available through particular agent binaries, editor integrations,
  or ecosystem tools, but it should not be assumed as Cursor's primary stable
  public API without implementation-time verification.
- If Cursor exposes a robust ACP server mode, Remodex can add a generic ACP
  adapter later and Cursor can plug into it.

The recommended plan is:

1. Build Cursor provider through SDK or CLI first.
2. Keep `acp-adapter` as a future generic adapter.
3. Do not block Cursor support on ACP.

## Recommended Cursor Path For Remodex

### Best First MVP

Use Cursor CLI in non-interactive/headless mode.

Why:

- It is closest to how the current Codex bridge already launches runtimes.
- It avoids needing to fully understand SDK lifecycle edge cases before proving
  value.
- It can stream structured output.
- It can run against the local working directory.
- It can be feature-flagged behind `REMODEX_PROVIDER=cursor`.

The MVP would be:

```text
phodex-bridge
  -> CursorCliAdapter
  -> spawn cursor-agent / agent
  -> stream-json parser
  -> normalize to Remodex thread/turn/item events
```

This is enough to prove:

- Can Remodex start a Cursor turn?
- Can it show streamed assistant output?
- Can it show tool/command progress?
- Can it interrupt a running task?
- Can it preserve enough history for mobile timeline?

### Best Long-Term Path

Use `@cursor/sdk`.

Why:

- It is typed.
- It can list models.
- It exposes Cursor agent concepts directly.
- It should be more stable than parsing CLI output.
- It can support local and cloud agents with one adapter family.

Long term:

```text
phodex-bridge
  -> CursorSdkAdapter
  -> @cursor/sdk
  -> Agent.create / Agent.resume / Agent.prompt
  -> normalize SDK events/results to Remodex events
```

### Optional Cloud Path

Add a separate Cursor Background provider later.

This should not share the same provider ID as local Cursor.

Suggested IDs:

- `cursor-cli`
- `cursor-sdk-local`
- `cursor-background`

or, if we want user-facing simplicity:

- display: `Cursor`
- internal runtime IDs:
  - `cursor.local.cli`
  - `cursor.local.sdk`
  - `cursor.cloud.background`

## Provider Capability Descriptor

Cursor needs a capability descriptor because not all Cursor surfaces support the
same features.

### Cursor CLI Capability Draft

```json
{
  "id": "cursor-cli",
  "displayName": "Cursor CLI",
  "executionEnvironment": "local",
  "transport": "stdio-process",
  "supportsModels": true,
  "supportsModelAliases": true,
  "supportsReasoningEffort": false,
  "supportsServiceTier": false,
  "supportsApprovals": "cli-dependent",
  "supportsSandboxPolicy": "cli-dependent",
  "supportsThreadFork": false,
  "supportsTurnPagination": "bridge-owned",
  "supportsHistoryRead": "bridge-owned",
  "supportsInterrupt": true,
  "supportsMCP": true,
  "supportsProviderAuthStatus": true,
  "supportsVoiceTranscription": false
}
```

### Cursor SDK Capability Draft

```json
{
  "id": "cursor-sdk",
  "displayName": "Cursor",
  "executionEnvironment": "local-or-cloud",
  "transport": "typescript-sdk",
  "supportsModels": true,
  "supportsModelAliases": true,
  "supportsReasoningEffort": false,
  "supportsServiceTier": false,
  "supportsApprovals": "sdk-dependent",
  "supportsSandboxPolicy": "sdk-dependent",
  "supportsThreadFork": "unknown",
  "supportsTurnPagination": "bridge-owned-or-sdk-dependent",
  "supportsHistoryRead": "sdk-dependent",
  "supportsInterrupt": true,
  "supportsMCP": true,
  "supportsProviderAuthStatus": true,
  "supportsVoiceTranscription": false
}
```

### Cursor Background Capability Draft

```json
{
  "id": "cursor-background",
  "displayName": "Cursor Background Agent",
  "executionEnvironment": "cloud",
  "transport": "https-api",
  "supportsModels": true,
  "supportsModelAliases": true,
  "supportsReasoningEffort": false,
  "supportsServiceTier": false,
  "supportsApprovals": "api-dependent",
  "supportsSandboxPolicy": false,
  "supportsThreadFork": false,
  "supportsTurnPagination": true,
  "supportsHistoryRead": true,
  "supportsInterrupt": true,
  "supportsMCP": false,
  "supportsProviderAuthStatus": true,
  "supportsVoiceTranscription": false
}
```

## Cursor RuntimeAdapter Shape

Cursor should implement the same bridge-level interface proposed for OpenCode.

Initial raw transport-compatible shape:

```js
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

Better structured shape:

```js
type CursorRuntimeAdapter = {
  listModels(): Promise<ModelListResult>
  startThread(input: StartThreadInput): Promise<ThreadStartResult>
  readThread(input: ReadThreadInput): Promise<ThreadReadResult>
  listThreadTurns(input: ListTurnsInput): Promise<ListTurnsResult>
  startTurn(input: StartTurnInput): Promise<TurnStartResult>
  interruptTurn(input: InterruptTurnInput): Promise<void>
  respondToApproval(input: ApprovalResponseInput): Promise<void>
  subscribe(handler: (event: RuntimeEvent) => void): () => void
}
```

For the first Cursor CLI adapter, the bridge can maintain most state itself.

For the SDK adapter, the bridge can map Remodex thread IDs to Cursor agent IDs
or session IDs.

## Cursor CLI Adapter Design

### Process Lifecycle

The Cursor CLI adapter should be process-per-turn at first.

```text
turn/start
  -> spawn cursor-agent
  -> stream output
  -> map output events to Remodex items
  -> exit
  -> turn/completed or turn/failed
```

Do not start with one long-lived Cursor CLI process unless the CLI explicitly
supports a stable daemon/session protocol. Process-per-turn is easier to
control and easier to kill.

### Command Discovery

Pseudo-code:

```js
async function resolveCursorAgentBinary(config) {
  if (config.cursorBin) return config.cursorBin
  for (const name of ["agent", "cursor-agent"]) {
    if (await commandExists(name)) return name
  }
  throw new Error("Cursor CLI not found. Install Cursor CLI or set REMODEX_CURSOR_BIN.")
}
```

### Spawn Shape

Pseudo-code:

```js
const child = spawn(cursorBin, [
  "-p",
  prompt,
  "--output-format",
  "stream-json",
], {
  cwd,
  env: buildCursorEnv(process.env, runtimeConfig),
  stdio: ["ignore", "pipe", "pipe"],
})
```

The exact flags should be verified against the installed CLI version. The
adapter should have a CLI capability check:

```bash
cursor-agent --help
agent --help
```

### Stream JSON Mapping

Cursor stream JSON should be parsed line-by-line.

The adapter should not assume one final JSON blob.

Suggested internal parser:

```js
class CursorCliStreamParser {
  push(chunk) {
    // split by newline, parse complete JSON lines, preserve partial line
  }
}
```

Then normalize:

```text
Cursor stream event
  -> RuntimeEvent
  -> Codex-compatible JSON-RPC notification for current iOS
```

### Interrupt

`turn/interrupt` should:

1. Send `SIGINT` to the child.
2. Wait a short grace period.
3. Send `SIGTERM`.
4. On Windows, use process-tree kill behavior like the Codex bridge already
   learned to do.

The adapter should emit:

```text
turn/interrupted
```

or whatever event iOS currently expects for a stopped turn.

### History

The CLI may not expose enough structured persistent history for Remodex's exact
timeline.

For MVP, use bridge-owned history:

```json
{
  "threadId": "remodex-thread-id",
  "providerId": "cursor-cli",
  "cwd": "/Users/example/project",
  "turns": [
    {
      "turnId": "remodex-turn-id",
      "prompt": "User request",
      "cursorRunId": "process-start-time-or-cli-id",
      "items": []
    }
  ]
}
```

This is less elegant than Codex JSONL or OpenCode sessions, but it keeps the app
working while we learn the Cursor runtime.

## Cursor SDK Adapter Design

The SDK adapter should be the real long-term target.

### SDK Import

The bridge is currently Node/CommonJS-heavy. npm metadata says `@cursor/sdk`
exports both CJS and ESM entrypoints, so direct `require("@cursor/sdk")` may
work. Still, the adapter can be defensive:

```js
async function loadCursorSdk() {
  try {
    return require("@cursor/sdk")
  } catch {
    return await import("@cursor/sdk")
  }
}
```

### Model Listing

Use `Cursor.models.list()` and convert Cursor model records to Remodex model
options.

Suggested model ID format:

```text
cursor:composer-latest
cursor:<cursor-model-id>
```

Keep aliases:

```json
{
  "id": "cursor:composer-latest",
  "providerId": "cursor-sdk",
  "displayName": "Cursor Composer Latest",
  "rawModelId": "composer-latest",
  "aliases": ["composer-latest"]
}
```

Do not let `composer-latest` collide with models from Codex, OpenCode, Claude,
or Gemini.

### Agent Lifecycle

Conceptually:

```js
const { Agent, Cursor } = await loadCursorSdk()

const agent = await Agent.create({
  model: { id: rawModelId },
})

const result = await agent.prompt(prompt)
```

Bridge state:

```json
{
  "threadId": "remodex-thread-id",
  "providerId": "cursor-sdk",
  "cursorAgentId": "sdk-agent-id-if-exposed",
  "model": "composer-latest",
  "cwd": "/Users/example/project"
}
```

If the SDK supports resume:

```js
const agent = await Agent.resume(cursorAgentId)
```

If local agents require explicit workspace/root settings, the adapter should
always pass `cwd` or equivalent settings from Remodex.

### Streaming

Implementation-time question:

Does `Agent.prompt(...)` expose streaming events, or only a final result?

If streaming exists, map deltas directly.

If only final results exist, the SDK adapter can still be correct, but the
mobile timeline will be less lively:

```text
turn/started
item/started assistant-message
item/completed assistant-message
turn/completed
```

If Cursor SDK has both sync and streaming APIs, prefer streaming.

### Disposal

Always dispose local SDK agents when the Remodex thread/session is done, unless
the SDK documents persistent local sessions that should survive.

```js
try {
  await agent.dispose()
} catch (error) {
  logger.warn("cursor agent dispose failed", safeError(error))
}
```

Do not dispose an agent in the middle of a foreground/background bridge
reconnect unless the user actually closes/stops the task.

## Background Agents API Adapter Design

Cursor Background Agents API should be a separate provider mode.

The bridge should not silently route local tasks to cloud agents.

### Required Inputs

Background agents likely need:

- Cursor API key.
- Repository.
- Branch or target ref.
- Prompt.
- Optional model.
- Optional environment/setup config.

Remodex local-only `cwd` is not enough. The adapter must map a local workspace
to a GitHub repository/ref.

### API Flow

Conceptual:

```text
turn/start
  -> POST create background agent
  -> store Cursor agent ID / run ID
  -> poll or stream status
  -> map messages/status to Remodex items
```

Follow-ups:

```text
turn/start on existing thread
  -> POST followup to existing Cursor background agent/run
```

Interrupt:

```text
turn/interrupt
  -> call Cursor cancel/interrupt endpoint if available
```

### Local-First Warning

The UI should label this clearly:

```text
Cursor Background Agent
Runs in Cursor cloud against a GitHub repo.
```

Do not present it as a local runtime.

## ACP Adapter Design

ACP should be considered a generic future adapter, not a Cursor-only adapter.

Target shape:

```text
phodex-bridge
  -> AcpRuntimeAdapter
  -> external ACP-compatible agent server
       -> Cursor-compatible agent, Zed-compatible agent, or other tool
```

This could be useful because Remodex wants exactly this kind of editor-agnostic
agent boundary.

### Why ACP Is Attractive

ACP gives a potential standard for:

- Sessions.
- Prompts.
- Agent responses.
- Tool calls.
- Client-agent JSON-RPC transport.
- Editor/client independence.

If Remodex implements ACP once, it may support multiple future agent runtimes
without building a custom adapter for each one.

### Why ACP Should Not Be First

ACP is a protocol layer, not proof that Cursor exposes all Cursor-specific
agent features through ACP today.

The first Cursor adapter should use surfaces Cursor documents directly:

- SDK.
- CLI.
- Background Agents API.

ACP can be a later win.

## Mapping To Remodex Concepts

### Thread Mapping

Remodex thread:

```json
{
  "id": "remodex-thread-id",
  "providerId": "cursor-sdk",
  "providerThreadId": "cursor-agent-or-session-id",
  "cwd": "/Users/example/project",
  "model": "cursor:composer-latest"
}
```

Cursor CLI may not have persistent provider thread IDs, so bridge-owned thread
IDs are mandatory there.

### Turn Mapping

Remodex turn:

```json
{
  "id": "remodex-turn-id",
  "providerTurnId": "cursor-run-id-or-process-id",
  "status": "running",
  "startedAt": "2026-05-22T00:00:00.000Z"
}
```

### Item Mapping

| Cursor concept | Remodex item |
| --- | --- |
| assistant text | assistant message item |
| code edit summary | assistant message or tool result item |
| command/tool call | command execution item |
| command output | command output delta |
| permission prompt | approval item |
| final result | turn completed item/update |
| error | turn failed item/update |

### Model Mapping

Cursor model options should be provider-qualified.

Examples:

```text
cursor:composer-latest
cursor:auto
cursor:<raw-model-id>
```

Raw Cursor model ID and aliases should be preserved:

```json
{
  "id": "cursor:composer-latest",
  "rawProvider": "cursor",
  "rawModelId": "composer-latest",
  "aliases": ["composer-latest"]
}
```

Never store only `composer-latest` in Remodex shared model state.

## Permissions And Approvals

Cursor can run commands and edit files.

Remodex must not blindly map a broad mobile permission mode into "allow all"
Cursor behavior.

Recommended MVP:

- Start Cursor CLI/SDK in the safest practical approval mode.
- Surface command/tool approval requests if the chosen Cursor surface exposes
  them.
- If a surface does not expose interactive approval requests, force a more
  conservative mode or label that surface as "autonomous run".

Provider capability:

```json
{
  "supportsApprovals": "partial",
  "approvalMode": "provider-controlled"
}
```

Bridge rule:

```text
Never grant Cursor broader filesystem or command rights than the user selected
in Remodex.
```

## Auth And Account Status

Cursor auth is separate from Codex/OpenAI auth.

The bridge should support:

- CLI login status detection.
- API key environment variable/config for CLI or Background Agents API.
- SDK auth status if exposed.
- Enterprise team/API-key setup if the user is on Cursor Enterprise.

Suggested bridge status:

```json
{
  "providerId": "cursor-sdk",
  "status": "authenticated",
  "accountLabel": "Cursor",
  "authMethod": "cli-login-or-api-key"
}
```

Do not store Cursor API keys in iOS local state.

Do not send Cursor API keys through the relay unless absolutely necessary. The
local bridge should own provider credentials.

## MCP And Tools

Cursor has MCP support at the CLI/editor level.

Remodex should not duplicate MCP setup UI in the first implementation.

The adapter should expose read-only diagnostics:

```json
{
  "providerId": "cursor-cli",
  "mcp": {
    "supported": true,
    "servers": [
      {
        "name": "filesystem",
        "status": "enabled"
      }
    ]
  }
}
```

Cursor CLI MCP commands can be used by the bridge for diagnostics:

```bash
cursor-agent mcp list
cursor-agent mcp list-tools <server>
```

or the equivalent `agent mcp ...` command for newer installs.

The exact command should be discovered from `--help`.

## Rules, Memories, And Context

Cursor has rules and memories.

For Remodex:

- Treat Cursor rules as provider-owned context.
- Do not convert Remodex project metadata into Cursor rules in MVP.
- Do not edit Cursor memories from iOS unless explicitly building that feature.
- Show a note in provider diagnostics if project rules are detected.

This keeps the first integration from unexpectedly changing a user's Cursor
environment.

## Security And Privacy

Cursor provider modes have different privacy implications.

### Local CLI / Local SDK

Local-first-ish, but the Cursor model calls still go through Cursor/provider
services according to the user's Cursor configuration.

Remodex should label it:

```text
Runs from your Mac using your Cursor CLI/SDK configuration.
```

### Background Agents API

Remote.

Remodex should label it:

```text
Runs in Cursor cloud against your GitHub repository.
```

### Logging

Do not log:

- Cursor API keys.
- Cursor auth tokens.
- raw provider session secrets.
- relay session IDs.
- pairing IDs.
- command output that might contain secrets, unless already part of the user's
  visible timeline and handled by existing redaction rules.

## Error Handling

Cursor adapter errors should become provider-neutral user messages.

Examples:

| Raw error | User-facing Remodex error |
| --- | --- |
| binary not found | Cursor CLI is not installed or not in PATH. |
| not authenticated | Cursor is not authenticated on this Mac. |
| API key missing | Cursor API key is missing for this provider mode. |
| unsupported output format | Installed Cursor CLI is too old for stream JSON. |
| process killed | Cursor turn was interrupted. |
| non-zero exit | Cursor run failed. See output for details. |
| cloud repo missing | Cursor Background Agent needs a GitHub-backed repository. |

## Implementation Plan

### Phase 0: Keep OpenCode First

OpenCode is still the cleaner first non-Codex provider because it has a local
server/SDK shape.

Do not let Cursor delay OpenCode.

### Phase 1: Cursor CLI Spike

Goal: prove Cursor can run from Remodex through the bridge.

Tasks:

1. Add `src/runtimes/cursor-cli-adapter.js`.
2. Add binary discovery.
3. Add `cursor-agent --help` / `agent --help` capability probe.
4. Add process-per-turn execution.
5. Parse stream JSON output.
6. Map assistant text and final result to Remodex items.
7. Implement interrupt.
8. Gate with `REMODEX_PROVIDER=cursor-cli`.

Expected scope:

- No iOS provider picker yet.
- No background agents yet.
- Bridge-owned history.
- Basic model selection only if CLI exposes model list cleanly.

### Phase 2: Cursor SDK Adapter

Goal: replace CLI parsing with typed SDK calls where possible.

Tasks:

1. Add optional dependency `@cursor/sdk`.
2. Add `src/runtimes/cursor-sdk-adapter.js`.
3. Implement `Cursor.models.list()` mapping.
4. Implement local `Agent.create`.
5. Implement `Agent.prompt`.
6. Implement resume if SDK exposes stable agent IDs.
7. Implement dispose/shutdown behavior.
8. Compare stream support against CLI.

Expected scope:

- Better model support.
- Better provider status.
- Cleaner tests with mocked SDK.

### Phase 3: Provider-Aware iOS UI

Goal: let the user pick Cursor intentionally.

Tasks:

1. Add provider metadata to model options.
2. Group models by provider.
3. Persist provider per thread.
4. Show provider label in terminal/thread metadata.
5. Hide unsupported controls based on capability descriptor.

### Phase 4: Cursor Background Agents

Goal: optional cloud Cursor mode.

Tasks:

1. Add provider ID `cursor-background`.
2. Add API key config.
3. Add GitHub repository/ref mapping.
4. Implement create/follow-up/status/cancel API calls.
5. Clearly label cloud execution in iOS.

### Phase 5: Generic ACP Adapter

Goal: support ACP-compatible agents as a reusable provider class.

Tasks:

1. Add `src/runtimes/acp-adapter.js`.
2. Implement ACP transport.
3. Map ACP session/prompt/tool events to Remodex events.
4. Test against one known ACP-compatible runtime.
5. Only then consider routing Cursor through ACP if Cursor exposes a stable ACP
   server mode.

## Testing Strategy

### Cursor CLI Tests

Mock child process output:

- assistant text stream.
- tool call stream.
- error output.
- non-zero exit.
- interrupted process.
- malformed JSON line.
- partial JSON line split across chunks.

### Cursor SDK Tests

Mock `@cursor/sdk`:

- `Cursor.models.list`.
- `Agent.create`.
- `Agent.resume`.
- `agent.prompt`.
- `agent.dispose`.
- auth/model errors.

### Integration Tests

Use a fake adapter first:

```text
turn/start
  -> fake Cursor assistant delta
  -> fake command item
  -> fake completion
```

Then add an opt-in local integration test requiring Cursor CLI installed.

Do not make Cursor installed/authenticated a required test dependency.

## Key Unknowns To Verify During Implementation

These should be answered by checking the installed Cursor CLI and SDK types at
implementation time:

- Exact current CLI binary name and flag set.
- Whether `agent` or `cursor-agent` is preferred on the user's machine.
- Exact stream JSON event schema.
- Whether the CLI exposes model listing in machine-readable form.
- Whether CLI command approvals can be externally answered.
- Whether SDK `Agent.prompt` streams or returns only final results.
- Whether SDK exposes stable agent/session IDs for resume.
- Whether SDK local agents accept an explicit workspace/cwd.
- Whether Background Agents API supports streaming status or only polling for
  the account tier in use.
- Whether Cursor exposes a stable ACP server mode suitable for Remodex.

## Recommendation

Add Cursor after OpenCode, but design the adapter now.

The best order is:

1. Implement the provider adapter seam.
2. Add OpenCode as the first full non-Codex provider.
3. Add Cursor CLI as a fast local spike.
4. Add Cursor SDK as the durable Cursor adapter.
5. Add Cursor Background Agents only as an explicit cloud provider.
6. Add ACP later as a generic adapter, not as the first Cursor path.

Cursor is absolutely viable for Remodex, but it should not be treated as one
thing.

Use three provider modes:

```text
cursor-cli          local process MVP
cursor-sdk          preferred programmatic local/provider adapter
cursor-background   explicit cloud/GitHub-backed mode
```

That keeps Remodex honest:

- local stays local;
- cloud is labeled cloud;
- SDK stays typed;
- CLI stays a pragmatic fallback;
- ACP remains a future interoperability layer.

