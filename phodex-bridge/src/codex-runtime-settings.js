// Canonical runtime settings shared by the app-server and Desktop IPC adapters.
// Missing fields inherit; null clears speed, while null effort inherits unless
// supplied in collaboration settings or an authoritative snapshot. Turn-only overrides
// are deliberately excluded from the persistent next-turn settings.
const hasOwn = (value, key) => Object.prototype.hasOwnProperty.call(value || {}, key);
const string = (value) => typeof value === "string" ? value.trim() : "";
const THREAD_SETTINGS_UPDATE_KEYS = [
  "approvalPolicy", "approvalsReviewer", "collaborationMode", "cwd", "effort", "model",
  "multiAgentMode", "permissions", "personality", "sandboxPolicy", "serviceTier", "summary",
];

function normalizeThreadSettingsUpdate(params, options = {}) {
  const settings = Object.fromEntries(THREAD_SETTINGS_UPDATE_KEYS.filter((key) => hasOwn(params, key))
    .map((key) => [key, structuredClone(params[key])]));
  const patch = runtimeSettingsPatch(params, options);
  if (settings.effort == null && !options.authoritative) delete settings.effort;
  if (hasOwn(patch, "serviceTier")) settings.serviceTier = patch.serviceTier;
  if (settings.collaborationMode?.settings) {
    if (patch.model) settings.collaborationMode.settings.model = patch.model;
    if (hasOwn(patch, "reasoningEffort")) settings.collaborationMode.settings.reasoning_effort = patch.reasoningEffort;
  }
  return settings;
}

// Confirmations may be partial (for example the first edit only selects Fast).
// Preserve omission instead of manufacturing resets for unknown fields.
function threadSettingsFromRuntimeSettings(settings) {
  const patch = runtimeSettingsPatch(settings);
  const result = { ...patch };
  if (hasOwn(patch, "reasoningEffort")) {
    result.effort = patch.reasoningEffort;
    delete result.reasoningEffort;
  }
  return result;
}

function normalizeServiceTier(value) {
  const tier = string(value);
  if (!tier || tier === "default") return null;
  return tier === "fast" ? "priority" : tier;
}

function runtimeSettingsPatch(params = {}, { authoritative = false } = {}) {
  const nested = params.collaborationMode?.settings || params.collaboration_mode?.settings || {};
  const patch = {};
  if (string(params.model) || string(nested.model)) patch.model = string(params.model) || string(nested.model);
  for (const [object, key] of [[params, "effort"], [params, "reasoningEffort"], [nested, "reasoning_effort"], [nested, "reasoningEffort"]]) {
    if (hasOwn(object, key) && (key !== "effort" || object[key] != null || authoritative)) {
      patch.reasoningEffort = string(object[key]) || null;
      break;
    }
  }
  if (hasOwn(params, "serviceTier") || hasOwn(params, "service_tier")) {
    patch.serviceTier = normalizeServiceTier(hasOwn(params, "serviceTier") ? params.serviceTier : params.service_tier);
  }
  return patch;
}

function runtimeSettingsFromConversation(conversation = {}) {
  const settings = conversation.latestThreadSettings || {};
  const fallback = {};
  if (string(conversation.latestModel)) fallback.model = conversation.latestModel;
  if (hasOwn(conversation, "latestReasoningEffort")) fallback.reasoningEffort = conversation.latestReasoningEffort;
  if (hasOwn(conversation, "latestServiceTier")) fallback.serviceTier = conversation.latestServiceTier;
  return { ...runtimeSettingsPatch(fallback), ...runtimeSettingsPatch(settings, { authoritative: true }) };
}

function applyRuntimeSettingsToConversation(conversation, params, options = {}) {
  if (!conversation) return;
  const patch = runtimeSettingsPatch(params, options);
  const settings = { ...(conversation.latestThreadSettings || {}), ...normalizeThreadSettingsUpdate(params, options) };
  if (hasOwn(patch, "model")) conversation.latestModel = settings.model = patch.model;
  if (hasOwn(patch, "reasoningEffort")) conversation.latestReasoningEffort = settings.effort = patch.reasoningEffort;
  if (hasOwn(patch, "serviceTier")) conversation.latestServiceTier = settings.serviceTier = patch.serviceTier;
  const mode = params.collaborationMode || conversation.latestCollaborationMode;
  if (mode || patch.model) {
    conversation.latestCollaborationMode = {
      ...(mode || { mode: "default" }),
      settings: {
        developer_instructions: null,
        ...(mode?.settings || {}),
        ...(patch.model ? { model: patch.model } : {}),
        ...(hasOwn(patch, "reasoningEffort") ? { reasoning_effort: patch.reasoningEffort } : {}),
      },
    };
    settings.collaborationMode = conversation.latestCollaborationMode;
  }
  conversation.latestThreadSettings = settings;
}

// Ordering is scoped to one runtime owner and task. Failures don't poison the
// queue, and the next mutation always waits for the preceding acknowledgement.
function createThreadMutationQueue() {
  const pending = new Map();
  return function enqueue(threadId, operation) {
    const result = (pending.get(threadId) || Promise.resolve()).catch(() => {}).then(operation);
    pending.set(threadId, result);
    result.finally(() => { if (pending.get(threadId) === result) pending.delete(threadId); }).catch(() => {});
    return result;
  };
}

module.exports = {
  applyRuntimeSettingsToConversation,
  createThreadMutationQueue,
  hasOwn,
  normalizeServiceTier,
  normalizeThreadSettingsUpdate,
  THREAD_SETTINGS_UPDATE_KEYS,
  threadSettingsFromRuntimeSettings,
  runtimeSettingsFromConversation,
  runtimeSettingsPatch,
};
