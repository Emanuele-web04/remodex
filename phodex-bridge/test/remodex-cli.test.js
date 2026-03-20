// FILE: remodex-cli.test.js
// Purpose: Verifies the public CLI exposes a simple version command for support/debugging.
// Layer: Integration-lite test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, child_process, fs, os, path, ../package.json, ../src/daemon-state

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { version } = require("../package.json");
const {
  writeBridgeStatus,
  writeDaemonConfig,
  writePairingSession,
} = require("../src/daemon-state");

test("remodex --version prints the package version", () => {
  const cliPath = path.join(__dirname, "..", "bin", "remodex.js");
  const output = execFileSync(process.execPath, [cliPath, "--version"], {
    encoding: "utf8",
  }).trim();

  assert.equal(output, version);
});

test("remodex status --json exposes daemon metadata for companion apps", {
  skip: process.platform !== "darwin",
}, () => {
  const cliPath = path.join(__dirname, "..", "bin", "remodex.js");

  withTempDaemonEnv(({ rootDir }) => {
    writeDaemonConfig({ relayUrl: "ws://127.0.0.1:9000/relay" });
    writeBridgeStatus({ state: "running", connectionStatus: "connected", pid: 77 });
    writePairingSession({ sessionId: "session-json", relay: "ws://127.0.0.1:9000/relay" });

    const output = execFileSync(process.execPath, [cliPath, "status", "--json"], {
      encoding: "utf8",
      env: {
        ...process.env,
        HOME: rootDir,
        REMODEX_DEVICE_STATE_DIR: rootDir,
      },
    }).trim();
    const payload = JSON.parse(output);

    assert.equal(payload.currentVersion, version);
    assert.equal(payload.daemonConfig?.relayUrl, "ws://127.0.0.1:9000/relay");
    assert.equal(payload.bridgeStatus?.connectionStatus, "connected");
    assert.equal(payload.pairingSession?.pairingPayload?.sessionId, "session-json");
  });
});

function withTempDaemonEnv(run) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const previousHome = process.env.HOME;
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-cli-test-"));
  process.env.REMODEX_DEVICE_STATE_DIR = rootDir;
  process.env.HOME = rootDir;

  try {
    return run({ rootDir });
  } finally {
    if (previousDir === undefined) {
      delete process.env.REMODEX_DEVICE_STATE_DIR;
    } else {
      process.env.REMODEX_DEVICE_STATE_DIR = previousDir;
    }
    if (previousHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = previousHome;
    }
    fs.rmSync(rootDir, { recursive: true, force: true });
  }
}
