// FILE: remodex-cli.test.js
// Purpose: Verifies the public CLI exposes version, service control, and machine-readable status output.
// Layer: Integration-lite test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, child_process, path, ../package.json, ../bin/remodex

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("child_process");
const path = require("path");
const { version } = require("../package.json");
const { main, runCli } = require("../bin/remodex");

test("remodex --version prints the package version", () => {
  const cliPath = path.join(__dirname, "..", "bin", "remodex.js");
  const output = execFileSync(process.execPath, [cliPath, "--version"], {
    encoding: "utf8",
  }).trim();

  assert.equal(output, version);
});

test("remodex restart kickstarts the installed macOS service without requiring relay config", async () => {
  const calls = [];
  const messages = [];

  await main({
    argv: ["node", "remodex", "restart"],
    platform: "darwin",
    consoleImpl: {
      log(message) {
        messages.push(message);
      },
      error(message) {
        messages.push(message);
      },
    },
    exitImpl(code) {
      throw new Error(`unexpected exit ${code}`);
    },
    deps: {
      async restartMacOSBridgeService() {
        calls.push("restart-service");
        return {
          plistPath: "/tmp/remodex.plist",
          pairingSession: null,
        };
      },
    },
  });

  assert.deepEqual(calls, [
    "restart-service",
  ]);
  assert.deepEqual(messages, [
    "[remodex] macOS bridge service restarted.",
  ]);
});

test("remodex start refreshes macOS service config and plist", async () => {
  const calls = [];
  const messages = [];

  await main({
    argv: ["node", "remodex", "start"],
    platform: "darwin",
    consoleImpl: {
      log(message) {
        messages.push(message);
      },
      error(message) {
        messages.push(message);
      },
    },
    exitImpl(code) {
      throw new Error(`unexpected exit ${code}`);
    },
    deps: {
      async startMacOSBridgeService(options) {
        calls.push(["start-service", options]);
        return {
          plistPath: "/tmp/remodex.plist",
          pairingSession: null,
        };
      },
    },
  });

  assert.deepEqual(calls, [
    ["start-service", undefined],
  ]);
  assert.deepEqual(messages, [
    "[remodex] macOS bridge service is running.",
  ]);
});

test("remodex up shows a startup indicator while waiting for the pairing QR", async () => {
  const calls = [];
  const messages = [];

  await main({
    argv: ["node", "remodex", "up"],
    platform: "darwin",
    consoleImpl: {
      log(message) {
        messages.push(message);
      },
      error(message) {
        messages.push(message);
      },
    },
    exitImpl(code) {
      throw new Error(`unexpected exit ${code}`);
    },
    deps: {
      async startMacOSBridgeService(options) {
        calls.push(["start-service", options]);
        return {
          pairingSession: { pairingPayload: { sessionId: "session-up" } },
        };
      },
      printMacOSBridgePairingQr(options) {
        calls.push(["print-qr", options]);
      },
    },
  });

  assert.deepEqual(messages, [
    "[remodex] Starting bridge and pairing QR...",
  ]);
  assert.deepEqual(calls, [
    ["start-service", { waitForPairing: true }],
    ["print-qr", { pairingSession: { pairingPayload: { sessionId: "session-up" } } }],
  ]);
});

test("remodex qr refreshes service config and prints the pairing QR", async () => {
  const calls = [];
  const messages = [];

  await main({
    argv: ["node", "remodex", "qr"],
    platform: "darwin",
    consoleImpl: {
      log(message) {
        messages.push(message);
      },
      error(message) {
        messages.push(message);
      },
    },
    exitImpl(code) {
      throw new Error(`unexpected exit ${code}`);
    },
    deps: {
      async startMacOSBridgeService(options) {
        calls.push(["start-service", options]);
        return {
          pairingSession: { pairingPayload: { sessionId: "session-qr" } },
        };
      },
      printMacOSBridgePairingQr(options) {
        calls.push(["print-qr", options]);
      },
    },
  });

  assert.deepEqual(messages, [
    "[remodex] Refreshing bridge pairing QR...",
  ]);
  assert.deepEqual(calls, [
    ["start-service", { waitForPairing: true }],
    ["print-qr", { pairingSession: { pairingPayload: { sessionId: "session-qr" } } }],
  ]);
});

test("remodex pair is an alias for the QR refresh flow", async () => {
  const calls = [];

  await main({
    argv: ["node", "remodex", "pair"],
    platform: "darwin",
    consoleImpl: {
      log() {},
      error(message) {
        throw new Error(`unexpected error: ${message}`);
      },
    },
    exitImpl(code) {
      throw new Error(`unexpected exit ${code}`);
    },
    deps: {
      async startMacOSBridgeService(options) {
        calls.push(["start-service", options]);
        return {
          pairingSession: { pairingPayload: { sessionId: "session-pair" } },
        };
      },
      printMacOSBridgePairingQr(options) {
        calls.push(["print-qr", options]);
      },
    },
  });

  assert.deepEqual(calls, [
    ["start-service", { waitForPairing: true }],
    ["print-qr", { pairingSession: { pairingPayload: { sessionId: "session-pair" } } }],
  ]);
});

test("remodex pair --json exposes pairing readiness without private payload fields", async () => {
  const writes = [];
  const originalWrite = process.stdout.write;

  process.stdout.write = (chunk, encoding, callback) => {
    writes.push(String(chunk));
    if (typeof callback === "function") {
      callback();
    }
    return true;
  };

  try {
    await main({
      argv: ["node", "remodex", "pair", "--json"],
      platform: "darwin",
      consoleImpl: {
        log(message) {
          throw new Error(`unexpected log: ${message}`);
        },
        error(message) {
          throw new Error(`unexpected error: ${message}`);
        },
      },
      exitImpl(code) {
        throw new Error(`unexpected exit ${code}`);
      },
      deps: {
        async startMacOSBridgeService(options) {
          assert.deepEqual(options, { waitForPairing: true });
          return {
            plistPath: "/tmp/remodex.plist",
            pairingSession: {
              pairingPayload: {
                relay: "ws://127.0.0.1:9000/relay",
                sessionId: "session-json-pair",
                macIdentityPublicKey: "pub-key-pair",
                expiresAt: 1_900_000_000_000,
              },
              pairingCode: "ABCDEFGHJK",
            },
          };
        },
        printMacOSBridgePairingQr() {
          throw new Error("QR printer should not run for --json");
        },
      },
    });
  } finally {
    process.stdout.write = originalWrite;
  }

  const payload = JSON.parse(writes.join("").trim());
  assert.equal(payload.ok, true);
  assert.equal(payload.currentVersion, version);
  assert.equal(payload.plistPath, "/tmp/remodex.plist");
  assert.equal(payload.pairingSession?.pairingPayload?.relay, undefined);
  assert.equal(payload.pairingSession?.pairingPayload?.sessionId, undefined);
  assert.equal(payload.pairingSession?.pairingPayload?.macIdentityPublicKey, undefined);
  assert.equal(payload.pairingSession?.pairingPayload?.hasRelay, true);
  assert.equal(payload.pairingSession?.pairingPayload?.hasSessionId, true);
  assert.equal(payload.pairingSession?.pairingPayload?.hasMacIdentityPublicKey, true);
  assert.equal(payload.pairingSession?.pairingPayload?.expiresAt, 1_900_000_000_000);
  assert.equal(writes.join("").includes("ws://127.0.0.1:9000/relay"), false);
  assert.equal(writes.join("").includes("session-json-pair"), false);
});

test("runCli prints expected failures without a Node stack trace", async () => {
  const messages = [];
  let exitCode = null;

  await runCli({
    async mainImpl() {
      throw new Error("No relay URL configured. Run ./run-local-remodex.sh.");
    },
    consoleImpl: {
      error(message) {
        messages.push(message);
      },
    },
    exitImpl(code) {
      exitCode = code;
    },
  });

  assert.equal(exitCode, 1);
  assert.deepEqual(messages, [
    "[remodex] No relay URL configured. Run ./run-local-remodex.sh.",
  ]);
  assert.equal(messages.join("\n").includes("at "), false);
});

test("remodex status --json exposes daemon metadata without relay URLs", async () => {
  const writes = [];
  const originalWrite = process.stdout.write;

  process.stdout.write = (chunk, encoding, callback) => {
    writes.push(String(chunk));
    if (typeof callback === "function") {
      callback();
    }
    return true;
  };

  try {
    await main({
      argv: ["node", "remodex", "status", "--json"],
      platform: "darwin",
      consoleImpl: {
        log() {},
        error(message) {
          throw new Error(`unexpected error: ${message}`);
        },
      },
      exitImpl(code) {
        throw new Error(`unexpected exit ${code}`);
      },
      deps: {
        getMacOSBridgeServiceStatus() {
          return {
            daemonConfig: {
              relayUrl: "ws://127.0.0.1:9000/relay",
              pushServiceUrl: "https://push.example",
              keepMacAwakeEnabled: true,
            },
            bridgeStatus: {
              connectionStatus: "connected",
              pid: 77,
            },
            pairingSession: {
              pairingPayload: {
                relay: "ws://127.0.0.1:9000/relay",
                sessionId: "session-json",
                macIdentityPublicKey: "pub-key-json",
                expiresAt: 1_900_000_000_000,
              },
              pairingCode: "ABCDEFGHJK",
            },
          };
        },
        printMacOSBridgeServiceStatus() {
          throw new Error("status printer should not run for --json");
        },
      },
    });
  } finally {
    process.stdout.write = originalWrite;
  }

  const payload = JSON.parse(writes.join("").trim());
  assert.equal(payload.currentVersion, version);
  assert.equal(payload.daemonConfig?.relayUrl, undefined);
  assert.equal(payload.daemonConfig?.pushServiceUrl, undefined);
  assert.equal(payload.daemonConfig?.relayConfigured, true);
  assert.equal(payload.daemonConfig?.pushServiceConfigured, true);
  assert.equal(payload.daemonConfig?.keepMacAwakeEnabled, true);
  assert.equal(payload.bridgeStatus?.connectionStatus, "connected");
  assert.equal(payload.pairingSession?.pairingPayload?.relay, undefined);
  assert.equal(payload.pairingSession?.pairingPayload?.sessionId, undefined);
  assert.equal(payload.pairingSession?.pairingPayload?.macIdentityPublicKey, undefined);
  assert.equal(payload.pairingSession?.pairingPayload?.hasRelay, true);
  assert.equal(payload.pairingSession?.pairingPayload?.hasSessionId, true);
  assert.equal(payload.pairingSession?.pairingPayload?.hasMacIdentityPublicKey, true);
  assert.equal(payload.pairingSession?.pairingPayload?.expiresAt, 1_900_000_000_000);
  assert.equal(writes.join("").includes("ws://127.0.0.1:9000/relay"), false);
  assert.equal(writes.join("").includes("session-json"), false);
});
