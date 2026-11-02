const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

test("iOS chat and review sends keep their original thread when it is missing", {
  skip: process.platform !== "darwin" ? "requires the macOS Swift compiler" : false,
  timeout: 60000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-thread-identity-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const mobile = path.resolve(__dirname, "../../CodexMobile/CodexMobile");
  const turns = fs.readFileSync(path.join(mobile, "Services/CodexService+ThreadsTurns.swift"), "utf8");
  const extracted = path.join(directory, "Turns.swift");
  const start = turns.slice(turns.indexOf("    func startTurn("), turns.indexOf("    // Lets the New Chat handoff"));
  const failure = turns.slice(turns.indexOf("    func handleTurnStartFailure("),
    turns.indexOf("    // Handles successful turn/start bookkeeping"));
  fs.writeFileSync(extracted, `import Foundation\nextension CodexService {\n${start}\n${failure}\n}`);
  const binary = path.join(directory, "thread-identity");
  execFileSync("xcrun", ["swiftc", "-default-isolation", "MainActor", "-parse-as-library",
    "-module-cache-path", path.join(directory, "cache"),
    path.join(mobile, "Models/JSONValue.swift"),
    path.join(mobile, "Models/RPCMessage.swift"),
    path.join(mobile, "Services/CodexService+Review.swift"),
    extracted, path.join(__dirname, "fixtures/thread-identity-harness.swift"), "-o", binary], { timeout: 45000 });
  const output = execFileSync(binary, { encoding: "utf8", timeout: 10000 });
  assert.match(output, /thread identity checks passed/);
});
