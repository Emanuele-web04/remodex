// FILE: agent-runtime-model-catalog.test.js
// Purpose: Verifies runtime-owned provider/model discovery helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/agent-runtime-model-catalog

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  createOpenCodeModelCatalog,
  discoverOpenCodeModelCatalog,
  openCodeModelPayloadForSelection,
  parseOpenCodeModelsOutput,
  readOpenCodePreferredModelId,
} = require("../src/agent-runtime-model-catalog");

test("OpenCode model output is parsed as provider/model identifiers", () => {
  assert.deepEqual(parseOpenCodeModelsOutput(`
opencode-go/deepseek-v4-flash
opencode-go/qwen3.6-plus
vercel/alibaba/qwen3.6-plus
not-a-model
opencode-go/deepseek-v4-flash
  `), [
    "opencode-go/deepseek-v4-flash",
    "opencode-go/qwen3.6-plus",
    "vercel/alibaba/qwen3.6-plus",
  ]);
});

test("OpenCode catalog groups discovered models by provider", () => {
  const catalog = createOpenCodeModelCatalog({
    modelIds: [
      "opencode-go/deepseek-v4-flash",
      "opencode-go/qwen3.6-plus",
      "vercel/alibaba/qwen3.6-plus",
    ],
    preferredModelId: "vercel/alibaba/qwen3.6-plus",
  });

  assert.equal(catalog.defaultModelId, "vercel/alibaba/qwen3.6-plus");
  assert.equal(catalog.defaultProviderId, "vercel");
  assert.deepEqual(catalog.providers.map((provider) => provider.id), ["opencode-go", "vercel"]);
  assert.deepEqual(catalog.providers.find((provider) => provider.id === "opencode-go").modelIds, [
    "opencode-go/deepseek-v4-flash",
    "opencode-go/qwen3.6-plus",
  ]);
  assert.equal(catalog.models.find((model) => model.id === "vercel/alibaba/qwen3.6-plus").modelID, "alibaba/qwen3.6-plus");
});

test("OpenCode selection dispatch preserves native provider and nested model ids", () => {
  const catalog = createOpenCodeModelCatalog({
    modelIds: ["vercel/alibaba/qwen3.6-plus"],
    preferredModelId: "vercel/alibaba/qwen3.6-plus",
  });

  assert.deepEqual(openCodeModelPayloadForSelection(catalog.models[0]), {
    providerID: "vercel",
    modelID: "alibaba/qwen3.6-plus",
  });
});

test("OpenCode preferred model is read from local model state shape", () => {
  const fsImpl = {
    readFileSync() {
      return JSON.stringify({
        favorite: [],
        recent: [
          { providerID: "opencode-go", modelID: "kimi-k2.6" },
        ],
      });
    },
  };

  assert.equal(readOpenCodePreferredModelId({ fsImpl }), "opencode-go/kimi-k2.6");
});

test("OpenCode discovery uses opencode models output and local preferred model", async () => {
  const fsImpl = {
    readFileSync() {
      return JSON.stringify({
        recent: [
          { providerID: "opencode-go", modelID: "qwen3.6-plus" },
        ],
      });
    },
  };
  const catalog = await discoverOpenCodeModelCatalog({
    fsImpl,
    execFileImpl: async () => ({
      stdout: "opencode-go/deepseek-v4-flash\nopencode-go/qwen3.6-plus\n",
    }),
  });

  assert.equal(catalog.defaultModelId, "opencode-go/qwen3.6-plus");
  assert.equal(catalog.models.length, 2);
});
