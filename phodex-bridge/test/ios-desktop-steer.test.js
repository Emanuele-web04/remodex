const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

test("iOS recovers a definitively ended Desktop steer without replaying uncertain delivery", {
  skip: process.platform !== "darwin" ? "requires the macOS Swift compiler" : false,
  timeout: 60000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-desktop-steer-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const mobile = path.resolve(__dirname, "../../CodexMobile/CodexMobile");
  const viewModel = fs.readFileSync(path.join(mobile, "Views/Turn/Core/TurnViewModel.swift"), "utf8");
  const extracted = path.join(directory, "Steer.swift");
  const steer = viewModel.slice(viewModel.indexOf("    func steerQueuedDraft("),
    viewModel.indexOf("    func resumeQueueAndFlushIfPossible("));
  fs.writeFileSync(extracted, `import Foundation\nextension TurnViewModel {\n${steer}\n}`);
  const binary = path.join(directory, "desktop-steer");
  execFileSync("xcrun", ["swiftc", "-default-isolation", "MainActor", "-parse-as-library",
    "-module-cache-path", path.join(directory, "cache"),
    path.join(mobile, "Models/JSONValue.swift"),
    path.join(mobile, "Models/RPCMessage.swift"),
    path.join(mobile, "Services/CodexServiceError.swift"),
    extracted, path.join(__dirname, "fixtures/desktop-steer-harness.swift"), "-o", binary], { timeout: 45000 });
  const output = execFileSync(binary, { encoding: "utf8", timeout: 10000 });
  assert.match(output, /desktop steer checks passed/);
});
