# Contributing to Remodex

I am not actively accepting contributions right now.

This project is very early. Things change fast, priorities shift, and I'm still figuring out the right direction. If you open a PR or issue, there's a good chance I close it, defer it, or never get to it. That's not personal — I just need to stay focused.

## If you still want to contribute

Read this whole file first.

### What I'm most likely to accept

- Small, focused bug fixes
- Small reliability or performance improvements
- Typo and documentation fixes

### What I'm least likely to accept

- Large PRs
- Drive-by feature work
- Opinionated rewrites or refactors
- Scope expansion I didn't ask for

### Before opening a PR

- **Open an issue first** for anything non-trivial. Describe the problem, not your solution.
- Keep changes minimal. One fix per PR.
- Explain exactly what changed and exactly why.
- If it touches UI, include a screenshot or video.

Opening a PR does not create an obligation on my side. I may close it. I may ignore it. I may take the idea and implement it differently. That's how early-stage projects work.

---

## Local Development Setup

### Prerequisites

- **Node.js** v18+
- **[Codex CLI](https://github.com/openai/codex)** installed and working
- **[Codex desktop app](https://openai.com/index/codex/)** (optional — for viewing threads on Mac)
- **macOS** (required for desktop refresh; core bridge works on any OS)
- **Xcode 16+** (only for building the iOS app)
- **iPhone** with the Remodex app (or built from source)

### Bridge setup

```sh
# Clone the repo
git clone https://github.com/Emanuele-web04/remodex.git
cd remodex/phodex-bridge

# Install dependencies
npm install

# Start the bridge
npm start
```

This runs `remodex up`, which:
1. Spawns a Codex `app-server` process
2. Connects to the default relay (`wss://relay.example.invalid/relay`) unless you override it
3. Prints a QR code in your terminal

Scan the QR code with the Remodex iOS app to pair.

### iOS app setup

```sh
cd CodexMobile
open CodexMobile.xcodeproj
```

1. Select your team in **Signing & Capabilities** (you'll need an Apple Developer account)
2. Pick a target device (physical iPhone or simulator)
3. Build and run (Cmd+R)

The app uses SwiftUI and the current project target is iOS 18.6. No CocoaPods or SPM dependencies — it's a standalone Xcode project.

### Testing a full local session

1. Start the bridge: `cd phodex-bridge && npm start`
2. Open the iOS app and scan the QR code
3. Create a new thread from the app
4. Send a message — you should see Codex respond in real-time
5. Try git operations from the phone (commit, push, branch switching)

### Environment variables

All optional. Override defaults as needed:

```sh
# Default relay (used when you do not override anything)
# REMODEX_RELAY=wss://relay.example.invalid/relay

# Connect to an existing Codex instance instead of spawning one
REMODEX_CODEX_ENDPOINT=ws://localhost:8080 npm start

# Use your own bridge session endpoint (`ws://` is unencrypted)
REMODEX_RELAY=ws://localhost:9000/relay npm start

# Enable auto-refresh of Codex.app on Mac
REMODEX_REFRESH_ENABLED=true npm start
```

### Project structure

```
remodex/
├── phodex-bridge/          # Node.js CLI bridge (npm package)
│   ├── bin/remodex.js      # CLI entrypoint
│   └── src/
│       ├── bridge.js               # Core relay + message forwarding
│       ├── codex-transport.js      # Spawn vs WebSocket abstraction
│       ├── codex-desktop-refresher.js  # Debounced Codex.app refresh
│       ├── git-handler.js          # Git command execution from phone
│       ├── workspace-handler.js    # Workspace/cwd management
│       ├── session-state.js        # Thread persistence (~/.remodex/)
│       ├── rollout-watch.js        # Thread event log tailing
│       └── qr.js                   # QR code generation
│
├── CodexMobile/            # Xcode project root
│   ├── CodexMobile/        # App source target
│   │   ├── Services/       # Core services
│   │   │   ├── CodexService.swift              # Main service coordinator
│   │   │   ├── CodexService+Connection.swift   # WebSocket connection
│   │   │   ├── CodexService+Incoming.swift     # Message handling
│   │   │   ├── CodexService+Messages.swift     # Message composition
│   │   │   ├── CodexService+History.swift      # Thread history
│   │   │   ├── CodexService+ThreadsTurns.swift # Thread/turn management
│   │   │   ├── GitActionsService.swift         # Git operations
│   │   │   └── AppEnvironment.swift            # Runtime config
│   │   ├── Views/          # SwiftUI views
│   │   │   ├── Turn/       # Message timeline + composer
│   │   │   ├── Sidebar/    # Project/thread navigation
│   │   │   └── Home/       # Home + onboarding
│   │   └── Models/         # Data models
│   ├── CodexMobileTests/   # Unit tests
│   ├── CodexMobileUITests/ # UI tests
│   └── BuildSupport/       # Build support files
```

### Code style

- **Bridge**: CommonJS, no transpilation, no TypeScript. Keep it simple.
- **iOS**: SwiftUI, async/await, MainActor isolation. Follow existing patterns.
- No linter or formatter is enforced — just match what's already there.

### Trust model

- The QR pairing is possession-based: it contains the relay URL and a live session ID.
- The default relay uses `wss://relay.example.invalid/relay`, so traffic is TLS-protected in transit.
- There is no end-to-end encryption layer above the relay. If you need a stricter trust boundary, use a relay you control.
