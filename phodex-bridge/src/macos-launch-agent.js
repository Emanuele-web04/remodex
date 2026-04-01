// FILE: macos-launch-agent.js
// Purpose: Owns macOS-only launchd install/start/stop/status helpers for the background Remodex bridge.
// Layer: CLI helper
// Exports: start/stop/status helpers plus the launchd service runner used by `remodex up`.
// Depends on: child_process, fs, os, path, ./bridge, ./daemon-state, ./codex-desktop-refresher, ./qr, ./secure-device-state

const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createRelayServer } = require("../../relay/server");
const { startBridge } = require("./bridge");
const { readBridgeConfig } = require("./codex-desktop-refresher");
const { printQR } = require("./qr");
const { resetBridgeDeviceState } = require("./secure-device-state");
const {
  clearBridgeStatus,
  clearPairingSession,
  ensureRemodexLogsDir,
  ensureRemodexStateDir,
  readBridgeStatus,
  readDaemonConfig,
  readPairingSession,
  resolveBridgeStderrLogPath,
  resolveBridgeStdoutLogPath,
  resolveRemodexStateDir,
  writeBridgeStatus,
  writeDaemonConfig,
  writePairingSession,
} = require("./daemon-state");

const SERVICE_LABEL = "com.remodex.bridge";
const DEFAULT_PAIRING_WAIT_TIMEOUT_MS = 10_000;
const DEFAULT_PAIRING_WAIT_INTERVAL_MS = 200;
const DEFAULT_LOCAL_RELAY_BIND_HOST = "0.0.0.0";

// Runs the bridge inside launchd while keeping QR rendering in the foreground CLI command.
async function runMacOSBridgeService({
  env = process.env,
  osImpl = os,
  execFileSyncImpl = execFileSync,
  fsImpl = fs,
  startBridgeImpl = startBridge,
  createRelayServerImpl = createRelayServer,
} = {}) {
  assertDarwinPlatform();
  const config = resolveMacOSBridgeStartConfig({ env, fsImpl });
  if (!config?.relayUrl) {
    const message = "No relay URL configured for the macOS bridge service.";
    // Clear any stale QR so the CLI does not keep showing a pairing payload for a dead service.
    clearPairingSession({ env });
    writeBridgeStatus({
      state: "error",
      connectionStatus: "error",
      pid: process.pid,
      lastError: message,
    }, { env });
    console.error(`[remodex] ${message}`);
    return;
  }

  try {
    await startEmbeddedRelayIfNeeded({
      config,
      env,
      osImpl,
      execFileSyncImpl,
      createRelayServerImpl,
    });
  } catch (error) {
    clearPairingSession({ env });
    writeBridgeStatus({
      state: "error",
      connectionStatus: "error",
      pid: process.pid,
      lastError: error?.message || "Failed to start the embedded relay.",
    }, { env });
    console.error(`[remodex] ${error?.message || "Failed to start the embedded relay."}`);
    return;
  }

  startBridgeImpl({
    config,
    printPairingQr: false,
    onPairingPayload(pairingPayload) {
      writePairingSession(pairingPayload, { env });
    },
    onBridgeStatus(status) {
      writeBridgeStatus(status, { env });
    },
  });
}

async function startEmbeddedRelayIfNeeded({
  config,
  env = process.env,
  osImpl = os,
  execFileSyncImpl = execFileSync,
  createRelayServerImpl = createRelayServer,
} = {}) {
  const relayRuntime = resolveEmbeddedRelayRuntime({
    relayUrl: config?.relayUrl,
    env,
    osImpl,
    execFileSyncImpl,
  });
  if (!relayRuntime) {
    return null;
  }

  const { server } = createRelayServerImpl();
  await new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off?.("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off?.("error", onError);
      resolve();
    };

    server.once?.("error", onError);
    server.once?.("listening", onListening);
    server.listen(relayRuntime.port, relayRuntime.bindHost);
  });
  console.log(
    `[remodex] embedded relay listening on ws://${relayRuntime.advertisedHost}:${relayRuntime.port}/relay`
  );
  return relayRuntime;
}

function resolveEmbeddedRelayRuntime({
  relayUrl,
  env = process.env,
  osImpl = os,
  execFileSyncImpl = execFileSync,
} = {}) {
  const parsedRelayUrl = safeURLParse(relayUrl);
  if (!parsedRelayUrl || parsedRelayUrl.protocol !== "ws:") {
    return null;
  }

  // Only auto-bind an embedded relay when the URL has an explicit port.
  // This avoids unexpected privileged-port binds (for example ws://host/relay => :80).
  if (!parsedRelayUrl.port) {
    return null;
  }

  const hostname = parsedRelayUrl.hostname;
  if (!hostname || !isAdvertisedRelayHostedByThisMac({
    hostname,
    osImpl,
    execFileSyncImpl,
  })) {
    return null;
  }

  return {
    advertisedHost: hostname,
    bindHost: resolveEmbeddedRelayBindHost(hostname, env),
    port: Number(parsedRelayUrl.port),
  };
}

function isAdvertisedRelayHostedByThisMac({
  hostname,
  osImpl = os,
  execFileSyncImpl = execFileSync,
} = {}) {
  const normalizedHostname = normalizeHostname(hostname);
  if (!normalizedHostname) {
    return false;
  }

  if (isLoopbackHost(normalizedHostname)) {
    return true;
  }

  const localCandidates = new Set();
  const osHostname = normalizeHostname(osImpl.hostname?.() || "");
  if (osHostname) {
    localCandidates.add(osHostname);
  }

  const localHostName = readMacLocalHostName(execFileSyncImpl);
  if (localHostName) {
    localCandidates.add(localHostName);
    localCandidates.add(`${localHostName}.local`);
  }

  for (const interfaceAddresses of Object.values(osImpl.networkInterfaces?.() || {})) {
    for (const interfaceAddress of interfaceAddresses || []) {
      const address = normalizeHostname(interfaceAddress?.address || "");
      if (address) {
        localCandidates.add(address);
      }
    }
  }

  return localCandidates.has(normalizedHostname);
}

function resolveEmbeddedRelayBindHost(hostname, env = process.env) {
  const override = typeof env.REMODEX_RELAY_BIND_HOST === "string"
    ? env.REMODEX_RELAY_BIND_HOST.trim()
    : "";
  if (override) {
    return override;
  }

  const normalizedHostname = normalizeHostname(hostname);
  if (normalizedHostname === "::1") {
    return "::1";
  }
  if (isLoopbackHost(normalizedHostname)) {
    return "127.0.0.1";
  }
  if (normalizedHostname.includes(":")) {
    return "::";
  }

  return DEFAULT_LOCAL_RELAY_BIND_HOST;
}

function readMacLocalHostName(execFileSyncImpl = execFileSync) {
  try {
    return normalizeHostname(
      execFileSyncImpl("scutil", ["--get", "LocalHostName"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      })
    );
  } catch {
    return "";
  }
}

function normalizeHostname(value) {
  return typeof value === "string" ? value.trim().replace(/\.+$/, "").toLowerCase() : "";
}

function isLoopbackHost(hostname) {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
}

function safeURLParse(value) {
  try {
    return new URL(value);
  } catch {
    return null;
  }
}

// Prepares config + launchd state and optionally waits for the fresh pairing payload written by the service.
async function startMacOSBridgeService({
  env = process.env,
  platform = process.platform,
  fsImpl = fs,
  execFileSyncImpl = execFileSync,
  osImpl = os,
  nodePath = process.execPath,
  cliPath = path.resolve(__dirname, "..", "bin", "remodex.js"),
  waitForPairing = false,
  pairingTimeoutMs = DEFAULT_PAIRING_WAIT_TIMEOUT_MS,
  pairingPollIntervalMs = DEFAULT_PAIRING_WAIT_INTERVAL_MS,
} = {}) {
  assertDarwinPlatform(platform);
  const config = resolveMacOSBridgeStartConfig({ env, fsImpl });
  assertRelayConfigured(config);
  const startedAt = Date.now();

  writeDaemonConfig(config, { env, fsImpl });
  clearPairingSession({ env, fsImpl });
  clearBridgeStatus({ env, fsImpl });
  ensureRemodexStateDir({ env, fsImpl, osImpl });
  ensureRemodexLogsDir({ env, fsImpl, osImpl });

  const plistPath = writeLaunchAgentPlist({
    env,
    fsImpl,
    osImpl,
    nodePath,
    cliPath,
  });
  restartLaunchAgent({
    env,
    execFileSyncImpl,
    plistPath,
  });

  if (!waitForPairing) {
    return {
      plistPath,
      pairingSession: null,
    };
  }

  const pairingSession = await waitForFreshPairingSession({
    env,
    fsImpl,
    startedAt,
    timeoutMs: pairingTimeoutMs,
    intervalMs: pairingPollIntervalMs,
  });
  return {
    plistPath,
    pairingSession,
  };
}

// In a source checkout, preserve the saved relay config when the shell lacks one,
// but always refresh code-owned defaults like the Convex deployment URL.
function resolveMacOSBridgeStartConfig({
  env = process.env,
  fsImpl = fs,
  osImpl = os,
  execFileSyncImpl = execFileSync,
} = {}) {
  const currentConfig = readBridgeConfig({ env, fsImpl });
  if (typeof currentConfig?.relayUrl === "string" && currentConfig.relayUrl.trim()) {
    return currentConfig;
  }

  const savedConfig = readDaemonConfig({ env, fsImpl });
  if (typeof savedConfig?.relayUrl === "string" && savedConfig.relayUrl.trim()) {
    return {
      ...currentConfig,
      ...savedConfig,
      convexSiteUrl: currentConfig.convexSiteUrl,
    };
  }

  const inferredRelayUrl = inferDefaultLocalRelayUrl({
    osImpl,
    execFileSyncImpl,
  });
  if (!inferredRelayUrl) {
    return currentConfig;
  }

  return {
    ...currentConfig,
    relayUrl: inferredRelayUrl,
  };
}

function inferDefaultLocalRelayUrl({
  osImpl = os,
  execFileSyncImpl = execFileSync,
} = {}) {
  const localHostName = readMacLocalHostName(execFileSyncImpl);
  if (localHostName) {
    return `ws://${localHostName}.local:9100/relay`;
  }

  const osHostname = normalizeHostname(osImpl.hostname?.() || "");
  if (osHostname) {
    return `ws://${osHostname}.local:9100/relay`;
  }

  return "";
}

function stopMacOSBridgeService({
  env = process.env,
  platform = process.platform,
  execFileSyncImpl = execFileSync,
  fsImpl = fs,
} = {}) {
  assertDarwinPlatform(platform);
  bootoutLaunchAgent({
    env,
    execFileSyncImpl,
    ignoreMissing: true,
  });
  clearPairingSession({ env, fsImpl });
  clearBridgeStatus({ env, fsImpl });
}

// Revokes pairing immediately on macOS by stopping the daemon before rotating identity/trust state.
function resetMacOSBridgePairing({
  env = process.env,
  platform = process.platform,
  execFileSyncImpl = execFileSync,
  fsImpl = fs,
  resetBridgePairingImpl = resetBridgeDeviceState,
} = {}) {
  assertDarwinPlatform(platform);
  stopMacOSBridgeService({
    env,
    platform,
    execFileSyncImpl,
    fsImpl,
  });
  return resetBridgePairingImpl();
}

function getMacOSBridgeServiceStatus({
  env = process.env,
  platform = process.platform,
  execFileSyncImpl = execFileSync,
  fsImpl = fs,
} = {}) {
  assertDarwinPlatform(platform);
  const launchd = readLaunchAgentState({ env, execFileSyncImpl });
  return {
    label: SERVICE_LABEL,
    platform: "darwin",
    installed: fsImpl.existsSync(resolveLaunchAgentPlistPath({ env })),
    launchdLoaded: launchd.loaded,
    launchdPid: launchd.pid,
    bridgeStatus: readBridgeStatus({ env, fsImpl }),
    pairingSession: readPairingSession({ env, fsImpl }),
    stdoutLogPath: resolveBridgeStdoutLogPath({ env }),
    stderrLogPath: resolveBridgeStderrLogPath({ env }),
  };
}

function printMacOSBridgeServiceStatus(options = {}) {
  const status = getMacOSBridgeServiceStatus(options);
  const bridgeState = status.bridgeStatus?.state || "unknown";
  const connectionStatus = status.bridgeStatus?.connectionStatus || "unknown";
  const pairingCreatedAt = status.pairingSession?.createdAt || "none";
  const helperStatus = status.bridgeStatus?.helperStatus || null;
  console.log(`[remodex] Service label: ${status.label}`);
  console.log(`[remodex] Installed: ${status.installed ? "yes" : "no"}`);
  console.log(`[remodex] Launchd loaded: ${status.launchdLoaded ? "yes" : "no"}`);
  console.log(`[remodex] PID: ${status.launchdPid || status.bridgeStatus?.pid || "unknown"}`);
  console.log(`[remodex] Bridge state: ${bridgeState}`);
  console.log(`[remodex] Connection: ${connectionStatus}`);
  if (helperStatus) {
    const helperLabel = helperStatus.displayName || "async helper";
    console.log(`[remodex] ${helperLabel}: ${helperStatus.running ? "running" : "stopped"}`);
    console.log(`[remodex] ${helperLabel} available: ${helperStatus.available ? "yes" : "no"}`);
    if (helperStatus.siteUrl) {
      console.log(`[remodex] ${helperLabel} site URL: ${helperStatus.siteUrl}`);
    }
    if (helperStatus.helperPath) {
      console.log(`[remodex] ${helperLabel} path: ${helperStatus.helperPath}`);
    }
    if (helperStatus.lastError) {
      console.log(`[remodex] ${helperLabel} last error: ${helperStatus.lastError}`);
    }
  }
  console.log(`[remodex] Pairing payload: ${pairingCreatedAt}`);
  console.log(`[remodex] Stdout log: ${status.stdoutLogPath}`);
  console.log(`[remodex] Stderr log: ${status.stderrLogPath}`);
}

function printMacOSBridgePairingQr({ pairingSession = null, env = process.env, fsImpl = fs } = {}) {
  const nextPairingSession = pairingSession || readPairingSession({ env, fsImpl });
  const pairingPayload = nextPairingSession?.pairingPayload;
  if (!pairingPayload) {
    throw new Error("The macOS bridge service did not publish a pairing payload yet.");
  }

  printQR(pairingPayload);
}

// Persists a launch agent that always runs the Node CLI entrypoint in service mode.
function writeLaunchAgentPlist({
  env = process.env,
  fsImpl = fs,
  osImpl = os,
  nodePath = process.execPath,
  cliPath = path.resolve(__dirname, "..", "bin", "remodex.js"),
} = {}) {
  const plistPath = resolveLaunchAgentPlistPath({ env, osImpl });
  const stateDir = resolveRemodexStateDir({ env, osImpl });
  const stdoutLogPath = resolveBridgeStdoutLogPath({ env, osImpl });
  const stderrLogPath = resolveBridgeStderrLogPath({ env, osImpl });
  const homeDir = env.HOME || osImpl.homedir();
  const serialized = buildLaunchAgentPlist({
    homeDir,
    pathEnv: env.PATH || "",
    stateDir,
    stdoutLogPath,
    stderrLogPath,
    nodePath,
    cliPath,
  });

  fsImpl.mkdirSync(path.dirname(plistPath), { recursive: true });
  fsImpl.writeFileSync(plistPath, serialized, "utf8");
  return plistPath;
}

function buildLaunchAgentPlist({
  homeDir,
  pathEnv,
  stateDir,
  stdoutLogPath,
  stderrLogPath,
  nodePath,
  cliPath,
}) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${escapeXml(SERVICE_LABEL)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escapeXml(nodePath)}</string>
    <string>${escapeXml(cliPath)}</string>
    <string>run-service</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>WorkingDirectory</key>
  <string>${escapeXml(homeDir)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${escapeXml(homeDir)}</string>
    <key>PATH</key>
    <string>${escapeXml(pathEnv)}</string>
    <key>REMODEX_DEVICE_STATE_DIR</key>
    <string>${escapeXml(stateDir)}</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${escapeXml(stdoutLogPath)}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(stderrLogPath)}</string>
</dict>
</plist>
`;
}

async function waitForFreshPairingSession({
  env = process.env,
  fsImpl = fs,
  startedAt = Date.now(),
  timeoutMs = DEFAULT_PAIRING_WAIT_TIMEOUT_MS,
  intervalMs = DEFAULT_PAIRING_WAIT_INTERVAL_MS,
} = {}) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() <= deadline) {
    const pairingSession = readPairingSession({ env, fsImpl });
    const createdAt = Date.parse(pairingSession?.createdAt || "");
    if (pairingSession?.pairingPayload && Number.isFinite(createdAt) && createdAt >= startedAt) {
      return pairingSession;
    }
    await sleep(intervalMs);
  }

  throw new Error(
    `Timed out waiting for the macOS bridge service to publish a pairing QR. `
    + `Check ${resolveBridgeStderrLogPath({ env })}.`
  );
}

function restartLaunchAgent({
  env = process.env,
  execFileSyncImpl = execFileSync,
  plistPath,
} = {}) {
  bootoutLaunchAgent({
    env,
    execFileSyncImpl,
    ignoreMissing: true,
  });
  execFileSyncImpl("launchctl", [
    "bootstrap",
    launchAgentDomain(env),
    plistPath,
  ], { stdio: ["ignore", "ignore", "pipe"] });
}

function bootoutLaunchAgent({
  env = process.env,
  execFileSyncImpl = execFileSync,
  ignoreMissing = false,
} = {}) {
  const bootoutTargets = [
    // Some macOS setups only fully unload the agent when bootout targets the plist path.
    [launchAgentDomain(env), resolveLaunchAgentPlistPath({ env })],
    [launchAgentLabelDomain(env)],
  ];
  let lastError = null;

  for (const targetArgs of bootoutTargets) {
    try {
      execFileSyncImpl("launchctl", [
        "bootout",
        ...targetArgs,
      ], { stdio: ["ignore", "ignore", "pipe"] });
      return;
    } catch (error) {
      lastError = error;
    }
  }

  if (ignoreMissing && isMissingLaunchAgentError(lastError)) {
    return;
  }
  throw lastError;
}

function readLaunchAgentState({
  env = process.env,
  execFileSyncImpl = execFileSync,
} = {}) {
  try {
    const output = execFileSyncImpl("launchctl", [
      "print",
      launchAgentLabelDomain(env),
    ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return {
      loaded: true,
      pid: parseLaunchdPid(output),
      raw: output,
    };
  } catch (error) {
    if (isMissingLaunchAgentError(error)) {
      return {
        loaded: false,
        pid: null,
        raw: "",
      };
    }
    throw error;
  }
}

function resolveLaunchAgentPlistPath({ env = process.env, osImpl = os } = {}) {
  const homeDir = env.HOME || osImpl.homedir();
  return path.join(homeDir, "Library", "LaunchAgents", `${SERVICE_LABEL}.plist`);
}

function assertDarwinPlatform(platform = process.platform) {
  if (platform !== "darwin") {
    throw new Error("macOS bridge service management is only available on macOS.");
  }
}

function assertRelayConfigured(config) {
  if (typeof config?.relayUrl === "string" && config.relayUrl.trim()) {
    return;
  }
  throw new Error("No relay URL configured. Run ./run-local-remodex.sh or set REMODEX_RELAY before enabling the macOS bridge service.");
}

function launchAgentDomain(env) {
  return `gui/${resolveUid(env)}`;
}

function launchAgentLabelDomain(env) {
  return `${launchAgentDomain(env)}/${SERVICE_LABEL}`;
}

function resolveUid(env) {
  if (typeof process.getuid === "function") {
    return process.getuid();
  }

  const uid = Number.parseInt(env.UID || "", 10);
  if (Number.isFinite(uid)) {
    return uid;
  }

  throw new Error("Could not determine the current macOS user id for launchctl.");
}

function parseLaunchdPid(output) {
  const match = typeof output === "string" ? output.match(/\bpid = (\d+)/) : null;
  return match ? Number.parseInt(match[1], 10) : null;
}

function isMissingLaunchAgentError(error) {
  const combined = [
    error?.message,
    error?.stderr?.toString?.("utf8"),
    error?.stdout?.toString?.("utf8"),
  ].filter(Boolean).join("\n").toLowerCase();
  return combined.includes("could not find service")
    || combined.includes("service could not be found")
    || combined.includes("no such process");
}

function escapeXml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = {
  buildLaunchAgentPlist,
  getMacOSBridgeServiceStatus,
  printMacOSBridgePairingQr,
  printMacOSBridgeServiceStatus,
  resetMacOSBridgePairing,
  resolveMacOSBridgeStartConfig,
  resolveLaunchAgentPlistPath,
  runMacOSBridgeService,
  startMacOSBridgeService,
  stopMacOSBridgeService,
};
