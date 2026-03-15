<p align="center">
  <img src="CodexMobile/CodexMobile/Assets.xcassets/remodex-og.imageset/remodex-og2%20(1).png" alt="Remodex" />
</p>

# Remodex

[![npm version](https://img.shields.io/npm/v/remodex)](https://www.npmjs.com/package/remodex)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[Follow on X](https://x.com/emanueledpt)

Control [Codex](https://openai.com/index/codex/) from your iPhone. Remodex is a local-first open-source bridge + iOS app that keeps the Codex runtime on your Mac and lets your phone connect through a paired secure session.

## Key App Features

- End-to-end encrypted pairing and chats between your iPhone and Mac
- Fast mode for lower-latency turns
- Plan mode for structured planning before execution
- Steer active runs without starting over
- Queue follow-up prompts while a turn is still running
- In-app notifications when turns finish or need attention
- Git actions from your phone, including commit, push, pull, and branch switching
- Reasoning controls to tune how much thinking Codex uses
- Access controls with On-Request or Full access
- Photo attachments from camera or library
- QR pairing for a live bridge session
- Live streaming on your phone while Codex runs on your Mac
- Shared thread history with Codex on your Mac

The repo stays local-first and self-host friendly: the iOS app source does not embed a public hosted endpoint, and the transport layer remains inspectable for anyone who wants to run their own setup.

If you want the public-repo distribution model explained clearly, read [SELF_HOSTING_MODEL.md](SELF_HOSTING_MODEL.md).

> **I am very early in this project. Expect bugs.**
>
> I am not actively accepting contributions yet. If you still want to help, read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Get the App

Build the iOS app from source in Xcode, install your own signed build on-device, then use the in-app onboarding flow to pair by scanning the QR from `remodex up`.

If you scan the pairing QR with a generic camera or QR reader before installing the app, your device may treat the QR payload as plain text and open a web search instead of pairing.

## Architecture

```
┌──────────────┐       Paired session   ┌───────────────┐       stdin/stdout       ┌─────────────┐
│  Remodex iOS │ ◄────────────────────► │ remodex (Mac) │ ◄──────────────────────► │ codex       │
│  app         │    WebSocket bridge    │ bridge        │    JSON-RPC              │ app-server  │
└──────────────┘                        └───────────────┘                          └─────────────┘
                                               │                                         │
                                               │  AppleScript route bounce                │ JSONL rollout
                                               ▼                                         ▼
                                        ┌─────────────┐                           ┌─────────────┐
                                        │  Codex.app  │ ◄─── reads from ──────── │  ~/.codex/  │
                                        │  (desktop)  │      disk on navigate     │  sessions   │
                                        └─────────────┘                           └─────────────┘
```

1. Run `remodex up` on your Mac — a QR code appears in the terminal
2. Scan it with the Remodex iOS app to pair
3. Your phone sends instructions to Codex through the bridge and receives responses in real-time
4. The bridge handles git operations and local session persistence on your Mac
5. `Codex.app` can read the same thread history from disk, but it is not a true live mirror unless you enable the optional refresh workaround

## Repository Structure

This repo contains the local bridge, the iOS app target, and their tests:

```
├── phodex-bridge/                # Node.js bridge package used by `remodex`
│   ├── bin/                      # CLI entrypoints
│   └── src/                      # Bridge runtime, git/workspace handlers, refresh helpers
├── CodexMobile/                  # Xcode project root
│   ├── CodexMobile/              # App source target
│   │   ├── Services/             # Connection, sync, incoming-event, git, and persistence logic
│   │   ├── Views/                # SwiftUI screens and timeline/sidebar components
│   │   ├── Models/               # RPC, thread, message, and UI models
│   │   └── Assets.xcassets/      # App icons and UI assets
│   ├── CodexMobileTests/         # Unit tests
│   ├── CodexMobileUITests/       # UI tests
│   └── BuildSupport/             # Info.plist, xcconfig defaults, and local override templates
```

## Prerequisites

- **Node.js** v18+
- **[Codex CLI](https://github.com/openai/codex)** installed and in your PATH
- **[Codex desktop app](https://openai.com/index/codex/)** (optional — for viewing threads on your Mac)
- **A signed Remodex iOS build** installed on your iPhone or iPad before scanning the pairing QR
- **macOS** (for desktop refresh features — the core bridge works on any OS)
- **Xcode 16+** (only if building the iOS app from source)

## Install the Bridge

<sub>Install from npm with `@latest` so you always get the newest bridge fixes.</sub>

```sh
npm install -g remodex@latest
```

To update an existing global install later:

```sh
npm install -g remodex@latest
```

If you only want to try Remodex, you can install it from npm and run it without cloning this repository.

## Quick Start

Install the bridge, then run:

```sh
remodex up
```

Open the Remodex app, follow the onboarding flow, then scan the QR code from inside the app and start coding.

## Run Locally

```sh
git clone https://github.com/Emanuele-web04/remodex.git
cd remodex
./run-local-remodex.sh
```

That launcher starts a local pairing endpoint, points the bridge at `ws://<your-host>:9000/relay`, and prints the pairing QR for the iPhone app.

Options:

- `./run-local-remodex.sh --hostname <lan-hostname-or-ip>`
- `./run-local-remodex.sh --bind-host 127.0.0.1 --port 9100`

If your iPhone is pairing over LAN, use a hostname or IP the phone can actually reach.

## Custom Pairing Endpoint

For a full public self-hosting walkthrough, see [`Docs/self-hosting.md`](Docs/self-hosting.md).

If you want the npm bridge to point at your own setup instead of the built-in default, override `REMODEX_RELAY` explicitly:

```sh
REMODEX_RELAY="ws://localhost:9000/relay" remodex up
```

Reverse-proxy subpaths work too, so a hosted relay behind Traefik can live under the same domain as other APIs:

```sh
REMODEX_RELAY="wss://api.example.com/remodex/relay" remodex up
```

In that setup, the public endpoints can look like this:

- `wss://api.example.com/remodex/relay`
- `https://api.example.com/remodex/v1/push/session/register-device`
- `https://api.example.com/remodex/v1/push/session/notify-completion`

Have the proxy strip `/remodex` before forwarding so the relay still receives `/relay/...` and `/v1/push/...`.

If you point `REMODEX_RELAY` at your own self-hosted relay, managed push stays off unless you also set `REMODEX_PUSH_SERVICE_URL` on the bridge and explicitly enable push on the relay.

You can also run the bridge from source:

```sh
cd phodex-bridge
npm install
REMODEX_RELAY="ws://localhost:9000/relay" npm start
```

## Commands

### `remodex up`

Starts the bridge:

- Spawns `codex app-server` (or connects to an existing endpoint)
- Connects the Mac bridge to the paired session endpoint
- Displays a fresh QR code for the current bridge launch
- Forwards JSON-RPC messages bidirectionally
- Handles git commands from the phone
- Persists the active thread for later resumption

### `remodex reset-pairing`

Clears the saved bridge pairing state so the next `remodex up` starts a fresh QR pairing flow.

```sh
remodex reset-pairing
# => [remodex] Cleared the saved pairing state. Run `remodex up` to pair again.
```

### `remodex resume`

Reopens the last active thread in Codex.app on your Mac.

```sh
remodex resume
# => [remodex] Opened last active thread: abc-123 (phone)
```

### `remodex watch [threadId]`

Tails the event log for a thread in real-time.

```sh
remodex watch
# => [14:32:01] Phone: "Fix the login bug in auth.ts"
# => [14:32:05] Codex: "I'll look at auth.ts and fix the login..."
# => [14:32:18] Task started
# => [14:33:42] Task complete
```

## Environment Variables

`REMODEX_RELAY` is optional, but the default depends on how you got Remodex:

- public GitHub/source checkouts stay open-source and self-host friendly, so they do not ship with a hosted relay baked in
- official published packages may include a default relay at publish time
- if you are running from source, assume you should use `./run-local-remodex.sh` or set `REMODEX_RELAY` yourself

| Variable | Default | Description |
|----------|---------|-------------|
| `REMODEX_RELAY` | empty in source checkouts; optional in published packages | Session base URL used for QR pairing and phone/Mac session routing |
| `REMODEX_PUSH_SERVICE_URL` | disabled by default | Optional HTTP base URL for managed push registration/completion |
| `REMODEX_CODEX_ENDPOINT` | — | Connect to an existing Codex WebSocket instead of spawning a local `codex app-server` |
| `REMODEX_REFRESH_ENABLED` | `false` | Auto-refresh Codex.app when phone activity is detected (`true` enables it explicitly) |
| `REMODEX_REFRESH_DEBOUNCE_MS` | `1200` | Debounce window (ms) for coalescing refresh events |
| `REMODEX_REFRESH_COMMAND` | — | Custom shell command to run instead of the built-in AppleScript refresh |
| `REMODEX_CODEX_BUNDLE_ID` | `com.openai.codex` | macOS bundle ID of the Codex app |
| `CODEX_HOME` | `~/.codex` | Codex data directory (used here for `sessions/` rollout files) |

```sh
# Enable desktop refresh explicitly
REMODEX_REFRESH_ENABLED=true remodex up

# Connect to an existing Codex instance
REMODEX_CODEX_ENDPOINT=ws://localhost:8080 remodex up

# Use a custom self-hosted pairing endpoint (`ws://` is unencrypted)
REMODEX_RELAY="ws://localhost:9000/relay" remodex up

# Enable managed push only if your self-hosted relay also exposes a configured APNs push service
REMODEX_RELAY="wss://relay.example/relay" \
REMODEX_PUSH_SERVICE_URL="https://relay.example" \
remodex up
```

On the relay/VPS side, keep push disabled until you actually want it. The HTTP push endpoints are off by default and only turn on when you set `REMODEX_ENABLE_PUSH_SERVICE=true`.

## Pairing and Safety

- Remodex is local-first: Codex, git operations, and workspace actions run on your Mac, while the iPhone acts as a paired remote control.
- The pairing QR carries the connection URL, the session ID, and the bridge identity key used to bootstrap end-to-end encryption. After a successful scan, the iPhone stores that pairing in Keychain and the bridge persists its trusted device identity locally on the Mac.
- The iPhone stores pairing metadata in Keychain, but you should not rely on hands-free reconnect across bridge restarts or fresh runs. In practice, expect to scan a fresh QR code when you start a new bridge session.
- The bridge state lives canonically in `~/.remodex/device-state.json` with local-only permissions. On macOS the bridge also mirrors that state to Keychain as best-effort backup/migration data.
- The CLI no longer prints the connection URL in plain text below the QR.
- Set `REMODEX_RELAY` only when you want to self-host or test locally against your own setup.
- Leave `REMODEX_TRUST_PROXY` unset for direct/self-hosted installs. Turn it on only when a trusted reverse proxy such as Traefik, Nginx, or Caddy is forwarding the relay traffic.
- The transport implementation is public in [`relay/`](relay/), but your real deployed hostname and credentials should stay private.
- On the iPhone, the default agent permission mode is `On-Request`. Switching the app to `Full access` auto-approves runtime approval prompts from the agent.

## Security and Privacy

Remodex now uses an authenticated end-to-end encrypted channel between the paired iPhone and the bridge running on your Mac. The transport layer still carries the WebSocket traffic, but it does not get the plaintext contents of prompts, tool calls, Codex responses, git output, or workspace RPC payloads once the secure session is established.

The secure channel is built in these steps:

1. The bridge generates and persists a long-term device identity keypair on the Mac.
2. The pairing QR shares the connection URL, session ID, bridge device ID, bridge identity public key, and a short expiry window.
3. During pairing, the iPhone and bridge exchange fresh X25519 ephemeral keys and nonces.
4. The bridge signs the handshake transcript with its Ed25519 identity key, and the iPhone verifies that signature against the public key from the QR code or the previously trusted Mac record.
5. The iPhone signs a client-auth transcript with its own Ed25519 identity key, and the bridge verifies that before accepting the session.
6. Both sides derive directional AES-256-GCM keys with HKDF-SHA256 and then wrap application messages in encrypted envelopes with monotonic counters for replay protection.

Privacy notes:

- The transport layer can still see connection metadata and the plaintext secure control messages used to set up the encrypted session, including session IDs, device IDs, public keys, nonces, and handshake result codes.
- The transport layer does not see decrypted application payloads after the secure handshake succeeds.
- The iPhone currently trusts a single paired phone identity per Mac bridge state. Pairing a different iPhone requires `remodex reset-pairing` on the Mac first.
- On-device message history is also encrypted at rest on iPhone using a Keychain-backed AES key.

## Git Integration

The bridge intercepts `git/*` JSON-RPC calls from the phone and executes them locally:

| Command | Description |
|---------|-------------|
| `git/status` | Branch, tracking info, dirty state, file list, and diff |
| `git/commit` | Commit staged changes with an optional message |
| `git/push` | Push to remote |
| `git/pull` | Pull from remote (auto-aborts on conflict) |
| `git/branches` | List all branches with current/default markers |
| `git/checkout` | Switch branches |
| `git/createBranch` | Create and switch to a new branch |
| `git/log` | Recent commit history |
| `git/stash` | Stash working changes |
| `git/stashPop` | Pop the latest stash |
| `git/resetToRemote` | Hard reset to remote (requires confirmation) |
| `git/remoteUrl` | Get the remote URL and owner/repo |

## Workspace Integration

The bridge also handles local workspace-scoped revert operations for the assistant revert flow:

| Command | Description |
|---------|-------------|
| `workspace/revertPatchPreview` | Checks whether a reverse patch can be applied cleanly in the local repo |
| `workspace/revertPatchApply` | Applies the reverse patch locally when the preview succeeds |

## Codex Desktop App Integration

Remodex works with both the Codex CLI and the Codex desktop app (`Codex.app`). Under the hood, the bridge spawns a `codex app-server` process — the same JSON-RPC interface that powers the desktop app and IDE extensions. Conversations are persisted as JSONL rollout files under `~/.codex/sessions`, so threads started from your phone show up in the desktop app too.

What is live today:

- The iPhone conversation is live while the bridge session is connected.
- The Mac-side Codex runtime is the real runtime doing the work.

What is not fully live today:

- `Codex.app` does not act like a second live subscriber to the active run by default.
- The desktop app catches up from the persisted session files and can be nudged with the optional refresh workaround below.
- True phone-to-desktop live sync in the `Codex.app` GUI is not supported today.

To make that limitation more practical, Remodex also includes a hand-off button in the iPhone app. It lets you explicitly continue the current chat on your Mac by opening the matching thread in `Codex.app` when you are ready to switch devices.

**Known limitation**: The Codex desktop app does not live-reload when an external `app-server` process writes new data to disk. Threads created or updated from your phone won't appear in the desktop app until it remounts that route. Remodex keeps desktop refresh off by default for now because the current deep-link bounce is still disruptive. You can still enable it manually if you want the old remount workaround.

```sh
# Enable the old deep-link refresh workaround manually
REMODEX_REFRESH_ENABLED=true remodex up
```

This triggers a debounced deep-link bounce (`codex://settings` → `codex://threads/<id>`) that forces the desktop app to remount the current thread without interrupting any running tasks. While a turn is running, Remodex also watches the persisted rollout for that thread and issues occasional throttled refreshes so long responses become visible on Mac without a full app relaunch. If the local desktop path is unavailable, the bridge self-disables desktop refresh for the rest of that run instead of retrying noisily forever.

## Connection Resilience

- **Auto-reconnect**: If the session connection drops, the bridge reconnects with exponential backoff (1 s → 5 s max)
- **Secure catch-up**: The bridge keeps a bounded local outbound buffer and re-sends missed encrypted messages after a secure reconnect
- **Codex persistence**: The Codex process stays alive across transient session reconnects during the current bridge run
- **Graceful shutdown**: SIGINT/SIGTERM cleanly close all connections

## Building the iOS App

```sh
cd CodexMobile
open CodexMobile.xcodeproj
```

Build and run on a physical device or simulator with Xcode. The app uses SwiftUI and the current project target is iOS 18.6.

## Contributing

I'm not actively accepting contributions yet. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## FAQ

**Do I need an OpenAI API key?**
Not for Remodex itself. You need Codex CLI set up and working independently.

**Does this work on Linux/Windows?**
The core bridge client (Codex forwarding + git) works on any OS. Desktop refresh (AppleScript) is macOS-only.

**What happens if I close the terminal?**
The bridge stops. Run `remodex up` again to start a fresh QR pairing flow for that bridge session.

**How do I force a fresh QR pairing?**
Run `remodex reset-pairing`, then start the bridge again with `remodex up`.

**Can I connect to a remote Codex instance?**
Yes — set `REMODEX_CODEX_ENDPOINT=ws://host:port` to skip spawning a local `codex app-server`.

**Why don't my phone threads show up in the Codex desktop app immediately?**
The desktop app reads session data from disk (`~/.codex/sessions`) but doesn't live-reload when an external process writes new data. Your phone still gets the live stream; it is the desktop GUI that lags unless you explicitly enable the refresh workaround with `REMODEX_REFRESH_ENABLED=true`.

**Does Remodex support true live sync between phone and `Codex.app`?**
No. The phone session is live, but the `Codex.app` GUI is not a true live mirror of the active run. To help with that, the iPhone app includes a `Hand off to Mac app` button so you can explicitly continue the same thread on your Mac.

**Can I self-host the pairing server?**
Yes. That is the intended forking path. The transport and push-service code are in [`relay/`](relay/); point `REMODEX_RELAY` at the instance you run.

**Is the transport layer safe for sensitive work?**
It is much stronger than a plain text proxy: traffic can be protected in transit with TLS, application payloads are end-to-end encrypted after the secure handshake, and all Codex execution still happens on your Mac. The transport can still observe connection metadata and handshake control messages, so the tightest trust model is to run it yourself.

## License

[ISC](LICENSE)
