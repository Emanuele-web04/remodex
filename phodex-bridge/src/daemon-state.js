// FILE: daemon-state.js
// Purpose: Persists macOS service config/runtime state outside the repo for the launchd bridge flow.
// Layer: CLI helper
// Exports: path resolvers plus read/write helpers for daemon config, pairing payloads, and service status.
// Depends on: fs, os, path

const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_STATE_DIR_NAME = ".remodex";
const DAEMON_CONFIG_FILE = "daemon-config.json";
const PAIRING_SESSION_FILE = "pairing-session.json";
const BRIDGE_STATUS_FILE = "bridge-status.json";
const LOGS_DIR = "logs";
const BRIDGE_STDOUT_LOG_FILE = "bridge.stdout.log";
const BRIDGE_STDERR_LOG_FILE = "bridge.stderr.log";

// Reuses the existing Remodex state root so daemon mode keeps the same local-first storage model.
function resolveRemodexStateDir({ env = process.env, osImpl = os } = {}) {
  return normalizeNonEmptyString(env.REMODEX_DEVICE_STATE_DIR)
    || path.join(osImpl.homedir(), DEFAULT_STATE_DIR_NAME);
}

function resolveDaemonConfigPath(options = {}) {
  return path.join(resolveRemodexStateDir(options), DAEMON_CONFIG_FILE);
}

function resolvePairingSessionPath(options = {}) {
  return path.join(resolveRemodexStateDir(options), PAIRING_SESSION_FILE);
}

function resolveBridgeStatusPath(options = {}) {
  return path.join(resolveRemodexStateDir(options), BRIDGE_STATUS_FILE);
}

function resolveBridgeLogsDir(options = {}) {
  return path.join(resolveRemodexStateDir(options), LOGS_DIR);
}

function resolveBridgeStdoutLogPath(options = {}) {
  return path.join(resolveBridgeLogsDir(options), BRIDGE_STDOUT_LOG_FILE);
}

function resolveBridgeStderrLogPath(options = {}) {
  return path.join(resolveBridgeLogsDir(options), BRIDGE_STDERR_LOG_FILE);
}

function writeDaemonConfig(config, options = {}) {
  writeJsonFile(resolveDaemonConfigPath(options), config, options);
}

function readDaemonConfig(options = {}) {
  return readJsonFile(resolveDaemonConfigPath(options), options);
}

// Persists the pairing payload so foreground CLI commands can render the QR locally.
function writePairingSession(pairingPayload, { now = () => Date.now(), ...options } = {}) {
  writeJsonFile(resolvePairingSessionPath(options), {
    createdAt: new Date(now()).toISOString(),
    pairingPayload,
  }, options);
}

function readPairingSession(options = {}) {
  return readJsonFile(resolvePairingSessionPath(options), options);
}

function clearPairingSession({ fsImpl = fs, ...options } = {}) {
  removeFile(resolvePairingSessionPath(options), fsImpl);
}

// Captures the last known service heartbeat so `remodex status` does not depend on launchctl output alone.
function writeBridgeStatus(status, { now = () => Date.now(), ...options } = {}) {
  writeJsonFile(resolveBridgeStatusPath(options), {
    ...status,
    updatedAt: new Date(now()).toISOString(),
  }, options);
}

function readBridgeStatus(options = {}) {
  return readJsonFile(resolveBridgeStatusPath(options), options);
}

function clearBridgeStatus({ fsImpl = fs, ...options } = {}) {
  removeFile(resolveBridgeStatusPath(options), fsImpl);
}

function ensureRemodexStateDir({ fsImpl = fs, ...options } = {}) {
  fsImpl.mkdirSync(resolveRemodexStateDir(options), { recursive: true });
}

function ensureRemodexLogsDir({ fsImpl = fs, ...options } = {}) {
  fsImpl.mkdirSync(resolveBridgeLogsDir(options), { recursive: true });
}

function writeJsonFile(targetPath, value, { fsImpl = fs } = {}) {
  fsImpl.mkdirSync(path.dirname(targetPath), { recursive: true });
  const serialized = JSON.stringify(value, null, 2);
  fsImpl.writeFileSync(targetPath, serialized, { mode: 0o600 });
  try {
    fsImpl.chmodSync(targetPath, 0o600);
  } catch {
    // Best-effort only on filesystems without POSIX mode support.
  }
}

function readJsonFile(targetPath, { fsImpl = fs } = {}) {
  if (!fsImpl.existsSync(targetPath)) {
    return null;
  }

  try {
    return JSON.parse(fsImpl.readFileSync(targetPath, "utf8"));
  } catch {
    return null;
  }
}

function removeFile(targetPath, fsImpl) {
  try {
    fsImpl.rmSync(targetPath, { force: true });
  } catch {
    // Missing runtime files should not block control-plane commands.
  }
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  clearBridgeStatus,
  clearPairingSession,
  ensureRemodexLogsDir,
  ensureRemodexStateDir,
  readBridgeStatus,
  readDaemonConfig,
  readPairingSession,
  resolveBridgeLogsDir,
  resolveBridgeStderrLogPath,
  resolveBridgeStatusPath,
  resolveBridgeStdoutLogPath,
  resolveDaemonConfigPath,
  resolvePairingSessionPath,
  resolveRemodexStateDir,
  writeBridgeStatus,
  writeDaemonConfig,
  writePairingSession,
};
