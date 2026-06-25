"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { parseOpenCodeModelSlug } = require("../src/opencode-model-slug");

describe("parseOpenCodeModelSlug", () => {
  it("parses provider/model slugs", () => {
    assert.deepEqual(parseOpenCodeModelSlug("opencode-go/deepseek-v4-flash"), {
      providerID: "opencode-go",
      modelID: "deepseek-v4-flash",
    });
  });

  it("returns null for invalid slugs", () => {
    assert.equal(parseOpenCodeModelSlug(""), null);
    assert.equal(parseOpenCodeModelSlug("no-separator"), null);
    assert.equal(parseOpenCodeModelSlug("/missing-provider"), null);
  });
});