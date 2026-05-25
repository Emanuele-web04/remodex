// FILE: opencode-discovery.test.js
// Purpose: Verifies HTTP-first OpenCode discovery with CLI fallback.
// Layer: Unit test
// Depends on: node:test, node:assert/strict, node:fs, node:path, ../src/opencode-discovery

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  discoverOpenCodeAgentCatalog,
  discoverOpenCodeSkillCatalog,
  discoverOpenCodeProvidersHttp,
} = require("../src/opencode-discovery");

const agentsFixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, "fixtures/opencode/agents-http.json"), "utf8"),
);
const skillsFixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, "fixtures/opencode/skills-http.json"), "utf8"),
);
const providersFixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, "fixtures/opencode/providers-http.json"), "utf8"),
);

function createServerManager(routeImpl) {
  return {
    getStatus() {
      return { state: "ready", baseUrl: "http://127.0.0.1:4096" };
    },
    async request(method, requestPath) {
      return routeImpl(method, requestPath);
    },
  };
}

test("discoverOpenCodeAgentCatalog prefers HTTP agents when serve is ready", async () => {
  const catalog = await discoverOpenCodeAgentCatalog({
    serverManager: createServerManager(async (_method, requestPath) => {
      if (requestPath === "/agent") {
        return agentsFixture;
      }
      throw new Error(`unexpected ${requestPath}`);
    }),
    execFileImpl: async () => {
      throw new Error("CLI should not run when HTTP succeeds");
    },
  });

  assert.equal(catalog.source, "http");
  assert.deepEqual(catalog.agents.map((entry) => entry.id), ["build"]);
  assert.equal(catalog.defaultBuildAgentName, "build");
});

test("discoverOpenCodeSkillCatalog returns HTTP skills", async () => {
  const catalog = await discoverOpenCodeSkillCatalog({
    serverManager: createServerManager(async (_method, requestPath) => {
      if (requestPath === "/skill") {
        return skillsFixture;
      }
      throw new Error(`unexpected ${requestPath}`);
    }),
  });

  assert.equal(catalog.source, "http");
  assert.deepEqual(catalog.skills.map((skill) => skill.id), ["diagnose", "tdd"]);
});

test("discoverOpenCodeProvidersHttp maps provider models into catalog ids", async () => {
  const result = await discoverOpenCodeProvidersHttp(
    createServerManager(async (_method, requestPath) => {
      if (requestPath === "/provider") {
        return providersFixture;
      }
      throw new Error(`unexpected ${requestPath}`);
    }),
  );

  assert.equal(result.source, "http");
  assert.ok(result.catalog.models.some((model) => model.id === "opencode-go/deepseek-v4-flash"));
});
