// FILE: codex-home.js
// Purpose: Resolves local Codex cache paths shared by bridge services.
// Layer: CLI helper
// Exports: resolveCodexHome, resolveCodexGeneratedImagesRoot
// Depends on: os, path

const os = require("os");
const path = require("path");

function resolveCodexHome() {
  return process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
}

function resolveCodexGeneratedImagesRoot() {
  return path.join(resolveCodexHome(), "generated_images");
}

module.exports = {
  resolveCodexGeneratedImagesRoot,
  resolveCodexHome,
};
