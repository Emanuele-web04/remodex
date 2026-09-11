const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const { createThreadRuntimeSettingsStore } = require("../src/thread-runtime-settings-store");

function fixture(t, options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-runtime-settings-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const storeFile = path.join(directory, "settings.json");
  return { storeFile, store: createThreadRuntimeSettingsStore({ storeFile, now: () => 100, ...options }) };
}

test("persists owner-confirmed settings, inheritance and explicit Standard", (t) => {
  const events = [];
  const { storeFile, store } = fixture(t, { onChange: (...args) => events.push(args) });
  const fast = store.commit("task", { model: "gpt-6-astra", effort: "ultra", serviceTier: "fast" }, { source: "phone" });
  assert.equal(fast.serviceTier, "priority");
  const inherited = store.commit("task", { effort: "high" }, { source: "desktop" });
  assert.equal(inherited.serviceTier, "priority");
  const normal = store.commit("task", { serviceTier: null, effort: null }, { source: "runtime" });
  assert.equal(normal.serviceTier, null);
  assert.equal(normal.reasoningEffort, null);
  assert.equal(normal.revision, 3);
  assert.equal(normal.updatedAt, 102, "ordering remains monotonic within a clock tick");
  assert.deepEqual(createThreadRuntimeSettingsStore({ storeFile }).get("task"), normal);
  store.commit("task", { serviceTier: "default" }, { source: "phone", turnId: "new-turn" });
  assert.equal(events.length, 3, "unchanged choices do not cause echo updates");
});

test("Desktop snapshots replace stale cached choices without rewriting the owner snapshot", (t) => {
  const { store } = fixture(t);
  store.commit("task", { model: "gpt-5.5", effort: "medium", serviceTier: "fast" }, { source: "phone" });
  const conversation = {
    latestModel: "gpt-6-astra", latestReasoningEffort: "ultra", latestServiceTier: null,
    latestThreadSettings: { model: "gpt-6-astra", effort: "ultra", serviceTier: null },
    turns: [{ params: { model: "gpt-5.5", effort: "medium", serviceTier: "priority" } }],
  };
  const before = structuredClone(conversation);
  store.attachToConversation("task", conversation);
  assert.deepEqual(conversation.latestThreadSettings, before.latestThreadSettings);
  store.observeConversation("task", conversation);
  assert.equal(store.get("task").model, "gpt-6-astra");
  assert.equal(store.get("task").serviceTier, null);
  assert.deepEqual(conversation.turns, before.turns, "running/historical settings stay item-scoped");
  assert.equal(conversation.remodexRuntimeSettings.source, "desktop");
  const thread = { id: "task", model: "executing-model" };
  store.attachToThread(thread);
  assert.equal(thread.model, "executing-model");
  assert.equal(thread.runtimeSettings.model, "gpt-6-astra");
});

test("migrates v1 preferences without replaying them as confirmed owner state", (t) => {
  const { storeFile } = fixture(t);
  fs.writeFileSync(storeFile, JSON.stringify({ version: 1, threads: {
    task: { model: "stale-model", serviceTier: "fast", revision: 40, updatedAt: 99, source: "phone" },
  } }));
  const store = createThreadRuntimeSettingsStore({ storeFile });
  assert.equal(store.get("task"), null);
  const thread = { id: "task", model: "server-model" };
  store.attachToThread(thread);
  assert.deepEqual(thread, { id: "task", model: "server-model" });
  const settings = store.commit("task", { model: "server-model", effort: "high" }, { source: "runtime" });
  assert.equal(settings.serviceTier, undefined);
  assert.equal(settings.revision, 1);
  assert.equal(JSON.parse(fs.readFileSync(storeFile)).version, 2);
});

test("turn-only speed overrides never replace next-turn choices", (t) => {
  const { store } = fixture(t);
  store.commit("task", { model: "gpt-6-astra", serviceTier: "priority" }, { source: "runtime" });
  const settings = store.commit("task", { serviceTierForTurn: "default" }, { source: "desktop" });
  assert.equal(settings.serviceTier, "priority");
  assert.equal(settings.revision, 1);
});

test("reopening an evicted task uses a new epoch instead of replaying lower revisions", (t) => {
  let timestamp = 100;
  const { storeFile, store } = fixture(t, { maxThreads: 1, now: () => timestamp++ });
  const before = store.commit("old", { model: "astra" }, { source: "runtime" });
  store.commit("new", { model: "sol" }, { source: "runtime" });
  assert.equal(store.get("old"), null);
  const restored = store.commit("old", { model: "astra", effort: "ultra" }, { source: "runtime" });
  assert.notEqual(restored.epoch, before.epoch);
  assert.equal(createThreadRuntimeSettingsStore({ storeFile }).get("old").epoch, restored.epoch);
});

test("failed persistence does not consume the next confirmed revision", (t) => {
  let failWrite = false;
  const events = [];
  const { storeFile, store } = fixture(t, {
    fsImpl: { ...fs, renameSync(...args) {
      if (failWrite) throw new Error("disk full");
      return fs.renameSync(...args);
    } },
    onChange: (...args) => events.push(args),
  });
  const before = store.commit("task", { model: "astra", effort: "medium" }, { source: "runtime" });
  failWrite = true;
  assert.throws(() => store.commit("task", { effort: "ultra" }, { source: "runtime" }), /disk full/);
  assert.deepEqual(store.get("task"), before);
  failWrite = false;
  const after = store.commit("task", { effort: "ultra" }, { source: "runtime" });
  assert.equal(after.revision, before.revision + 1);
  assert.deepEqual(createThreadRuntimeSettingsStore({ storeFile }).get("task"), after);
  assert.equal(events.length, 2);
});

test("unsolicited settings updates survive a cache-write failure and retry on the next snapshot", (t) => {
  let failWrite = true;
  const errors = [];
  const { store } = fixture(t, {
    fsImpl: { ...fs, writeFileSync(...args) {
      if (failWrite) throw new Error("disk full");
      return fs.writeFileSync(...args);
    } },
    onError: (error) => errors.push(error.message),
  });
  assert.equal(store.observe("task", { model: "astra", effort: "ultra" }), null);
  assert.deepEqual(errors, ["disk full"]);
  failWrite = false;
  const restored = store.observe("task", { model: "astra", effort: "ultra" });
  assert.equal(restored.revision, 1);
  assert.equal(restored.reasoningEffort, "ultra");
});

for (const tier of ["priority", null]) {
  test(`first speed-only acknowledgement persists ${tier ?? "Normal"} without inventing other settings`, (t) => {
    const { storeFile, store } = fixture(t);
    const settings = store.commit("new-task", { serviceTier: tier }, { source: "phone" });
    assert.equal(settings?.serviceTier, tier);
    assert.equal(Object.hasOwn(settings, "model"), false);
    assert.equal(Object.hasOwn(settings, "reasoningEffort"), false);
    assert.deepEqual(createThreadRuntimeSettingsStore({ storeFile }).get("new-task"), settings);
    const complete = store.commit("new-task", { model: "astra", effort: "ultra" }, { source: "runtime" });
    assert.equal(complete.serviceTier, tier);
  });
}
