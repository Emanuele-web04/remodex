<p align="center">
  <img src="assets/remodex-og.png" alt="Remodex" />
</p>

# Remodex

[![npm version](https://img.shields.io/npm/v/remodex)](https://www.npmjs.com/package/remodex)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)

Control [Codex](https://openai.com/index/codex/) from your iPhone. Remodex is a local-first open-source bridge + iOS app that keeps the Codex runtime on your Mac and lets your phone connect through a paired WebSocket relay session.

Right now, testing the full phone-to-Mac flow still depends on `relay.example.invalid`.

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

```sh
npm install -g remodex
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
| `REMODEX_RELAY` | `wss://relay.example.invalid/relay` | Relay base URL used for QR pairing and phone/Mac session routing |
| `REMODEX_CODEX_ENDPOINT` | — | Connect to an existing Codex WebSocket instead of spawning a local `codex app-server` |
| `REMODEX_REFRESH_ENABLED` | `false` | Auto-refresh Codex.app when phone activity is detected |
| `REMODEX_REFRESH_DEBOUNCE_MS` | `1200` | Debounce window (ms) for coalescing refresh events |
| `REMODEX_REFRESH_COMMAND` | — | Custom shell command to run instead of the built-in AppleScript refresh |
| `REMODEX_CODEX_BUNDLE_ID` | `com.openai.codex` | macOS bundle ID of the Codex app |
| `CODEX_HOME` | `~/.codex` | Codex data directory (used here for `sessions/` rollout files) |

```sh
# Enable desktop refresh
REMODEX_REFRESH_ENABLED=true remodex up

# Connect to an existing Codex instance
REMODEX_CODEX_ENDPOINT=ws://localhost:8080 remodex up

# Use a custom relay endpoint (`ws://` is unencrypted)
REMODEX_RELAY=ws://localhost:9000/relay remodex up
```

## Pairing and Safety

- Remodex is local-first: Codex, git operations, and workspace actions run on your Mac, while the iPhone acts as a paired remote control.
- The pairing QR contains the relay base URL and a random session ID. After a successful scan, the iPhone stores that pairing in Keychain and tries to reconnect automatically on relaunch or when the app returns to the foreground.
- The default relay is `wss://relay.example.invalid/relay`, so traffic is encrypted in transit with TLS. You can also point Remodex at your own relay if you prefer to keep routing fully under your control.
- On the iPhone, the default agent permission mode is `On-Request`. Switching the app to `Full access` auto-approves runtime approval prompts from the agent.

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

**Known limitation**: The Codex desktop app does not live-reload when an external `app-server` process writes new data to disk. Threads created or updated from your phone won't appear in the desktop app until you navigate away and back, or close and reopen the app. Remodex includes a built-in workaround: enable desktop refresh to have the bridge automatically bounce the Codex app's route via AppleScript after each turn completes.

```sh
# Auto-refresh Codex.app when phone activity is detected
REMODEX_REFRESH_ENABLED=true remodex up
```

This triggers a debounced deep-link bounce (`codex://settings` → `codex://threads/<id>`) that forces the desktop app to remount the current thread without interrupting any running tasks.

## Connection Resilience

- **Auto-reconnect**: If the relay connection drops, the bridge reconnects with exponential backoff (1 s → 5 s max)
- **Message buffering**: Messages are queued while the relay is disconnected and flushed on reconnect
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

**Why don't my phone threads show up in the Codex desktop app?**
The desktop app reads session data from disk (`~/.codex/sessions`) but doesn't live-reload when an external process writes new data. Navigate away and back, or enable `REMODEX_REFRESH_ENABLED=true` to have the bridge auto-refresh the desktop app after each turn.

**Can I self-host the relay server?**
Yes — set `REMODEX_RELAY` to your own relay base URL. Remodex works well as a local-first setup with a relay you control, and the default hosted relay is there if you want the quickest path to getting started.

**Is the default hosted relay safe for sensitive work?**
For everyday use, it is a practical default: traffic is protected in transit with TLS and all Codex execution still happens on your Mac. If you want the tightest control over routing, set `REMODEX_RELAY` to a relay you run yourself.

## License

[ISC](LICENSE)
