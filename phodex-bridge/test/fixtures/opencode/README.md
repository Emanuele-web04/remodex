# OpenCode Fixture Notes

Verified against local `opencode --version` output `1.15.7`.

Serve command used by the bridge:

```bash
OPENCODE_SERVER_USERNAME=opencode OPENCODE_SERVER_PASSWORD=<random> \
  opencode serve --hostname 127.0.0.1 --port 0 --pure --print-logs
```

Runtime endpoints used by tests and adapter code:

- `POST /session` creates an OpenCode session for `thread/start`.
- `POST /session/{sessionID}/prompt_async` sends the user prompt for `turn/start`.
- `GET /event` streams OpenCode SSE events.
- `POST /session/{sessionID}/abort` stops an active turn.
- `GET /session/{sessionID}/diff` refreshes changed-file state after completion.
- `POST /session/{sessionID}/permissions/{permissionID}` replies to phone-mediated permission prompts.
- `POST /permission/{requestID}/reply` exists in the local OpenCode API and remains allowlisted for compatibility.

Denied security-sensitive endpoints include `PUT /auth` and share/auth mutation paths. Tests keep the server loopback-only, use an ephemeral port, never enable `--mdns`, and avoid printing live passwords or relay/session identifiers.
