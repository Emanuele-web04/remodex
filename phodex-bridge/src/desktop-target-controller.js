// FILE: desktop-target-controller.js
// Purpose: Transactionally changes the persisted macOS Codex Desktop target.
// Layer: CLI helper
// Exports: setMacOSDesktopTarget, resetMacOSDesktopTarget
// Depends on: ./daemon-state, ./desktop-target, ./macos-launch-agent

const fs = require("fs");
const os = require("os");
const {
  readBridgeStatus,
  readDaemonConfig,
  writeDaemonConfig,
} = require("./daemon-state");
const {
  DEFAULT_CODEX_BUNDLE_ID,
  DEFAULT_CODEX_URL_SCHEME,
  defaultCodexAppPath,
  defaultCodexHome,
  desktopTargetFingerprint,
  normalizeDesktopTarget,
  validateDesktopTarget,
} = require("./desktop-target");
const {
  getMacOSBridgeServiceStatus,
  restartMacOSBridgeService,
} = require("./macos-launch-agent");

const TARGET_HEALTH_TIMEOUT_MS = 30_000;
const TARGET_HEALTH_INTERVAL_MS = 100;

async function setMacOSDesktopTarget({
  target,
  restart = false,
  env = process.env,
  fsImpl = fs,
  platform = process.platform,
  validateTargetImpl = validateDesktopTarget,
  getServiceStatusImpl = getMacOSBridgeServiceStatus,
  restartServiceImpl = restartMacOSBridgeService,
  readBridgeStatusImpl = readBridgeStatus,
  readDaemonConfigImpl = readDaemonConfig,
  writeDaemonConfigImpl = writeDaemonConfig,
  waitForHealthyTargetImpl = waitForHealthyTarget,
} = {}) {
  if (platform !== "darwin") {
    throw new Error("Desktop target switching is only available on macOS.");
  }

  const serviceStatus = getServiceStatusImpl({ env, fsImpl });
  if (serviceStatus.launchdLoaded && !restart) {
    throw new Error("The Remodex service is running. Repeat the command with --restart to switch it safely.");
  }

  const validated = validateTargetImpl(target, { fsImpl, platform });
  const previousConfig = readDaemonConfigImpl({ env, fsImpl }) || {};
  const nextConfig = {
    ...previousConfig,
    ...validated,
  };
  writeDaemonConfigImpl(nextConfig, { env, fsImpl });

  if (!restart) {
    return { target: validated, restarted: false, rolledBack: false };
  }

  try {
    const restartStartedAt = Date.now();
    await restartServiceImpl({ env, fsImpl, platform });
    await waitForHealthyTargetImpl(validated.codexTargetFingerprint, {
      env,
      fsImpl,
      notBeforeMs: restartStartedAt,
      readBridgeStatusImpl,
    });
    return { target: validated, restarted: true, rolledBack: false };
  } catch (error) {
    writeDaemonConfigImpl(previousConfig, { env, fsImpl });
    try {
      await restartServiceImpl({ env, fsImpl, platform });
    } catch {
      // The original error remains the actionable failure; status reports whether rollback restarted.
    }
    throw new Error(`Could not activate the new Remodex target; the previous configuration was restored. ${error.message}`);
  }
}

async function resetMacOSDesktopTarget(options = {}) {
  const fsImpl = options.fsImpl || fs;
  const osImpl = options.osImpl || os;
  const target = normalizeDesktopTarget({
    codexHome: defaultCodexHome({ osImpl }),
    codexBundleId: DEFAULT_CODEX_BUNDLE_ID,
    codexAppPath: defaultCodexAppPath({ fsImpl }),
    codexUrlScheme: DEFAULT_CODEX_URL_SCHEME,
    desktopIpcSocketPath: "",
  }, { fsImpl, osImpl, strictIpc: false });
  target.codexTargetFingerprint = desktopTargetFingerprint(target);
  return setMacOSDesktopTarget({
    ...options,
    target,
    validateTargetImpl: options.validateTargetImpl || ((value) => validateDesktopTarget(value, {
      fsImpl,
      platform: options.platform || process.platform,
      strictIpc: false,
    })),
  });
}

async function waitForHealthyTarget(fingerprint, {
  env = process.env,
  fsImpl = fs,
  readBridgeStatusImpl = readBridgeStatus,
  notBeforeMs = 0,
  timeoutMs = TARGET_HEALTH_TIMEOUT_MS,
  intervalMs = TARGET_HEALTH_INTERVAL_MS,
} = {}) {
  const deadline = Date.now() + timeoutMs;
  let latest = null;
  while (Date.now() <= deadline) {
    latest = readBridgeStatusImpl({ env, fsImpl });
    const updatedAtMs = Date.parse(latest?.updatedAt || "");
    if (latest?.state === "running"
      && Number.isFinite(updatedAtMs)
      && updatedAtMs >= notBeforeMs
      && latest?.codexTargetFingerprint === fingerprint
      && latest?.codexLaunchState === "connected") {
      return latest;
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  throw new Error(
    `The restarted bridge did not confirm target ${fingerprint}; Codex state was ${latest?.codexLaunchState || "unknown"}.`
  );
}

module.exports = {
  resetMacOSDesktopTarget,
  setMacOSDesktopTarget,
  waitForHealthyTarget,
};
