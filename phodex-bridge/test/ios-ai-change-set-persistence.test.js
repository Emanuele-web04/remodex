const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

test("iOS AI change-set ledger stays encrypted and retries interrupted migrations", {
  skip: process.platform !== "darwin" ? "requires the macOS Swift compiler and CryptoKit" : false,
  timeout: 60000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-change-set-ledger-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const mobile = path.resolve(__dirname, "../../CodexMobile/CodexMobile");
  const source = fs.readFileSync(path.join(mobile, "Services/CodexService+MacContext.swift"), "utf8");
  // Compile the real ledger lifecycle methods without unrelated view, messaging, or defaults state.
  const methods = [
    ["func loadMacScopedAIChangeSets(", "func loadCurrentMacScopedDefaultsState("],
    ["func uniqueNormalizedMacDeviceIds(", "func migrateMacScopedLocalCaches("],
    ["func normalizedMacScopedDeviceId(", "func shouldLoadLegacyLocalStateFallback("],
  ].map(([start, end]) => {
    const first = source.indexOf(`    ${start}`);
    const last = source.indexOf(`    ${end}`, first);
    assert.ok(first >= 0 && last > first, `missing ledger lifecycle declaration: ${start}`);
    return source.slice(first, last);
  });
  const extracted = path.join(directory, "ChangeSetMacContext.swift");
  fs.writeFileSync(extracted, `import Foundation\nextension CodexService {\n${methods.join("\n")}\n}\n`);
  const binary = path.join(directory, "change-set-ledger");
  execFileSync("xcrun", ["swiftc", "-default-isolation", "MainActor", "-parse-as-library",
    "-module-cache-path", path.join(directory, "cache"),
    ...["AIChangeSetModels", "GitActionModels", "JSONValue"]
      .map((name) => path.join(mobile, "Models", `${name}.swift`)),
    ...["AIChangeSetPersistence", "CodexLocalPersistenceKeyProvider"]
      .map((name) => path.join(mobile, "Services", `${name}.swift`)),
    extracted, path.join(__dirname, "fixtures/ai-change-set-persistence-harness.swift"),
    "-o", binary], { timeout: 45000 });
  const output = execFileSync(binary, [directory], {
    encoding: "utf8",
    env: { ...process.env, CFFIXED_USER_HOME: directory },
    timeout: 10000,
  });
  assert.match(output, /AI change-set ledger recovery checks passed/);
});
