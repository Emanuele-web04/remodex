// Distinguishes internal compaction handoffs from user-visible final answers.
// Unknown formats fail open; only an exact match in a subsequent compacted
// record can suppress a provider item. One candidate bounds memory usage.
const crypto = require("crypto");
const { responseItemMessageText } = require("./desktop-ipc-shared");

const HANDOFF_PREFIX = "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:";

function createCompactionSummaryFilter() {
  let candidate = null;
  const visibleItemIds = new Set();

  function flush() {
    if (!candidate?.pending.length) return [];
    const entries = candidate.pending;
    candidate.pending = [];
    return entries;
  }

  function push(entry, { eventItemId = "" } = {}) {
    const event = entry?.type === "event_msg" ? entry.payload : null;
    if (event?.type === "item_completed") {
      const item = event.item;
      if (typeof item?.id === "string" && (item.type === "agentMessage"
          || (item.type === "message" && item.role === "assistant"))) {
        visibleItemIds.add(item.id);
        if (visibleItemIds.size > 128) visibleItemIds.delete(visibleItemIds.values().next().value);
      }
    }
    if (entry?.type === "token_usage_record"
        || (entry?.type === "event_msg" && entry.payload?.type === "token_count")) {
      return { entries: [entry], suppressedItemIds: [] };
    }

    if (entry?.type === "compacted" && candidate
        && matchesCompactionMessage(entry.payload?.message, candidate.text)) {
      const suppressedItemIds = candidate.ids;
      candidate = null;
      return { entries: [entry], suppressedItemIds };
    }

    const payload = entry?.payload;
    const isResponse = entry?.type === "response_item" && payload?.type === "message" && payload.role === "assistant";
    const isEvent = event?.type === "agent_message";
    const id = isEvent ? (payload.itemId || eventItemId) : payload?.id;
    const phase = payload?.phase;
    const text = isResponse ? responseItemMessageText(payload).trim()
      : (isEvent ? String(payload.message || payload.text || "").trim() : "");
    const eligible = (isResponse || isEvent) && phase === "final_answer"
      && typeof id === "string" && id.trim() && text && !visibleItemIds.has(id);
    // Codex may persist the same final once as an event and once as a response
    // item. Keep just that pair, not an unbounded series of repeated messages.
    const source = isResponse ? "response" : "event";
    if (eligible && candidate?.text === text && !candidate.sources.has(source)) {
      candidate.sources.add(source);
      if (!candidate.ids.includes(id)) candidate.ids.push(id);
      if (isResponse) candidate.pending.push(entry);
      return { entries: isEvent ? [entry] : [], suppressedItemIds: [] };
    }
    const entries = flush();
    candidate = null;
    if (eligible) {
      candidate = { ids: [id], text, pending: isEvent ? [] : [entry], sources: new Set([source]) };
      // Legacy agent_message events drive the live stream. Preserve their
      // timing, but retain their exact synthetic/provider ID so later evidence
      // can retract that representation along with the response-item copy.
      return { entries: isEvent ? [...entries, entry] : entries, suppressedItemIds: [] };
    }
    return { entries: [...entries, entry], suppressedItemIds: [] };
  }

  return { push, flush };
}

function matchesCompactionMessage(message, text) {
  if (typeof message !== "string") return false;
  const normalized = message.replace(/\r\n/g, "\n").trim();
  const expected = text.replace(/\r\n/g, "\n").trim();
  if (normalized === expected) return true;
  if (!normalized.startsWith(`${HANDOFF_PREFIX}\n`)) return false;
  return normalized.slice(HANDOFF_PREFIX.length).trim() === expected;
}

// Must stay identical for live events and history cleanup of earlier builds.
function rolloutAgentMessageItemId(threadId, turnId, entry, message) {
  const timestamp = typeof entry?.timestamp === "string" && entry.timestamp.trim() ? entry.timestamp.trim() : "untimed";
  const hash = crypto.createHash("sha256").update(String(message || "").trim()).digest("hex").slice(0, 12);
  return `rollout-agent-message:${threadId}:${turnId || "turnless"}:${timestamp}:${hash}`;
}

module.exports = { createCompactionSummaryFilter, rolloutAgentMessageItemId };
