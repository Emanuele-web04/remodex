// FILE: opencode-attachments.test.js
// Purpose: Verifies attachment-store threat model and image prompt part wiring.
// Layer: Unit test

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { randomUUID } = require("crypto");
const {
  createAttachmentStore,
  isAttachmentsEnabled,
  MAX_IMAGE_BYTES,
  MAX_IMAGES_PER_TURN,
} = require("../src/attachment-store");
const { buildPromptFromTurnInput, imageItemToPromptPart } = require("../src/opencode-models");
const { createOpenCodeProvider } = require("../src/opencode-provider");

test("isAttachmentsEnabled respects REMODEX_OPENCODE_ATTACHMENTS", () => {
  assert.equal(isAttachmentsEnabled({ REMODEX_OPENCODE_ATTACHMENTS: "0" }), false);
  assert.equal(isAttachmentsEnabled({ REMODEX_OPENCODE_ATTACHMENTS: "1" }), true);
  assert.equal(isAttachmentsEnabled({}), true);
});

test("attachment store writes 0700 dir and UUID filenames", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const store = createAttachmentStore({ rootDir });
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
    "base64",
  );
  const stored = store.storeImageBuffer(png, { filename: "shot.png" });
  assert.match(path.basename(stored.path), /^[0-9a-f-]{36}\.png$/u);
  assert.equal(fs.existsSync(stored.path), true);
  const mode = fs.statSync(rootDir).mode & 0o777;
  assert.equal(mode, 0o700);
});

test("attachment store rejects oversize images", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const store = createAttachmentStore({ rootDir });
  const big = Buffer.alloc(MAX_IMAGE_BYTES + 1, 0xff);
  assert.throws(() => store.storeImageBuffer(big), /4194304|too large/i);
});

test("buildPromptFromTurnInput truncates images at MAX_IMAGES_PER_TURN", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const store = createAttachmentStore({ rootDir });
  const dataUrl = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
  const input = Array.from({ length: MAX_IMAGES_PER_TURN + 2 }, (_, index) => ({
    type: "image",
    dataURL: dataUrl,
    filename: `pixel-${index}.png`,
  }));

  const { parts } = buildPromptFromTurnInput(input, {
    attachmentStore: store,
    attachmentsEnabled: true,
  });
  const fileParts = parts.filter((part) => part.type === "file");
  assert.equal(fileParts.length, MAX_IMAGES_PER_TURN);
});

test("attachment store cleanupExpired removes old files", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const now = Date.now();
  const store = createAttachmentStore({
    rootDir,
    ttlMs: 60_000,
    now: () => now,
  });
  const stalePath = path.join(rootDir, `${randomUUID()}.png`);
  const freshPath = path.join(rootDir, `${randomUUID()}.png`);
  fs.writeFileSync(stalePath, "stale");
  fs.writeFileSync(freshPath, "fresh");
  const staleTime = new Date(now - 120_000);
  const freshTime = new Date(now - 30_000);
  fs.utimesSync(stalePath, staleTime, staleTime);
  fs.utimesSync(freshPath, freshTime, freshTime);

  const removed = store.cleanupExpired();
  assert.equal(removed, 1);
  assert.equal(fs.existsSync(stalePath), false);
  assert.equal(fs.existsSync(freshPath), true);
});

test("ensureStarted schedules throttled attachment cleanup", async () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const now = Date.now();
  const store = createAttachmentStore({
    rootDir,
    ttlMs: 60_000,
    now: () => now,
  });
  const stalePath = path.join(rootDir, `${randomUUID()}.png`);
  fs.writeFileSync(stalePath, "stale");
  const staleTime = new Date(now - 120_000);
  fs.utimesSync(stalePath, staleTime, staleTime);

  let running = false;
  const provider = createOpenCodeProvider({
    env: { REMODEX_ENABLE_OPENCODE: "1" },
    attachmentStore: store,
    serverFactory: () => ({
      get baseUrl() {
        return running ? "http://127.0.0.1:4291" : "";
      },
      get isRunning() {
        return running;
      },
      start() {
        running = true;
        return Promise.resolve();
      },
      stop() {
        running = false;
        return Promise.resolve();
      },
    }),
    clientFactory: async () => ({
      listModels: async () => [],
      listAgents: async () => [],
      createSession: async () => "ses_fake",
      getSession: async () => ({}),
      prompt: async () => {},
      abort: async () => {},
      getMessages: async () => [],
      replyToPermission: async () => ({ success: true }),
      subscribeToEvents: () => () => {},
    }),
  });

  provider.__test.setLastAttachmentCleanupAt(0);
  await provider.warmup();
  assert.equal(fs.existsSync(stalePath), false);
  await provider.shutdown();
});

test("imageItemToPromptPart rejects paths outside the attachment store", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const store = createAttachmentStore({ rootDir });
  const outsidePath = path.join(os.tmpdir(), "outside-store.png");
  fs.writeFileSync(outsidePath, "outside");

  const rejected = imageItemToPromptPart(
    { type: "image", path: outsidePath, filename: "outside-store.png" },
    { attachmentStore: store, attachmentsEnabled: true },
  );

  assert.equal(rejected, null);
});

test("imageItemToPromptPart accepts files stored in the attachment store", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const store = createAttachmentStore({ rootDir });
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
    "base64",
  );
  const stored = store.storeImageBuffer(png, { filename: "stored.png" });
  const part = imageItemToPromptPart(
    { type: "image", path: stored.path, filename: "stored.png" },
    { attachmentStore: store, attachmentsEnabled: true },
  );

  assert.equal(part.type, "file");
  assert.match(part.url, /^file:\/\//);
});

test("attachment store rejects declared MIME that mismatches magic bytes (SEC-05)", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const store = createAttachmentStore({ rootDir });
  const png = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
    "base64",
  );
  assert.throws(
    () => store.storeImageBuffer(png, { filename: "evil.gif", mime: "image/gif" }),
    /mime_mismatch|does not match/i,
  );
});

test("imageItemToPromptPart stores data URLs via attachment store", () => {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-attach-"));
  const store = createAttachmentStore({ rootDir });
  const dataUrl = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
  const part = imageItemToPromptPart(
    { type: "image", dataURL: dataUrl, filename: "pixel.png" },
    { attachmentStore: store, attachmentsEnabled: true },
  );
  assert.equal(part.type, "file");
  assert.match(part.url, /^file:\/\//);
  assert.equal(part.mime, "image/png");
});