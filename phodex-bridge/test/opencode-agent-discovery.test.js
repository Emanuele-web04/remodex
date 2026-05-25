// FILE: opencode-agent-discovery.test.js
// Purpose: Verifies OpenCode agent discovery via CLI output parsing and catalog provider.
// Layer: Unit test
// Depends on: node:test, node:assert/strict, node:fs, ../src/opencode-agent-discovery

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  createOpenCodeAgentCatalogProvider,
  discoverOpenCodeAgentCatalog,
  parseOpenCodeAgentListOutput,
  readOpenCodeDefaultAgentName,
} = require("../src/opencode-agent-discovery");

const fixturePath = path.join(__dirname, "fixtures/opencode/agent-list-sample.txt");
const agentListSample = fs.readFileSync(fixturePath, "utf8");

test("parseOpenCodeAgentListOutput parses agent headers and ignores permission blocks", () => {
  const parsed = parseOpenCodeAgentListOutput(agentListSample);

  assert.deepEqual(
    parsed.map((entry) => `${entry.name}|${entry.mode}`),
    [
      "Sisyphus - Ultraworker|primary",
      "Hephaestus - Deep Agent|primary",
      "build|subagent",
      "plan|subagent",
      "title|primary",
      "compaction|primary",
      "summary|primary",
      "explore|subagent",
    ],
  );
});

test("discoverOpenCodeAgentCatalog filters primary/all, hidden natives, and plan from payload", async () => {
  const configDir = "/tmp/opencode-agent-discovery-config";
  const catalog = await discoverOpenCodeAgentCatalog({
    configDir,
    execFileImpl: async () => ({ stdout: agentListSample }),
    fsImpl: {
      readFileSync(filePath) {
        if (filePath.endsWith("oh-my-openagent.json")) {
          throw new Error("should not read oh-my-openagent.json");
        }
        if (filePath.endsWith("opencode.json")) {
          return JSON.stringify({ default_agent: "Hephaestus - Deep Agent" });
        }
        throw new Error(`unexpected read: ${filePath}`);
      },
    },
  });

  assert.equal(catalog.defaultBuildAgentName, "Hephaestus - Deep Agent");
  assert.equal(catalog.defaultPlanAgentName, "plan");
  assert.deepEqual(
    catalog.agents.map((entry) => entry.id),
    ["Sisyphus - Ultraworker", "Hephaestus - Deep Agent"],
  );
  assert.ok(catalog.agents.every((entry) => entry.id !== "plan"));
  assert.ok(catalog.agents.every((entry) => !["title", "compaction", "summary"].includes(entry.id)));
  assert.ok(catalog.agents.find((entry) => entry.id === "Hephaestus - Deep Agent")?.isDefaultBuild);
});

test("discoverOpenCodeAgentCatalog returns degraded build/plan defaults when CLI fails", async () => {
  const catalog = await discoverOpenCodeAgentCatalog({
    execFileImpl: async () => {
      throw new Error("ENOENT");
    },
    fsImpl: {
      readFileSync(filePath) {
        if (filePath.endsWith("oh-my-openagent.json")) {
          throw new Error("should not read oh-my-openagent.json");
        }
        throw new Error("missing");
      },
    },
  });

  assert.equal(catalog.status, "degraded");
  assert.equal(catalog.defaultBuildAgentName, "build");
  assert.equal(catalog.defaultPlanAgentName, "plan");
  assert.deepEqual(catalog.agents.map((entry) => entry.id), ["build"]);
});

test("readOpenCodeDefaultAgentName reads default_agent from opencode.json only", () => {
  const configDir = "/tmp/opencode-default-agent";
  const defaultAgent = readOpenCodeDefaultAgentName({
    configDir,
    fsImpl: {
      readFileSync(filePath) {
        if (filePath.endsWith("opencode.json")) {
          return JSON.stringify({ default_agent: "Sisyphus - Ultraworker" });
        }
        throw new Error("missing");
      },
    },
  });

  assert.equal(defaultAgent, "Sisyphus - Ultraworker");
});

test("createOpenCodeAgentCatalogProvider caches catalog results", async () => {
  let calls = 0;
  const provider = createOpenCodeAgentCatalogProvider({
    discover: async () => {
      calls += 1;
      return {
        agents: [{ id: "build", displayName: "Build", isDefaultBuild: true, isDefaultPlan: false }],
        defaultBuildAgentName: "build",
        defaultPlanAgentName: "plan",
      };
    },
    ttlMs: 60_000,
  });

  const first = await provider.get();
  const second = await provider.get();
  assert.equal(calls, 1);
  assert.equal(first, second);
});
