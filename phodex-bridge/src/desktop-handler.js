// FILE: desktop-handler.js
// Purpose: Handles explicit desktop-handoff bridge actions for Codex.app.
// Layer: Bridge handler
// Exports: handleDesktopRequest
// Depends on: child_process, fs, os, path, ./rollout-watch

const { execFile } = require("child_process");
const fs = require("fs");
const path = require("path");
const { promisify } = require("util");
const { findRolloutFileForThread, resolveSessionsRoot } = require("./rollout-watch");

const execFileAsync = promisify(execFile);
const DEFAULT_BUNDLE_ID = "com.openai.codex";
const DEFAULT_APP_PATH = "/Applications/Codex.app";
const DEFAULT_PLATFORM = process.platform;
const HANDOFF_TIMEOUT_MS = 20_000;
const DEFAULT_RELAUNCH_WAIT_MS = 300;
const DEFAULT_APP_BOOT_WAIT_MS = 1_200;
const DEFAULT_THREAD_MATERIALIZE_WAIT_MS = 4_000;
const DEFAULT_THREAD_MATERIALIZE_POLL_MS = 250;

function handleDesktopRequest(rawMessage, sendResponse, options = {}) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (!method.startsWith("desktop/")) {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};

  handleDesktopMethod(method, params, options)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "desktop_error";
      const message = err.userMessage || err.message || "Unknown desktop handoff error";
      sendResponse(JSON.stringify({
        id,
        error: {
          code: -32000,
          message,
          data: { errorCode },
        },
      }));
    });

  return true;
}

async function handleDesktopMethod(method, params, options = {}) {
  const platform = options.platform || DEFAULT_PLATFORM;
  const bundleId = options.bundleId || DEFAULT_BUNDLE_ID;
  const appPath = options.appPath || DEFAULT_APP_PATH;
  const executor = options.executor || execFileAsync;
  const env = options.env || process.env;
  const fsModule = options.fsModule || fs;
  const isAppRunning = options.isAppRunning || null;
  const sleepFn = options.sleepFn || sleep;
  const appBootWaitMs = options.appBootWaitMs ?? DEFAULT_APP_BOOT_WAIT_MS;
  const relaunchWaitMs = options.relaunchWaitMs ?? DEFAULT_RELAUNCH_WAIT_MS;
  const threadMaterializeWaitMs = options.threadMaterializeWaitMs ?? DEFAULT_THREAD_MATERIALIZE_WAIT_MS;
  const threadMaterializePollMs = options.threadMaterializePollMs ?? DEFAULT_THREAD_MATERIALIZE_POLL_MS;

  if (platform !== "darwin") {
    throw desktopError(
      "unsupported_platform",
      "Mac handoff is only available when the bridge is running on macOS."
    );
  }

  switch (method) {
    case "desktop/continueOnMac":
      return continueOnMac(params, {
        bundleId,
        appPath,
        executor,
        env,
        fsModule,
        isAppRunning,
        sleepFn,
        appBootWaitMs,
        relaunchWaitMs,
        threadMaterializeWaitMs,
        threadMaterializePollMs,
      });
    default:
      throw desktopError("unknown_method", `Unknown desktop method: ${method}`);
  }
}

// Waits for fresh phone-authored chats to materialize locally before deep-linking them on Mac.
async function continueOnMac(
  params,
  {
    bundleId,
    appPath,
    executor,
    env,
    fsModule,
    isAppRunning,
    sleepFn,
    appBootWaitMs,
    relaunchWaitMs,
    threadMaterializeWaitMs,
    threadMaterializePollMs,
  }
) {
  const threadId = resolveThreadId(params);
  if (!threadId) {
    throw desktopError("missing_thread_id", "A thread id is required to continue on Mac.");
  }

  const targetUrl = `codex://threads/${threadId}`;
  const desktopKnown = isThreadLikelyKnownOnDesktop(threadId, { env, fsModule });
  const appRunning = typeof isAppRunning === "function"
    ? await isAppRunning(appPath)
    : await detectRunningCodexApp(appPath, executor);

  // Preserve the safer direct-open path for threads the desktop already knows
  // about. Relaunching here regressed handoff reliability for existing threads.
  if (desktopKnown) {
    try {
      await openCodexTarget(targetUrl, { bundleId, appPath, executor });
    } catch (error) {
      throw desktopError(
        "handoff_failed",
        "Could not open Codex.app on this Mac.",
        error
      );
    }

    return {
      success: true,
      relaunched: false,
      targetUrl,
      threadId,
      desktopKnown,
    };
  }

  // Brand-new phone-authored threads still need a short boot/materialization
  // window before the final deep link is likely to work.
  if (!appRunning) {
    try {
      await openCodexApp({ bundleId, appPath, executor });
      await sleepFn(appBootWaitMs);
      await openWhenThreadReady(threadId, targetUrl, {
        bundleId,
        appPath,
        executor,
        env,
        fsModule,
        sleepFn,
        waitMs: threadMaterializeWaitMs,
        pollMs: threadMaterializePollMs,
      });
    } catch (error) {
      throw desktopError(
        "handoff_failed",
        "Could not open Codex.app on this Mac.",
        error
      );
    }

    return {
      success: true,
      relaunched: false,
      targetUrl,
      threadId,
      desktopKnown,
    };
  }

  try {
    await forceRelaunchCodexApp({
      bundleId,
      appPath,
      executor,
      isAppRunning,
      sleepFn,
      relaunchWaitMs,
      appBootWaitMs,
    });
    await openWhenThreadReady(threadId, targetUrl, {
      bundleId,
      appPath,
      executor,
      env,
      fsModule,
      sleepFn,
      waitMs: threadMaterializeWaitMs,
      pollMs: threadMaterializePollMs,
    });
  } catch (error) {
    throw desktopError(
      "handoff_failed",
      "Could not force close and reopen Codex.app on this Mac.",
      error
    );
  }

  return {
    success: true,
    relaunched: true,
    targetUrl,
    threadId,
    desktopKnown,
  };
}

function resolveThreadId(params) {
  if (!params || typeof params !== "object") {
    return "";
  }

  const candidates = [
    params.threadId,
    params.thread_id,
  ];

  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) {
      return candidate.trim();
    }
  }

  return "";
}

function desktopError(errorCode, userMessage, cause = null) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  if (cause) {
    error.cause = cause;
  }
  return error;
}

function isThreadLikelyKnownOnDesktop(threadId, { env, fsModule }) {
  const sessionsRoot = resolveSessionsRootForEnv(env);
  // Any rollout means the thread already materialized locally, even if it originated on iPhone.
  return findRolloutFileForThread(sessionsRoot, threadId, { fsModule }) != null;
}

function resolveSessionsRootForEnv(env) {
  if (env?.CODEX_HOME) {
    return path.join(env.CODEX_HOME, "sessions");
  }

  return resolveSessionsRoot();
}

async function detectRunningCodexApp(appPath, executor) {
  const appName = path.basename(appPath, ".app");

  try {
    await executor("pgrep", ["-x", appName], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
    return true;
  } catch {
    return false;
  }
}

async function openCodexTarget(targetUrl, { bundleId, appPath, executor }) {
  try {
    await executor("open", ["-b", bundleId, targetUrl], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  } catch {
    await executor("open", ["-a", appPath, targetUrl], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  }
}

async function openCodexApp({ bundleId, appPath, executor }) {
  try {
    await executor("open", ["-b", bundleId], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  } catch {
    await executor("open", ["-a", appPath], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  }
}

// Gives the desktop a short window to materialize the requested thread before the final deep link.
async function openWhenThreadReady(
  threadId,
  targetUrl,
  { bundleId, appPath, executor, env, fsModule, sleepFn, waitMs, pollMs }
) {
  await waitForThreadMaterialization(threadId, {
    env,
    fsModule,
    sleepFn,
    timeoutMs: waitMs,
    pollMs,
  });
  await openCodexTarget(targetUrl, { bundleId, appPath, executor });
}

async function forceRelaunchCodexApp({
  bundleId,
  appPath,
  executor,
  isAppRunning,
  sleepFn,
  relaunchWaitMs,
  appBootWaitMs,
}) {
  const appName = path.basename(appPath, ".app");

  try {
    await executor("pkill", ["-x", appName], {
      timeout: HANDOFF_TIMEOUT_MS,
    });
  } catch (error) {
    if (error?.code !== 1) {
      throw error;
    }
  }

  await waitForAppExit(appPath, executor, isAppRunning);
  await sleepFn(relaunchWaitMs);
  await openCodexApp({ bundleId, appPath, executor });
  await sleepFn(appBootWaitMs);
}

async function waitForAppExit(appPath, executor, isAppRunning) {
  const deadline = Date.now() + HANDOFF_TIMEOUT_MS;

  while (Date.now() < deadline) {
    const isRunning = typeof isAppRunning === "function"
      ? await isAppRunning(appPath)
      : await detectRunningCodexApp(appPath, executor);
    if (!isRunning) {
      return;
    }

    await sleep(100);
  }

  throw desktopError("handoff_timeout", "Timed out waiting for Codex.app to close.");
}

function hasDesktopRolloutForThread(threadId, { env, fsModule }) {
  const sessionsRoot = resolveSessionsRootForEnv(env);
  return findRolloutFileForThread(sessionsRoot, threadId, { fsModule }) != null;
}

async function waitForThreadMaterialization(
  threadId,
  { env, fsModule, sleepFn, timeoutMs, pollMs }
) {
  if (hasDesktopRolloutForThread(threadId, { env, fsModule })) {
    return true;
  }

  const deadline = Date.now() + Math.max(0, timeoutMs);
  while (Date.now() < deadline) {
    await sleepFn(pollMs);
    if (hasDesktopRolloutForThread(threadId, { env, fsModule })) {
      return true;
    }
  }

  return false;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = {
  handleDesktopRequest,
};
