const assert = require("node:assert/strict");
const test = require("node:test");
const {
  applyRuntimeSettingsToConversation, createThreadMutationQueue,
  runtimeSettingsPatch, runtimeSettingsFromConversation,
} = require("../src/codex-runtime-settings");
const { canonicalThreadTurnsListRequest, normalizePhoneRuntimeRequest, normalizeTurnStartForCodex } = require("../src/bridge");
const { desktopFollowerPayloadForResponse } = require("../src/desktop-ipc-action-follower");
const { synchronizeDesktopConversationCompatibility } = require("../src/desktop-ipc-conversation-adapter");

test("runtime patch distinguishes inherit, Standard and selected tier, including legacy Fast", () => {
  assert.deepEqual(runtimeSettingsPatch({}), {});
  assert.deepEqual(runtimeSettingsPatch({ effort: null }), {});
  assert.deepEqual(runtimeSettingsPatch({ effort: null }, { authoritative: true }), { reasoningEffort: null });
  assert.deepEqual(runtimeSettingsPatch({ collaborationMode: { settings: { reasoning_effort: null } } }), { reasoningEffort: null });
  assert.deepEqual(runtimeSettingsPatch({ serviceTier: null, service_tier: "fast" }), { serviceTier: null });
  assert.deepEqual(runtimeSettingsPatch({ serviceTierForTurn: "default" }), {});
  assert.deepEqual(runtimeSettingsPatch({ serviceTier: null }), { serviceTier: null });
  assert.deepEqual(runtimeSettingsPatch({ serviceTier: "default" }), { serviceTier: null });
  assert.deepEqual(runtimeSettingsPatch({ serviceTier: "fast" }), { serviceTier: "priority" });
  assert.deepEqual(runtimeSettingsPatch({ serviceTier: "ultrafast" }), { serviceTier: "ultrafast" });
  assert.deepEqual(runtimeSettingsPatch({ effort: null, collaborationMode: { settings: { model: "gpt-6-astra", reasoning_effort: "ultra" } } }), { model: "gpt-6-astra", reasoningEffort: "ultra" });
});

test("only the legacy phone boundary translates omitted speed into Standard", () => {
  const request = { id: 1, method: "turn/start", params: { threadId: "task", input: [] } };
  assert.equal(JSON.parse(normalizePhoneRuntimeRequest(JSON.stringify(request))).params.serviceTier, "default");
  request.params.remodexRuntimeSettingsVersion = 2;
  assert.deepEqual(JSON.parse(normalizePhoneRuntimeRequest(JSON.stringify(request))).params, { threadId: "task", input: [] });
  request.params.serviceTier = "fast";
  assert.equal(JSON.parse(normalizePhoneRuntimeRequest(JSON.stringify(request))).params.serviceTier, "priority");
  request.method = "thread/settings/update";
  request.params.serviceTier = null;
  assert.equal(JSON.parse(normalizePhoneRuntimeRequest(JSON.stringify(request))).params.serviceTier, null);
});

test("null top-level effort inherits collaboration effort, matching the installed runtime", () => {
  const request = { method: "turn/start", params: { model: "gpt-6-astra", effort: null, collaborationMode: { mode: "plan", settings: { model: "gpt-5.5", reasoning_effort: "high" } } } };
  const result = JSON.parse(normalizeTurnStartForCodex(JSON.stringify(request)));
  assert.equal(result.params.collaborationMode.settings.model, "gpt-6-astra");
  assert.equal(result.params.collaborationMode.settings.reasoning_effort, "high");
});

test("next-turn Standard and Auto survive Desktop snapshot normalization without rewriting an active turn", () => {
  const conversation = { id: "task", turns: [{ id: "turn", status: "inProgress", params: { model: "gpt-5.5", effort: "high", serviceTier: "priority" }, items: [] }], latestThreadSettings: { model: "gpt-5.5", effort: "high", serviceTier: "priority" } };
  applyRuntimeSettingsToConversation(conversation, { model: "gpt-6-astra", effort: null, serviceTier: null }, { authoritative: true });
  synchronizeDesktopConversationCompatibility(conversation);
  assert.deepEqual(runtimeSettingsFromConversation(conversation), { model: "gpt-6-astra", reasoningEffort: null, serviceTier: null });
  assert.equal(conversation.turns[0].params.serviceTier, "priority");
  assert.equal(conversation.turns[0].params.effort, "high");
});

test("permission replies preserve scope, exact subsets and numeric IDs", () => {
  const result = { permissions: { fileSystem: { read: ["/workspace"] } }, scope: "session" };
  const route = { method: "item/permissions/requestApproval", threadId: "task", requestId: "42", desktopRequestId: 42 };
  const reply = desktopFollowerPayloadForResponse(route, { result });
  assert.equal(reply.method, "thread-follower-permissions-request-approval-response");
  assert.equal(reply.params.requestId, 42);
  assert.deepEqual(reply.params.response, result);
  assert.equal(desktopFollowerPayloadForResponse(route, { result: { decision: "accept" } }), null);
  assert.equal(desktopFollowerPayloadForResponse({ ...route, method: "item/commandExecution/requestApproval" }, { result: { decision: "decline" } }).params.requestId, 42);
});

test("history requests select full items while lightweight probes remain summaries", () => {
  const request = { method: "thread/turns/list", params: { threadId: "task", cursor: "older", limit: 5 } };
  assert.equal(canonicalThreadTurnsListRequest(request).params.itemsView, "full");
  assert.equal(canonicalThreadTurnsListRequest({ ...request, params: { ...request.params, remodexTurnStateOnly: true } }).params.itemsView, "summary");
  assert.equal(request.params.itemsView, undefined);
});

test("mutations serialize by task, continue after failure, and do not block other tasks", async () => {
  const enqueue = createThreadMutationQueue();
  const order = [];
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const first = enqueue("task", async () => { order.push("settings"); await gate; throw new Error("rejected"); });
  const rejection = assert.rejects(first, /rejected/);
  const second = enqueue("task", () => { order.push("turn"); });
  await enqueue("other", () => { order.push("other"); });
  assert.deepEqual(order, ["settings", "other"]);
  release();
  await Promise.all([rejection, second]);
  assert.deepEqual(order, ["settings", "other", "turn"]);
});

test("settings and IPC adapters match the captured installed protocol", () => {
  const fixture = require("./fixtures/codex-runtime-contract.json");
  const { THREAD_SETTINGS_UPDATE_KEYS } = require("../src/codex-runtime-settings");
  const { DESKTOP_IPC_METHOD_VERSIONS } = require("../src/desktop-ipc-shared");
  assert.deepEqual([...THREAD_SETTINGS_UPDATE_KEYS].sort(), fixture.threadSettingsUpdateKeys);
  for (const [method, version] of Object.entries(fixture.desktopVersions)) {
    assert.equal(DESKTOP_IPC_METHOD_VERSIONS.get(method), version, method);
  }
});
