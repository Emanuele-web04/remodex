# Remodex Convex Sync

This is an optional self-hosted Convex backend for Remodex off-LAN async messaging.

It does one job: store encrypted phone-to-Mac fallback messages long enough for the bridge to claim them, run them through the local Codex bridge, and publish the encrypted response back for the phone to poll.

## Routes

- `GET /async/health`
- `POST /async/outbound/enqueue`
- `GET /async/outbound/claim?toDeviceId=...&leaseMs=...`
- `POST /async/outbound/respond`
- `POST /async/outbound/error`
- `POST /async/inbound/poll`
- `POST /async/inbound/delivered`

Legacy `/remodex/...` aliases are also exposed for bridge-side compatibility.

## Local dev

```bash
cd remodex-convex-sync
npm install
npx convex dev
```

The source tree owns the default `.convex.site` URL in the bridge and iOS app. If you point at a different Convex project, update the matching code constants in [`phodex-bridge/src/codex-desktop-refresher.js`](../phodex-bridge/src/codex-desktop-refresher.js) and [`CodexMobile/CodexMobile/Services/AppEnvironment.swift`](../CodexMobile/CodexMobile/Services/AppEnvironment.swift).

## Deploy

```bash
cd remodex-convex-sync
npm install
npx convex deploy
```

Those constants already point at the default deployment; only change them if you deploy a different Convex project.

The payloads remain end-to-end encrypted. Convex stores ciphertext plus signatures and does not need relay session secrets beyond what is already exchanged during Remodex pairing.
