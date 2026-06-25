# Relay

This folder contains the public relay and push-service code used by Remodex pairing and trusted reconnect.

The point of keeping this code in the repo is transparency: anyone forking Remodex can inspect the transport boundary, verify the encrypted-session flow, and run a compatible relay of their own. What should stay private is the actual deployed endpoint and any production credentials.

## What It Does

- accepts WebSocket connections at `/relay/{sessionId}`
- pairs one Mac host with one live mobile client for a session
- keeps an in-memory index of the current live session for each trusted Mac
- resolves the current live session for a previously trusted mobile client through an authenticated HTTP lookup
- forwards secure control messages and encrypted payloads between Mac and the mobile client
- exposes optional HTTP endpoints for push registration and run-completion alerts only when push is enabled explicitly
- logs only connection metadata and payload sizes, not plaintext prompts or responses

## What It Does Not Do

- it does not run Codex
- it does not execute git commands
- it does not contain the user's repository checkout
- it does not decrypt Remodex application payloads after the secure session is established

Codex, git, and local file operations still run on the user's Mac.

## Security Model

Remodex uses the relay as a transport hop, not as a trusted application server.

- The pairing QR gives the mobile client the bridge identity public key plus short-lived session details.
- After the first successful QR bootstrap, the relay can help the mobile client find the Mac's current live session again through a signed trusted-session resolve request.
- The mobile client and bridge perform a signed handshake, derive shared AES-256-GCM keys with X25519 + HKDF-SHA256, and then encrypt application payloads end to end.
- The relay can still observe connection metadata and the plaintext secure control messages needed to establish the encrypted session.
- The relay does not receive plaintext Remodex application payloads after the secure session is active.

## Relay Flow

```mermaid
flowchart TD
    A[Mac bridge starts] --> B[Bridge creates sessionId and notification secret]
    B --> C[Bridge prints QR with relay URL, sessionId, bridge identity key, expiry]
    B --> D[Mac opens WebSocket to /relay/{sessionId}<br/>x-role: mac]
    D --> E[Relay creates in-memory session room]
    D --> E2[Relay records macDeviceId plus trusted phone metadata for live-session resolve]

    C --> F[Mobile client scans QR]
    F --> G[Mobile client opens WebSocket to /relay/{sessionId}<br/>x-role: iphone or android]
    G --> H{Mac session live?}
    H -- No --> I[Relay closes mobile socket<br/>4002 session unavailable]
    H -- Yes --> J[Relay binds mobile client to that session]

    E --> K[Relay forwards secure control messages]
    J --> K
    K --> L[Mac and mobile client exchange signed handshake]
    L --> M[Both sides derive AES-256-GCM session keys]

    M --> N[Mobile client sends encrypted app messages]
    M --> O[Mac sends encrypted Codex and bridge responses]
    N --> P[Relay forwards ciphertext to Mac]
    O --> Q[Relay forwards ciphertext to mobile client]

    P --> R[Bridge decrypts and routes locally]
    R --> S[Codex app-server / git / workspace handlers]
    S --> O

    Q --> T[Mobile client decrypts and renders timeline]

    D --> U[Relay stores per-session notification secret]
    U --> V[Push registration/completion endpoints only work while live Mac session exists]

    D --> W{Mac reconnects?}
    W -- Yes --> X[Relay replaces older Mac socket<br/>4001 to old connection]
    G --> Y{Mobile client reconnects?}
    Y -- Yes --> Z[Relay replaces older mobile socket<br/>4003 to old connection]

    X --> E
    Z --> J

    D --> AA{Mac disconnects?}
    AA -- Yes --> AB[Relay closes mobile socket(s)<br/>4002 Mac disconnected]
    AB --> AC[Empty session cleaned up after delay]

    T --> AD[Later app reopen]
    AD --> AE[Mobile client calls POST /v1/trusted/session/resolve]
    AE --> AF[Relay verifies trusted-device signature, nonce, and freshness]
    AF --> AG[Relay returns current live sessionId for that Mac]
    AG --> G
```

## Protocol Notes

- WebSocket path: `/relay/{sessionId}`
- required role: `x-role: mac`, `x-role: iphone`, or `x-role: android`
- mobile clients that cannot send custom WebSocket headers may use `/relay/{sessionId}?role=iphone` or `/relay/{sessionId}?role=android`
- close code `4000`: invalid session or role
- close code `4001`: previous Mac connection replaced
- close code `4002`: session unavailable / Mac disconnected
- close code `4003`: previous mobile connection replaced

Optional HTTP endpoints:

- `GET /health`
- `POST /v1/trusted/session/resolve`
- `POST /v1/push/session/register-device`
- `POST /v1/push/session/notify-completion`

The trusted-session resolve endpoint is intended for mobile clients that have already completed the first QR bootstrap. It returns the current live session only after signature, nonce, and freshness checks pass.

Push uses staged production defaults:

- **`dev` profile** (`NODE_ENV=development`, `NODE_ENV=test`, or `REMODEX_PROFILE=dev`): opt-in only — set `REMODEX_ENABLE_PUSH_SERVICE=true`.
- **`managed-relay` profile** (APNs credentials present): push routes **auto-enable** when `REMODEX_APNS_*` is complete. Opt out with `REMODEX_ENABLE_PUSH_SERVICE=false`.
- **`self-hosted` profile**: dark-launch only — when APNs creds are present the relay logs `would_enable_push=true` but keeps routes disabled until you opt in.

Also wire the bridge-side `REMODEX_PUSH_SERVICE_URL` so the Mac bridge can register devices and notify completions.

WebSocket frames are capped at **4 MiB** (`maxPayload` on the relay `WebSocketServer`). Oversize frames close with code `1009`.

Production/self-host installs bind **`127.0.0.1`** by default (`RELAY_BIND_HOST`). Set `RELAY_BIND_HOST=0.0.0.0` only when you intentionally expose the relay on your LAN.

## Deploy Notes

- Keep the real relay base URL in private config such as `REMODEX_RELAY`, not in committed source.
- Keep APNs credentials in private env vars or protected files (`REMODEX_APNS_*`).
- Leave `REMODEX_TRUST_PROXY` unset for direct/self-hosted installs. Set it to `true` only when a trusted reverse proxy is forwarding requests to this relay.
- When `REMODEX_TRUST_PROXY=true`, configure the proxy to send sanitized client IP headers (`X-Real-Ip` and/or appended `X-Forwarded-For`) instead of passing client-supplied values through unchanged.
- If you expose the relay under a shared-domain prefix such as `/remodex`, have the proxy strip that prefix before forwarding so the Node server still receives `/relay/...` and `/v1/push/...`.
- The public repo should document the protocol and code, not your real deployed hostname or deploy defaults.

## Canonical entrypoint

Production and local self-hosting should use:

- **`server.js`** — HTTP server, health, trusted-session resolve, optional push routes; calls `setupRelay(wss)` from **`relay.js`**.
- **`relay.js`** — WebSocket relay transport (pairing rooms, heartbeat, forwarding, `getRelayStats()`).

`npm start` runs `node ./server.js`. Do not deploy the legacy `phodex-backend-relay.mjs` snapshot; it duplicated heartbeat logic without metrics and was removed to avoid drift.

## Usage

```sh
cd relay
npm install
npm start
```

`server.js` exports `createRelayServer()`. `relay.js` exports `setupRelay(wss)` and `getRelayStats()` if you embed the relay in your own server.
