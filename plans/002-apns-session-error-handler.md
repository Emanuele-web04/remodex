# Plan 002: Attach an `error` handler to the APNs HTTP/2 session so a network blip can't crash the relay

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 6f27902..HEAD -- relay/apns-client.js relay/apns-client.test.js`
> If either changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as
> a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `6f27902`, 2026-07-07

## Why this matters

`relay/apns-client.js` opens a fresh HTTP/2 client session to Apple for every
push (`http2Connect(authority)`), but attaches an `error` listener only to the
individual request stream — never to the session (`client`) itself. In Node.js,
an unhandled `'error'` event on an `EventEmitter` is **re-thrown as an uncaught
exception and crashes the process**. Session-level errors (DNS failure,
ECONNREFUSED, TLS handshake failure, an idle session reset by Apple) fire on
`client`, not on the request. Because the relay is a shared, long-lived process
serving push for every connected session (`relay/server.js`), one transient
network hiccup while reaching `api.push.apple.com` can take the whole relay down
for all users. Every other network primitive in this file already settles its
promise on error; the session just needs the same treatment.

## Current state

- `relay/apns-client.js:42-78` — `sendNotification`'s send path:
  ```js
  const authority = apnsEnvironment === "development"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";
  const client = http2Connect(authority);          // <-- no client.on("error", ...)

  try {
    const response = await sendRequest(client, { /* headers */ }, JSON.stringify({ /* body */ }));
    if (response.status >= 400) {
      throw apnsError("apns_request_failed", /* ... */, response.status);
    }
    return { ok: true };
  } finally {
    client.close();
  }
  ```
- `relay/apns-client.js:109-131` — `sendRequest` only guards the **stream**:
  ```js
  function sendRequest(client, headers, body) {
    return new Promise((resolve, reject) => {
      const request = client.request(headers);
      // ... response/data/end handlers ...
      request.on("error", reject);   // <-- stream-level only; does not cover session errors
      request.end(body);
    });
  }
  ```
- `http2Connect` is an injected dependency (constructor parameter), defaulting to
  Node's `require("node:http2").connect`. Confirm this by reading the top of
  `relay/apns-client.js` where the factory function destructures its options — the
  test injects a stub here.

Convention for this file: functions reject with `apnsError(code, message, status)`
(defined near the top of the file); errors are surfaced as rejected promises, not
thrown synchronously. Match that. The existing test file
`relay/apns-client.test.js` injects a fake `http2Connect` returning a stub client
object — study it before writing new tests (see Test plan).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Test file | `cd relay && node --test apns-client.test.js` | all tests pass |
| Full relay suite | `cd relay && npm test` | all tests pass |

## Scope

**In scope** (the only files you should modify):
- `relay/apns-client.js`
- `relay/apns-client.test.js`

**Out of scope** (do NOT touch):
- `relay/push-service.js`, `relay/server.js`, `relay/relay.js` — callers; their
  handling of a rejected `sendNotification` is already correct and unchanged.
- The JWT/`authorizationToken` logic — unrelated.

## Git workflow

- Branch: `advisor/002-apns-session-error`
- One commit; short imperative message, e.g. `Handle APNs HTTP/2 session errors instead of crashing`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make `sendRequest` (or the send path) reject on session-level errors

The goal: a session-level `'error'` on `client` must reject the in-flight
`sendNotification` promise instead of going unhandled. Two constraints:

1. The promise must **settle exactly once** — a session error and a stream error
   can both fire; whichever is first wins, the later one must be a no-op (don't
   call `reject`/`resolve` twice).
2. `client.close()` in the existing `finally` must still run.

Recommended shape: pass a way to signal session errors into `sendRequest`, or
attach the session listener in `sendNotification` and race it against
`sendRequest`. The simplest self-contained version — attach the listener inside
`sendRequest` since it already owns the Promise:

```js
function sendRequest(client, headers, body) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const settleReject = (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    };
    const settleResolve = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };

    client.on("error", (error) => {
      settleReject(apnsError("apns_session_error", `APNs session error: ${error?.message || error}`, 502));
    });

    const request = client.request(headers);
    const chunks = [];
    let responseHeaders = null;

    request.setEncoding("utf8");
    request.on("response", (headers) => { responseHeaders = headers; });
    request.on("data", (chunk) => { chunks.push(chunk); });
    request.on("end", () => {
      settleResolve({
        status: Number(responseHeaders?.[":status"] || 0),
        body: safeParseJSON(chunks.join("")),
      });
    });
    request.on("error", settleReject);
    request.end(body);
  });
}
```

Keep `apnsError` usage consistent with the rest of the file. The exact status
code (`502`) is not load-bearing — pick something in the 5xx range and matching
the file's existing error style.

**Verify**: `cd relay && node --test apns-client.test.js` → all existing tests still pass.

### Step 2: Add a regression test for the session-error path

Add a test to `relay/apns-client.test.js` that injects an `http2Connect` stub
whose returned client emits an `'error'` event (instead of a normal response),
and asserts that `sendNotification(...)` **rejects** rather than throwing an
uncaught exception. Model the stub shape on the existing test's fake client.

Also add (or extend) a test asserting the promise settles only once when both a
session `error` and a stream `error`/`end` could fire — assert no unhandled
rejection and a single settlement.

**Verify**: `cd relay && node --test apns-client.test.js` → all tests pass, including the new one(s).

## Test plan

- New tests in `relay/apns-client.test.js`:
  - **session error rejects**: stub client emits `'error'` → `sendNotification`
    promise rejects with an `apns_*` error, no uncaught exception.
  - **single settlement**: if a response arrives after (or a stream error fires
    alongside) a session error, the promise is not settled twice.
- Structural pattern: model after the existing test in the same file that injects
  a fake `http2Connect` and drives a successful/failed request.
- Verification: `cd relay && npm test` → all pass, including the new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n 'client.on("error"' relay/apns-client.js` returns a match
- [ ] `cd relay && node --test apns-client.test.js` → all tests pass, new session-error test present
- [ ] `cd relay && npm test` exits 0
- [ ] `git status` shows only the two in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The current code no longer matches the "Current state" excerpts (e.g. the file
  already attaches `client.on("error", ...)`) — the bug may already be fixed.
- Adding the session listener causes a pre-existing test to fail in a way that
  suggests some caller relies on the crash behavior (it should not; report it).
- You cannot construct a stub that emits a session-level `error` because the test
  seam differs from what's described — report the actual injection shape.

## Maintenance notes

- If this file is ever refactored to reuse a single long-lived HTTP/2 session
  across pushes (instead of one-per-notification), the error handling changes
  materially — a persistent session's `error` must trigger reconnect, not just
  reject one push. Flag that in review.
- Reviewer should confirm the "settle once" guard is present — the double-settle
  bug is subtle and won't show up in the happy-path test.
