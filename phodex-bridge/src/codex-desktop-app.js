const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_CODEX_BUNDLE_ID = "com.openai.codex";
const LEGACY_CODEX_APP_PATH = "/Applications/Codex.app";

function resolveCodexAppPath({
  appPath,
  platform = process.platform,
  homeDir = os.homedir(),
  fsImpl = fs,
} = {}) {
  if (typeof appPath === "string" && appPath.trim()) return appPath.trim();
  if (platform !== "darwin") return LEGACY_CODEX_APP_PATH;

  const folders = ["/Applications", path.join(homeDir, "Applications")];
  for (const appName of ["ChatGPT.app", "Codex.app"]) {
    for (const folder of folders) {
      const candidate = path.join(folder, appName);
      if (resolveBundledCodexCommand(candidate, { fsImpl })) return candidate;
    }
  }
  return LEGACY_CODEX_APP_PATH;
}

function resolveBundledCodexCommand(appPath, { fsImpl = fs, pathImpl = path } = {}) {
  if (typeof appPath !== "string" || !appPath.trim()) return "";

  const resources = pathImpl.join(appPath.trim(), "Contents", "Resources");
  const candidates = [
    pathImpl.join(resources, "codex-cli", "bin", "codex"),
    pathImpl.join(resources, "codex"),
  ];
  for (const candidate of candidates) {
    try {
      if (fsImpl.statSync(candidate).isFile()) return candidate;
    } catch {
      // The desktop app may use the other bundle layout.
    }
  }
  return "";
}

module.exports = {
  DEFAULT_CODEX_BUNDLE_ID,
  resolveCodexAppPath,
  resolveBundledCodexCommand,
};
