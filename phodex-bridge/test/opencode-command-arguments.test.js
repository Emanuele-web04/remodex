// FILE: opencode-command-arguments.test.js
// Purpose: Table-driven fixtures for serializeCommandArguments (PM-1 / design §5b).
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-command-arguments

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  deriveRequiresArguments,
  extractNumericPlaceholderKeys,
  usesArgumentsOnlyPlaceholder,
  mapSdkCommandToBridge,
  serializeCommandArguments,
} = require("../src/opencode-command-arguments");

const INIT_TEMPLATE_SNIPPET =
  "User-provided focus or constraints (honor these):\n$ARGUMENTS";

const REVIEW_TEMPLATE_SNIPPET = "Input: $ARGUMENTS";

test("deriveRequiresArguments is false for empty template and hints", () => {
  assert.equal(deriveRequiresArguments("", []), false);
});

test("deriveRequiresArguments is true when hints are present", () => {
  assert.equal(deriveRequiresArguments("", ["scope"]), true);
});

test("deriveRequiresArguments is true for $ARGUMENTS or $n in template", () => {
  assert.equal(deriveRequiresArguments(INIT_TEMPLATE_SNIPPET, []), true);
  assert.equal(deriveRequiresArguments("Run review on $1", []), true);
});

test("usesArgumentsOnlyPlaceholder detects lone $ARGUMENTS templates", () => {
  assert.equal(usesArgumentsOnlyPlaceholder(INIT_TEMPLATE_SNIPPET, []), true);
  assert.equal(usesArgumentsOnlyPlaceholder(INIT_TEMPLATE_SNIPPET, ["$ARGUMENTS"]), true);
  assert.equal(usesArgumentsOnlyPlaceholder("Do $1 then $ARGUMENTS", ["$1", "$ARGUMENTS"]), false);
});

test("extractNumericPlaceholderKeys returns sorted unique placeholders", () => {
  assert.deepEqual(extractNumericPlaceholderKeys("A $2 B $1 C $2"), ["$1", "$2"]);
});

test("serializeCommandArguments passes full string for $ARGUMENTS-only templates", () => {
  const serialized = serializeCommandArguments({
    template: INIT_TEMPLATE_SNIPPET,
    hints: ["$ARGUMENTS"],
    fields: [{ key: "$ARGUMENTS", value: "focus on tests\nand docs" }],
  });
  assert.equal(serialized, "focus on tests\nand docs");
});

test("serializeCommandArguments quotes spaced tokens for numeric placeholders", () => {
  const serialized = serializeCommandArguments({
    template: "Review commit $1 with scope $2",
    hints: ["$1", "$2"],
    fields: [
      { key: "$1", value: "abc123" },
      { key: "$2", value: "security review" },
    ],
  });
  assert.equal(serialized, 'abc123 "security review"');
});

test("serializeCommandArguments joins hint-ordered values when template has no placeholders", () => {
  const serialized = serializeCommandArguments({
    template: "Plain command body",
    hints: ["topic", "depth"],
    fields: [
      { key: "topic", value: "auth" },
      { key: "depth", value: "deep dive" },
    ],
  });
  assert.equal(serialized, 'auth "deep dive"');
});

test("serializeCommandArguments passes trimmed text when no placeholders", () => {
  const serialized = serializeCommandArguments({
    template: "Summarize the repo",
    hints: [],
    fields: [{ key: "input", value: "  extra context  " }],
  });
  assert.equal(serialized, "extra context");
});

test("mapSdkCommandToBridge derives requiresArguments from SDK shape", () => {
  const mapped = mapSdkCommandToBridge({
    name: "init",
    description: "guided AGENTS.md setup",
    template: INIT_TEMPLATE_SNIPPET,
    hints: ["$ARGUMENTS"],
    source: "command",
  });
  assert.equal(mapped.token, "/init");
  assert.equal(mapped.requiresArguments, true);
  assert.equal(mapped.template, INIT_TEMPLATE_SNIPPET);
  assert.deepEqual(mapped.hints, ["$ARGUMENTS"]);
  assert.equal(mapped.source, "command");
});

test("mapSdkCommandToBridge leaves requiresArguments false for zero-arg SDK rows", () => {
  const mapped = mapSdkCommandToBridge({
    name: "build",
    title: "Build",
    description: "Build the project",
    template: "Run the build",
    hints: [],
  });
  assert.equal(mapped.requiresArguments, false);
  assert.equal(mapped.template, "Run the build");
});