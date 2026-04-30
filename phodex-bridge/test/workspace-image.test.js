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

const validOnePixelPNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=",
  "base64"
);

function useProcessPlatform(t, platform) {
  const descriptor = Object.getOwnPropertyDescriptor(process, "platform");
  Object.defineProperty(process, "platform", {
    ...descriptor,
    value: platform,
  });
  t.after(() => {
    Object.defineProperty(process, "platform", descriptor);
  });
}

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

test("workspace/readImage accepts bounded preview reads", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  const bytes = validOnePixelPNG;
  fs.writeFileSync(imagePath, bytes);

  const result = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    maxPixelDimension: 1600,
  });

  assert.equal(result.path, fs.realpathSync(imagePath));
  assert.equal(result.byteLength, bytes.length);
  assert.equal(result.previewMaxPixelDimension, 1600);
  assert.equal(typeof result.dataBase64, "string");
  assert.ok(Buffer.from(result.dataBase64, "base64").length > 0);
});

test("workspace/readImage ignores client platform fields for non-mac preview decisions", async (t) => {
  useProcessPlatform(t, "win32");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  fs.writeFileSync(imagePath, validOnePixelPNG);

  const result = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    maxPixelDimension: 1600,
    previewPlatform: "darwin",
    hostPlatform: "darwin",
    platform: "darwin",
  });

  assert.equal(result.previewMaxPixelDimension, 1600);
  assert.equal(Buffer.from(result.dataBase64, "base64").length, validOnePixelPNG.length);
});

test("workspace/readImage retries smaller previews when the first preview is still too large", async (t) => {
  useProcessPlatform(t, "darwin");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  const fakeBinDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-fake-sips-"));
  const fakeSipsLog = path.join(tempDir, "sips.log");
  const previousPath = process.env.PATH;
  process.env.PATH = `${fakeBinDir}${path.delimiter}${previousPath || ""}`;
  t.after(() => {
    if (previousPath == null) {
      delete process.env.PATH;
    } else {
      process.env.PATH = previousPath;
    }
    fs.rmSync(tempDir, { recursive: true, force: true });
    fs.rmSync(fakeBinDir, { recursive: true, force: true });
  });

  const fakeSipsPath = path.join(fakeBinDir, "sips");
  fs.writeFileSync(
    fakeSipsPath,
    `#!/usr/bin/env node
const fs = require("fs");
const validOnePixelPNG = Buffer.from("${validOnePixelPNG.toString("base64")}", "base64");
const dimension = Number(process.argv[process.argv.indexOf("-Z") + 1]);
const outputPath = process.argv[process.argv.indexOf("--out") + 1];
fs.appendFileSync(${JSON.stringify(fakeSipsLog)}, String(dimension) + "\\n");
fs.writeFileSync(outputPath, dimension > 512 ? Buffer.alloc(2 * 1024 * 1024 + 1) : validOnePixelPNG);
`
  );
  fs.chmodSync(fakeSipsPath, 0o755);

  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  fs.writeFileSync(imagePath, validOnePixelPNG);

  const result = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    maxPixelDimension: 1600,
  });

  const attemptedDimensions = fs.readFileSync(fakeSipsLog, "utf8").trim().split("\n").map(Number);
  assert.deepEqual(attemptedDimensions, [1600, 1200, 1024, 900, 768, 675, 512]);
  assert.equal(Buffer.from(result.dataBase64, "base64").length, validOnePixelPNG.length);
  assert.equal(result.previewMaxPixelDimension, 1600);
});

test("workspace/readImage stops preview retries when sips times out", async (t) => {
  useProcessPlatform(t, "darwin");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  const fakeBinDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-fake-sips-timeout-"));
  const fakeSipsLog = path.join(tempDir, "sips-timeout.log");
  const previousPath = process.env.PATH;
  process.env.PATH = `${fakeBinDir}${path.delimiter}${previousPath || ""}`;
  t.after(() => {
    if (previousPath == null) {
      delete process.env.PATH;
    } else {
      process.env.PATH = previousPath;
    }
    fs.rmSync(tempDir, { recursive: true, force: true });
    fs.rmSync(fakeBinDir, { recursive: true, force: true });
  });

  const fakeSipsPath = path.join(fakeBinDir, "sips");
  fs.writeFileSync(
    fakeSipsPath,
    `#!/usr/bin/env node
const fs = require("fs");
const dimension = Number(process.argv[process.argv.indexOf("-Z") + 1]);
fs.appendFileSync(${JSON.stringify(fakeSipsLog)}, String(dimension) + "\\n");
setTimeout(() => {}, 30_000);
`
  );
  fs.chmodSync(fakeSipsPath, 0o755);

  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  fs.writeFileSync(imagePath, validOnePixelPNG);

  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readImage", {
      cwd: tempDir,
      path: imagePath,
      maxPixelDimension: 1600,
    }),
    /took too long/
  );

  const attemptedDimensions = fs.readFileSync(fakeSipsLog, "utf8").trim().split("\n").map(Number);
  assert.deepEqual(attemptedDimensions, [1600]);
});

test("workspace/readImage revalidates cached preview dimensions", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "preview.png");
  fs.writeFileSync(imagePath, validOnePixelPNG);

  const first = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    maxPixelDimension: 1600,
  });
  const samePreview = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    maxPixelDimension: 1600,
    ifByteLength: first.byteLength,
    ifMtimeMs: first.mtimeMs,
    ifPreviewMaxPixelDimension: first.previewMaxPixelDimension,
  });
  const differentPreview = await handleWorkspaceMethod("workspace/readImage", {
    cwd: tempDir,
    path: imagePath,
    maxPixelDimension: 1200,
    ifByteLength: first.byteLength,
    ifMtimeMs: first.mtimeMs,
    ifPreviewMaxPixelDimension: first.previewMaxPixelDimension,
  });

  assert.equal(samePreview.notModified, true);
  assert.equal(differentPreview.notModified, undefined);
  assert.equal(differentPreview.previewMaxPixelDimension, 1200);
  assert.equal(typeof differentPreview.dataBase64, "string");
});

test("workspace/readImage does not fall back to original bytes when preview conversion fails", async (t) => {
  useProcessPlatform(t, "darwin");
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  execFileSync("git", ["init"], { cwd: tempDir, stdio: "ignore" });
  const imagePath = path.join(tempDir, "corrupt.png");
  fs.writeFileSync(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readImage", {
      cwd: tempDir,
      path: imagePath,
      maxPixelDimension: 1600,
    }),
    /lightweight phone preview/
  );
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
  const tempDir = fs.mkdtempSync(path.join(os.homedir(), "remodex-image-"));
  const imagePath = path.join(tempDir, "preview.png");
  fs.writeFileSync(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

  try {
  await assert.rejects(
    () => handleWorkspaceMethod("workspace/readImage", {
      path: imagePath,
    }),
    /Only images in this workspace/
  );
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("workspace/readImage allows generated images under CODEX_HOME", async (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const imageDir = path.join(codexHome, "generated_images", "thread-1");
  fs.mkdirSync(imageDir, { recursive: true });
  const imagePath = path.join(imageDir, "ig_123.png");
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
  fs.writeFileSync(imagePath, bytes);

  const result = await handleWorkspaceMethod("workspace/readImage", {
    path: imagePath,
  });

  assert.equal(result.path, fs.realpathSync(imagePath));
  assert.equal(result.dataBase64, bytes.toString("base64"));
});

test("workspace/readImage allows temporary screenshot images", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-image-"));
  const imagePath = path.join(tempDir, "emanuele-mobile.png");
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
  fs.writeFileSync(imagePath, bytes);

  const result = await handleWorkspaceMethod("workspace/readImage", {
    path: imagePath,
  });

  assert.equal(result.path, fs.realpathSync(imagePath));
  assert.equal(result.dataBase64, bytes.toString("base64"));
});

test("workspace/readImage allows macOS shared /tmp screenshot images", { skip: process.platform !== "darwin" }, async () => {
  const tempDir = fs.mkdtempSync(path.join("/tmp", "remodex-image-"));
  const imagePath = path.join(tempDir, "emanuele-mobile.png");
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
  fs.writeFileSync(imagePath, bytes);

  try {
    const result = await handleWorkspaceMethod("workspace/readImage", {
      path: imagePath,
    });

    assert.equal(result.path, fs.realpathSync(imagePath));
    assert.equal(result.dataBase64, bytes.toString("base64"));
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("workspace/readImage rejects cwd widening outside a repository", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.homedir(), "remodex-image-"));
  const imagePath = path.join(tempDir, "preview.png");
  fs.writeFileSync(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

  try {
    await assert.rejects(
      () => handleWorkspaceMethod("workspace/readImage", {
        cwd: "/",
        path: imagePath,
      }),
      /Only images in this workspace/
    );
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
