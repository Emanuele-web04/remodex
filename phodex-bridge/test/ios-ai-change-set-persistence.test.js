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
  const macContext = fs.readFileSync(path.join(mobile, "Services/CodexService+MacContext.swift"), "utf8");
  const changeSets = fs.readFileSync(path.join(mobile, "Services/CodexService+AIChangeSets.swift"), "utf8");
  // Compile the real ledger lifecycle methods without unrelated view, messaging, or defaults state.
  const methods = [
    [macContext, "func loadMacScopedAIChangeSets(", "func loadCurrentMacScopedDefaultsState("],
    [macContext, "func uniqueNormalizedMacDeviceIds(", "func migrateMacScopedLocalCaches("],
    [macContext, "func normalizedMacScopedDeviceId(", "func shouldLoadLegacyLocalStateFallback("],
    [changeSets, "func noteTurnFinished(", "// Remembers canonical repo roots"],
    [changeSets, "func hasRevertPatchPayload(", "func latestAssistantMessageId("],
  ].map(([source, start, end]) => extractDeclaration(source, `    ${start}`, `    ${end}`));
  const revertError = extractDeclaration(changeSets, "enum AIChangeSetError:", "private struct AIRevertOverlapAnalysis");
  const revertRequest = extractDeclaration(changeSets, "private struct AIRevertBridgeRequest", "extension CodexService {");
  const buildRevert = extractDeclaration(changeSets, "    var revertLedgerAvailabilityError:", "    func hasRevertPatchPayload(");
  const fixture = fs.readFileSync(path.join(__dirname, "fixtures/ai-change-set-persistence-harness.swift"), "utf8");
  const extracted = path.join(directory, "ChangeSetMacContext.swift");
  fs.writeFileSync(extracted, `import Foundation
${revertError}
${revertRequest}
extension CodexService {
${methods.join("\n")}
}
private extension CodexService {
${buildRevert}
}
${fixture}`);
  const binary = path.join(directory, "change-set-ledger");
  execFileSync("xcrun", ["swiftc", "-default-isolation", "MainActor", "-parse-as-library",
    "-module-cache-path", path.join(directory, "cache"),
    ...["AIChangeSetModels", "GitActionModels", "JSONValue"]
      .map((name) => path.join(mobile, "Models", `${name}.swift`)),
    ...["AIChangeSetPersistence", "CodexLocalPersistenceKeyProvider"]
      .map((name) => path.join(mobile, "Services", `${name}.swift`)),
    extracted,
    "-o", binary], { timeout: 45000 });
  const output = execFileSync(binary, [directory], {
    encoding: "utf8",
    env: { ...process.env, CFFIXED_USER_HOME: directory },
    timeout: 10000,
  });
  assert.match(output, /AI change-set ledger recovery checks passed/);
});

function extractDeclaration(source, start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first);
  assert.ok(first >= 0 && last > first, `missing ledger declaration: ${start}`);
  return source.slice(first, last);
}
