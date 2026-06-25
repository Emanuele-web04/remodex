// FILE: opencode-usage-mapper.test.js
// Purpose: Verifies OpenCode session token counter mapping and provider auth error detection helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-usage-mapper

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  mapOpenCodeSessionToContextUsage,
  resolveOpenCodeSessionPayload,
  isProviderAuthErrorPayload,
} = require("../src/opencode-usage-mapper");

// --- resolveOpenCodeSessionPayload ---

test("resolveOpenCodeSessionPayload returns null for non-objects", () => {
  assert.equal(resolveOpenCodeSessionPayload(null), null);
  assert.equal(resolveOpenCodeSessionPayload(undefined), null);
  assert.equal(resolveOpenCodeSessionPayload("session"), null);
  assert.equal(resolveOpenCodeSessionPayload(42), null);
});

test("resolveOpenCodeSessionPayload unwraps SDK-style data envelopes", () => {
  const inner = { tokens: { input: 1 } };
  assert.equal(resolveOpenCodeSessionPayload({ data: inner }), inner);
});

test("resolveOpenCodeSessionPayload ignores array data and returns the response itself", () => {
  const response = { data: [1, 2, 3], tokens: {} };
  assert.equal(resolveOpenCodeSessionPayload(response), response);
});

test("resolveOpenCodeSessionPayload ignores non-object data fields", () => {
  const response = { data: "nope" };
  assert.equal(resolveOpenCodeSessionPayload(response), response);
});

// --- mapOpenCodeSessionToContextUsage ---

test("mapOpenCodeSessionToContextUsage sums input/output/reasoning/cache counters", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    {
      tokens: { input: 100, output: 50, reasoning: 25, cache: { read: 10, write: 5 } },
      contextWindow: 1000,
    },
    {},
  );
  assert.deepEqual(usage, { tokensUsed: 190, tokenLimit: 1000 });
});

test("mapOpenCodeSessionToContextUsage prefers tokens.total when present and positive", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    { tokens: { total: 777, input: 1, output: 1 }, contextWindow: 1000 },
    {},
  );
  assert.deepEqual(usage, { tokensUsed: 777, tokenLimit: 1000 });
});

test("mapOpenCodeSessionToContextUsage falls back to component sum when total is zero", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    { tokens: { total: 0, input: 3, output: 4 }, contextWindow: 100 },
    {},
  );
  assert.deepEqual(usage, { tokensUsed: 7, tokenLimit: 100 });
});

test("mapOpenCodeSessionToContextUsage accepts numeric strings and floors floats", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    { tokens: { input: "100", output: 2.9 }, contextWindow: "5000" },
    {},
  );
  assert.deepEqual(usage, { tokensUsed: 102, tokenLimit: 5000 });
});

test("mapOpenCodeSessionToContextUsage treats negative and non-numeric counts as zero", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    { tokens: { input: -50, output: "abc", reasoning: NaN, cache: { read: null } }, contextWindow: 100 },
    {},
  );
  assert.deepEqual(usage, { tokensUsed: 0, tokenLimit: 100 });
});

test("mapOpenCodeSessionToContextUsage clamps tokensUsed to the limit", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    { tokens: { input: 5000 }, contextWindow: 1000 },
    {},
  );
  assert.deepEqual(usage, { tokensUsed: 1000, tokenLimit: 1000 });
});

test("mapOpenCodeSessionToContextUsage returns null without a resolvable token limit", () => {
  assert.equal(mapOpenCodeSessionToContextUsage({ tokens: { input: 10 } }, {}), null);
  assert.equal(
    mapOpenCodeSessionToContextUsage({ tokens: { input: 10 }, contextWindow: 0 }, {}),
    null,
  );
});

test("mapOpenCodeSessionToContextUsage returns null for malformed payloads", () => {
  assert.equal(mapOpenCodeSessionToContextUsage(null, {}), null);
  assert.equal(mapOpenCodeSessionToContextUsage("bad", {}), null);
  assert.equal(mapOpenCodeSessionToContextUsage(undefined, {}), null);
});

test("mapOpenCodeSessionToContextUsage tolerates missing tokens object", () => {
  const usage = mapOpenCodeSessionToContextUsage({ contextWindow: 2000 }, {});
  assert.deepEqual(usage, { tokensUsed: 0, tokenLimit: 2000 });
});

test("mapOpenCodeSessionToContextUsage tolerates non-object tokens and cache fields", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    { tokens: "weird", contextWindow: 500 },
    {},
  );
  assert.deepEqual(usage, { tokensUsed: 0, tokenLimit: 500 });

  const usage2 = mapOpenCodeSessionToContextUsage(
    { tokens: { input: 5, cache: "weird" }, contextWindow: 500 },
    {},
  );
  assert.deepEqual(usage2, { tokensUsed: 5, tokenLimit: 500 });
});

test("mapOpenCodeSessionToContextUsage prefers explicit tokenLimit option over payload windows", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    { tokens: { input: 10 }, contextWindow: 999 },
    { tokenLimit: 4096 },
  );
  assert.deepEqual(usage, { tokensUsed: 10, tokenLimit: 4096 });
});

test("mapOpenCodeSessionToContextUsage resolves snake_case and model context window fields", () => {
  assert.deepEqual(
    mapOpenCodeSessionToContextUsage({ tokens: { input: 1 }, context_window: 100 }, {}),
    { tokensUsed: 1, tokenLimit: 100 },
  );
  assert.deepEqual(
    mapOpenCodeSessionToContextUsage({ tokens: { input: 1 }, modelContextWindow: 200 }, {}),
    { tokensUsed: 1, tokenLimit: 200 },
  );
  assert.deepEqual(
    mapOpenCodeSessionToContextUsage({ tokens: { input: 1 }, model_context_window: 300 }, {}),
    { tokensUsed: 1, tokenLimit: 300 },
  );
});

test("mapOpenCodeSessionToContextUsage reads payloads through data envelopes", () => {
  const usage = mapOpenCodeSessionToContextUsage(
    { data: { tokens: { input: 60, cache: { read: 40 } }, contextWindow: 8192 } },
    {},
  );
  assert.deepEqual(usage, { tokensUsed: 100, tokenLimit: 8192 });
});

// --- isProviderAuthErrorPayload (covers readStructuredErrorCode / ProviderId / HttpStatus) ---

test("isProviderAuthErrorPayload rejects non-object payloads", () => {
  assert.equal(isProviderAuthErrorPayload(null), false);
  assert.equal(isProviderAuthErrorPayload(undefined), false);
  assert.equal(isProviderAuthErrorPayload("ProviderAuthError"), false);
});

test("isProviderAuthErrorPayload matches ProviderAuthError name/type case-insensitively", () => {
  assert.equal(isProviderAuthErrorPayload({ name: "ProviderAuthError" }), true);
  assert.equal(isProviderAuthErrorPayload({ type: "providerautherror" }), true);
  assert.equal(isProviderAuthErrorPayload({ name: "SomeOtherError" }), false);
});

test("isProviderAuthErrorPayload matches known auth error codes from multiple locations", () => {
  assert.equal(isProviderAuthErrorPayload({ errorCode: "provider_auth_error" }), true);
  assert.equal(isProviderAuthErrorPayload({ code: "AUTH_ERROR" }), true);
  assert.equal(isProviderAuthErrorPayload({ data: { errorCode: "invalid_api_key" } }), true);
  assert.equal(isProviderAuthErrorPayload({ data: { code: "api_key_invalid" } }), true);
  assert.equal(isProviderAuthErrorPayload({ errorCode: "authentication_failed" }), true);
  assert.equal(isProviderAuthErrorPayload({ errorCode: "totally_unrelated" }), false);
});

test("isProviderAuthErrorPayload requires provider id for 401/403 http status detection", () => {
  assert.equal(isProviderAuthErrorPayload({ providerID: "anthropic", status: 401 }), true);
  assert.equal(isProviderAuthErrorPayload({ providerId: "openai", statusCode: 403 }), true);
  assert.equal(
    isProviderAuthErrorPayload({ data: { providerID: "anthropic" }, response: { status: 401 } }),
    true,
  );
  assert.equal(isProviderAuthErrorPayload({ status: 401 }), false);
  assert.equal(isProviderAuthErrorPayload({ providerID: "anthropic", status: 500 }), false);
});

test("isProviderAuthErrorPayload matches unauthorized/forbidden codes only with provider id", () => {
  assert.equal(isProviderAuthErrorPayload({ authProvider: "openai", code: "unauthorized" }), true);
  assert.equal(
    isProviderAuthErrorPayload({ data: { authProvider: "openai" }, errorCode: "forbidden" }),
    true,
  );
  assert.equal(isProviderAuthErrorPayload({ code: "unauthorized" }), false);
});

test("isProviderAuthErrorPayload tolerates non-numeric statuses", () => {
  assert.equal(isProviderAuthErrorPayload({ providerID: "p", status: "not-a-number" }), false);
});
