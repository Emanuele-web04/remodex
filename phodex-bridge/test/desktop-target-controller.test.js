// FILE: desktop-target-controller.test.js
// Purpose: Verifies safe target switching, preservation, and transactional rollback.
// Layer: Unit test

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  setMacOSDesktopTarget,
  waitForHealthyTarget,
} = require("../src/desktop-target-controller");

const selected = {
  codexHome: "/Users/test/.codex-secondary",
  codexBundleId: "com.openai.codex.secondary",
  codexAppPath: "/Users/test/Applications/ChatGPT Personal.app",
  codexUrlScheme: "codex-secondary",
  desktopIpcSocketPath: "/Users/test/.codex-secondary/ipc/ipc.sock",
  codexTargetFingerprint: "secondary-fingerprint",
};

test("running service requires --restart before changing target", async () => {
  let wrote = false;
  await assert.rejects(setMacOSDesktopTarget({
    target: selected,
    platform: "darwin",
    getServiceStatusImpl: () => ({ launchdLoaded: true }),
    validateTargetImpl: () => selected,
    writeDaemonConfigImpl: () => { wrote = true; },
  }), /with --restart/);
  assert.equal(wrote, false);
});

test("target switch preserves pairing and relay configuration", async () => {
  const writes = [];
  let restarted = 0;
  const previous = {
    relayUrl: "wss://relay.example/relay",
    trustedPhoneId: "phone-1",
    codexHome: "/Users/test/.codex",
  };
  const result = await setMacOSDesktopTarget({
    target: selected,
    restart: true,
    platform: "darwin",
    getServiceStatusImpl: () => ({ launchdLoaded: true }),
    validateTargetImpl: () => selected,
    readDaemonConfigImpl: () => previous,
    writeDaemonConfigImpl: (value) => writes.push(value),
    restartServiceImpl: async () => { restarted += 1; },
    waitForHealthyTargetImpl: async (fingerprint) => {
      assert.equal(fingerprint, "secondary-fingerprint");
    },
  });
  assert.equal(restarted, 1);
  assert.equal(writes.length, 1);
  assert.equal(writes[0].relayUrl, previous.relayUrl);
  assert.equal(writes[0].trustedPhoneId, previous.trustedPhoneId);
  assert.equal(writes[0].codexHome, selected.codexHome);
  assert.equal(result.restarted, true);
});

test("failed startup restores the complete previous configuration", async () => {
  const writes = [];
  let restarts = 0;
  const previous = {
    relayUrl: "wss://relay.example/relay",
    trustedPhoneId: "phone-1",
    codexHome: "/Users/test/.codex",
    codexTargetFingerprint: "primary-fingerprint",
  };
  await assert.rejects(setMacOSDesktopTarget({
    target: selected,
    restart: true,
    platform: "darwin",
    getServiceStatusImpl: () => ({ launchdLoaded: true }),
    validateTargetImpl: () => selected,
    readDaemonConfigImpl: () => previous,
    writeDaemonConfigImpl: (value) => writes.push({ ...value }),
    restartServiceImpl: async () => { restarts += 1; },
    waitForHealthyTargetImpl: async () => { throw new Error("app-server disconnected"); },
  }), /previous configuration was restored/);
  assert.equal(restarts, 2);
  assert.deepEqual(writes, [{ ...previous, ...selected }, previous]);
});

test("health verification rejects stale and stopped bridge status", async () => {
  const statuses = [
    {
      state: "running",
      updatedAt: "2026-08-23T12:59:59.000Z",
      codexTargetFingerprint: "secondary-fingerprint",
      codexLaunchState: "connected",
    },
    {
      state: "stopped",
      updatedAt: "2026-08-23T13:00:01.000Z",
      codexTargetFingerprint: "secondary-fingerprint",
      codexLaunchState: "connected",
    },
    {
      state: "running",
      updatedAt: "2026-08-23T13:00:02.000Z",
      codexTargetFingerprint: "secondary-fingerprint",
      codexLaunchState: "connected",
    },
  ];
  let reads = 0;
  const result = await waitForHealthyTarget("secondary-fingerprint", {
    notBeforeMs: Date.parse("2026-08-23T13:00:00.000Z"),
    timeoutMs: 100,
    intervalMs: 0,
    readBridgeStatusImpl: () => statuses[Math.min(reads++, statuses.length - 1)],
  });
  assert.equal(reads, 3);
  assert.equal(result.state, "running");
});
