// FILE: bridge-cascade-order.test.js
// Purpose: Regression gate for load-bearing handler cascade order in bridge.js composition root.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, path

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");

const BRIDGE_SOURCE_PATH = path.join(__dirname, "../src/bridge.js");

// Must match docs/contracts/bridge-rpc.md § Handler Cascade Order and bridge.js:578–664.
const EXPECTED_CASCADE_MARKERS = [
  "handleBridgeManagedHandshakeMessage",
  "handleBridgeManagedAccountRequest",
  "voiceHandler.handleVoiceRequest",
  "handleThreadContextRequest",
  "runtimeProviderRouter.handleAuxiliaryRequest",
  "handleWorkspaceRequest",
  "handleProjectRequest",
  "handlePetRequest",
  "notificationsHandler.handleNotificationsRequest",
  "handleDesktopRequest",
  "handleGitRequest",
  "runtimeProviderRouter.handleApplicationMessage",
  "desktopRefresher.handleInbound",
  "rolloutLiveMirror?.observeInbound",
  "desktopIpcActionFollower?.observeInbound",
  "handleBridgeManagedThreadTurnsListRequest",
  "codex.send",
];

function readHandleApplicationMessageBlock(source) {
  const fnStart = source.indexOf("function handleApplicationMessage(rawMessage)");
  assert.notEqual(fnStart, -1, "handleApplicationMessage must exist in bridge.js");

  const fnEnd = source.indexOf("function sendApplicationResponse(rawMessage)", fnStart);
  assert.notEqual(fnEnd, -1, "sendApplicationResponse must follow handleApplicationMessage");
  return source.slice(fnStart, fnEnd);
}

function markerPositions(block, markers) {
  return markers.map((marker) => {
    const index = block.indexOf(marker);
    assert.notEqual(index, -1, `cascade marker missing from bridge.js: ${marker}`);
    return { marker, index };
  });
}

test("bridge.js handleApplicationMessage preserves documented handler cascade order", () => {
  const source = fs.readFileSync(BRIDGE_SOURCE_PATH, "utf8");
  const block = readHandleApplicationMessageBlock(source);
  const positions = markerPositions(block, EXPECTED_CASCADE_MARKERS);

  for (let i = 1; i < positions.length; i += 1) {
    const prev = positions[i - 1];
    const current = positions[i];
    assert.ok(
      current.index > prev.index,
      `${current.marker} must appear after ${prev.marker} in handleApplicationMessage`,
    );
  }
});

test("runtime provider router stays before desktop refresher observers", () => {
  const source = fs.readFileSync(BRIDGE_SOURCE_PATH, "utf8");
  const block = readHandleApplicationMessageBlock(source);

  const routerIndex = block.indexOf("runtimeProviderRouter.handleApplicationMessage");
  const refresherIndex = block.indexOf("desktopRefresher.handleInbound");
  assert.notEqual(routerIndex, -1);
  assert.notEqual(refresherIndex, -1);
  assert.ok(
    routerIndex < refresherIndex,
    "runtime provider router must run before desktop refresher observers",
  );
});

test("desktop and git handlers stay before runtime provider router", () => {
  const source = fs.readFileSync(BRIDGE_SOURCE_PATH, "utf8");
  const block = readHandleApplicationMessageBlock(source);

  const desktopIndex = block.indexOf("handleDesktopRequest");
  const gitIndex = block.indexOf("handleGitRequest");
  const routerIndex = block.indexOf("runtimeProviderRouter.handleApplicationMessage");

  assert.ok(desktopIndex < routerIndex, "desktop handler must precede runtime router");
  assert.ok(gitIndex < routerIndex, "git handler must precede runtime router");
  assert.ok(desktopIndex < gitIndex, "desktop handler must precede git handler");
});