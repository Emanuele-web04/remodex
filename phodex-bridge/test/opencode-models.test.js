// FILE: opencode-models.test.js
// Purpose: Verifies OpenCode provider model parsing and provider normalization helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-models

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  DEFAULT_OPENCODE_MODEL,
  parseOpenCodeModelsOutput,
  readModelProvider,
} = require("../src/opencode-models");

test("OpenCode model parser keeps valid provider/model refs and dedupes them", () => {
  const models = parseOpenCodeModelsOutput(`
opencode/gpt-5.5
not-a-model
openai/gpt-5.4
opencode/gpt-5.5
{"json":"ignored"}
`);

  assert.deepEqual(
    models.map((model) => model.id),
    ["opencode/gpt-5.5", "openai/gpt-5.4"],
  );
  assert.equal(models[0].modelProvider, "opencode");
  assert.equal(models[0].isDefault, true);
  assert.equal(models[0].model, DEFAULT_OPENCODE_MODEL);
});

test("provider reader accepts aliases and nested collaboration settings", () => {
  assert.equal(readModelProvider({ modelProvider: "open-code" }), "opencode");
  assert.equal(
    readModelProvider({
      collaborationMode: {
        settings: {
          model_provider: "open_code",
        },
      },
    }),
    "opencode",
  );
  assert.equal(readModelProvider({}), "codex");
});
