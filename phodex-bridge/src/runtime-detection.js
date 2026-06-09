// FILE: runtime-detection.js
// Purpose: Resolves which coding runtimes are available before bridge boot and pairing.
// Layer: Bridge policy
// Exports: resolveAvailableRuntimes, formatRuntimePreflightFailureMessage
// Depends on: child_process, fs, path, ./codex-transport, ./normalize, ./opencode-runtime-policy

const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const { createCodexLaunchPlans } = require("./codex-transport");
const { readString } = require("./normalize");
const { isOpenCodeRuntimeDisabled } = require("./opencode-runtime-policy");

const RUNTIME_MODES = new Set([
  "codex+opencode",
  "opencode-only",
  "codex-only",
  "none",
]);

function resolveAvailableRuntimes(env = process.env, options = {}) {
  const {
    platform = process.platform,
    appPath = "",
    codexEndpoint = "",
    execFileSyncImpl = execFileSync,
    fsImpl = fs,
    pathImpl = path,
  } = options;

  const opencodeCommand = readString(env.REMODEX_OPENCODE_COMMAND) || "opencode";
  const opencodeEnabled = !isOpenCodeRuntimeDisabled(env);
  const opencodeAvailable = opencodeEnabled
    && isExecutableOnPath(opencodeCommand, env, platform, execFileSyncImpl);

  const codexFromEndpoint = Boolean(readString(codexEndpoint));
  const codexFromPath = isExecutableOnPath("codex", env, platform, execFileSyncImpl);
  const codexFromBundle = hasBundledCodexLaunchPlan({
    env,
    appPath,
    platform,
    fsImpl,
    pathImpl,
  });
  const codexAvailable = codexFromEndpoint || codexFromPath || codexFromBundle;

  let mode = "none";
  if (codexAvailable && opencodeAvailable) {
    mode = "codex+opencode";
  } else if (opencodeAvailable) {
    mode = "opencode-only";
  } else if (codexAvailable) {
    mode = "codex-only";
  }

  return {
    mode,
    codexAvailable,
    opencodeAvailable,
    opencodeEnabled,
    opencodeCommand,
    codexFromEndpoint,
    codexFromPath,
    codexFromBundle,
  };
}

function formatRuntimePreflightFailureMessage(runtimes = {}) {
  const opencodeCommand = readString(runtimes.opencodeCommand) || "opencode";
  return [
    "Remodex needs at least one coding runtime on this Mac.",
    "Install OpenCode (`brew install opencode` or https://opencode.ai) or install the Codex CLI:",
    "  npm install -g @openai/codex@latest",
    `Checked commands: codex, ${opencodeCommand}.`,
  ].join("\n");
}

function hasBundledCodexLaunchPlan({
  env,
  appPath,
  platform,
  fsImpl = fs,
  pathImpl = path,
} = {}) {
  const launches = createCodexLaunchPlans({
    env,
    appPath,
    platform,
    fsImpl,
    pathImpl,
  });
  return launches.some((launch) => launch.command !== "codex" && launch.command !== "cmd.exe");
}

function isExecutableOnPath(executable, env, platform, execFileSyncImpl = execFileSync) {
  const normalized = readString(executable);
  if (!normalized) {
    return false;
  }

  if (path.isAbsolute(normalized) || normalized.includes(path.sep)) {
    return isLaunchableFile(normalized);
  }

  try {
    if (platform === "win32") {
      execFileSyncImpl("where", [normalized], {
        env,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
      return true;
    }

    execFileSyncImpl("which", [normalized], {
      env,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return true;
  } catch {
    return false;
  }
}

function isLaunchableFile(candidatePath) {
  try {
    return fs.statSync(candidatePath).isFile();
  } catch {
    return false;
  }
}

function opencodeCarriesBridge(runtimes = {}) {
  return runtimes.opencodeAvailable === true;
}

module.exports = {
  RUNTIME_MODES,
  formatRuntimePreflightFailureMessage,
  isExecutableOnPath,
  opencodeCarriesBridge,
  resolveAvailableRuntimes,
};