# Self-Hosting Remodex

This guide is for developers who clone the public GitHub repository and want to run Remodex on infrastructure they control.

It covers two supported setups:

1. Local LAN pairing on your own machine
2. A self-hosted VPS relay that your bridge connects to over the internet

This document intentionally avoids any private hosted-service details. If you are using the public repo, assume you are bringing your own relay endpoint.

The public source tree is local-first and self-host friendly:

- there is no public production relay baked into the GitHub source
- local pairing should work out of the box with `./run-local-remodex.sh`
- internet-facing setups should pass their own relay URL explicitly with `REMODEX_RELAY`

## What Remodex Self-Hosting Means

Remodex is local-first.

That means:

- the bridge runs on your own Mac
- Codex runs on your own Mac
- git commands run on your own Mac
- your iPhone is a remote control
- the relay is only a transport layer for pairing and encrypted message forwarding

The relay does not run Codex and does not get your plaintext application payloads after the secure handshake completes.

## Option 1: Local LAN Setup

This is the easiest way to try the public repo, but on iPhone it should be treated as a best-effort local test path. The recommended self-host setup for regular use is Tailscale or another stable private network path to your relay.

### What you need

- a Mac with Codex CLI installed
- an iPhone with a Remodex build installed
- both devices on the same local network

### Start everything locally

From the repo root:

```sh
git clone https://github.com/Emanuele-web04/remodex.git
cd remodex
./run-local-remodex.sh
```

What this does:

- starts a local relay on your machine
- starts the Remodex bridge
- prints a pairing QR code

Then:

1. Open the iPhone app
2. Scan the QR code from inside the app
3. Start a thread and send a message

### If your iPhone cannot reach the default hostname

Pass a hostname or IP address that the phone can actually reach:

```sh
./run-local-remodex.sh --hostname 192.168.1.10
```

### Health check

By default the local relay listens on port `9000`.

From the same Mac:

```sh
curl http://127.0.0.1:9000/health
```

You should get:

```json
{"ok":true}
```

## Option 2: Self-Hosted VPS Relay

Use this when you want the bridge on your Mac to connect through a relay you run on a VPS.

### What runs where

On your VPS:

- the Remodex relay

On your Mac:

- the Remodex bridge
- Codex CLI / `codex app-server`

On your iPhone:

- the Remodex app

### Start the relay on the VPS

From the public repo:

```sh
git clone https://github.com/Emanuele-web04/remodex.git
cd remodex/relay
npm install
npm start
```

By default the relay listens on port `9000`.

### Verify the relay

On the VPS:

```sh
curl http://127.0.0.1:9000/health
```

You should get:

```json
{"ok":true}
```

### Put a reverse proxy in front of it

Expose the relay through a public `ws://` or `wss://` endpoint that forwards to the Node relay.

Two common patterns are:

- a dedicated subdomain, for example `wss://relay.example.com/relay`
- a shared-domain subpath, for example `wss://api.example.com/remodex/relay`

If you use a shared-domain subpath, make sure your reverse proxy strips the prefix before forwarding so the Node process still receives `/relay/...`.

### Point the bridge at your VPS relay

On the Mac that runs the bridge:

```sh
REMODEX_RELAY="wss://relay.example.com/relay" remodex up
```

Or, if you are running from source:

```sh
cd phodex-bridge
npm install
REMODEX_RELAY="wss://relay.example.com/relay" npm start
```

The bridge will print a QR code.

That QR carries the relay URL and session information, so the iPhone does not need a hardcoded relay endpoint in the public source build.

If you install the bridge from npm and do not use the local launcher, make sure you export `REMODEX_RELAY` before running `remodex up`.

## Push Notifications

Managed push is optional.

For public self-hosting:

- you do not need push to use Remodex
- local in-app and local-device flows can still work without it
- the relay keeps push endpoints disabled by default

Do not turn push on unless you are also ready to configure:

- a bridge-side `REMODEX_PUSH_SERVICE_URL`
- APNs credentials on the relay side
- your own operational setup for notification delivery

If you do nothing here, push stays off.

## Reverse Proxy Notes

If your relay sits behind Traefik, Nginx, or Caddy:

- forward WebSocket upgrades correctly
- forward the `/relay/...` path to the relay process
- only enable `REMODEX_TRUST_PROXY=true` when the proxy is trusted and sanitizes forwarded IP headers

## What Not to Commit

If you are self-hosting from the public repo, keep these things out of Git:

- your real relay hostname
- your private VPS IP addresses
- any APNs credentials
- any private package or App Store build defaults

The public repo should stay generic. Your actual deployment values belong in your own environment, build pipeline, or private config.

## Troubleshooting

### The bridge starts but the iPhone cannot connect

Check:

- the relay is reachable from the phone
- your reverse proxy forwards WebSockets
- the bridge is using the correct `REMODEX_RELAY`
- the public endpoint uses `wss://` if you are going over the internet

### Local LAN pairing fails

Try a concrete LAN IP:

```sh
./run-local-remodex.sh --hostname 192.168.1.10
```

If local LAN pairing still fails on iPhone even though the relay health check works, prefer a Tailscale-reachable relay instead of continuing to rely on plain `ws://` over the same Wi-Fi.

### The relay health check works, but pairing still fails

That usually means one of these:

- the public path is wrong
- the reverse proxy is not forwarding upgrades
- the bridge is pointing at the wrong relay base URL

## Minimal Summary

If you cloned the public repo, the supported self-hosting story is:

- run the relay yourself
- prefer a relay path reachable from iPhone over Tailscale or another stable private network
- point the bridge at your relay with `REMODEX_RELAY`
- scan the QR from the iPhone app
- keep private hostnames and credentials out of the public repo
