const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

test("iOS runtime synchronization preserves pending edits across acknowledgement and reconnect races", {
  skip: process.platform !== "darwin" ? "requires the macOS Swift compiler" : false,
  timeout: 60000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-swift-settings-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const mobile = path.resolve(__dirname, "../../CodexMobile/CodexMobile");
  // Compile the actual persistence type and coordinator, with only the transport/host mocked.
  const service = fs.readFileSync(path.join(mobile, "Services/CodexService.swift"), "utf8");
  const override = service.slice(service.indexOf("struct CodexThreadRuntimeOverride:"), service.indexOf("struct CodexThreadCompletionBanner:"));
  const overrideFile = path.join(directory, "RuntimeOverride.swift");
  const config = fs.readFileSync(path.join(mobile, "Services/CodexService+RuntimeConfig.swift"), "utf8");
  const speed = config.slice(config.indexOf("    func effectiveServiceTier("), config.indexOf("    // Copies per-chat runtime overrides"));
  fs.writeFileSync(overrideFile, `import Foundation\n${override}\nextension CodexService {\n${speed}\n}`);
  const sources = ["JSONValue", "RPCMessage", "CodexServiceTier", "CodexModelOption", "CodexReasoningEffortOption", "CodexRuntimeSettings"]
    .map((file) => path.join(mobile, "Models", `${file}.swift`));
  const binary = path.join(directory, "runtime-settings");
  execFileSync("xcrun", ["swiftc", "-default-isolation", "MainActor", "-module-cache-path", path.join(directory, "cache"), "-parse-as-library", ...sources, overrideFile,
    path.join(mobile, "Views/Turn/Composer/TurnComposerRuntimeState.swift"),
    path.join(mobile, "Views/Turn/Composer/TurnComposerMetaMapper.swift"),
    path.join(mobile, "Services/CodexService+RuntimeSettingsSync.swift"), path.join(__dirname, "fixtures/runtime-settings-harness.swift"), "-o", binary], { timeout: 45000 });
  const output = execFileSync(binary, [path.join(__dirname, "fixtures/codex-runtime-contract.json")], { encoding: "utf8", timeout: 10000 });
  assert.match(output, /catalog checks passed/);
});
