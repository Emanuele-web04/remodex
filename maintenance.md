# Remodex Local Maintenance

This MacBook is running the local Remodex relay, bridge, Codex runtime, and iOS development build path.

## Current local values

- Repo root: `/Users/dyllon/Developer/codex-remote`
- Tailscale IP: `100.107.153.95`
- Relay port: `9000`
- Relay URL: `ws://100.107.153.95:9000/relay`
- Health URL: `http://100.107.153.95:9000/health`
- Relay LaunchAgent: `/Users/dyllon/Library/LaunchAgents/com.remodex.tailnet-relay.plist`
- Relay stdout log: `/Users/dyllon/Library/Logs/remodex-tailnet-relay/relay.out.log`
- Relay stderr log: `/Users/dyllon/Library/Logs/remodex-tailnet-relay/relay.err.log`
- iOS local bundle ID: `com.dyllon.remodex.local`
- iOS app path: `/Users/dyllon/Developer/codex-remote/.derivedData-remodex/Build/Products/Debug-iphoneos/CodexMobile.app`

## Check relay health

```bash
curl -fsS "http://100.107.153.95:9000/health"
```

Expected:

```json
{"ok":true}
```

## Relay restart

```bash
launchctl kickstart -k gui/$(id -u)/com.remodex.tailnet-relay
```

## Relay stop

```bash
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.remodex.tailnet-relay.plist"
```

## Relay logs

```bash
tail -f "$HOME/Library/Logs/remodex-tailnet-relay/relay.out.log"
```

```bash
tail -f "$HOME/Library/Logs/remodex-tailnet-relay/relay.err.log"
```

## Bridge start

```bash
cd "/Users/dyllon/Developer/codex-remote/phodex-bridge"
REMODEX_RELAY="ws://100.107.153.95:9000/relay" node ./bin/remodex.js up
```

## Bridge status

```bash
cd "/Users/dyllon/Developer/codex-remote/phodex-bridge"
REMODEX_RELAY="ws://100.107.153.95:9000/relay" node ./bin/remodex.js status
```

## Fresh pairing

```bash
cd "/Users/dyllon/Developer/codex-remote/phodex-bridge"
REMODEX_RELAY="ws://100.107.153.95:9000/relay" node ./bin/remodex.js reset-pairing
REMODEX_RELAY="ws://100.107.153.95:9000/relay" node ./bin/remodex.js up
```

Scan the printed QR from inside the Remodex app onboarding or pairing flow, not with the iPhone Camera app.

## iPhone connectivity check

On the iPhone, keep Tailscale enabled and open:

```text
http://100.107.153.95:9000/health
```

Expected:

```json
{"ok":true}
```
