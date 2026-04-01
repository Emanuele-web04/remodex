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
  resetMacOSBridgePairing,
  resolveMacOSBridgeStartConfig,
  resolveLaunchAgentPlistPath,
  startMacOSBridgeService,
  runMacOSBridgeService,
  stopMacOSBridgeService,
} = require("../src/macos-launch-agent");
const {
  readBridgeStatus,
  readDaemonConfig,
  readPairingSession,
  writeDaemonConfig,
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

test("resolveMacOSBridgeStartConfig preserves saved relay settings while refreshing stale Convex defaults", () => {
  withTempDaemonEnv(() => {
    writeDaemonConfig({
      relayUrl: "ws://127.0.0.1:9100/relay",
      pushServiceUrl: "https://relay.example",
      convexSiteUrl: "https://stale.convex.site",
      refreshEnabled: true,
      refreshDebounceMs: 999,
      codexEndpoint: "ws://codex.example",
      refreshCommand: "echo refresh",
    });

    const config = resolveMacOSBridgeStartConfig({
      env: {
        HOME: process.env.HOME,
        REMODEX_DEVICE_STATE_DIR: process.env.REMODEX_DEVICE_STATE_DIR,
      },
    });

    assert.equal(config.relayUrl, "ws://127.0.0.1:9100/relay");
    assert.equal(config.pushServiceUrl, "https://relay.example");
    assert.equal(config.refreshEnabled, true);
    assert.equal(config.refreshDebounceMs, 999);
    assert.equal(config.codexEndpoint, "ws://codex.example");
    assert.equal(config.refreshCommand, "echo refresh");
    assert.equal(config.convexSiteUrl, "https://determined-ladybug-18.convex.site");
  });
});

test("startMacOSBridgeService rewrites stale Convex defaults into daemon config before launchd restart", { concurrency: false }, async () => {
  const previousDir = process.env.REMODEX_DEVICE_STATE_DIR;
  const previousHome = process.env.HOME;
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-launch-agent-"));
  const daemonEnv = {
    HOME: rootDir,
    REMODEX_DEVICE_STATE_DIR: rootDir,
  };
  process.env.REMODEX_DEVICE_STATE_DIR = rootDir;
  process.env.HOME = rootDir;

  try {
    writeDaemonConfig({
      relayUrl: "ws://zacks-mac-studio.local:9100/relay",
      convexSiteUrl: "https://stale.convex.site",
      refreshEnabled: true,
    }, { env: daemonEnv });

    const launchCalls = [];

    await startMacOSBridgeService({
      env: daemonEnv,
      osImpl: {
        hostname: () => "Zacks-Mac-Studio",
        networkInterfaces: () => ({}),
        homedir: () => rootDir,
      },
      execFileSyncImpl(command, args) {
        launchCalls.push([command, args]);
        if (command === "scutil") {
          return "Zacks-Mac-Studio\n";
        }
        return "";
      },
      createRelayServerImpl() {
        return {
          server: {
            once(eventName, handler) {
              if (eventName === "listening") {
                this.onListening = handler;
              }
              if (eventName === "error") {
                this.onError = handler;
              }
            },
            off() {},
            listen(port, host) {
              launchCalls.push(["listen", [port, host]]);
              this.onListening?.();
            },
          },
        };
      },
      startBridgeImpl() {},
    });

    const savedConfig = readDaemonConfig({ env: daemonEnv });
    assert.equal(savedConfig?.relayUrl, "ws://zacks-mac-studio.local:9100/relay");
    assert.equal(savedConfig?.convexSiteUrl, "https://determined-ladybug-18.convex.site");
    assert.equal(savedConfig?.refreshEnabled, true);
    assert.ok(launchCalls.length > 0);
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

test("runMacOSBridgeService records a clean error state instead of throwing when daemon config is missing", { concurrency: false }, async () => {
  await withTempDaemonEnv(async ({ rootDir }) => {
    const daemonEnv = {
      HOME: rootDir,
      REMODEX_DEVICE_STATE_DIR: rootDir,
    };
    writePairingSession({ sessionId: "stale-session" }, { env: daemonEnv });
    let startBridgeCalls = 0;

    await assert.doesNotReject(async () => {
      await runMacOSBridgeService({
        env: daemonEnv,
        startBridgeImpl() {
          startBridgeCalls += 1;
        },
      });
    });

    assert.equal(startBridgeCalls, 0);
  });
});

test("runMacOSBridgeService starts an embedded relay when the saved relay URL points at this Mac", { concurrency: false }, async () => {
  await withTempDaemonEnv(async ({ rootDir }) => {
    const daemonEnv = {
      HOME: rootDir,
      REMODEX_DEVICE_STATE_DIR: rootDir,
    };
    writeDaemonConfig({
      relayUrl: "ws://zacks-mac-studio.local:9100/relay",
      convexSiteUrl: "https://stale.convex.site",
    }, { env: daemonEnv });

    const relayListenCalls = [];
    let bridgeConfig = null;

    await runMacOSBridgeService({
      env: daemonEnv,
      osImpl: {
        hostname: () => "Zacks-Mac-Studio",
        networkInterfaces: () => ({}),
      },
      execFileSyncImpl() {
        return "Zacks-Mac-Studio\n";
      },
      createRelayServerImpl() {
        return {
          server: {
            once(eventName, handler) {
              if (eventName === "listening") {
                this.onListening = handler;
              }
              if (eventName === "error") {
                this.onError = handler;
              }
            },
            off() {},
            listen(port, host) {
              relayListenCalls.push({ port, host });
              this.onListening?.();
            },
          },
        };
      },
      startBridgeImpl(options) {
        bridgeConfig = options.config;
      },
    });

    assert.deepEqual(relayListenCalls, [{ port: 9100, host: "0.0.0.0" }]);
    assert.equal(bridgeConfig?.relayUrl, "ws://zacks-mac-studio.local:9100/relay");
    assert.equal(bridgeConfig?.convexSiteUrl, "https://determined-ladybug-18.convex.site");
  });
});

test("runMacOSBridgeService does not start an embedded relay for external relay URLs", { concurrency: false }, async () => {
  await withTempDaemonEnv(async ({ rootDir }) => {
    const daemonEnv = {
      HOME: rootDir,
      REMODEX_DEVICE_STATE_DIR: rootDir,
    };
    writeDaemonConfig({
      relayUrl: "wss://relay.example.com/relay",
    }, { env: daemonEnv });

    let createRelayServerCalls = 0;
    let bridgeStarted = false;

    await runMacOSBridgeService({
      env: daemonEnv,
      createRelayServerImpl() {
        createRelayServerCalls += 1;
        return {
          server: {
            once() {},
            off() {},
            listen() {},
          },
        };
      },
      startBridgeImpl() {
        bridgeStarted = true;
      },
    });

    assert.equal(createRelayServerCalls, 0);
    assert.equal(bridgeStarted, true);
  });
});

test("resolveMacOSBridgeStartConfig falls back to the saved daemon relay config", () => {
  withTempDaemonEnv(() => {
    writeDaemonConfig({
      relayUrl: "ws://127.0.0.1:9100/relay",
      refreshEnabled: true,
    });

    const config = resolveMacOSBridgeStartConfig({
      env: {
        HOME: process.env.HOME,
        REMODEX_DEVICE_STATE_DIR: process.env.REMODEX_DEVICE_STATE_DIR,
      },
    });

    assert.equal(config.relayUrl, "ws://127.0.0.1:9100/relay");
    assert.equal(config.refreshEnabled, true);
  });
});

test("resolveMacOSBridgeStartConfig infers a local relay URL when nothing is configured", () => {
  withTempDaemonEnv(({ rootDir }) => {
    const config = resolveMacOSBridgeStartConfig({
      env: {
        HOME: rootDir,
        REMODEX_DEVICE_STATE_DIR: rootDir,
      },
      osImpl: {
        hostname: () => "Zacks-Mac-Studio",
      },
      execFileSyncImpl() {
        return "Zacks-Mac-Studio\n";
      },
    });

    assert.equal(config.relayUrl, "ws://zacks-mac-studio.local:9100/relay");
    assert.equal(config.convexSiteUrl, "https://determined-ladybug-18.convex.site");
  });
});

test("getMacOSBridgeServiceStatus reports launchd + runtime metadata together", () => {
  withTempDaemonEnv(({ rootDir }) => {
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
