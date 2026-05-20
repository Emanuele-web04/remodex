// FILE: workspace-file.test.js
// Purpose: Verifies bridge-side read-only text file previews stay scoped and size-safe.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/workspace-handler

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { handleWorkspaceMethod } = require("../src/workspace-handler");

function makeGitWorkspace() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-file-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  return tempDir;
}

test("workspace/readFile returns UTF-8 text for a file inside cwd", async () => {
  const tempDir = makeGitWorkspace();
  const filePath = path.join(tempDir, "src", "App.swift");
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, "let value = 1\nprint(value)\n", "utf8");

  const result = await handleWorkspaceMethod("workspace/readFile", {
    cwd: tempDir,
    path: "src/App.swift",
  });

  assert.equal(result.path, fs.realpathSync(filePath));
  assert.equal(result.fileName, "App.swift");
  assert.equal(result.content, "let value = 1\nprint(value)\n");
  assert.equal(result.lineCount, 2);
  assert.equal(result.encoding, "utf-8");
  assert.equal(typeof result.mtimeMs, "number");
});

test("workspace/readFile can return metadata without file content", async () => {
  const tempDir = makeGitWorkspace();
  const filePath = path.join(tempDir, "README.md");
  fs.writeFileSync(filePath, "# Demo\n", "utf8");

  const result = await handleWorkspaceMethod("workspace/readFile", {
    cwd: tempDir,
    path: filePath,
    includeContent: false,
  });

  assert.equal(result.path, fs.realpathSync(filePath));
  assert.equal(result.content, undefined);
});

test("workspace/readFile resolves a unique bare filename inside the workspace", async () => {
  const tempDir = makeGitWorkspace();
  const filePath = path.join(tempDir, "phodex-bridge", "test", "bridge-desktop-ipc-integration.test.js");
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, "test('demo', () => {})\n", "utf8");

  const result = await handleWorkspaceMethod("workspace/readFile", {
    cwd: tempDir,
    path: "bridge-desktop-ipc-integration.test.js",
  });

  assert.equal(result.path, fs.realpathSync(filePath));
  assert.equal(result.content, "test('demo', () => {})\n");
});

test("workspace/readFile rejects ambiguous bare filename matches", async () => {
  const tempDir = makeGitWorkspace();
  const firstPath = path.join(tempDir, "Sources", "App.swift");
  const secondPath = path.join(tempDir, "Tests", "App.swift");
  fs.mkdirSync(path.dirname(firstPath), { recursive: true });
  fs.mkdirSync(path.dirname(secondPath), { recursive: true });
  fs.writeFileSync(firstPath, "let first = true\n", "utf8");
  fs.writeFileSync(secondPath, "let second = true\n", "utf8");

  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: tempDir,
      path: "App.swift",
    }),
    /Multiple files named "App.swift"/
  );
});

test("workspace/readFile skips content when cached metadata still matches", async () => {
  const tempDir = makeGitWorkspace();
  const filePath = path.join(tempDir, "README.md");
  fs.writeFileSync(filePath, "# Demo\n", "utf8");

  const first = await handleWorkspaceMethod("workspace/readFile", {
    cwd: tempDir,
    path: filePath,
  });
  const second = await handleWorkspaceMethod("workspace/readFile", {
    cwd: tempDir,
    path: filePath,
    ifByteLength: first.byteLength,
    ifMtimeMs: first.mtimeMs,
  });

  assert.equal(second.notModified, true);
  assert.equal(second.content, undefined);
});

test("workspace/readFile rejects files outside the selected workspace", async () => {
  const tempDir = makeGitWorkspace();
  const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-file-outside-"));
  const outsidePath = path.join(outsideDir, "secret.txt");
  fs.writeFileSync(outsidePath, "nope", "utf8");

  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: tempDir,
      path: outsidePath,
    }),
    /Only files in the current workspace/
  );
});

test("workspace/readFile rejects binary files", async () => {
  const tempDir = makeGitWorkspace();
  const filePath = path.join(tempDir, "data.bin");
  fs.writeFileSync(filePath, Buffer.from([0x00, 0x01, 0x02, 0x03]));

  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readFile", {
      cwd: tempDir,
      path: filePath,
    }),
    /looks binary/
  );
});
