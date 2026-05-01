// FILE: macos-launch-agent.test.js
// Purpose: Verifies launchd plist generation and macOS service cleanup helpers.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/macos-launch-agent, ../src/daemon-state

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  buildLaunchAgentPlist,
  getMacOSBridgeServiceStatus,
  mergeBridgeStatusForDaemon,
  resetMacOSBridgePairing,
  resolveLaunchAgentPlistPath,
  runMacOSBridgeService,
  startMacOSBridgeService,
  stopMacOSBridgeService,
} = require("../src/macos-launch-agent");
const {
  writeDaemonConfig,
  readBridgeStatus,
  readPairingSession,
  writeBridgeStatus,
  writePairingSession,
} = require("../src/daemon-state");

test("buildLaunchAgentPlist points launchd at run-service with remodex state paths", () => {
  const plist = buildLaunchAgentPlist({
    homeDir: "/Users/tester",
    pathEnv: "/usr/local/bin:/usr/bin",
    stateDir: "/Users/tester/.remodex",
    stdoutLogPath: "/Users/tester/.remodex/logs/bridge.stdout.log",
    stderrLogPath: "/Users/tester/.remodex/logs/bridge.stderr.log",
    nodePath: "/usr/local/bin/node",
    cliPath: "/tmp/remodex/bin/remodex.js",
  });

  assert.match(plist, /<string>com\.remodex\.bridge<\/string>/);
  assert.match(plist, /<string>run-service<\/string>/);
  assert.match(plist, /<key>KeepAlive<\/key>\s*<dict>\s*<key>SuccessfulExit<\/key>\s*<false\/>\s*<\/dict>/);
  assert.match(plist, /<key>REMODEX_DEVICE_STATE_DIR<\/key>/);
});

test("resolveLaunchAgentPlistPath writes into the user's LaunchAgents folder", () => {
  assert.equal(
    resolveLaunchAgentPlistPath({
      env: { HOME: "/Users/tester" },
      osImpl: { homedir: () => "/Users/fallback" },
    }),
    path.join("/Users/tester", "Library", "LaunchAgents", "com.remodex.bridge.plist")
  );
});

test("stopMacOSBridgeService clears stale pairing and status files", () => {
  withTempDaemonEnv(() => {
    writePairingSession({ sessionId: "session-1" });
    writeBridgeStatus({ state: "running", connectionStatus: "connected" });

    stopMacOSBridgeService({
      platform: "darwin",
      execFileSyncImpl() {
        const error = new Error("Could not find service");
        error.stderr = Buffer.from("Could not find service");
        throw error;
      },
    });

    assert.equal(readPairingSession(), null);
    assert.equal(readBridgeStatus(), null);
  });
});

test("stopMacOSBridgeService falls back to label bootout when plist bootout fails", () => {
  withTempDaemonEnv(() => {
    const calls = [];

    stopMacOSBridgeService({
      platform: "darwin",
      execFileSyncImpl(command, args) {
        calls.push([command, args]);
        if (args[1] === `gui/${process.getuid()}`) {
          const error = new Error("Input/output error");
          error.stderr = Buffer.from("Bootstrap failed: 5: Input/output error");
          throw error;
        }
      },
    });

    assert.deepEqual(calls, [
      [
        "launchctl",
        [
          "bootout",
          `gui/${process.getuid()}`,
          path.join(process.env.HOME, "Library", "LaunchAgents", "com.remodex.bridge.plist"),
        ],
      ],
      [
        "launchctl",
        [
          "bootout",
          `gui/${process.getuid()}/com.remodex.bridge`,
        ],
      ],
    ]);
  });
});

test("startMacOSBridgeService kickstarts the launch agent after bootstrap", () => {
  withTempDaemonEnv(({ rootDir }) => {
    const calls = [];
    const env = {
      ...process.env,
      HOME: rootDir,
      REMODEX_DEVICE_STATE_DIR: rootDir,
      REMODEX_RELAY: "ws://127.0.0.1:9000/relay",
    };

    startMacOSBridgeService({
      env,
      platform: "darwin",
      waitForPairing: false,
      execFileSyncImpl(command, args) {
        calls.push([command, args]);
        if (args[0] === "bootout") {
          const error = new Error("Could not find service");
          error.stderr = Buffer.from("Could not find service");
          throw error;
        }
      },
    });

    assert.deepEqual(
      calls.map(([command, args]) => [command, args[0], args[1], args[2]]),
      [
        ["launchctl", "bootout", `gui/${process.getuid()}`, path.join(rootDir, "Library", "LaunchAgents", "com.remodex.bridge.plist")],
        ["launchctl", "bootout", `gui/${process.getuid()}/com.remodex.bridge`, undefined],
        ["launchctl", "bootstrap", `gui/${process.getuid()}`, path.join(rootDir, "Library", "LaunchAgents", "com.remodex.bridge.plist")],
        ["launchctl", "kickstart", "-k", `gui/${process.getuid()}/com.remodex.bridge`],
      ]
    );
  });
});

test("resetMacOSBridgePairing stops the daemon before revoking persisted trust", () => {
  withTempDaemonEnv(() => {
    writePairingSession({ sessionId: "session-reset" });
    writeBridgeStatus({ state: "running", connectionStatus: "connected" });

    let stopCalls = 0;
    let resetCalls = 0;
    const result = resetMacOSBridgePairing({
      platform: "darwin",
      execFileSyncImpl() {
        stopCalls += 1;
        const error = new Error("Could not find service");
        error.stderr = Buffer.from("Could not find service");
        throw error;
      },
      resetBridgePairingImpl() {
        resetCalls += 1;
        return { hadState: true };
      },
    });

    assert.equal(stopCalls, 2);
    assert.equal(resetCalls, 1);
    assert.equal(result.hadState, true);
    assert.equal(readPairingSession(), null);
    assert.equal(readBridgeStatus(), null);
  });
});

test("runMacOSBridgeService records a clean error state instead of throwing when daemon config is missing", () => {
  withTempDaemonEnv(() => {
    writePairingSession({ sessionId: "stale-session" });

    assert.doesNotThrow(() => {
      runMacOSBridgeService({ env: process.env });
    });

    assert.equal(readPairingSession(), null);
    const status = readBridgeStatus();
    assert.equal(status?.state, "error");
    assert.equal(status?.connectionStatus, "error");
    assert.equal(status?.pid, process.pid);
    assert.equal(status?.lastError, "No relay URL configured for the macOS bridge service.");
    assert.equal(typeof status?.updatedAt, "string");
  });
});

test("mergeBridgeStatusForDaemon keeps the last fatal startup error visible during reconnect loops", () => {
  assert.deepEqual(
    mergeBridgeStatusForDaemon(
      {
        state: "running",
        connectionStatus: "connecting",
        pid: 27479,
        lastError: "",
        codexLaunchState: "starting",
      },
      {
        state: "error",
        connectionStatus: "error",
        pid: 27479,
        lastError: "spawn codex ENOENT",
      }
    ),
    {
      state: "running",
      connectionStatus: "connecting",
      pid: 27479,
      lastError: "spawn codex ENOENT",
      codexLaunchState: "starting",
    }
  );
});

test("mergeBridgeStatusForDaemon clears preserved errors once the bridge is actually connected", () => {
  const connectedStatus = {
    state: "running",
    connectionStatus: "connected",
    pid: 27479,
    lastError: "",
  };

  assert.deepEqual(
    mergeBridgeStatusForDaemon(connectedStatus, {
      state: "error",
      connectionStatus: "error",
      pid: 27479,
      lastError: "spawn codex ENOENT",
    }),
    connectedStatus
  );
});

test("mergeBridgeStatusForDaemon stops preserving startup errors once Codex has launched", () => {
  const reconnectingStatus = {
    state: "running",
    connectionStatus: "connecting",
    pid: 27479,
    lastError: "",
    codexLaunchState: "connected",
  };

  assert.deepEqual(
    mergeBridgeStatusForDaemon(reconnectingStatus, {
      state: "error",
      connectionStatus: "error",
      pid: 27479,
      lastError: "spawn codex ENOENT",
      codexLaunchState: "error",
    }),
    reconnectingStatus
  );
});

test("getMacOSBridgeServiceStatus reports launchd + runtime metadata together", () => {
  withTempDaemonEnv(({ rootDir }) => {
    writeDaemonConfig({ relayUrl: "ws://127.0.0.1:9000/relay" });
    writePairingSession({ sessionId: "session-2" });
    writeBridgeStatus({ state: "running", connectionStatus: "connected", pid: 55 });

    const plistPath = path.join(rootDir, "LaunchAgents", "com.remodex.bridge.plist");
    fs.mkdirSync(path.dirname(plistPath), { recursive: true });
    fs.writeFileSync(plistPath, "plist");

    const status = getMacOSBridgeServiceStatus({
      platform: "darwin",
      env: { HOME: rootDir, REMODEX_DEVICE_STATE_DIR: rootDir },
      execFileSyncImpl() {
        return "pid = 55";
      },
    });

    assert.equal(status.launchdLoaded, true);
    assert.equal(status.launchdPid, 55);
    assert.equal(status.daemonConfig?.relayUrl, "ws://127.0.0.1:9000/relay");
    assert.equal(status.bridgeStatus?.connectionStatus, "connected");
    assert.equal(status.pairingSession?.pairingPayload?.sessionId, "session-2");
  });
});

function withTempDaemonEnv(run) {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const previousHome = process.env.HOME;
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-launch-agent-"));
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
