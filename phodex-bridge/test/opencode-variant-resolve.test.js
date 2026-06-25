"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { resolveOpenCodeVariantForPrompt } = require("../src/opencode-variant-resolve");

describe("resolveOpenCodeVariantForPrompt", () => {
  it("omits variant when effort has no catalog match", () => {
    const result = resolveOpenCodeVariantForPrompt({
      effort: "high",
      modelRecord: { variants: { max: {} } },
    });
    assert.equal(result.variant, undefined);
    assert.equal(result.omittedReason, "no_catalog_match");
  });

  it("passes variant when effort matches catalog key", () => {
    const result = resolveOpenCodeVariantForPrompt({
      effort: "max",
      modelRecord: { variants: { max: {}, fast: {} } },
    });
    assert.equal(result.variant, "max");
    assert.equal(result.omittedReason, null);
  });
});