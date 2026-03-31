// FILE: icloud-helper-client.js
// Purpose: Spawns and communicates with the native macOS CloudKit helper used for async off-LAN requests.
// Layer: CLI helper
// Exports: createICloudHelperClient
// Depends on: child_process, fs, path, readline

const fs = require("fs");
const path = require("path");
const readline = require("readline");
const { spawn } = require("child_process");

function createICloudHelperClient({
  enabled = false,
  helperPath = "",
  containerId = "",
  deviceStateDir = "",
  logPrefix = "[remodex]",
  onAsyncRequest = null,
  onStatusChange = null,
} = {}) {
  let child = null;
  let isStopping = false;
  let currentStatus = {
    enabled: Boolean(enabled),
    running: false,
    available: false,
    provider: "icloud",
    displayName: "iCloud helper",
    helperPath: "",
    containerId: containerId || "",
    lastError: "",
  };

  function publishStatus(nextStatus) {
    currentStatus = {
      ...currentStatus,
      ...nextStatus,
    };
    onStatusChange?.(currentStatus);
  }

  function resolveLaunchCommand() {
    const normalizedHelperPath = readString(helperPath);
    if (normalizedHelperPath) {
      return {
        command: normalizedHelperPath,
        args: ["daemon"],
        helperPath: normalizedHelperPath,
      };
    }

    const helperSourcePath = path.join(__dirname, "remodex-icloud-helper.swift");
    if (fs.existsSync(helperSourcePath)) {
      return {
        command: "xcrun",
        args: ["swift", helperSourcePath, "daemon"],
        helperPath: helperSourcePath,
      };
    }

    return null;
  }

  function start() {
    if (!enabled || child) {
      publishStatus({
        enabled: Boolean(enabled),
      });
      return;
    }

    const launchCommand = resolveLaunchCommand();
    if (!launchCommand) {
      publishStatus({
        enabled: true,
        available: false,
        running: false,
        lastError: "No CloudKit helper binary or source was found.",
      });
      return;
    }

    const env = {
      ...process.env,
      REMODEX_DEVICE_STATE_DIR: deviceStateDir || process.env.REMODEX_DEVICE_STATE_DIR || "",
      REMODEX_ICLOUD_CONTAINER: containerId || process.env.REMODEX_ICLOUD_CONTAINER || "",
    };
    child = spawn(launchCommand.command, launchCommand.args, {
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    isStopping = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");

    publishStatus({
      enabled: true,
      available: true,
      running: true,
      helperPath: launchCommand.helperPath,
      lastError: "",
    });

    const stdoutReader = readline.createInterface({ input: child.stdout });
    stdoutReader.on("line", (line) => {
      const message = safeParseJSON(line);
      if (!message || typeof message !== "object") {
        return;
      }
      if (message.kind === "asyncRequest" && typeof onAsyncRequest === "function") {
        onAsyncRequest(message);
        return;
      }
      if (message.kind === "helperStatus") {
        publishStatus({
          available: Boolean(message.available),
          running: true,
          lastError: readString(message.lastError),
        });
      }
    });

    child.stderr.on("data", (chunk) => {
      const text = String(chunk).trim();
      if (!text) {
        return;
      }
      publishStatus({
        lastError: text,
      });
      console.warn(`${logPrefix} [icloud-helper] ${text}`);
    });

    child.on("exit", (code, signal) => {
      child = null;
      publishStatus({
        running: false,
        available: isStopping || code === 0,
        lastError: isStopping || code === 0 ? "" : `Helper exited (${signal || code || "unknown"})`,
      });
      isStopping = false;
    });
  }

  function stop() {
    if (!child) {
      publishStatus({
        running: false,
      });
      return;
    }
    isStopping = true;
    child.kill("SIGTERM");
    child = null;
    publishStatus({
      running: false,
    });
  }

  function sendResponse({ recordName, payloadText, requestId }) {
    if (!child || !recordName) {
      return false;
    }
    child.stdin.write(JSON.stringify({
      kind: "asyncResponse",
      recordName,
      payloadText,
      requestId: requestId || "",
    }) + "\n");
    return true;
  }

  function sendError({ recordName, requestId, message }) {
    if (!child || !recordName) {
      return false;
    }
    child.stdin.write(JSON.stringify({
      kind: "asyncError",
      recordName,
      requestId: requestId || "",
      message: readString(message) || "Bridge request failed.",
    }) + "\n");
    return true;
  }

  return {
    currentStatus() {
      return currentStatus;
    },
    sendError,
    sendResponse,
    start,
    stop,
  };
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  createICloudHelperClient,
};
