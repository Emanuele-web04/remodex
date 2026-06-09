// FILE: runtime-detection.test.js
// Purpose: Verifies tri-state runtime detection for bridge preflight.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/runtime-detection

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const {
  formatRuntimePreflightFailureMessage,
  resolveAvailableRuntimes,
} = require("../src/runtime-detection");

function createLookupExec({ codex = false, opencode = false } = {}) {
  return (command, args) => {
    const target = String(args?.[0] || "");
    if (command === "which" && target === "codex" && codex) {
      return "/usr/local/bin/codex";
    }
    if (command === "which" && target === "opencode" && opencode) {
      return "/usr/local/bin/opencode";
    }
    const error = new Error(`not found: ${target}`);
    error.status = 1;
    throw error;
  };
}

test("resolveAvailableRuntimes reports codex+opencode when both commands are on PATH", () => {
  const runtimes = resolveAvailableRuntimes(
    { PATH: "/usr/local/bin", REMODEX_DISABLE_OPENCODE: "" },
    { execFileSyncImpl: createLookupExec({ codex: true, opencode: true }) },
  );

  assert.equal(runtimes.mode, "codex+opencode");
  assert.equal(runtimes.codexAvailable, true);
  assert.equal(runtimes.opencodeAvailable, true);
});

test("resolveAvailableRuntimes reports opencode-only when codex is missing", () => {
  const runtimes = resolveAvailableRuntimes(
    { PATH: "/usr/local/bin" },
    { execFileSyncImpl: createLookupExec({ codex: false, opencode: true }) },
  );

  assert.equal(runtimes.mode, "opencode-only");
  assert.equal(runtimes.codexAvailable, false);
  assert.equal(runtimes.opencodeAvailable, true);
});

test("resolveAvailableRuntimes reports codex-only when OpenCode is disabled", () => {
  const runtimes = resolveAvailableRuntimes(
    { PATH: "/usr/local/bin", REMODEX_DISABLE_OPENCODE: "1" },
    { execFileSyncImpl: createLookupExec({ codex: true, opencode: true }) },
  );

  assert.equal(runtimes.mode, "codex-only");
  assert.equal(runtimes.codexAvailable, true);
  assert.equal(runtimes.opencodeAvailable, false);
});

test("resolveAvailableRuntimes reports none when neither runtime is available", () => {
  const runtimes = resolveAvailableRuntimes(
    { PATH: "/usr/local/bin" },
    { execFileSyncImpl: createLookupExec({ codex: false, opencode: false }) },
  );

  assert.equal(runtimes.mode, "none");
  assert.equal(runtimes.codexAvailable, false);
  assert.equal(runtimes.opencodeAvailable, false);
});

test("resolveAvailableRuntimes treats bundled Codex.app as codex availability", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-runtime-detect-"));
  const appPath = path.join(tempDir, "Codex.app");
  const bundledCodexPath = path.join(appPath, "Contents", "Resources", "codex");
  fs.mkdirSync(path.dirname(bundledCodexPath), { recursive: true });
  fs.writeFileSync(bundledCodexPath, "#!/bin/sh\nexit 0\n", { mode: 0o755 });

  try {
    const runtimes = resolveAvailableRuntimes(
      { PATH: "/usr/local/bin" },
      {
        appPath,
        execFileSyncImpl: createLookupExec({ codex: false, opencode: true }),
      },
    );

    assert.equal(runtimes.mode, "codex+opencode");
    assert.equal(runtimes.codexFromBundle, true);
    assert.equal(runtimes.codexAvailable, true);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("formatRuntimePreflightFailureMessage explains install options", () => {
  const message = formatRuntimePreflightFailureMessage({ opencodeCommand: "opencode" });
  assert.match(message, /at least one coding runtime/i);
  assert.match(message, /npm install -g @openai\/codex@latest/);
  assert.match(message, /opencode/);
});