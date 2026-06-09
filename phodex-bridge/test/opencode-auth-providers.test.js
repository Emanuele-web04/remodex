"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { readAuthProviderIds } = require("../src/opencode-auth-providers");

describe("readAuthProviderIds", () => {
  it("reads provider keys only from auth.json", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-auth-"));
    const authPath = path.join(dir, "auth.json");
    fs.writeFileSync(authPath, JSON.stringify({ deepseek: { token: "secret" }, "opencode-go": {} }), "utf8");
    const result = readAuthProviderIds({ authPath });
    assert.equal(result.authDiscoveryReasonCode, "ok");
    assert.deepEqual(result.ids.sort(), ["deepseek", "opencode-go"]);
  });
});