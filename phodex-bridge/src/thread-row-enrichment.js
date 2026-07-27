// FILE: thread-row-enrichment.js
// Purpose: One walk over the thread rows carried by thread/list, thread/read, and
//          thread/resume responses, so every enricher shares the same shape handling
//          and a response is traversed once no matter how many enrichers run on it.
// Layer: CLI helper
// Exports: forEachThreadRowInResponse
// Depends on: (none)

const THREAD_LIST_ROW_KEYS = ["data", "items", "threads"];

function forEachThreadRowInResponse(method, envelope, visit) {
  if (typeof visit !== "function") {
    return envelope;
  }
  if (!envelope || typeof envelope !== "object" || envelope.error) {
    return envelope;
  }
  const result = envelope.result;
  if (!result || typeof result !== "object") {
    return envelope;
  }

  if (method === "thread/read" || method === "thread/resume") {
    if (result.thread && typeof result.thread === "object") {
      visit(result.thread);
    }
    return envelope;
  }

  if (method === "thread/list") {
    const key = THREAD_LIST_ROW_KEYS.find((candidate) => Array.isArray(result[candidate]));
    for (const thread of key ? result[key] : []) {
      if (thread && typeof thread === "object") {
        visit(thread);
      }
    }
  }
  return envelope;
}

module.exports = {
  forEachThreadRowInResponse,
};
