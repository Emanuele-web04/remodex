// FILE: opencode-auth-error-handler.test.js
// Purpose: Verifies ProviderAuthError extraction, runtime/auth/error emission shape, and dedupe.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-auth-error-handler

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  createOpenCodeAuthErrorNotifier,
  extractOpenCodeAuthError,
} = require("../src/opencode-auth-error-handler");

// --- extractOpenCodeAuthError ---

test("extractOpenCodeAuthError returns null for non-auth payloads", () => {
  assert.equal(extractOpenCodeAuthError({}), null);
  assert.equal(extractOpenCodeAuthError({ error: { name: "SyntaxError" } }), null);
  assert.equal(extractOpenCodeAuthError(), null);
});

test("extractOpenCodeAuthError normalizes a ProviderAuthError nested in payload.error", () => {
  const normalized = extractOpenCodeAuthError({
    threadId: "thread-1",
    turnId: "turn-2",
    error: {
      name: "ProviderAuthError",
      providerID: "anthropic",
      message: "Invalid API key",
    },
  });

  assert.deepEqual(normalized, {
    providerID: "anthropic",
    providerId: "anthropic",
    threadId: "thread-1",
    turnId: "turn-2",
    message: "Invalid API key",
    errorCode: "provider_auth_error",
    source: "opencode",
  });
});

test("extractOpenCodeAuthError detects auth errors on the top-level payload", () => {
  const normalized = extractOpenCodeAuthError({
    name: "ProviderAuthError",
    providerId: "openai",
    message: "401 from provider",
  });

  assert.equal(normalized.providerID, "openai");
  assert.equal(normalized.message, "401 from provider");
  assert.equal(normalized.errorCode, "provider_auth_error");
});

test("extractOpenCodeAuthError falls back to default message and null provider", () => {
  const normalized = extractOpenCodeAuthError({
    error: { errorCode: "provider_auth_error" },
  });

  assert.equal(normalized.providerID, null);
  assert.equal(normalized.providerId, null);
  assert.equal(
    normalized.message,
    "OpenCode provider authentication failed. Re-authenticate on your Mac.",
  );
  assert.equal(normalized.threadId, null);
  assert.equal(normalized.turnId, null);
});

test("extractOpenCodeAuthError reads snake_case thread/turn ids and custom source", () => {
  const normalized = extractOpenCodeAuthError({
    thread_id: "thread-snake",
    turn_id: "turn-snake",
    source: "turn_failed",
    error: { name: "ProviderAuthError", data: { providerID: "google" } },
  });

  assert.equal(normalized.threadId, "thread-snake");
  assert.equal(normalized.turnId, "turn-snake");
  assert.equal(normalized.source, "turn_failed");
  assert.equal(normalized.providerID, "google");
});

// --- createOpenCodeAuthErrorNotifier ---

test("notifyAuthError emits a structured runtime/auth/error message", () => {
  const sent = [];
  const notifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: (payload) => sent.push(JSON.parse(payload)),
  });

  const emitted = notifier.notifyAuthError({
    threadId: "thread-a",
    error: { name: "ProviderAuthError", providerID: "anthropic", message: "key revoked" },
  });

  assert.equal(emitted, true);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].method, "runtime/auth/error");
  assert.equal(sent[0].params.providerID, "anthropic");
  assert.equal(sent[0].params.threadId, "thread-a");
  assert.equal(sent[0].params.message, "key revoked");
  assert.equal(sent[0].params.errorCode, "provider_auth_error");
  assert.ok(!JSON.stringify(sent[0]).includes("\n    at "), "no raw stack traces emitted");
});

test("notifyAuthError ignores payloads that are not provider auth errors", () => {
  const sent = [];
  const notifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: (payload) => sent.push(payload),
  });

  assert.equal(notifier.notifyAuthError({ error: { message: "random failure" } }), false);
  assert.equal(sent.length, 0);
});

test("notifyAuthError dedupes the same provider/message within the dedupe window", () => {
  const sent = [];
  const notifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: (payload) => sent.push(payload),
  });
  const payload = {
    error: { name: "ProviderAuthError", providerID: "anthropic", message: "key revoked" },
  };

  assert.equal(notifier.notifyAuthError(payload), true);
  assert.equal(notifier.notifyAuthError(payload), false);
  assert.equal(notifier.notifyAuthError(payload), false);
  assert.equal(sent.length, 1);
});

test("notifyAuthError does not dedupe distinct provider/message pairs", () => {
  const sent = [];
  const notifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: (payload) => sent.push(JSON.parse(payload)),
  });

  assert.equal(
    notifier.notifyAuthError({
      error: { name: "ProviderAuthError", providerID: "anthropic", message: "key revoked" },
    }),
    true,
  );
  assert.equal(
    notifier.notifyAuthError({
      error: { name: "ProviderAuthError", providerID: "openai", message: "key revoked" },
    }),
    true,
  );
  assert.equal(
    notifier.notifyAuthError({
      error: { name: "ProviderAuthError", providerID: "anthropic", message: "different" },
    }),
    true,
  );
  assert.equal(sent.length, 3);
});

test("notifyAuthError emits again after the dedupe window expires", () => {
  const sent = [];
  const notifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: (payload) => sent.push(payload),
  });
  const payload = {
    error: { name: "ProviderAuthError", providerID: "anthropic", message: "key revoked" },
  };

  const realNow = Date.now;
  try {
    let now = 1_000_000;
    Date.now = () => now;
    assert.equal(notifier.notifyAuthError(payload), true);

    now += 14_999; // still inside the 15s window
    assert.equal(notifier.notifyAuthError(payload), false);

    now += 1; // exactly 15s after the first emission
    assert.equal(notifier.notifyAuthError(payload), true);
  } finally {
    Date.now = realNow;
  }
  assert.equal(sent.length, 2);
});

test("notifyAuthError returns false without a sendApplicationMessage function", () => {
  const notifier = createOpenCodeAuthErrorNotifier({});
  const result = notifier.notifyAuthError({
    error: { name: "ProviderAuthError", providerID: "anthropic", message: "no sink" },
  });
  assert.equal(result, false);
});

test("inspectTurnFailure forwards turn failures with source turn_failed", () => {
  const sent = [];
  const notifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: (payload) => sent.push(JSON.parse(payload)),
  });

  const emitted = notifier.inspectTurnFailure({
    threadId: "thread-t",
    turnId: "turn-t",
    error: { name: "ProviderAuthError", providerID: "openai", message: "expired" },
  });

  assert.equal(emitted, true);
  assert.equal(sent[0].params.source, "turn_failed");
  assert.equal(sent[0].params.threadId, "thread-t");
  assert.equal(sent[0].params.turnId, "turn-t");
});

test("inspectTurnFailure ignores non-auth turn failures", () => {
  const sent = [];
  const notifier = createOpenCodeAuthErrorNotifier({
    sendApplicationMessage: (payload) => sent.push(payload),
  });

  const emitted = notifier.inspectTurnFailure({
    threadId: "thread-t",
    turnId: "turn-t",
    error: { message: "network timeout" },
  });

  assert.equal(emitted, false);
  assert.equal(sent.length, 0);
});
