const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

test("iOS stream recovery checks terminal identity and sends a continuation at most once", {
  skip: process.platform !== "darwin" ? "requires the macOS Swift compiler" : false,
  timeout: 60000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-stream-recovery-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const mobile = path.resolve(__dirname, "../../CodexMobile/CodexMobile");
  const binary = path.join(directory, "stream-recovery");
  const turns = fs.readFileSync(path.join(mobile, "Services/CodexService+ThreadsTurns.swift"), "utf8");
  const snapshot = turns.slice(turns.indexOf("    func turnStateSnapshot("), turns.indexOf("    private func knownParallelTurnIDs("));
  const statuses = turns.slice(turns.indexOf("    func normalizedInterruptTurnStatus("), turns.indexOf("    // Retries with snake_case params for strict or legacy server parsers."));
  const extracted = path.join(directory, "TurnSnapshot.swift");
  fs.writeFileSync(extracted, `import Foundation\nextension CodexService {\n${snapshot}\n${statuses}\n}`);
  execFileSync("xcrun", ["swiftc", "-default-isolation", "MainActor", "-module-cache-path",
    path.join(directory, "cache"), "-parse-as-library",
    path.join(mobile, "Models/JSONValue.swift"),
    path.join(mobile, "Models/CodexSyntheticIdentifiers.swift"),
    path.join(mobile, "Models/CodexStreamFailure.swift"),
    path.join(mobile, "Services/CodexService+StreamRecovery.swift"),
    path.join(mobile, "Views/Turn/Core/TurnViewModel+StreamRecovery.swift"),
    extracted, path.join(__dirname, "fixtures/stream-recovery-harness.swift"), "-o", binary], { timeout: 45000 });
  const output = execFileSync(binary, { encoding: "utf8", timeout: 10000 });
  assert.match(output, /stream recovery checks passed/);
});
