// FILE: opencode-handoff.js
// Purpose: Builds OpenCode desktop handoff payloads and runs TUI session selection with desktop-app fallback.
// Layer: Bridge desktop handoff
// Exports: continueOpenCodeHandoff, buildHandoffPayload, isOpenCodeHandoffEnabled, detectOpenCodeApp
// Depends on: ./normalize, ./opencode-models

const { resolveOpenCodeHandoffEnabled } = require("./bridge-operator-profile");
const { readString, resolvedParam } = require("./normalize");
const { OPENCODE_PROVIDER_ID } = require("./opencode-models");

const HANDOFF_TIMEOUT_MS = 20_000;
const DESKTOP_THREAD_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/;
const OPENCODE_BUNDLE_IDS = [
  "ai.opencode.desktop",
  "ai.opencode.desktop.dev",
  "ai.opencode.desktop.beta",
];
const OPENCODE_APP_PATH = "/Applications/OpenCode.app";

function isOpenCodeHandoffEnabled(env = process.env) {
  return resolveOpenCodeHandoffEnabled(env);
}

function buildHandoffPayload({
  threadId = "",
  sessionId = "",
  cwd = "",
  model = "",
  agent = "",
  title = "",
} = {}) {
  return {
    threadId: readString(threadId),
    sessionId: readString(sessionId),
    cwd: readString(cwd),
    model: readString(model),
    agent: readString(agent),
    title: readString(title),
  };
}

function resolveThreadId(params = {}) {
  return readString(params.threadId || params.thread_id);
}

function resolveDirectory(params = {}) {
  return readString(params.directory || params.cwd || params.current_working_directory);
}

function isValidDesktopThreadId(threadId) {
  return typeof threadId === "string" && DESKTOP_THREAD_ID_PATTERN.test(threadId);
}

function handoffError(errorCode, userMessage, cause = null) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  if (cause) {
    error.cause = cause;
  }
  return error;
}

async function detectOpenCodeApp({ executor, fsModule, env } = {}) {
  const exec = executor || defaultExecutor;
  const fs = fsModule || require("fs");
  const platform = readString(env?.platform) || process.platform;

  if (platform !== "darwin") {
    return { installed: false, bundleId: "", appPath: "" };
  }

  if (fs.existsSync?.(OPENCODE_APP_PATH)) {
    return { installed: true, bundleId: OPENCODE_BUNDLE_IDS[0], appPath: OPENCODE_APP_PATH };
  }

  for (const bundleId of OPENCODE_BUNDLE_IDS) {
    try {
      const { stdout } = await exec(
        "/usr/bin/osascript",
        [
          "-e",
          `id of application id "${bundleId}"`,
        ],
        { timeout: HANDOFF_TIMEOUT_MS },
      );
      if (readString(stdout)) {
        return { installed: true, bundleId, appPath: OPENCODE_APP_PATH };
      }
    } catch {
      // Try next bundle id.
    }
  }

  try {
    const { stdout } = await exec(
      "/usr/bin/mdfind",
      [`kMDItemCFBundleIdentifier == '${OPENCODE_BUNDLE_IDS[0]}'`],
      { timeout: HANDOFF_TIMEOUT_MS },
    );
    const appPath = readString(stdout).split("\n").find((line) => line.endsWith(".app"));
    if (appPath) {
      return { installed: true, bundleId: OPENCODE_BUNDLE_IDS[0], appPath };
    }
  } catch {
    // Fall through to not installed.
  }

  return { installed: false, bundleId: "", appPath: "" };
}

async function openOpenCodeDesktopApp({ bundleId, appPath, executor } = {}) {
  const exec = executor || defaultExecutor;
  const resolvedBundleId = readString(bundleId) || OPENCODE_BUNDLE_IDS[0];
  const resolvedAppPath = readString(appPath) || OPENCODE_APP_PATH;

  try {
    await exec("open", ["-b", resolvedBundleId], { timeout: HANDOFF_TIMEOUT_MS });
    return true;
  } catch {
    await exec("open", ["-a", resolvedAppPath], { timeout: HANDOFF_TIMEOUT_MS });
    return true;
  }
}

function buildBridgeHandoffCommand(payload = {}) {
  const cwd = readString(payload.cwd);
  if (!cwd) {
    return "";
  }
  return `cd ${JSON.stringify(cwd)} && opencode`;
}

function buildInstructions(payload, { handoffMode, sessionSelected, desktopOpened } = {}) {
  const lines = [];
  if (sessionSelected) {
    lines.push("Session selected in OpenCode TUI.");
  } else if (desktopOpened || handoffMode === "desktop_app") {
    lines.push("OpenCode is open on your Mac.");
  } else {
    lines.push("Continue this OpenCode session on your Mac.");
  }

  const sessionId = readString(payload?.sessionId);
  const cwd = readString(payload?.cwd);
  if (sessionId) {
    lines.push(`Session ID: ${sessionId}`);
  }
  if (cwd) {
    lines.push(`Folder: ${cwd}`);
  }
  if (!sessionSelected) {
    lines.push("In Terminal, run `opencode` in that folder and select this session from the picker.");
  }
  return lines.join(" ");
}

async function continueOpenCodeHandoff(params = {}, options = {}) {
  const env = options.env || process.env;
  const platform = options.platform || process.platform;
  const ownershipStore = options.ownershipStore || null;
  const opencodeProvider = options.opencodeProvider || null;
  const executor = options.executor;
  const fsModule = options.fsModule;
  const logPrefix = readString(options.logPrefix) || "[remodex:opencode]";
  const preferDesktopApp = params.preferDesktopApp !== false;

  if (!isOpenCodeHandoffEnabled(env)) {
    throw handoffError(
      "opencode_handoff_disabled",
      "OpenCode handoff is not enabled on this Mac bridge.",
    );
  }

  if (platform !== "darwin") {
    throw handoffError(
      "unsupported_platform",
      "OpenCode handoff is only available when the bridge is running on macOS.",
    );
  }

  const threadId = resolveThreadId(params);
  if (!threadId) {
    throw handoffError("missing_thread_id", "A thread id is required to continue in OpenCode.");
  }
  if (!isValidDesktopThreadId(threadId)) {
    throw handoffError("invalid_thread_id", "The requested desktop thread id is not valid.");
  }

  const owner = ownershipStore?.getOwnership?.(threadId) || null;
  if (owner !== OPENCODE_PROVIDER_ID) {
    throw handoffError("wrong_provider", "This thread is not owned by OpenCode.");
  }

  if (!opencodeProvider || typeof opencodeProvider.getHandoffContext !== "function") {
    throw handoffError(
      "opencode_server_unreachable",
      "OpenCode is not available on this Mac bridge.",
    );
  }

  let context;
  try {
    context = await opencodeProvider.getHandoffContext(threadId, {
      sessionId: readString(params.sessionId || params.session_id),
      directory: resolveDirectory(params),
    });
  } catch (error) {
    const errorCode = readString(error?.errorCode) || "thread_not_found";
    if (errorCode === "opencode_session_expired") {
      throw handoffError(
        "opencode_session_expired",
        "This OpenCode session expired. Start a new thread on your phone.",
        error,
      );
    }
    if (errorCode === "opencode_server_unreachable" || errorCode === "opencode_not_installed") {
      throw handoffError(
        "opencode_server_unreachable",
        "OpenCode server is unreachable on this Mac.",
        error,
      );
    }
    throw handoffError(
      errorCode === "thread_not_found" ? "thread_not_found" : "thread_not_found",
      error?.userMessage || error?.message || "OpenCode thread not found.",
      error,
    );
  }

  const payload = buildHandoffPayload(context);
  const desktopDetection = await detectOpenCodeApp({ executor, fsModule, env: { platform } });
  let handoffMode = "tui_only";
  let sessionSelected = false;
  let desktopOpened = false;

  if (preferDesktopApp && desktopDetection.installed) {
    try {
      await openOpenCodeDesktopApp({
        bundleId: desktopDetection.bundleId,
        appPath: desktopDetection.appPath,
        executor,
      });
      desktopOpened = true;
      handoffMode = "desktop_app";
    } catch (error) {
      console.warn(
        `${logPrefix} OpenCode desktop launch failed: ${error?.message || error}`,
      );
    }
  }

  let tuiSelected = false;
  if (typeof opencodeProvider.selectTuiSession === "function" && payload.sessionId) {
    try {
      tuiSelected = await opencodeProvider.selectTuiSession(payload.sessionId);
    } catch (error) {
      console.warn(
        `${logPrefix} OpenCode TUI selectSession failed: ${error?.message || error}`,
      );
      tuiSelected = false;
    }
  }

  if (tuiSelected) {
    handoffMode = "tui";
    sessionSelected = true;
  } else if (desktopOpened) {
    handoffMode = "desktop_app";
    sessionSelected = false;
  } else {
    handoffMode = "tui_only";
    sessionSelected = false;
  }

  const handoffStatus = sessionSelected ? "complete" : "partial";

  return {
    success: true,
    ...payload,
    handoffMode,
    handoffStatus,
    sessionSelected,
    desktopAppInstalled: desktopDetection.installed,
    instructions: buildInstructions(payload, { handoffMode, sessionSelected, desktopOpened }),
    bridgeHandoffCommand: buildBridgeHandoffCommand(payload),
  };
}

function defaultExecutor(command, args, options) {
  const { promisify } = require("util");
  const { execFile } = require("child_process");
  const execFileAsync = promisify(execFile);
  return execFileAsync(command, args, options);
}

module.exports = {
  continueOpenCodeHandoff,
  buildHandoffPayload,
  buildBridgeHandoffCommand,
  buildInstructions,
  isOpenCodeHandoffEnabled,
  detectOpenCodeApp,
  isValidDesktopThreadId,
  OPENCODE_BUNDLE_IDS,
};