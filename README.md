<p align="center">
  <img src="CodexMobile/CodexMobile/Assets.xcassets/remodex-og.imageset/remodex-og2%20(1).png" alt="Remodex" />
</p>

# Remodex

[![npm version](https://img.shields.io/npm/v/remodex)](https://www.npmjs.com/package/remodex)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[Follow on X](https://x.com/emanueledpt)

Control [Codex](https://openai.com/index/codex/) from your iPhone. Remodex is a local-first open-source bridge + iOS app that keeps the Codex runtime on your Mac and lets your phone connect through a paired WebSocket relay session.

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
- QR pairing with automatic reconnect
- Shared thread history with Codex on your Mac

By default, the phone-to-Mac flow uses the hosted relay at `api.phodex.app`, but you can now run the same relay yourself on your LAN or on your own server.

Right now I'm letting people use the hosted relay for free while I test things and clean up the experience. Longer term, the open-source path is for self-hosted setups, and the App Store version is meant to cover the managed relay and ongoing maintenance.

The current TestFlight phase is free while I validate the app over the next few days. After that, the iOS app is planned to move to the App Store as a one-time paid app. That decision is mainly to help cover the cost of the VPS behind the pairing flow and the ongoing development/support needed to keep Remodex working well; final pricing will be shared separately.

> **I am very early in this project. Expect bugs.**
>
> I am not actively accepting contributions yet. If you still want to help, read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Get the App

Install the Remodex app from [TestFlight](https://testflight.apple.com/join/PKZhBUVM) before you run `remodex up`.

Once the app is installed, onboarding inside Remodex walks you through pairing and scanning the QR from inside the app.

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
4. The bridge handles git operations, desktop refresh, and session persistence locally

## Repository Structure

This is a monorepo with a local bridge, an iOS app target, and its tests:

```
├── phodex-bridge/                # Node.js bridge package used by `remodex`
│   ├── bin/                      # CLI entrypoints
│   └── src/                      # Bridge runtime, git/workspace handlers, refresh helpers
│
├── CodexMobile/                  # Xcode project root
│   ├── CodexMobile/              # App source target
│   │   ├── Services/             # Connection, sync, incoming-event, git, and persistence logic
│   │   ├── Views/                # SwiftUI screens and timeline/sidebar components
│   │   ├── Models/               # RPC, thread, message, and UI models
│   │   └── Assets.xcassets/      # App icons and UI assets
│   ├── CodexMobileTests/         # Unit tests
│   ├── CodexMobileUITests/       # UI tests
│   └── BuildSupport/             # Info.plist and build-time support files
```

## Prerequisites

- **Node.js** v18+
- **[Codex CLI](https://github.com/openai/codex)** installed and in your PATH
- **[Codex desktop app](https://openai.com/index/codex/)** (optional — for viewing threads on your Mac)
- **[Remodex iOS app via TestFlight](https://testflight.apple.com/join/PKZhBUVM)** installed on your iPhone or iPad before scanning the pairing QR
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

```sh
remodex up
```

Open the Remodex app, follow the onboarding flow, then scan the QR code from inside the app and start coding.

## Local Development

```sh
cd phodex-bridge
npm install
npm start
```

## Commands

### `remodex up`

Starts the bridge:

- Spawns `codex app-server` (or connects to an existing endpoint)
- Connects the Mac bridge to the relay session endpoint
- Displays a QR code for phone pairing
- Forwards JSON-RPC messages bidirectionally
- Handles git commands from the phone
- Persists the active thread for later resumption

### `remodex relay [--host HOST] [--port PORT]`

Starts a self-hosted relay server with HTTP health endpoints:

- Binds a WebSocket relay on `/relay/{sessionId}`
- Serves `GET /healthz` and `GET /stats`
- Prints LAN-reachable `ws://.../relay` URLs you can feed into `REMODEX_RELAY`

```sh
remodex relay --host 0.0.0.0 --port 9000
# => [remodex relay] reachable WebSocket URLs:
# => - ws://192.168.1.23:9000/relay
# => REMODEX_RELAY=ws://192.168.1.23:9000/relay remodex up
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

All optional. Sensible defaults are provided.

| Variable | Default | Description |
|----------|---------|-------------|
| `REMODEX_RELAY` | `wss://api.phodex.app/relay` | Relay base URL used for QR pairing and phone/Mac session routing |
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

# Use a custom relay endpoint (`ws://` is unencrypted)
REMODEX_RELAY=ws://localhost:9000/relay remodex up

# Run a relay on your LAN, then point the bridge at it
remodex relay --host 0.0.0.0 --port 9000
REMODEX_RELAY=ws://192.168.1.23:9000/relay remodex up
```

## Pairing and Safety

- Remodex is local-first: Codex, git operations, and workspace actions run on your Mac, while the iPhone acts as a paired remote control.
- The pairing QR now carries the relay base URL, the session ID, and the bridge identity key used to bootstrap end-to-end encryption. After a successful scan, the iPhone stores that pairing in Keychain and tries to reconnect automatically on relaunch or when the app returns to the foreground.
- The default relay is `wss://api.phodex.app/relay`, so the socket itself is protected with TLS in transit, and Remodex wraps application payloads in end-to-end encryption after the secure handshake completes.
- If you want to inspect or self-host the relay, the server code is available in [`relay/`](relay/) and the npm package now exposes `remodex relay` for local/LAN use.
- On the iPhone, the default agent permission mode is `On-Request`. Switching the app to `Full access` auto-approves runtime approval prompts from the agent.

## Self-Hosted Relay

For local testing on the same Wi-Fi or a trusted LAN:

```sh
# Terminal 1: run the relay on your Mac
remodex relay --host 0.0.0.0 --port 9000

# Terminal 2: point the bridge at the LAN IP that the relay command printed
REMODEX_RELAY=ws://192.168.1.23:9000/relay remodex up
```

Then open the Remodex iPhone app and scan the QR code from `remodex up` as usual. The QR payload includes your custom relay URL, so the iPhone reconnect path follows the same self-hosted endpoint.

For access outside your current Wi-Fi, you can also run the relay over Tailscale. As long as the iPhone and Mac are on the same tailnet, point `REMODEX_RELAY` at the Mac's Tailscale IP instead of its LAN IP:

```sh
# Terminal 1: run the relay on the Mac
remodex relay --host 0.0.0.0 --port 9000

# Terminal 2: use the Mac's Tailscale IPv4 address
REMODEX_RELAY=ws://100.x.y.z:9000/relay remodex up
```

Notes:

- `ws://` is fine for a trusted LAN. If you expose the relay beyond your LAN, put TLS in front of it and use `wss://.../relay`.
- `ws://` also works well over Tailscale because the tailnet transport is already encrypted, and Remodex still layers end-to-end encryption on top.
- The relay is still transport-only. Codex, git, and local file operations stay on your Mac.
- The relay health endpoint is `http://HOST:PORT/healthz`, and stats are available at `/stats`.

## Security and Privacy

Remodex now uses an authenticated end-to-end encrypted channel between the paired iPhone and the bridge running on your Mac. The relay still carries the WebSocket traffic, but it does not get the plaintext contents of prompts, tool calls, Codex responses, git output, or workspace RPC payloads once the secure session is established.

The secure channel is built in these steps:

1. The bridge generates and persists a long-term device identity keypair on the Mac.
2. The pairing QR shares the relay URL, session ID, bridge device ID, bridge identity public key, and a short expiry window.
3. During pairing, the iPhone and bridge exchange fresh X25519 ephemeral keys and nonces.
4. The bridge signs the handshake transcript with its Ed25519 identity key, and the iPhone verifies that signature against the public key from the QR code or the previously trusted Mac record.
5. The iPhone signs a client-auth transcript with its own Ed25519 identity key, and the bridge verifies that before accepting the session.
6. Both sides derive directional AES-256-GCM keys with HKDF-SHA256 and then wrap application messages in encrypted envelopes with monotonic counters for replay protection.

Privacy notes:

- The relay can still see connection metadata and the plaintext secure control messages used to set up the encrypted session, including session IDs, device IDs, public keys, nonces, and handshake result codes.
- The relay does not see decrypted application payloads after the secure handshake succeeds.
- The iPhone currently trusts a single paired phone identity per Mac bridge state. Pairing a different iPhone requires resetting pairing on the Mac first.
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

**Known limitation**: The Codex desktop app does not live-reload when an external `app-server` process writes new data to disk. Threads created or updated from your phone won't appear in the desktop app until it remounts that route. Remodex keeps desktop refresh off by default for now because the current deep-link bounce is still disruptive. You can still enable it manually if you want the old remount workaround.

```sh
# Enable the old deep-link refresh workaround manually
REMODEX_REFRESH_ENABLED=true remodex up
```

This triggers a debounced deep-link bounce (`codex://settings` → `codex://threads/<id>`) that forces the desktop app to remount the current thread without interrupting any running tasks. While a turn is running, Remodex also watches the persisted rollout for that thread and issues occasional throttled refreshes so long responses become visible on Mac without a full app relaunch. If the local desktop path is unavailable, the bridge self-disables desktop refresh for the rest of that run instead of retrying noisily forever.

## Connection Resilience

- **Auto-reconnect**: If the relay connection drops, the bridge reconnects with exponential backoff (1 s → 5 s max)
- **Secure catch-up**: The bridge keeps a bounded local outbound buffer and re-sends missed encrypted messages after a secure reconnect
- **Codex persistence**: The Codex process stays alive across relay reconnects
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
The core bridge (relay + Codex forwarding + git) works on any OS. Desktop refresh (AppleScript) is macOS-only.

**What happens if I close the terminal?**
The bridge stops. Run `remodex up` again — your phone will reconnect when it detects the relay session.

**Can I connect to a remote Codex instance?**
Yes — set `REMODEX_CODEX_ENDPOINT=ws://host:port` to skip spawning a local `codex app-server`.

**Why don't my phone threads show up in the Codex desktop app immediately?**
The desktop app reads session data from disk (`~/.codex/sessions`) but doesn't live-reload when an external process writes new data. Remodex keeps desktop refresh off by default for now because the current workaround bounces the Codex app route and can feel disruptive. If you still want that workaround, enable it explicitly with `REMODEX_REFRESH_ENABLED=true`.

**Can I self-host the relay server?**
Yes. The default hosted relay runs on my VPS, and the relay server code is available in [`relay/`](relay/) if you want to inspect it or run your own compatible relay. Then point Remodex at your relay with `REMODEX_RELAY`.

**Is the default hosted relay safe for sensitive work?**
For everyday use, it is now much stronger than a plain relay: traffic is protected in transit with TLS, application payloads are end-to-end encrypted after the secure handshake, and all Codex execution still happens on your Mac. The relay can still observe connection metadata and handshake control messages, so if you want the tightest control over routing and metadata exposure, set `REMODEX_RELAY` to a relay you run yourself.

## License

[ISC](LICENSE)
