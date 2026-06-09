// FILE: opencode-runtime-policy.test.js
// Purpose: Verifies default-on OpenCode policy and explicit disable flags.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-runtime-policy

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  isOpenCodeRuntimeDisabled,
  isOpenCodeRuntimeEnabled,
} = require("../src/opencode-runtime-policy");

test("OpenCode is enabled by default", () => {
  assert.equal(isOpenCodeRuntimeEnabled({}), true);
  assert.equal(isOpenCodeRuntimeDisabled({}), false);
});

test("REMODEX_DISABLE_OPENCODE opts out", () => {
  assert.equal(isOpenCodeRuntimeDisabled({ REMODEX_DISABLE_OPENCODE: "1" }), true);
});

test("legacy REMODEX_ENABLE_OPENCODE=0 opts out", () => {
  assert.equal(isOpenCodeRuntimeDisabled({ REMODEX_ENABLE_OPENCODE: "0" }), true);
});

test("resolveDefaultOpenCodeAgent defaults to build", () => {
  const { resolveDefaultOpenCodeAgent } = require("../src/opencode-runtime-policy");
  assert.equal(resolveDefaultOpenCodeAgent({}), "build");
});

test("REMODEX_OPENCODE_DEFAULT_AGENT overrides the default agent", () => {
  const { resolveDefaultOpenCodeAgent } = require("../src/opencode-runtime-policy");
  assert.equal(resolveDefaultOpenCodeAgent({ REMODEX_OPENCODE_DEFAULT_AGENT: "plan" }), "plan");
  assert.equal(resolveDefaultOpenCodeAgent({ REMODEX_OPENCODE_DEFAULT_AGENT: "  " }), "build");
});
