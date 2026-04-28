// FILE: workspace-image.test.js
// Purpose: Verifies bridge-side local image preview reads stay scoped and size-safe.
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

test("workspace/readImage returns base64 image data for a file inside cwd", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
  fs.writeFileSync(imagePath, bytes);

  const result = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
  });

  assert.equal(result.path, fs.realpathSync(imagePath));
  assert.equal(result.fileName, "preview.png");
  assert.equal(result.mimeType, "image/png");
  assert.equal(result.byteLength, bytes.length);
  assert.equal(typeof result.mtimeMs, "number");
  assert.equal(result.dataBase64, bytes.toString("base64"));
});

test("workspace/readImage can return metadata without image bytes", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
  fs.writeFileSync(imagePath, bytes);

  const result = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    includeData: false,
  });

  assert.equal(result.path, fs.realpathSync(imagePath));
  assert.equal(result.byteLength, bytes.length);
  assert.equal(typeof result.mtimeMs, "number");
  assert.equal(result.dataBase64, undefined);
});

test("workspace/readImage skips bytes when cached metadata still matches", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
  fs.writeFileSync(imagePath, bytes);

  const first = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
  });
  const second = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    ifByteLength: first.byteLength,
    ifMtimeMs: first.mtimeMs,
  });

  assert.equal(second.notModified, true);
  assert.equal(second.byteLength, bytes.length);
  assert.equal(second.dataBase64, undefined);
});

test("workspace/readImage does not round cached mtime checks", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
  fs.writeFileSync(imagePath, bytes);

  const first = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
  });
  const second = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    ifByteLength: first.byteLength,
    ifMtimeMs: first.mtimeMs + 0.4,
  });

  assert.equal(second.notModified, undefined);
  assert.equal(second.dataBase64, bytes.toString("base64"));
});

test("workspace/readImage rejects non-image paths", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const textPath = path.join(tempDir, "notes.txt");
  fs.writeFileSync(textPath, "not an image");

  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readImage", {
      cwd: tempDir,
      path: textPath,
    }),
    /Only local image files/
  );
});

test("workspace/readImage rejects workspace images when cwd is missing", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  const imagePath = path.join(tempDir, "preview.png");
  fs.writeFileSync(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readImage", {
      path: imagePath,
    }),
    /Only images in this workspace/
  );
});

test("workspace/readImage rejects cwd widening outside a repository", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  const imagePath = path.join(tempDir, "preview.png");
  fs.writeFileSync(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readImage", {
      cwd: "/",
      path: imagePath,
    }),
    /Only images in this workspace/
  );
});
