#!/usr/bin/env node
// FILE: bootstrap-codex-cli.js
// Purpose: Runs during global Remodex installs to transparently bootstrap the global Codex CLI.
// Layer: CLI helper
// Exports: none
// Depends on: ./codex-cli-bootstrap

const {
  ensureCodexCLI,
  shouldSkipCodexBootstrap,
} = require("./codex-cli-bootstrap");
const { version: bridgePackageVersion = "" } = require("../package.json");
const { readBridgeDeviceState } = require("./secure-device-state");
const { buildCachedIOSAppCompatibilityWarning } = require("./ios-app-compatibility");

const installLocation = String(process.env.npm_config_location || "").trim().toLowerCase();
const isGlobalInstall = process.env.npm_config_global === "true" || installLocation === "global";

if (shouldSkipCodexBootstrap(process.env)) {
  ensureCodexCLI({
    env: process.env,
    logger: console,
    shouldUpdate: true,
  });
  process.exit(0);
}

if (!isGlobalInstall) {
  process.exit(0);
}

ensureCodexCLI({
  env: process.env,
  logger: console,
  shouldUpdate: true,
});

logCachedIOSAppCompatibilityWarning();

function logCachedIOSAppCompatibilityWarning() {
  try {
    const deviceState = readBridgeDeviceState();
    const warning = buildCachedIOSAppCompatibilityWarning({
      bridgeVersion: bridgePackageVersion,
      iosAppVersion: deviceState?.lastSeenPhoneAppVersion,
    });
    if (warning) {
      console.warn(warning);
    }
  } catch {
    // Keep postinstall non-blocking even if the cached pairing state is unavailable.
  }
}
