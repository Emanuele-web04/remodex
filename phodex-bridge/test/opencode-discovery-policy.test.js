// FILE: opencode-discovery-policy.test.js
// Purpose: Verifies Remodex app client-param discovery policy with env overrides.

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  resolveDiscoverProjectsEnabled,
  resolveDiscoverSessionsEnabled,
} = require("../src/opencode-discovery-policy");

test("resolveDiscoverSessionsEnabled defaults off without client params or env", () => {
  assert.equal(resolveDiscoverSessionsEnabled({}, {}), false);
  assert.equal(
    resolveDiscoverSessionsEnabled({}, { discoverOpenCodeSessions: false }),
    false,
  );
});

test("resolveDiscoverSessionsEnabled honors Remodex app thread/list params", () => {
  assert.equal(
    resolveDiscoverSessionsEnabled({}, { discoverOpenCodeSessions: true }),
    true,
  );
  assert.equal(
    resolveDiscoverSessionsEnabled({}, { discover_open_code_sessions: true }),
    true,
  );
});

test("resolveDiscoverSessionsEnabled env zero overrides client true", () => {
  assert.equal(
    resolveDiscoverSessionsEnabled(
      { REMODEX_OPENCODE_DISCOVER_SESSIONS: "0" },
      { discoverOpenCodeSessions: true },
    ),
    false,
  );
});

test("resolveDiscoverSessionsEnabled env one works without client params", () => {
  assert.equal(
    resolveDiscoverSessionsEnabled({ REMODEX_OPENCODE_DISCOVER_SESSIONS: "1" }, {}),
    true,
  );
});

test("resolveDiscoverProjectsEnabled mirrors client and env semantics", () => {
  assert.equal(resolveDiscoverProjectsEnabled({}, {}), false);
  assert.equal(
    resolveDiscoverProjectsEnabled({}, { discoverOpenCodeProjects: true }),
    true,
  );
  assert.equal(
    resolveDiscoverProjectsEnabled(
      { REMODEX_OPENCODE_DISCOVER_PROJECTS: "0" },
      { discoverOpenCodeProjects: true },
    ),
    false,
  );
});

test("discovery flags are off when OpenCode runtime is disabled", () => {
  const env = { REMODEX_DISABLE_OPENCODE: "1" };
  assert.equal(
    resolveDiscoverSessionsEnabled(env, { discoverOpenCodeSessions: true }),
    false,
  );
  assert.equal(
    resolveDiscoverProjectsEnabled(env, { discoverOpenCodeProjects: true }),
    false,
  );
});