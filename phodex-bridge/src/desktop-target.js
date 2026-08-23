// FILE: desktop-target.js
// Purpose: Defines and validates the one-per-bridge Codex Desktop target.
// Layer: CLI helper
// Exports: target defaults, normalization, deep-link construction, fingerprinting, and macOS bundle validation.
// Depends on: crypto, child_process, fs, os, path

const { execFileSync } = require("child_process");
const { createHash } = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_CODEX_BUNDLE_ID = "com.openai.codex";
const DEFAULT_CODEX_URL_SCHEME = "codex";
const LEGACY_CODEX_APP_PATH = "/Applications/Codex.app";
const CURRENT_CODEX_APP_PATH = "/Applications/ChatGPT.app";
const BUNDLE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9.-]*$/;
const URL_SCHEME_PATTERN = /^[A-Za-z][A-Za-z0-9+.-]*$/;

function defaultCodexHome({ osImpl = os } = {}) {
  return path.join(osImpl.homedir(), ".codex");
}

function defaultCodexAppPath({ fsImpl = fs } = {}) {
  if (fsImpl.existsSync(CURRENT_CODEX_APP_PATH)) {
    return CURRENT_CODEX_APP_PATH;
  }
  return LEGACY_CODEX_APP_PATH;
}

function normalizeDesktopTarget(target = {}, {
  fsImpl = fs,
  osImpl = os,
  strictIpc = false,
} = {}) {
  const codexHome = path.resolve(readString(target.codexHome) || defaultCodexHome({ osImpl }));
  const bundleId = readString(target.codexBundleId) || DEFAULT_CODEX_BUNDLE_ID;
  const appPath = path.resolve(readString(target.codexAppPath) || defaultCodexAppPath({ fsImpl }));
  const urlScheme = readString(target.codexUrlScheme) || DEFAULT_CODEX_URL_SCHEME;
  const configuredSocket = readString(target.desktopIpcSocketPath);
  const desktopIpcSocketPath = strictIpc
    ? path.join(codexHome, "ipc", "ipc.sock")
    : configuredSocket;

  return {
    codexHome,
    codexBundleId: bundleId,
    codexAppPath: appPath,
    codexUrlScheme: urlScheme,
    desktopIpcSocketPath,
  };
}

function validateDesktopTarget(target, {
  execFileSyncImpl = execFileSync,
  fsImpl = fs,
  platform = process.platform,
  processImpl = process,
  strictIpc = true,
} = {}) {
  validateConfiguredAbsolutePath(target?.codexHome, "Codex home");
  validateConfiguredAbsolutePath(target?.codexAppPath, "Codex app");
  const normalized = normalizeDesktopTarget(target, { fsImpl, strictIpc });
  validateIdentifier(normalized.codexBundleId, BUNDLE_ID_PATTERN, "bundle identifier");
  validateIdentifier(normalized.codexUrlScheme, URL_SCHEME_PATTERN, "URL scheme");
  validateAbsoluteDirectory(normalized.codexHome, "Codex home", { fsImpl, processImpl });
  validateAbsoluteDirectory(normalized.codexAppPath, "Codex app", {
    fsImpl,
    processImpl,
    requireOwnership: false,
    requireWritable: false,
  });

  if (platform === "darwin") {
    validateMacOSBundleMetadata(normalized, { execFileSyncImpl });
  }

  return {
    ...normalized,
    codexTargetFingerprint: desktopTargetFingerprint(normalized),
  };
}

function validateConfiguredAbsolutePath(value, label) {
  const configured = readString(value);
  if (configured && !path.isAbsolute(configured)) {
    throw new Error(`${label} must be an absolute path.`);
  }
}

function validateMacOSBundleMetadata(target, { execFileSyncImpl = execFileSync } = {}) {
  const infoPath = path.join(target.codexAppPath, "Contents", "Info.plist");
  let bundleId;
  let plistJSON;
  try {
    bundleId = execFileSyncImpl("/usr/bin/plutil", ["-extract", "CFBundleIdentifier", "raw", infoPath], {
      encoding: "utf8",
    }).trim();
    plistJSON = execFileSyncImpl("/usr/bin/plutil", ["-convert", "json", "-o", "-", infoPath], {
      encoding: "utf8",
    });
  } catch (error) {
    throw new Error(`Could not read the configured Codex app metadata: ${error.message}`);
  }

  if (bundleId !== target.codexBundleId) {
    throw new Error(
      `The configured app bundle is ${bundleId || "unknown"}, not ${target.codexBundleId}.`
    );
  }

  const plist = JSON.parse(plistJSON);
  const schemes = (Array.isArray(plist.CFBundleURLTypes) ? plist.CFBundleURLTypes : [])
    .flatMap((entry) => Array.isArray(entry?.CFBundleURLSchemes) ? entry.CFBundleURLSchemes : [])
    .filter((value) => typeof value === "string");
  if (!schemes.includes(target.codexUrlScheme)) {
    throw new Error(
      `The configured app does not register the ${target.codexUrlScheme} URL scheme.`
    );
  }
}

function validateAbsoluteDirectory(value, label, {
  fsImpl = fs,
  processImpl = process,
  requireOwnership = true,
  requireWritable = true,
} = {}) {
  if (!path.isAbsolute(value)) {
    throw new Error(`${label} must be an absolute path.`);
  }
  let stats;
  try {
    stats = fsImpl.statSync(value);
  } catch {
    throw new Error(`${label} does not exist: ${value}`);
  }
  if (!stats.isDirectory()) {
    throw new Error(`${label} is not a directory: ${value}`);
  }
  if (requireOwnership && typeof processImpl.getuid === "function" && typeof stats.uid === "number"
    && stats.uid !== processImpl.getuid()) {
    throw new Error(`${label} is not owned by the current user: ${value}`);
  }
  if (requireWritable) {
    try {
      fsImpl.accessSync(value, fs.constants.R_OK | fs.constants.W_OK | fs.constants.X_OK);
    } catch {
      throw new Error(`${label} is not readable and writable by the current user: ${value}`);
    }
  }
}

function validateIdentifier(value, pattern, label) {
  if (!pattern.test(value)) {
    throw new Error(`The ${label} is invalid: ${value}`);
  }
}

function buildCodexDeepLink(route, urlScheme = DEFAULT_CODEX_URL_SCHEME) {
  const scheme = readString(urlScheme) || DEFAULT_CODEX_URL_SCHEME;
  validateIdentifier(scheme, URL_SCHEME_PATTERN, "URL scheme");
  const normalizedRoute = readString(route).replace(/^\/+/, "");
  if (!normalizedRoute) {
    throw new Error("A desktop deep-link route is required.");
  }
  return `${scheme}://${normalizedRoute}`;
}

function desktopTargetFingerprint(target = {}) {
  const values = [
    readString(target.codexHome),
    readString(target.codexBundleId),
    readString(target.codexAppPath),
    readString(target.codexUrlScheme),
    readString(target.desktopIpcSocketPath),
  ];
  return createHash("sha256").update(values.join("\0")).digest("hex").slice(0, 16);
}

function activateCodexHome(target, { env = process.env } = {}) {
  const codexHome = readString(target?.codexHome);
  if (codexHome) {
    env.CODEX_HOME = codexHome;
  }
  return env;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  CURRENT_CODEX_APP_PATH,
  DEFAULT_CODEX_BUNDLE_ID,
  DEFAULT_CODEX_URL_SCHEME,
  LEGACY_CODEX_APP_PATH,
  activateCodexHome,
  buildCodexDeepLink,
  defaultCodexAppPath,
  defaultCodexHome,
  desktopTargetFingerprint,
  normalizeDesktopTarget,
  validateDesktopTarget,
};
