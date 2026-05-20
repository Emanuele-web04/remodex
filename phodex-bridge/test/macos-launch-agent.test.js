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
  printMacOSBridgePairingQr,
  resetMacOSBridgePairing,
  restartMacOSBridgeService,
  resolveLaunchAgentPlistPath,
  runMacOSBridgeService,
  startMacOSBridgeService,
  stopMacOSBridgeService,
} = require("../src/macos-launch-agent");
const {
  writeDaemonConfig,
  readBridgeStatus,
  readDaemonConfig,
  readPairingSession,
  writeBridgeStatus,
  writePairingSession,
} = require("../src/daemon-state");

const TEST_UID = typeof process.getuid === "function" ? process.getuid() : 501;

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
      env: { ...process.env, UID: String(TEST_UID) },
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

test("stopMacOSBridgeService terminates the recorded run-service process when launchd is stale", () => {
  withTempDaemonEnv(() => {
    writeBridgeStatus({ state: "running", connectionStatus: "connected", pid: 4242 });

    const killed = [];
    stopMacOSBridgeService({
      env: { ...process.env, UID: String(TEST_UID) },
      platform: "darwin",
      execFileSyncImpl(command, args) {
        if (command === "launchctl") {
          const error = new Error("Could not find service");
          error.stderr = Buffer.from("Could not find service");
          throw error;
        }

        assert.equal(command, "ps");
        assert.deepEqual(args, ["-p", "4242", "-o", "command="]);
        return "/usr/local/bin/node /usr/local/bin/remodex run-service";
      },
      processImpl: {
        pid: 9999,
        kill(pid, signal) {
          killed.push([pid, signal]);
        },
      },
    });

    assert.deepEqual(killed, [[4242, "SIGTERM"]]);
    assert.equal(readBridgeStatus(), null);
  });
});

test("stopMacOSBridgeService does not kill an unrelated stale pid", () => {
  withTempDaemonEnv(() => {
    writeBridgeStatus({ state: "running", connectionStatus: "connected", pid: 4243 });

    const killed = [];
    stopMacOSBridgeService({
      env: { ...process.env, UID: String(TEST_UID) },
      platform: "darwin",
      execFileSyncImpl(command) {
        if (command === "launchctl") {
          const error = new Error("Could not find service");
          error.stderr = Buffer.from("Could not find service");
          throw error;
        }

        return "/Applications/Other.app/Contents/MacOS/Other";
      },
      processImpl: {
        pid: 9999,
        kill(pid, signal) {
          killed.push([pid, signal]);
        },
      },
    });

    assert.deepEqual(killed, []);
    assert.equal(readBridgeStatus(), null);
  });
});

test("stopMacOSBridgeService falls back to label bootout when plist bootout fails", () => {
  withTempDaemonEnv(() => {
    const calls = [];

    stopMacOSBridgeService({
      env: { ...process.env, UID: String(TEST_UID) },
      platform: "darwin",
      execFileSyncImpl(command, args) {
        calls.push([command, args]);
        if (args[1] === `gui/${TEST_UID}`) {
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
          `gui/${TEST_UID}`,
          path.join(process.env.HOME, "Library", "LaunchAgents", "com.remodex.bridge.plist"),
        ],
      ],
      [
        "launchctl",
        [
          "bootout",
          `gui/${TEST_UID}/com.remodex.bridge`,
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
      UID: String(TEST_UID),
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
        ["launchctl", "bootout", `gui/${TEST_UID}`, path.join(rootDir, "Library", "LaunchAgents", "com.remodex.bridge.plist")],
        ["launchctl", "bootout", `gui/${TEST_UID}/com.remodex.bridge`, undefined],
        ["launchctl", "bootstrap", `gui/${TEST_UID}`, path.join(rootDir, "Library", "LaunchAgents", "com.remodex.bridge.plist")],
        ["launchctl", "kickstart", "-k", `gui/${TEST_UID}/com.remodex.bridge`],
      ]
    );
    assert.equal(readDaemonConfig({ env })?.extraRelaySessions, undefined);
  });
});

test("restartMacOSBridgeService kickstarts an existing LaunchAgent without relay config", async () => {
  await withTempDaemonEnv(async ({ rootDir }) => {
    const calls = [];
    const env = {
      ...process.env,
      HOME: rootDir,
      REMODEX_DEVICE_STATE_DIR: rootDir,
      UID: String(TEST_UID),
    };
    const plistPath = path.join(rootDir, "Library", "LaunchAgents", "com.remodex.bridge.plist");
    fs.mkdirSync(path.dirname(plistPath), { recursive: true });
    fs.writeFileSync(plistPath, "<plist />", "utf8");

    const result = await restartMacOSBridgeService({
      env,
      platform: "darwin",
      execFileSyncImpl(command, args) {
        calls.push([command, args]);
      },
    });

    assert.equal(result.plistPath, plistPath);
    assert.equal(result.pairingSession, null);
    assert.deepEqual(calls, [
      ["launchctl", ["kickstart", "-k", `gui/${TEST_UID}/com.remodex.bridge`]],
    ]);
  });
});

test("restartMacOSBridgeService can wait for the daemon to publish a fresh pairing QR", async () => {
  await withTempDaemonEnv(async ({ rootDir }) => {
    const calls = [];
    const env = {
      ...process.env,
      HOME: rootDir,
      REMODEX_DEVICE_STATE_DIR: rootDir,
      UID: String(TEST_UID),
    };
    const plistPath = path.join(rootDir, "Library", "LaunchAgents", "com.remodex.bridge.plist");
    fs.mkdirSync(path.dirname(plistPath), { recursive: true });
    fs.writeFileSync(plistPath, "<plist />", "utf8");
    writePairingSession({
      createdAt: "2000-01-01T00:00:00.000Z",
      pairingPayload: { sessionId: "stale-session" },
    }, { env });

    const result = await restartMacOSBridgeService({
      env,
      platform: "darwin",
      pairingTimeoutMs: 200,
      pairingPollIntervalMs: 5,
      waitForPairing: true,
      execFileSyncImpl(command, args) {
        calls.push([command, args]);
        writePairingSession({
          pairingPayload: {
            v: 2,
            relay: "ws://127.0.0.1:9000/relay",
            sessionId: "fresh-session",
            macDeviceId: "mac-1",
            macIdentityPublicKey: "mac-pub",
            expiresAt: Date.now() + 60_000,
          },
          pairingCode: "PAIRME",
        }, { env });
      },
    });

    assert.equal(result.plistPath, plistPath);
    assert.equal(result.pairingSession?.pairingPayload?.sessionId, "fresh-session");
    assert.deepEqual(calls, [
      ["launchctl", ["kickstart", "-k", `gui/${TEST_UID}/com.remodex.bridge`]],
    ]);
  });
});

test("printMacOSBridgePairingQr renders the daemon pairing session", () => {
  withTempDaemonEnv(() => {
    writePairingSession({
      pairingPayload: {
        v: 1,
        relay: "ws://127.0.0.1:9000/relay",
        sessionId: "session-primary",
        macDeviceId: "mac-1",
        macIdentityPublicKey: "mac-pub",
        expiresAt: Date.now() + 60_000,
      },
      pairingCode: "ABC123",
    });

    const logs = [];
    const errors = [];
    const originalLog = console.log;
    const originalError = console.error;
    console.log = (message = "") => logs.push(String(message));
    console.error = (message = "") => errors.push(String(message));
    try {
      printMacOSBridgePairingQr();
    } finally {
      console.log = originalLog;
      console.error = originalError;
    }

    assert.deepEqual(errors, []);
    assert.ok(logs.some((line) => line.includes("ABC123")));
  });
});

test("resetMacOSBridgePairing stops the daemon before revoking persisted trust", () => {
  withTempDaemonEnv(() => {
    writePairingSession({ sessionId: "session-reset" });
    writeBridgeStatus({ state: "running", connectionStatus: "connected" });

    let stopCalls = 0;
    let resetCalls = 0;
    const result = resetMacOSBridgePairing({
      env: { ...process.env, UID: String(TEST_UID) },
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
      runMacOSBridgeService({ env: process.env, platform: "darwin" });
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
      env: { HOME: rootDir, REMODEX_DEVICE_STATE_DIR: rootDir, UID: String(TEST_UID) },
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

  const cleanup = () => {
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
  };

  try {
    const result = run({ rootDir });
    if (result && typeof result.then === "function") {
      return result.finally(cleanup);
    }
    cleanup();
    return result;
  } catch (error) {
    cleanup();
    throw error;
  }
}
