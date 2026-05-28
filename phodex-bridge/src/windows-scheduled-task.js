// FILE: windows-scheduled-task.js
// Purpose: Owns Windows per-user Task Scheduler helpers for the background Remodex bridge.
// Layer: CLI helper
// Exports: Windows service lifecycle helpers plus testable XML/runner builders.
// Depends on: child_process, fs, os, path, crypto, ./codex-desktop-refresher, ./daemon-bridge-runner, ./daemon-state, ./qr, ./secure-device-state

const { execFileSync } = require("child_process");
const { createHash } = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { readBridgeConfig } = require("./codex-desktop-refresher");
const { runDaemonBridgeService } = require("./daemon-bridge-runner");
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
  writeDaemonConfig,
} = require("./daemon-state");
const { printQR } = require("./qr");
const { readBridgeDeviceState, resetBridgeTrustState } = require("./secure-device-state");

const TASK_NAME = "\\Remodex\\Bridge";
const TASK_XML_FILE = "windows-bridge-task.xml";
const RUNNER_CMD_FILE = "windows-bridge-runner.cmd";
const DEFAULT_PAIRING_WAIT_TIMEOUT_MS = 10_000;
const DEFAULT_PAIRING_WAIT_INTERVAL_MS = 200;

function runWindowsBridgeService({ env = process.env, platform = process.platform } = {}) {
  assertWindowsPlatform(platform);
  runDaemonBridgeService({
    env,
    missingRelayMessage: "No relay URL configured for the Windows bridge service.",
  });
}

async function startWindowsBridgeService({
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
  assertWindowsPlatform(platform);
  const config = readBridgeConfig({ env, fsImpl });
  assertRelayConfigured(config);
  const startedAt = Date.now();

  writeDaemonConfig(config, { env, fsImpl });
  clearPairingSession({ env, fsImpl });
  clearBridgeStatus({ env, fsImpl });
  ensureRemodexStateDir({ env, fsImpl, osImpl });
  ensureRemodexLogsDir({ env, fsImpl, osImpl });

  const runnerPath = writeWindowsBridgeRunnerCmd({
    env,
    fsImpl,
    osImpl,
    nodePath,
    cliPath,
  });
  const taskXmlPath = writeWindowsScheduledTaskXml({
    env,
    fsImpl,
    osImpl,
    runnerPath,
  });

  registerWindowsScheduledTask({
    execFileSyncImpl,
    taskName: TASK_NAME,
    taskXmlPath,
  });
  startWindowsScheduledTask({
    execFileSyncImpl,
    taskName: TASK_NAME,
  });

  if (!waitForPairing) {
    return {
      taskName: TASK_NAME,
      taskXmlPath,
      runnerPath,
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
    taskName: TASK_NAME,
    taskXmlPath,
    runnerPath,
    pairingSession,
  };
}

async function restartWindowsBridgeService({
  env = process.env,
  platform = process.platform,
  fsImpl = fs,
  execFileSyncImpl = execFileSync,
  osImpl = os,
  waitForPairing = false,
  pairingTimeoutMs = DEFAULT_PAIRING_WAIT_TIMEOUT_MS,
  pairingPollIntervalMs = DEFAULT_PAIRING_WAIT_INTERVAL_MS,
  ...startOptions
} = {}) {
  assertWindowsPlatform(platform);
  const runnerPath = resolveWindowsBridgeRunnerPath({ env, osImpl });
  const taskXmlPath = resolveWindowsScheduledTaskXmlPath({ env, osImpl });
  if (!fsImpl.existsSync(runnerPath) || !fsImpl.existsSync(taskXmlPath)) {
    return startWindowsBridgeService({
      env,
      platform,
      fsImpl,
      execFileSyncImpl,
      osImpl,
      waitForPairing,
      pairingTimeoutMs,
      pairingPollIntervalMs,
      ...startOptions,
    });
  }

  const startedAt = Date.now();
  stopWindowsScheduledTask({
    execFileSyncImpl,
    ignoreMissing: true,
    taskName: TASK_NAME,
  });
  clearPairingSession({ env, fsImpl });
  clearBridgeStatus({ env, fsImpl });
  startWindowsScheduledTask({
    execFileSyncImpl,
    taskName: TASK_NAME,
  });

  if (!waitForPairing) {
    return {
      taskName: TASK_NAME,
      taskXmlPath,
      runnerPath,
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
    taskName: TASK_NAME,
    taskXmlPath,
    runnerPath,
    pairingSession,
  };
}

function stopWindowsBridgeService({
  env = process.env,
  platform = process.platform,
  fsImpl = fs,
  execFileSyncImpl = execFileSync,
  processImpl = process,
} = {}) {
  assertWindowsPlatform(platform);
  const status = getWindowsBridgeServiceStatus({
    env,
    fsImpl,
    execFileSyncImpl,
  });
  stopWindowsScheduledTask({
    execFileSyncImpl,
    ignoreMissing: true,
    taskName: TASK_NAME,
  });
  terminateRecordedBridgeProcess(status, {
    execFileSyncImpl,
    processImpl,
  });
  clearPairingSession({ env, fsImpl });
  clearBridgeStatus({ env, fsImpl });
}

function resetWindowsBridgePairing({
  env = process.env,
  platform = process.platform,
  fsImpl = fs,
  execFileSyncImpl = execFileSync,
  processImpl = process,
} = {}) {
  assertWindowsPlatform(platform);
  stopWindowsBridgeService({
    env,
    platform,
    fsImpl,
    execFileSyncImpl,
    processImpl,
  });
  resetBridgeTrustState({ env, fsImpl });
  clearPairingSession({ env, fsImpl });
  clearBridgeStatus({ env, fsImpl });
}

function getWindowsBridgeServiceStatus({
  env = process.env,
  fsImpl = fs,
  execFileSyncImpl = execFileSync,
  osImpl = os,
} = {}) {
  const task = readWindowsScheduledTaskState({
    execFileSyncImpl,
    taskName: TASK_NAME,
  });
  const bridgeStatus = readBridgeStatus({ env, fsImpl });
  return {
    taskName: TASK_NAME,
    installed: task.installed,
    taskStatus: task.status,
    taskLastRunTime: task.lastRunTime,
    taskLastResult: task.lastResult,
    taskNextRunTime: task.nextRunTime,
    runnerPath: resolveWindowsBridgeRunnerPath({ env, osImpl }),
    taskXmlPath: resolveWindowsScheduledTaskXmlPath({ env, osImpl }),
    stdoutLogPath: resolveBridgeStdoutLogPath({ env, osImpl }),
    stderrLogPath: resolveBridgeStderrLogPath({ env, osImpl }),
    pid: bridgeStatus?.pid || null,
    daemonConfig: readDaemonConfig({ env, fsImpl }),
    bridgeStatus,
    pairingSession: readPairingSession({ env, fsImpl }),
    trustedDevice: buildTrustedDeviceSummary(readBridgeDeviceState({ env, fsImpl })),
  };
}

function printWindowsBridgeServiceStatus(options = {}) {
  const status = getWindowsBridgeServiceStatus(options);
  const bridgeState = status.bridgeStatus?.state || "unknown";
  const connectionStatus = status.bridgeStatus?.connectionStatus || "unknown";
  const pairingCreatedAt = status.pairingSession?.createdAt || "none";
  const activeDevice = status.bridgeStatus?.activeDevice || status.bridgeStatus?.activePhone;
  const activeDeviceName = formatDeviceKind(activeDevice?.deviceKind) || "device";
  const trustedDeviceName = formatDeviceKind(status.trustedDevice?.lastSeenDeviceKind) || "device";
  const trustedDeviceCount = status.trustedDevice?.trustedPhoneCount || 0;
  console.log(`[remodex] Task name: ${status.taskName}`);
  console.log(`[remodex] Installed: ${status.installed ? "yes" : "no"}`);
  console.log(`[remodex] Task status: ${status.taskStatus || "unknown"}`);
  console.log(`[remodex] PID: ${status.pid || "unknown"}`);
  console.log(`[remodex] Bridge state: ${bridgeState}`);
  console.log(`[remodex] Connection: ${connectionStatus}`);
  console.log(`[remodex] Active ${activeDeviceName}: ${activeDevice?.connected ? activeDevice.phoneFingerprint || "yes" : "no"}`);
  console.log(`[remodex] Trusted ${trustedDeviceName}: ${trustedDeviceCount > 0 ? "yes" : "no"}`);
  console.log(`[remodex] Pairing payload: ${pairingCreatedAt}`);
  console.log(`[remodex] Stdout log: ${status.stdoutLogPath}`);
  console.log(`[remodex] Stderr log: ${status.stderrLogPath}`);
}

function printWindowsBridgePairingQr({ pairingSession = null, env = process.env, fsImpl = fs } = {}) {
  const nextPairingSession = pairingSession || readPairingSession({ env, fsImpl });
  if (!nextPairingSession?.pairingPayload) {
    throw new Error("The Windows bridge service did not publish a pairing payload yet.");
  }

  printQR(nextPairingSession);
}

function writeWindowsBridgeRunnerCmd({
  env = process.env,
  fsImpl = fs,
  osImpl = os,
  nodePath = process.execPath,
  cliPath = path.resolve(__dirname, "..", "bin", "remodex.js"),
} = {}) {
  const runnerPath = resolveWindowsBridgeRunnerPath({ env, osImpl });
  const stateDir = resolveRemodexStateDir({ env, osImpl });
  const stdoutLogPath = resolveBridgeStdoutLogPath({ env, osImpl });
  const stderrLogPath = resolveBridgeStderrLogPath({ env, osImpl });
  const content = buildWindowsBridgeRunnerCmd({
    env: buildRunnerEnvironment({ env, osImpl, stateDir }),
    nodePath,
    cliPath,
    stdoutLogPath,
    stderrLogPath,
  });

  fsImpl.mkdirSync(path.dirname(runnerPath), { recursive: true });
  fsImpl.writeFileSync(runnerPath, content, "utf8");
  return runnerPath;
}

function buildWindowsBridgeRunnerCmd({
  env = {},
  nodePath,
  cliPath,
  stdoutLogPath,
  stderrLogPath,
}) {
  const setLines = Object.entries(env)
    .filter(([, value]) => normalizeNonEmptyString(value))
    .map(([name, value]) => `set "${name}=${escapeCmdSetValue(value)}"`);
  return [
    "@echo off",
    "setlocal",
    ...setLines,
    `${quoteCmdPath(nodePath)} ${quoteCmdPath(cliPath)} run-service >> ${quoteCmdPath(stdoutLogPath)} 2>> ${quoteCmdPath(stderrLogPath)}`,
    "exit /b %ERRORLEVEL%",
    "",
  ].join("\r\n");
}

function writeWindowsScheduledTaskXml({
  env = process.env,
  fsImpl = fs,
  osImpl = os,
  runnerPath = resolveWindowsBridgeRunnerPath({ env, osImpl }),
} = {}) {
  const taskXmlPath = resolveWindowsScheduledTaskXmlPath({ env, osImpl });
  const stateDir = resolveRemodexStateDir({ env, osImpl });
  const serialized = buildWindowsScheduledTaskXml({
    actionCommand: env.ComSpec || "cmd.exe",
    actionArguments: `/d /c ${quoteCmdForCommandLine(runnerPath)}`,
    workingDirectory: stateDir,
  });

  fsImpl.mkdirSync(path.dirname(taskXmlPath), { recursive: true });
  fsImpl.writeFileSync(taskXmlPath, serialized, "utf8");
  return taskXmlPath;
}

function buildWindowsScheduledTaskXml({
  actionCommand,
  actionArguments,
  workingDirectory,
  author = "Remodex",
  taskUri = TASK_NAME,
}) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>${escapeXml(author)}</Author>
    <URI>${escapeXml(taskUri)}</URI>
    <Description>Runs the Remodex bridge in the current user's background session.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>${escapeXml(actionCommand)}</Command>
      <Arguments>${escapeXml(actionArguments)}</Arguments>
      <WorkingDirectory>${escapeXml(workingDirectory)}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
`;
}

function registerWindowsScheduledTask({
  execFileSyncImpl = execFileSync,
  taskName = TASK_NAME,
  taskXmlPath,
} = {}) {
  execFileSyncImpl("schtasks", [
    "/create",
    "/tn",
    taskName,
    "/xml",
    taskXmlPath,
    "/f",
  ], { stdio: ["ignore", "ignore", "pipe"] });
}

function startWindowsScheduledTask({
  execFileSyncImpl = execFileSync,
  taskName = TASK_NAME,
} = {}) {
  execFileSyncImpl("schtasks", [
    "/run",
    "/tn",
    taskName,
  ], { stdio: ["ignore", "ignore", "pipe"] });
}

function stopWindowsScheduledTask({
  execFileSyncImpl = execFileSync,
  taskName = TASK_NAME,
  ignoreMissing = false,
} = {}) {
  try {
    execFileSyncImpl("schtasks", [
      "/end",
      "/tn",
      taskName,
    ], { stdio: ["ignore", "ignore", "pipe"] });
  } catch (error) {
    if (ignoreMissing && isMissingScheduledTaskError(error)) {
      return;
    }
    if (ignoreMissing && isTaskNotRunningError(error)) {
      return;
    }
    throw error;
  }
}

function readWindowsScheduledTaskState({
  execFileSyncImpl = execFileSync,
  taskName = TASK_NAME,
} = {}) {
  try {
    const output = execFileSyncImpl("schtasks", [
      "/query",
      "/tn",
      taskName,
      "/fo",
      "CSV",
      "/v",
    ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    const records = parseCsvRecords(output);
    const record = records[0] || {};
    return {
      installed: true,
      status: record.Status || "",
      lastRunTime: record["Last Run Time"] || "",
      lastResult: record["Last Result"] || "",
      nextRunTime: record["Next Run Time"] || "",
      raw: output,
    };
  } catch (error) {
    if (isMissingScheduledTaskError(error)) {
      return {
        installed: false,
        status: "",
        lastRunTime: "",
        lastResult: "",
        nextRunTime: "",
        raw: "",
      };
    }
    throw error;
  }
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
    if (
      pairingSession?.pairingPayload
      && Number.isFinite(createdAt)
      && createdAt >= startedAt
    ) {
      return pairingSession;
    }
    await sleep(intervalMs);
  }

  throw new Error(
    `Timed out waiting for the Windows bridge service to publish a pairing QR. `
    + `Check ${resolveBridgeStderrLogPath({ env })}.`
  );
}

function terminateRecordedBridgeProcess(status, {
  execFileSyncImpl = execFileSync,
  processImpl = process,
} = {}) {
  const pid = Number(status?.pid || status?.bridgeStatus?.pid);
  if (!Number.isInteger(pid) || pid <= 0 || pid === processImpl.pid) {
    return false;
  }

  if (!isRecordedRemodexBridgeProcess(pid, { execFileSyncImpl })) {
    return false;
  }

  execFileSyncImpl("taskkill", [
    "/pid",
    String(pid),
    "/t",
    "/f",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  return true;
}

function isRecordedRemodexBridgeProcess(pid, { execFileSyncImpl = execFileSync } = {}) {
  const processInfo = readWindowsProcessInfo(pid, { execFileSyncImpl });
  const commandLine = normalizeNonEmptyString(processInfo?.CommandLine || processInfo?.commandLine).toLowerCase();
  return commandLine.includes("remodex")
    && commandLine.includes("run-service");
}

function readWindowsProcessInfo(pid, { execFileSyncImpl = execFileSync } = {}) {
  try {
    const script = [
      `$p = Get-CimInstance Win32_Process -Filter "ProcessId = ${Number(pid)}" -ErrorAction SilentlyContinue`,
      "if ($p) { $p | Select-Object -Property ProcessId,CommandLine | ConvertTo-Json -Compress }",
    ].join("; ");
    const output = execFileSyncImpl("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      script,
    ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    return output.trim() ? JSON.parse(output) : null;
  } catch {
    return null;
  }
}

function resolveWindowsBridgeRunnerPath({ env = process.env, osImpl = os } = {}) {
  return path.join(resolveRemodexStateDir({ env, osImpl }), RUNNER_CMD_FILE);
}

function resolveWindowsScheduledTaskXmlPath({ env = process.env, osImpl = os } = {}) {
  return path.join(resolveRemodexStateDir({ env, osImpl }), TASK_XML_FILE);
}

function buildRunnerEnvironment({ env = process.env, osImpl = os, stateDir }) {
  return {
    USERPROFILE: env.USERPROFILE || osImpl.homedir(),
    HOME: env.HOME || "",
    APPDATA: env.APPDATA || "",
    LOCALAPPDATA: env.LOCALAPPDATA || "",
    PATH: env.PATH || "",
    ComSpec: env.ComSpec || "",
    CODEX_HOME: env.CODEX_HOME || "",
    REMODEX_DEVICE_STATE_DIR: stateDir,
  };
}

function assertWindowsPlatform(platform = process.platform) {
  if (platform !== "win32") {
    throw new Error("Windows bridge service management is only available on Windows.");
  }
}

function assertRelayConfigured(config) {
  if (typeof config?.relayUrl === "string" && config.relayUrl.trim()) {
    return;
  }
  throw new Error("No relay URL configured. Run ./run-local-remodex.sh or set REMODEX_RELAY before enabling the Windows bridge service.");
}

function parseCsvRecords(output) {
  const rows = String(output || "")
    .split(/\r?\n/)
    .filter((line) => line.trim());
  if (rows.length < 2) {
    return [];
  }
  const headers = parseCsvLine(rows[0]);
  return rows.slice(1).map((row) => {
    const values = parseCsvLine(row);
    const record = {};
    for (let i = 0; i < headers.length; i += 1) {
      record[headers[i]] = values[i] || "";
    }
    return record;
  });
}

function parseCsvLine(line) {
  const values = [];
  let current = "";
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"') {
      if (quoted && line[i + 1] === '"') {
        current += '"';
        i += 1;
      } else {
        quoted = !quoted;
      }
      continue;
    }
    if (char === "," && !quoted) {
      values.push(current);
      current = "";
      continue;
    }
    current += char;
  }
  values.push(current);
  return values;
}

function isMissingScheduledTaskError(error) {
  const combined = collectErrorText(error);
  return combined.includes("cannot find")
    || combined.includes("could not find")
    || combined.includes("does not exist")
    || combined.includes("the system cannot find")
    || combined.includes("specified task name");
}

function isTaskNotRunningError(error) {
  const combined = collectErrorText(error);
  return combined.includes("not currently running")
    || combined.includes("is not running");
}

function collectErrorText(error) {
  return [
    error?.message,
    error?.stderr?.toString?.("utf8"),
    error?.stdout?.toString?.("utf8"),
  ].filter(Boolean).join("\n").toLowerCase();
}

function quoteCmdPath(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

function quoteCmdForCommandLine(value) {
  return `""${String(value).replaceAll('"', '""')}""`;
}

function escapeCmdSetValue(value) {
  return String(value).replaceAll('"', '""').replace(/\r?\n/g, "");
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

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function buildTrustedDeviceSummary(deviceState) {
  const trustedPhoneEntries = Object.entries(deviceState?.trustedPhones || {})
    .filter(([phoneDeviceId, publicKey]) => normalizeNonEmptyString(phoneDeviceId) && normalizeNonEmptyString(publicKey));
  const firstTrustedPhoneId = trustedPhoneEntries[0]?.[0] || "";
  const lastSeenPhoneAppVersion = normalizeNonEmptyString(deviceState?.lastSeenPhoneAppVersion) || null;
  return {
    macDeviceFingerprint: shortFingerprint(deviceState?.macDeviceId),
    trustedPhoneCount: trustedPhoneEntries.length,
    trustedPhoneFingerprint: shortFingerprint(firstTrustedPhoneId),
    lastSeenDeviceKind: normalizeNonEmptyString(deviceState?.lastSeenDeviceKind) || (lastSeenPhoneAppVersion ? "iphone" : null),
    lastSeenPhoneAppVersion,
  };
}

function formatDeviceKind(deviceKind) {
  const normalized = normalizeNonEmptyString(deviceKind).toLowerCase();
  if (normalized === "iphone") {
    return "iPhone";
  }
  if (normalized === "android") {
    return "Android";
  }
  if (normalized === "mac") {
    return "Mac";
  }
  return "";
}

function shortFingerprint(value) {
  const normalized = normalizeNonEmptyString(value);
  if (!normalized) {
    return null;
  }
  return createHash("sha256").update(normalized).digest("hex").slice(0, 8);
}

module.exports = {
  buildWindowsBridgeRunnerCmd,
  buildWindowsScheduledTaskXml,
  getWindowsBridgeServiceStatus,
  isRecordedRemodexBridgeProcess,
  parseCsvRecords,
  printWindowsBridgePairingQr,
  printWindowsBridgeServiceStatus,
  resetWindowsBridgePairing,
  resolveWindowsBridgeRunnerPath,
  resolveWindowsScheduledTaskXmlPath,
  restartWindowsBridgeService,
  runWindowsBridgeService,
  startWindowsBridgeService,
  stopWindowsBridgeService,
  TASK_NAME,
  terminateRecordedBridgeProcess,
  writeWindowsBridgeRunnerCmd,
  writeWindowsScheduledTaskXml,
};
