// FILE: opencode-runtime-status.test.js
// Purpose: Verifies OpenCode runtime status and version comparison helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-runtime-status

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  buildOpenCodeRuntimeStatus,
  isVersionBelowMinimum,
  OPENCODE_MIN_CLI_VERSION,
} = require("../src/opencode-runtime-status");

test("isVersionBelowMinimum detects older OpenCode CLI", () => {
  assert.equal(isVersionBelowMinimum("1.15.11", OPENCODE_MIN_CLI_VERSION), true);
  assert.equal(isVersionBelowMinimum("1.15.12", OPENCODE_MIN_CLI_VERSION), false);
  assert.equal(isVersionBelowMinimum("1.15.13", OPENCODE_MIN_CLI_VERSION), false);
  assert.equal(isVersionBelowMinimum("2.0.0", OPENCODE_MIN_CLI_VERSION), false);
});

test("buildOpenCodeRuntimeStatus marks versionBelowMinimum", () => {
  const status = buildOpenCodeRuntimeStatus({
    enabled: true,
    version: "1.0.0",
    serveUrl: "http://127.0.0.1:4200",
    sessionCount: 2,
    handoffEnvEnabled: true,
  });
  assert.equal(status.versionBelowMinimum, true);
  assert.equal(status.minVersion, OPENCODE_MIN_CLI_VERSION);
  assert.equal(status.sessionCount, 2);
  assert.equal(status.handoffEnvEnabled, true);
});

test("buildOpenCodeRuntimeStatus includes connected provider discovery fields", () => {
  const status = buildOpenCodeRuntimeStatus({
    connectedProviders: [{ id: "anthropic", displayName: "Anthropic", modelCount: 3 }],
    providerDiscoveryReasonCode: "ok",
  });
  assert.equal(status.connectedProviders.length, 1);
  assert.equal(status.providerDiscoveryReasonCode, "ok");
});

test("buildOpenCodeRuntimeStatus preserves authConfigured tri-state", () => {
  assert.equal(
    buildOpenCodeRuntimeStatus({ authConfigured: true }).authConfigured,
    true,
  );
  assert.equal(
    buildOpenCodeRuntimeStatus({ authConfigured: false }).authConfigured,
    false,
  );
  assert.equal(buildOpenCodeRuntimeStatus({}).authConfigured, null);
});