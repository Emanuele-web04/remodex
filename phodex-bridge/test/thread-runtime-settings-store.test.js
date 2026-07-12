const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  createThreadRuntimeSettingsStore,
} = require("../src/thread-runtime-settings-store");

test("persists accepted per-thread runtime settings and explicit normal speed", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-runtime-settings-"));
  const storeFile = path.join(directory, "settings.json");
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const firstStore = createThreadRuntimeSettingsStore({ storeFile, now: () => 100 });
  const fast = firstStore.commit("thread-1", {
    model: "gpt-5.5",
    effort: "high",
    serviceTier: "fast",
  }, { source: "phone", turnId: "turn-1" });
  assert.equal(fast.revision, 1);
  assert.equal(fast.serviceTier, "fast");

  const normal = firstStore.commit("thread-1", {
    model: "gpt-5.5",
    effort: "medium",
  }, { source: "phone", turnId: "turn-2" });
  assert.equal(normal.revision, 2);
  assert.equal(normal.serviceTier, null);

  const restoredStore = createThreadRuntimeSettingsStore({ storeFile, now: () => 200 });
  assert.deepEqual(restoredStore.get("thread-1"), normal);
  const conversation = { latestCollaborationMode: { mode: "default", settings: {} } };
  restoredStore.attachToConversation("thread-1", conversation);
  assert.deepEqual(conversation.latestThreadSettings, {
    model: "gpt-5.5",
    effort: "medium",
    serviceTier: null,
  });
});

test("enriches thread list and read responses without exposing a separate side channel", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-runtime-enrich-"));
  const storeFile = path.join(directory, "settings.json");
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const store = createThreadRuntimeSettingsStore({ storeFile, now: () => 123 });
  store.commit("thread-2", {
    model: "gpt-5.6",
    effort: "xhigh",
    serviceTier: "fast",
  }, { source: "phone", turnId: "turn-9" });

  const envelope = { result: { data: [{ id: "thread-2", title: "Hello" }] } };
  store.enrichResponse("thread/list", envelope);
  assert.deepEqual(envelope.result.data[0], {
    id: "thread-2",
    title: "Hello",
    model: "gpt-5.6",
    reasoningEffort: "xhigh",
    serviceTier: "fast",
    runtimeSettingsRevision: 1,
    runtimeSettingsUpdatedAt: 123,
    runtimeSettingsSource: "phone",
  });
});

test("ignores Desktop-origin runtime settings and legacy persisted records", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-runtime-phone-authority-"));
  const storeFile = path.join(directory, "settings.json");
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  fs.writeFileSync(storeFile, JSON.stringify({
    version: 1,
    threads: {
      "thread-legacy-desktop": {
        model: "gpt-desktop",
        reasoningEffort: "high",
        serviceTier: "fast",
        revision: 7,
        updatedAt: 100,
        source: "desktop",
        turnId: "turn-desktop",
      },
    },
  }));

  const store = createThreadRuntimeSettingsStore({ storeFile, now: () => 200 });
  assert.equal(store.get("thread-legacy-desktop"), null);
  assert.equal(store.commit("thread-new-desktop", {
    model: "gpt-desktop",
    effort: "high",
    serviceTier: "fast",
  }, { source: "desktop", turnId: "turn-new-desktop" }), null);
  assert.equal(store.get("thread-new-desktop"), null);
});
