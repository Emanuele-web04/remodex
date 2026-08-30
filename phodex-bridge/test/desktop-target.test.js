// FILE: desktop-target.test.js
// Purpose: Verifies configurable Codex Desktop target validation and isolation.
// Layer: Unit test

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const {
  activateCodexHome,
  buildCodexDeepLink,
  desktopTargetFingerprint,
  normalizeDesktopTarget,
  validateDesktopTarget,
} = require("../src/desktop-target");

test("legacy configuration retains primary target defaults", () => {
  const target = normalizeDesktopTarget({}, {
    osImpl: { homedir: () => "/Users/test" },
    fsImpl: { existsSync: () => true },
  });
  assert.deepEqual(target, {
    codexHome: "/Users/test/.codex",
    codexBundleId: "com.openai.codex",
    codexAppPath: "/Applications/ChatGPT.app",
    codexUrlScheme: "codex",
    desktopIpcSocketPath: "",
  });
});

function createTargetFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "remodex target "));
  const codexHome = path.join(root, "Codex Home");
  const codexAppPath = path.join(root, "ChatGPT Personal.app");
  fs.mkdirSync(codexHome, { recursive: true });
  fs.mkdirSync(path.join(codexAppPath, "Contents"), { recursive: true });
  fs.writeFileSync(path.join(codexAppPath, "Contents", "Info.plist"), "fixture");
  return { root, codexHome, codexAppPath };
}

test("custom target validation derives IPC strictly from its Codex home", (t) => {
  const fixture = createTargetFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const calls = [];
  const target = validateDesktopTarget({
    codexHome: fixture.codexHome,
    codexBundleId: "com.openai.codex.secondary",
    codexAppPath: fixture.codexAppPath,
    codexUrlScheme: "codex-secondary",
    desktopIpcSocketPath: "/tmp/unsafe-primary.sock",
  }, {
    platform: "darwin",
    execFileSyncImpl(command, args) {
      calls.push([command, args]);
      if (args.includes("CFBundleIdentifier")) {
        return "com.openai.codex.secondary\n";
      }
      return JSON.stringify({
        CFBundleURLTypes: [{ CFBundleURLSchemes: ["codex-secondary"] }],
      });
    },
  });

  assert.equal(target.desktopIpcSocketPath, path.join(fixture.codexHome, "ipc", "ipc.sock"));
  assert.equal(target.codexTargetFingerprint, desktopTargetFingerprint(target));
  assert.equal(calls.length, 2);
});

test("target validation rejects relative homes and app paths", (t) => {
  const fixture = createTargetFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const input = {
    codexHome: fixture.codexHome,
    codexBundleId: "com.openai.codex.secondary",
    codexAppPath: fixture.codexAppPath,
    codexUrlScheme: "codex-secondary",
  };
  assert.throws(
    () => validateDesktopTarget({ ...input, codexHome: ".codex-secondary" }, { platform: "linux" }),
    /Codex home must be an absolute path/
  );
  assert.throws(
    () => validateDesktopTarget({ ...input, codexAppPath: "ChatGPT Personal.app" }, { platform: "linux" }),
    /Codex app must be an absolute path/
  );
});

test("target validation rejects mismatched bundle metadata and schemes", (t) => {
  const fixture = createTargetFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const input = {
    codexHome: fixture.codexHome,
    codexBundleId: "com.openai.codex.secondary",
    codexAppPath: fixture.codexAppPath,
    codexUrlScheme: "codex-secondary",
  };
  assert.throws(() => validateDesktopTarget(input, {
    platform: "darwin",
    execFileSyncImpl(command, args) {
      return args.includes("CFBundleIdentifier")
        ? "com.openai.codex.wrong\n"
        : JSON.stringify({ CFBundleURLTypes: [] });
    },
  }), /not com\.openai\.codex\.secondary/);
  assert.throws(() => validateDesktopTarget(input, {
    platform: "darwin",
    execFileSyncImpl(command, args) {
      return args.includes("CFBundleIdentifier")
        ? "com.openai.codex.secondary\n"
        : JSON.stringify({ CFBundleURLTypes: [{ CFBundleURLSchemes: ["codex"] }] });
    },
  }), /does not register the codex-secondary/);
});

test("deep links and child environment use the selected target", () => {
  const env = { CODEX_HOME: "/old" };
  activateCodexHome({ codexHome: "/Users/test/.codex-secondary" }, { env });
  assert.equal(env.CODEX_HOME, "/Users/test/.codex-secondary");
  assert.equal(
    buildCodexDeepLink("threads/thread-123", "codex-secondary"),
    "codex-secondary://threads/thread-123"
  );
});
