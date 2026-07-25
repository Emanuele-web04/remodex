// FILE: bridge.js
// Purpose: Runs Codex locally, bridges relay traffic, and coordinates desktop refreshes for Codex.app.
// Layer: CLI service
// Exports: startBridge
// Depends on: ws, crypto, os, ./bridge-status, ./codex-desktop-refresher, ./codex-transport, ./rollout-watch, ./voice-handler

const WebSocket = require("ws");
const { constants: bufferConstants } = require("buffer");
const { createHash, randomBytes } = require("crypto");
const { execFile, spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { promisify } = require("util");
const {
  CodexDesktopRefresher,
  readBridgeConfig,
} = require("./codex-desktop-refresher");
const {
  buildHeartbeatBridgeStatus,
  createBridgeStatusPublisher,
  hasRelayConnectionGoneStale,
} = require("./bridge-status");
const { createCodexTransport } = require("./codex-transport");
const {
  createThreadRolloutActivityWatcher,
  findRecentRolloutFileForContextRead,
  resolveSessionsRoot,
} = require("./rollout-watch");
const { printQR } = require("./qr");
const { rememberActiveThread } = require("./session-state");
const { handleDesktopRequest } = require("./desktop-handler");
const { readDaemonConfig, writeDaemonConfig } = require("./daemon-state");
const { handleGitRequest } = require("./git-handler");
const { handleThreadContextRequest } = require("./thread-context-handler");
const { handleWorkspaceRequest } = require("./workspace-handler");
const { handleProjectRequest } = require("./project-handler");
const { handlePetRequest } = require("./pet-handler");
const { createNotificationsHandler } = require("./notifications-handler");
const { createVoiceHandler, resolveVoiceAuth } = require("./voice-handler");
const {
  composeSanitizedAuthStatusFromSettledResults,
} = require("./account-status");
const { createBridgePackageVersionStatusReader } = require("./package-version-status");
const { createPushNotificationServiceClient } = require("./push-notification-service-client");
const { createPushNotificationTracker } = require("./push-notification-tracker");
const { resolveCodexGeneratedImagesRoot } = require("./codex-home");
const {
  loadOrCreateBridgeDeviceState,
  rememberLastSeenClientDeviceKind,
  rememberLastSeenPhoneAppVersion,
  resolveBridgeRelaySession,
} = require("./secure-device-state");
const { createBridgeSecureTransport } = require("./secure-transport");
const { createRolloutLiveMirrorController } = require("./rollout-live-mirror");
const {
  isContextualUserText,
  isThreadTurnStateProbeRequest,
  isUserRoleItem,
  readUserItemText,
  sanitizeUserRoleItem,
  visibleUserPromptText,
} = require("./desktop-ipc-shared");
const {
  createDesktopIpcActionFollower,
  seedConversationStateFromThreadRead,
} = require("./desktop-ipc-action-follower");
const { createDesktopIpcLiveOwner } = require("./desktop-ipc-live-owner");
const { createThreadRuntimeSettingsStore } = require("./thread-runtime-settings-store");
const { version: bridgePackageVersion = "" } = require("../package.json");
const {
  MINIMUM_SUPPORTED_IOS_APP_VERSION,
  buildCachedIOSAppCompatibilityWarning,
  buildIOSAppCompatibilitySnapshot,
  normalizeVersionString,
} = require("./ios-app-compatibility");
const { createShortPairingCode, SHORT_PAIRING_CODE_LENGTH } = require("./qr");
const {
  JSONL_OLDER_HANDOFF_CURSOR,
  parseSessionJsonlTurns,
  readRecentSessionJsonlTurns,
  readSessionJsonlMetadataFromFile,
  readThreadTurnsListPageFromSessionJsonl,
} = require("./session-jsonl-history");
const { buildApplyPatchFileChangeItem } = require("./apply-patch-changes");

const execFileAsync = promisify(execFile);
const RELAY_WATCHDOG_PING_INTERVAL_MS = 10_000;
const RELAY_HISTORY_IMAGE_REFERENCE_URL = "remodex://history-image-elided";
const RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES = 4 * 1024 * 1024;
const RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS = 24_000;
// Recent-turn window used only when a thread/read payload already exceeds the
// relay soft budget: heavy threads first paint with this many newest turns and
// older history arrives via thread/turns/list pagination. Normal threads are
// never trimmed.
const RELAY_HISTORY_RECENT_TURN_TARGET = 16;
const RELAY_TURNS_LIST_TARGET_BUDGET_MS = 5_500;
const RELAY_TURNS_LIST_BUDGET_RESERVE_MS = 1_000;
const RELAY_TURNS_LIST_MAX_INITIAL_LIMIT = 5;
const RELAY_TURNS_LIST_SAFE_RETRY_LIMIT = 5;
const RELAY_JSONL_TURNS_LIST_CACHE_TTL_MS = 30_000;
const RELAY_JSONL_ARTIFACT_CACHE_TTL_MS = 2_000;
const RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES = 128;
// Session cwd is stable for a rollout file, but the same thread can later get a
// newer rollout with a different cwd; cache entries are validated against file identity.
const RELAY_JSONL_THREAD_CWD_CACHE_TTL_MS = 5 * 60_000;
const RELAY_JSONL_THREAD_EMPTY_CWD_CACHE_TTL_MS = 30_000;
const RELAY_JSONL_FAST_FIRST_PAGE_WAIT_MS = 1_500;
// The phone may be backgrounded between the provisional JSONL page and its
// canonical reconciliation. Keep the handoff long enough that a normal
// foreground/reconnect does not turn a coherent first page into a dead cursor.
const RELAY_JSONL_CANONICAL_HANDOFF_TTL_MS = 10 * 60_000;
const RELAY_JSONL_CANONICAL_HANDOFF_MAX_ENTRIES = 32;
const JSONL_CANONICAL_HANDOFF_CURSOR_PREFIX = "remodex-jsonl-handoff-v1:";
const RELAY_JSONL_FULL_ARTIFACT_FALLBACK_MAX_BYTES = Math.max(
  0,
  bufferConstants.MAX_STRING_LENGTH - (8 * 1024 * 1024)
);
const BRIDGE_PACKAGE_UPDATE_COMMAND = "npm install -g remodex@latest";
const BRIDGE_PACKAGE_UPDATE_TIMEOUT_MS = 180_000;
const BRIDGE_RESTART_AFTER_UPDATE_DELAY_MS = 750;
const MODELS_WITHOUT_REASONING_SUMMARY = new Set([
  "gpt-5.3-codex-spark",
]);
const RELAY_TURNS_LIST_RESULT_KEYS = ["data", "items", "turns"];
const RELAY_TURNS_LIST_PAGINATION_RESULT_KEYS = [
  "nextCursor",
  "next_cursor",
  "cursor",
  "hasNextCursor",
  "has_next_cursor",
  "hasNextPage",
  "has_next_page",
  "hasMore",
  "has_more",
  "prevCursor",
  "prev_cursor",
  "previousCursor",
  "previous_cursor",
];
const RELAY_TURNS_LIST_PREVIOUS_PAGINATION_RESULT_KEYS = new Set([
  "prevCursor",
  "prev_cursor",
  "previousCursor",
  "previous_cursor",
]);
const jsonlArtifactItemsCacheByThread = new Map();
const jsonlThreadCwdCacheByThread = new Map();
const FORWARDED_REQUEST_METHODS_MAX_SIZE = 500;
const JSONL_ROLLOUT_PATH_CACHE_MAX_SIZE = 200;

function evictOldestEntries(map, maxSize) {
  if (map.size <= maxSize) {
    return;
  }
  const excess = map.size - maxSize;
  const iterator = map.keys();
  for (let i = 0; i < excess; i += 1) {
    const key = iterator.next().value;
    map.delete(key);
  }
}

function createThreadTurnsListFastPageCoordinator({
  waitMs = RELAY_JSONL_FAST_FIRST_PAGE_WAIT_MS,
  handoffTTLms = RELAY_JSONL_CANONICAL_HANDOFF_TTL_MS,
  maxHandoffs = RELAY_JSONL_CANONICAL_HANDOFF_MAX_ENTRIES,
  payloadSoftLimitBytes = RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES,
  sanitizeForRelay = sanitizeThreadHistoryImagesForRelay,
  now = Date.now,
  setTimeoutImpl = setTimeout,
  clearTimeoutImpl = clearTimeout,
  createToken = () => randomBytes(12).toString("hex"),
} = {}) {
  const handoffsByToken = new Map();
  const latestHandoffTokenByThread = new Map();
  const canonicalFirstPageByKey = new Map();

  function pruneHandoffs() {
    const cutoff = now() - handoffTTLms;
    for (const [token, entry] of handoffsByToken) {
      if (entry.createdAt >= cutoff) {
        continue;
      }
      handoffsByToken.delete(token);
      if (latestHandoffTokenByThread.get(entry.threadId) === token) {
        latestHandoffTokenByThread.delete(entry.threadId);
      }
    }
    for (const [cacheKey, entry] of canonicalFirstPageByKey) {
      if (entry.createdAt < cutoff) {
        canonicalFirstPageByKey.delete(cacheKey);
      }
    }
    while (handoffsByToken.size > maxHandoffs) {
      const oldestToken = handoffsByToken.keys().next().value;
      const oldest = handoffsByToken.get(oldestToken);
      handoffsByToken.delete(oldestToken);
      if (oldest && latestHandoffTokenByThread.get(oldest.threadId) === oldestToken) {
        latestHandoffTokenByThread.delete(oldest.threadId);
      }
    }
  }

  function rememberHandoff(threadId, canonicalOutcomePromise, jsonlFallback) {
    pruneHandoffs();
    const token = createToken();
    const entry = {
      token,
      threadId,
      canonicalOutcomePromise,
      hadNonEmptyJsonl: Boolean(jsonlFallback?.response),
      anchorTurnId: firstTurnsListTurnId(jsonlFallback?.response),
      createdAt: now(),
    };
    handoffsByToken.set(token, entry);
    latestHandoffTokenByThread.set(threadId, token);
    pruneHandoffs();
    return token;
  }

  function consumeHandoff(entry) {
    if (!entry?.token) {
      return;
    }
    handoffsByToken.delete(entry.token);
    if (latestHandoffTokenByThread.get(entry.threadId) === entry.token) {
      latestHandoffTokenByThread.delete(entry.threadId);
    }
  }

  function canonicalFirstPageOutcome(cacheKey, canonicalRequest, fetchCanonical) {
    pruneHandoffs();
    const existing = canonicalFirstPageByKey.get(cacheKey);
    if (existing) {
      return existing.canonicalOutcomePromise;
    }
    const canonicalOutcomePromise = settleThreadTurnsListCanonicalOutcome(
      fetchCanonical(canonicalRequest)
    );
    canonicalFirstPageByKey.set(cacheKey, {
      canonicalOutcomePromise,
      createdAt: now(),
    });
    canonicalOutcomePromise.then(() => {
      forgetCanonicalFirstPage(cacheKey, canonicalOutcomePromise);
    });
    return canonicalOutcomePromise;
  }

  function forgetCanonicalFirstPage(cacheKey, canonicalOutcomePromise) {
    const existing = canonicalFirstPageByKey.get(cacheKey);
    if (existing?.canonicalOutcomePromise === canonicalOutcomePromise) {
      canonicalFirstPageByKey.delete(cacheKey);
    }
  }

  function readHandoffEntry(request) {
    pruneHandoffs();
    const threadId = threadIdFromRequestParams(request?.params);
    const cursor = request?.params?.cursor;
    const token = threadTurnsListHandoffDescriptor(cursor)?.token
      || latestHandoffTokenByThread.get(threadId)
      || "";
    const entry = token ? handoffsByToken.get(token) : null;
    return entry?.threadId === threadId ? entry : null;
  }

  async function awaitCanonicalOutcome(canonicalOutcomePromise) {
    const outcome = await canonicalOutcomePromise;
    if (!outcome.ok) {
      throw outcome.error;
    }
    return outcome.response;
  }

  async function extendCanonicalResponseThroughAnchor(
    response,
    canonicalRequest,
    anchorTurnId,
    fetchCanonical,
    maxPages = 12
  ) {
    if (threadTurnsListResponseContainsAnchor(response, anchorTurnId)) {
      return response;
    }
    const firstResult = response?.result;
    const turnsKey = findTurnsListResultKey(firstResult);
    if (!turnsKey) {
      return null;
    }

    let lastResult = firstResult;
    let combinedTurns = [...firstResult[turnsKey]];
    let cursor = readTurnsListNextCursor(firstResult);
    const seenCursors = new Set();
    for (let pageIndex = 0; pageIndex < maxPages && hasRelayCursor(cursor); pageIndex += 1) {
      const cursorKey = JSON.stringify(cursor);
      if (seenCursors.has(cursorKey)) {
        break;
      }
      seenCursors.add(cursorKey);
      const nextRequest = {
        ...canonicalRequest,
        params: buildAdaptiveTurnsListPageParams(
          canonicalRequest.params,
          RELAY_TURNS_LIST_SAFE_RETRY_LIMIT,
          cursor
        ),
      };
      const nextResponse = await awaitCanonicalOutcome(
        settleThreadTurnsListCanonicalOutcome(fetchCanonical(nextRequest))
      );
      const nextResult = nextResponse?.result;
      const nextTurnsKey = findTurnsListResultKey(nextResult);
      if (!nextTurnsKey) {
        break;
      }
      for (const turn of nextResult[nextTurnsKey]) {
        const turnId = turnListTurnIdentifier(turn);
        if (!turnId || !combinedTurns.some((existing) => turnListTurnIdentifier(existing) === turnId)) {
          combinedTurns.push(turn);
        }
      }
      lastResult = nextResult;
      const combinedResponse = buildSafeTurnsListResponse(
        canonicalRequest.id,
        firstResult,
        lastResult,
        turnsKey,
        combinedTurns
      );
      if (threadTurnsListResponseContainsAnchor(combinedResponse, anchorTurnId)) {
        // The cursor belongs after every turn through the anchor. Keep that
        // complete boundary intact, compacting items if needed; never slice
        // turns and accidentally make the omitted range unreachable.
        return buildCompactedCompleteTurnsListResponse({
          requestId: canonicalRequest.id,
          firstResult,
          lastResult,
          turnsKey,
          turns: combinedTurns,
          sanitizeForRelay,
          sanitizeContext: buildThreadTurnsListRelaySanitizeContext(canonicalRequest),
          payloadSoftLimitBytes,
        });
      }
      const nextCursor = readTurnsListNextCursor(nextResult);
      if (nextResult[nextTurnsKey].length === 0 || !hasRelayCursor(nextCursor)) {
        break;
      }
      cursor = nextCursor;
    }
    return null;
  }

  async function resolveCanonicalRequest(request, fetchCanonical, existingEntry = null, {
    alignToHandoffAnchor = false,
    validateHandoffAnchor = false,
    handoffAnchorTurnId = "",
  } = {}) {
    const canonicalRequest = canonicalThreadTurnsListRequest(request);
    let entry = existingEntry;
    let response = null;
    const anchorTurnId = entry?.anchorTurnId || handoffAnchorTurnId;
    const canMatchCanonicalAnchor = anchorTurnId
      && !isSyntheticJsonlHistoryTurnId(anchorTurnId);
    if (entry) {
      const observedOutcomePromise = entry.canonicalOutcomePromise;
      const firstOutcome = await observedOutcomePromise;
      const firstResponseIsUsable = firstOutcome.ok
        && !isEmptyTurnsListResponse(firstOutcome.response);
      if (firstResponseIsUsable) {
        response = firstOutcome.response;
      } else {
        if (entry.canonicalOutcomePromise === observedOutcomePromise) {
          entry.canonicalOutcomePromise = settleThreadTurnsListCanonicalOutcome(
            fetchCanonical(canonicalRequest)
          );
          entry.createdAt = now();
        }
      }
    }

    response = response || await awaitCanonicalOutcome(
      entry?.canonicalOutcomePromise
        || settleThreadTurnsListCanonicalOutcome(fetchCanonical(canonicalRequest))
    );
    if (entry?.hadNonEmptyJsonl && isEmptyTurnsListResponse(response)) {
      throw new Error("Canonical thread history was empty after a non-empty JSONL first page.");
    }
    if (validateHandoffAnchor
        && canMatchCanonicalAnchor
        && !threadTurnsListResponseContainsAnchor(response, anchorTurnId)) {
      response = await extendCanonicalResponseThroughAnchor(
        response,
        canonicalRequest,
        anchorTurnId,
        fetchCanonical
      );
      if (!response) {
        throw new Error("Canonical history does not contain the JSONL handoff anchor yet.");
      }
    }
    const rebound = rebindThreadTurnsListResponseId(response, request.id);
    if (!alignToHandoffAnchor || !canMatchCanonicalAnchor) {
      return rebound;
    }
    const aligned = alignThreadTurnsListResponseToAnchor(rebound, anchorTurnId);
    if (!aligned) {
      throw new Error("Canonical history no longer contains the JSONL handoff anchor.");
    }
    return aligned;
  }

  async function resolve(request, { fetchCanonical, readJsonl }) {
    const params = request?.params || {};
    const cursor = params.cursor;
    const handoffDescriptor = threadTurnsListHandoffDescriptor(cursor);
    const isHandoffRequest = cursor === JSONL_OLDER_HANDOFF_CURSOR
      || Boolean(handoffDescriptor);
    const requiresCanonical = params.remodexRequireCanonical === true;
    const hasOrdinaryCursor = hasRelayCursor(cursor) && !isHandoffRequest;

    if (hasOrdinaryCursor) {
      return {
        source: "canonical",
        response: await resolveCanonicalRequest(request, fetchCanonical),
        usesJsonl: false,
      };
    }

    if (isHandoffRequest || requiresCanonical) {
      const handoffEntry = readHandoffEntry(request);
      const response = await resolveCanonicalRequest(request, fetchCanonical, handoffEntry, {
        alignToHandoffAnchor: isHandoffRequest,
        validateHandoffAnchor: true,
        handoffAnchorTurnId: handoffDescriptor?.anchorTurnId || "",
      });
      consumeHandoff(handoffEntry);
      return {
        source: "canonical",
        response,
        usesJsonl: false,
      };
    }

    const canonicalRequest = canonicalThreadTurnsListRequest(request);
    const threadId = threadIdFromRequestParams(params);
    const canonicalFirstPageCacheKey = canonicalThreadTurnsListRequestShapeKey(canonicalRequest);
    const canonicalOutcomePromise = canonicalFirstPageOutcome(
      canonicalFirstPageCacheKey,
      canonicalRequest,
      fetchCanonical
    );
    let jsonlFallback = null;
    try {
      jsonlFallback = await readJsonl(request);
    } catch {
      jsonlFallback = null;
    }
    // A rollout tail is a useful emergency baseline only when it contains a
    // whole turn package. Never let a bare tail (for example a file-change or
    // final assistant fragment) win the race with canonical history: iOS would
    // render it as a complete conversation and then merge the real opener in
    // later, which is exactly how orphan cards and duplicate rows appeared.
    if (jsonlFallback?.response && !isCoherentJsonlFirstPageResponse(jsonlFallback.response)) {
      jsonlFallback = null;
    }
    if (!jsonlFallback?.response) {
      const response = await awaitCanonicalOutcome(canonicalOutcomePromise);
      forgetCanonicalFirstPage(canonicalFirstPageCacheKey, canonicalOutcomePromise);
      return {
        source: "canonical",
        response: rebindThreadTurnsListResponseId(response, request.id),
        usesJsonl: false,
      };
    }

    let timeoutId = null;
    const deadline = new Promise((resolveDeadline) => {
      timeoutId = setTimeoutImpl(() => resolveDeadline({ deadline: true }), waitMs);
    });
    const first = await Promise.race([canonicalOutcomePromise, deadline]);
    if (timeoutId != null) {
      clearTimeoutImpl(timeoutId);
    }

    if (first?.ok && !isEmptyTurnsListResponse(first.response)) {
      if (shouldPreferJsonlFirstPage(first.response, jsonlFallback.response)) {
        const token = rememberHandoff(threadId, canonicalOutcomePromise, jsonlFallback);
        return {
          source: "jsonl",
          response: buildJsonlCanonicalHandoffResponse(
            jsonlFallback.response,
            request.id,
            token,
            firstTurnsListTurnId(jsonlFallback.response)
          ),
          usesJsonl: true,
        };
      }
      forgetCanonicalFirstPage(canonicalFirstPageCacheKey, canonicalOutcomePromise);
      return {
        source: "canonical",
        response: rebindThreadTurnsListResponseId(first.response, request.id),
        usesJsonl: false,
        jsonlFallback,
      };
    }

    const token = rememberHandoff(threadId, canonicalOutcomePromise, jsonlFallback);
    return {
      source: "jsonl",
      response: buildJsonlCanonicalHandoffResponse(
        jsonlFallback.response,
        request.id,
        token,
        firstTurnsListTurnId(jsonlFallback.response)
      ),
      usesJsonl: true,
    };
  }

  return { resolve };
}

function settleThreadTurnsListCanonicalOutcome(promise) {
  return Promise.resolve(promise).then(
    (response) => ({ ok: true, response }),
    (error) => ({ ok: false, error })
  );
}

function threadTurnsListHandoffDescriptor(cursor) {
  if (typeof cursor !== "string" || !cursor.startsWith(JSONL_CANONICAL_HANDOFF_CURSOR_PREFIX)) {
    return null;
  }
  const raw = cursor.slice(JSONL_CANONICAL_HANDOFF_CURSOR_PREFIX.length);
  const separatorIndex = raw.lastIndexOf(":");
  if (separatorIndex < 0) {
    return raw ? { anchorTurnId: "", token: raw } : null;
  }
  const token = raw.slice(separatorIndex + 1);
  if (!token) {
    return null;
  }
  let anchorTurnId = "";
  try {
    anchorTurnId = decodeURIComponent(raw.slice(0, separatorIndex));
  } catch {
    return null;
  }
  return { anchorTurnId, token };
}

// The bounded canonical page can read a busy mirrored run as closed for a
// beat, which used to flap the phone's running state. When the rollout mirror
// is actively tailing a real turn, ride its id along on the turn-state probe
// as an advisory field; history pages stay untouched.
function annotateTurnStateProbeWithMirrorActiveTurn(request, response, getMirrorActiveTurnId) {
  if (!isThreadTurnStateProbeRequest(request)) {
    return response;
  }
  const params = request?.params || {};
  const threadId = normalizeNonEmptyString(params.threadId)
    || normalizeNonEmptyString(params.thread_id);
  const mirrorActiveTurnId = threadId ? getMirrorActiveTurnId?.(threadId) : null;
  const result = response?.result;
  if (!mirrorActiveTurnId || !result || typeof result !== "object" || Array.isArray(result)) {
    return response;
  }
  // Page responses can come from the fast-page cache: never mutate a shared
  // object, or the annotation would outlive the mirror on later replays.
  return {
    ...response,
    result: {
      ...result,
      remodexMirrorActiveTurnId: mirrorActiveTurnId,
    },
  };
}

function canonicalThreadTurnsListRequest(request) {
  const params = { ...(request?.params || {}) };
  delete params.remodexRequireCanonical;
  delete params.remodexTurnStateOnly;
  if (params.cursor === JSONL_OLDER_HANDOFF_CURSOR || threadTurnsListHandoffDescriptor(params.cursor)) {
    delete params.cursor;
  }
  return { ...request, params };
}

function canonicalThreadTurnsListRequestShapeKey(canonicalRequest) {
  const params = canonicalRequest?.params || {};
  return JSON.stringify(sortJsonValueForCacheKey({
    threadId: threadIdFromRequestParams(params),
    params,
  }));
}

function sortJsonValueForCacheKey(value) {
  if (Array.isArray(value)) {
    return value.map(sortJsonValueForCacheKey);
  }
  if (!value || typeof value !== "object") {
    return value;
  }
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((key) => [key, sortJsonValueForCacheKey(value[key])])
  );
}

function rebindThreadTurnsListResponseId(response, requestId) {
  return response && typeof response === "object"
    ? { ...response, id: requestId }
    : response;
}

function buildJsonlCanonicalHandoffResponse(response, requestId, token, anchorTurnId = "") {
  const result = response?.result;
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return response;
  }
  return {
    ...response,
    id: requestId,
    result: {
      ...result,
      nextCursor: `${JSONL_CANONICAL_HANDOFF_CURSOR_PREFIX}${encodeURIComponent(anchorTurnId)}:${token}`,
      remodexJsonlFallback: true,
      remodexCanonicalHandoff: true,
    },
  };
}

function shouldPreferJsonlFirstPage(canonicalResponse, jsonlResponse) {
  const canonicalResult = canonicalResponse?.result;
  const jsonlResult = jsonlResponse?.result;
  const canonicalTurnsKey = findTurnsListResultKey(canonicalResult);
  const jsonlTurnsKey = findTurnsListResultKey(jsonlResult);
  if (!canonicalTurnsKey || !jsonlTurnsKey) {
    return false;
  }
  const jsonlTurn = jsonlResult[jsonlTurnsKey]?.[0];
  const jsonlTurnId = turnListTurnIdentifier(jsonlTurn);
  return Boolean(jsonlTurnId)
    && !canonicalResult[canonicalTurnsKey].some((turn) => turnListTurnIdentifier(turn) === jsonlTurnId)
    && shouldMergeLatestJsonlTurn(jsonlTurn);
}

function firstTurnsListTurnId(response) {
  const result = response?.result;
  const turnsKey = findTurnsListResultKey(result);
  return turnsKey ? turnListTurnIdentifier(result[turnsKey]?.[0]) : "";
}

function isCoherentJsonlFirstPageResponse(response) {
  const result = response?.result;
  const turnsKey = findTurnsListResultKey(result);
  const turns = turnsKey ? result[turnsKey] : null;
  if (!Array.isArray(turns) || turns.length === 0) {
    return false;
  }
  // A running turn must contain its materialized user opener. Otherwise an
  // orphan file card or assistant tail can win the fast-page race and later
  // be mistaken for a complete conversation. Explicit terminal turns are
  // allowed without a user item because older compacted/system turns can be
  // legitimately item-only.
  const newestTurn = turns[0];
  const items = Array.isArray(newestTurn?.items) ? newestTurn.items : null;
  if (!items) {
    return false;
  }
  if (items.length === 0) {
    return false;
  }
  const status = String(newestTurn?.status || "").replace(/[_-]/g, "").toLowerCase();
  const isExplicitTerminal = new Set(["completed", "failed", "aborted", "cancelled", "canceled", "interrupted"])
    .has(status);
  if (isExplicitTerminal) {
    return true;
  }
  return items.some((item) => {
    const role = String(item?.role || "").toLowerCase();
    const type = String(item?.type || "").replace(/[_-]/g, "").toLowerCase();
    return role === "user" || type === "usermessage";
  });
}

function threadTurnsListResponseContainsAnchor(response, anchorTurnId) {
  const result = response?.result;
  const turnsKey = findTurnsListResultKey(result);
  return Boolean(turnsKey) && result[turnsKey].some((turn) => (
    turnListTurnIdentifier(turn) === anchorTurnId
  ));
}

function alignThreadTurnsListResponseToAnchor(response, anchorTurnId) {
  const result = response?.result;
  const turnsKey = findTurnsListResultKey(result);
  if (!turnsKey) {
    return null;
  }
  const anchorIndex = result[turnsKey].findIndex((turn) => (
    turnListTurnIdentifier(turn) === anchorTurnId
  ));
  if (anchorIndex < 0) {
    return null;
  }
  if (anchorIndex === 0) {
    return response;
  }
  return {
    ...response,
    result: {
      ...result,
      [turnsKey]: result[turnsKey].slice(anchorIndex),
    },
  };
}

function startBridge({
  config: explicitConfig = null,
  printPairingQr = true,
  onPairingSession = null,
  onBridgeStatus = null,
} = {}) {
  const config = explicitConfig || readBridgeConfig();
  config.keepMacAwakeEnabled = config.keepMacAwakeEnabled === true;
  const bridgeWakeAssertion = createMacOSBridgeWakeAssertion({
    enabled: config.keepMacAwakeEnabled,
  });
  const relayBaseUrl = config.relayUrl.replace(/\/+$/, "");
  if (!relayBaseUrl) {
    console.error("[remodex] No relay URL configured.");
    console.error("[remodex] In a source checkout, run ./run-local-remodex.sh or set REMODEX_RELAY.");
    process.exit(1);
  }

  let deviceState;
  try {
    deviceState = loadOrCreateBridgeDeviceState();
  } catch (error) {
    console.error(`[remodex] ${(error && error.message) || "Failed to load the saved bridge pairing state."}`);
    process.exit(1);
  }
  const relaySession = resolveBridgeRelaySession(deviceState);
  deviceState = relaySession.deviceState;
  let lastIOSAppCompatibilityWarning = "";
  const cachedIOSAppCompatibilityWarning = buildCachedIOSAppCompatibilityWarning({
    bridgeVersion: bridgePackageVersion,
    iosAppVersion: deviceState.lastSeenPhoneAppVersion,
  });
  logIOSAppCompatibilityWarning(cachedIOSAppCompatibilityWarning);
  const sessionId = relaySession.sessionId;
  const relaySessionUrl = `${relayBaseUrl}/${sessionId}`;
  const notificationSecret = randomBytes(24).toString("hex");
  const desktopRefresher = new CodexDesktopRefresher({
    enabled: config.refreshEnabled,
    // With IPC live sync streaming content, deep-link refreshes are only needed
    // to navigate Desktop onto the phone-driven thread, not to reload content.
    navigationOnly: config.desktopIpcLiveSyncEnabled,
    debounceMs: config.refreshDebounceMs,
    refreshCommand: config.refreshCommand,
    bundleId: config.codexBundleId,
    appPath: config.codexAppPath,
  });
  const pushServiceClient = createPushNotificationServiceClient({
    baseUrl: config.pushServiceUrl,
    sessionId,
    notificationSecret,
  });
  const notificationsHandler = createNotificationsHandler({
    pushServiceClient,
  });
  const pushNotificationTracker = createPushNotificationTracker({
    sessionId,
    pushServiceClient,
    previewMaxChars: config.pushPreviewMaxChars,
  });
  const readBridgePackageVersionStatus = createBridgePackageVersionStatusReader();

  // Keep the local Codex runtime alive across transient relay disconnects.
  let socket = null;
  let isShuttingDown = false;
  let reconnectAttempt = 0;
  let reconnectTimer = null;
  let relayWatchdogTimer = null;
  let lastRelayActivityAt = 0;
  let lastConnectionStatus = null;
  let codexLaunchState = config.codexEndpoint ? "connected" : "starting";
  let codexHandshakeState = config.codexEndpoint ? "warm" : "cold";
  const forwardedInitializeRequestIds = new Set();
  const bridgeManagedCodexRequestWaiters = new Map();
  const forwardedRequestMethodsById = new Map();
  const relaySanitizedResponseMethodsById = new Map();
  const desktopIpcLiveOwnerObservedInboundKeys = new Set();
  const jsonlTurnsListRolloutCacheByThread = new Map();
  const jsonlTurnsListRolloutMissCacheByThread = new Map();
  const threadTurnsListFastPageCoordinator = createThreadTurnsListFastPageCoordinator();
  const threadRuntimeSettingsStore = createThreadRuntimeSettingsStore();
  const trackedForwardedRequestMethods = new Set([
    "account/login/start",
    "account/login/cancel",
    "account/logout",
  ]);
  const relaySanitizedRequestMethods = new Set([
    "thread/list",
    "thread/read",
    "thread/resume",
    "thread/turns/list",
  ]);
  const forwardedRequestMethodTTLms = 2 * 60_000;
  const pendingAuthLogin = {
    loginId: null,
    authUrl: null,
    requestId: null,
    startedAt: 0,
  };
  let activePhoneSummary = null;
  const secureTransport = createBridgeSecureTransport({
    sessionId,
    relayUrl: relayBaseUrl,
    deviceState,
    displayName: os.hostname(),
    onTrustedPhoneUpdate(nextDeviceState) {
      deviceState = nextDeviceState;
      sendRelayRegistrationUpdate(nextDeviceState);
    },
    onSecureSessionReady(session) {
      activePhoneSummary = buildActivePhoneSummary(session, deviceState);
      const lastPublishedBridgeStatus = bridgeStatusPublisher.latest();
      if (lastPublishedBridgeStatus) {
        publishBridgeStatus(lastPublishedBridgeStatus);
      }
    },
  });
  // Keeps one stable sender identity across reconnects so buffered replay state
  // reflects what actually made it onto the current relay socket.
  function sendRelayWireMessage(wireMessage) {
    if (socket?.readyState !== WebSocket.OPEN) {
      return false;
    }

    socket.send(wireMessage);
    return true;
  }
  // Only the spawned local runtime needs rollout mirroring; a real endpoint
  // already provides the authoritative live stream for resumed threads.
  const rolloutLiveMirror = !config.codexEndpoint
    ? createRolloutLiveMirrorController({
      sendApplicationResponse,
      // One live source per thread. The follower keeps fresh/idle Desktop state
      // authoritative, but yields an active cache that stopped broadcasting;
      // a later Desktop snapshot is announced as a new source epoch so the
      // phone performs canonical repair instead of mixing both mirrors.
      shouldSuppressThread: (threadId) => shouldSuppressRolloutMirrorForThread(
        threadId,
        { desktopIpcActionFollower, desktopIpcLiveOwner }
      ),
    })
    : null;
  const desktopIpcActionFollower = !config.codexEndpoint
    ? createDesktopIpcActionFollower({
      sendApplicationResponse,
      readConversationState: async (threadId) => seedConversationStateFromThreadRead(
        await sendCodexRequest("thread/read", { threadId })
      ),
      forwardToLocalCodex: (rawMessage) => {
        observeDesktopIpcLiveOwnerInbound(rawMessage);
        forwardInboundRequestToCodex(rawMessage);
      },
      // Threads streamed by the bridge's own app-server must never be held,
      // served from Desktop echoes, or routed over the IPC bus.
      isLocallyOwnedThread: (threadId) => Boolean(desktopIpcLiveOwner?.isThreadOwned(threadId)),
      normalizeTurnStartParams: normalizeTurnStartParamsForCodex,
      runtimeSettingsStore: threadRuntimeSettingsStore,
      socketPath: config.desktopIpcSocketPath || undefined,
      snapshotDebounceMs: config.desktopIpcSnapshotDebounceMs,
    })
    : null;
  const desktopIpcLiveOwner = !config.codexEndpoint
    ? createDesktopIpcLiveOwner({
      enabled: config.desktopIpcLiveSyncEnabled !== false,
      sendApplicationResponse,
      sendCodexRequest,
      sendRawCodexMessage: (rawMessage) => codex.send(rawMessage),
      normalizeTurnStartParams: normalizeTurnStartParamsForCodex,
      runtimeSettingsStore: threadRuntimeSettingsStore,
      socketPath: config.desktopIpcSocketPath || undefined,
      snapshotDebounceMs: config.desktopIpcSnapshotDebounceMs,
    })
    : null;
  let contextUsageWatcher = null;
  let watchedContextUsageKey = null;

  const codex = createCodexTransport({
    endpoint: config.codexEndpoint,
    env: process.env,
    appPath: config.codexAppPath,
    logPrefix: "[remodex]",
  });
  const voiceHandler = createVoiceHandler({
    sendCodexRequest,
    logPrefix: "[remodex]",
  });
  const bridgeStatusPublisher = createBridgeStatusPublisher({
    onBridgeStatus,
    getCodexLaunchState: () => codexLaunchState,
  });
  bridgeStatusPublisher.startHeartbeat({
    shouldPublish: () => !isShuttingDown,
    getLastRelayActivityAt: () => lastRelayActivityAt,
  });
  publishBridgeStatus({
    state: "starting",
    connectionStatus: "starting",
    pid: process.pid,
    lastError: "",
  });

  codex.onError((error) => {
    codexLaunchState = "error";
    publishBridgeStatus({
      state: "error",
      connectionStatus: "error",
      pid: process.pid,
      lastError: error.message,
    });
    if (config.codexEndpoint) {
      console.error(`[remodex] Failed to connect to Codex endpoint: ${config.codexEndpoint}`);
    } else {
      console.error("[remodex] Failed to start `codex app-server`.");
      console.error(`[remodex] Launch command: ${codex.describe()}`);
      console.error("[remodex] Make sure the Codex CLI is installed, authenticated, and launchable on this OS.");
    }
    console.error(error.message);
    process.exit(1);
  });
  // Marks the local Codex runtime as launchable before relay/network recovery updates.
  codex.onStarted(() => {
    codexLaunchState = "connected";
    const lastPublishedBridgeStatus = bridgeStatusPublisher.latest();
    if (!lastPublishedBridgeStatus) {
      return;
    }

    publishBridgeStatus(lastPublishedBridgeStatus);
  });

  function clearReconnectTimer() {
    if (!reconnectTimer) {
      return;
    }

    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  // Tracks relay liveness locally so sleep/wake zombie sockets can be force-reconnected.
  function markRelayActivity() {
    lastRelayActivityAt = Date.now();
  }

  function clearRelayWatchdog() {
    if (!relayWatchdogTimer) {
      return;
    }

    clearInterval(relayWatchdogTimer);
    relayWatchdogTimer = null;
  }

  function prepareBridgeShutdown() {
    isShuttingDown = true;
    bridgeWakeAssertion.stop();
    clearReconnectTimer();
    clearRelayWatchdog();
    bridgeStatusPublisher.stopHeartbeat();
    stopContextUsageWatcher();
    rolloutLiveMirror?.stopAll();
    desktopIpcActionFollower?.stopAll();
    desktopIpcLiveOwner?.stopAll();
  }

  function stopBridge() {
    if (isShuttingDown) {
      return;
    }

    prepareBridgeShutdown();
    desktopRefresher.handleTransportReset();
    failBridgeManagedCodexRequests(new Error("Bridge stopped before the request completed."));
    forwardedRequestMethodsById.clear();

    if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
      socket.close();
    }
    codex.shutdown();
  }

  function startRelayWatchdog(trackedSocket) {
    clearRelayWatchdog();
    markRelayActivity();

    relayWatchdogTimer = setInterval(() => {
      if (isShuttingDown || socket !== trackedSocket) {
        clearRelayWatchdog();
        return;
      }

      if (trackedSocket.readyState !== WebSocket.OPEN) {
        return;
      }

      if (hasRelayConnectionGoneStale(lastRelayActivityAt)) {
        console.warn("[remodex] relay heartbeat stalled; forcing reconnect");
        logConnectionStatus("disconnected");
        trackedSocket.terminate();
        return;
      }

      try {
        trackedSocket.ping();
      } catch {
        trackedSocket.terminate();
      }
    }, RELAY_WATCHDOG_PING_INTERVAL_MS);
    relayWatchdogTimer.unref?.();
  }

  // Keeps npm start output compact by emitting only high-signal connection states.
  function logConnectionStatus(status) {
    if (lastConnectionStatus === status) {
      return;
    }

    lastConnectionStatus = status;
    if (status !== "connected") {
      activePhoneSummary = null;
    }
    publishBridgeStatus({
      state: "running",
      connectionStatus: status,
      pid: process.pid,
      lastError: "",
    });
    console.log(`[remodex] ${status}`);
  }

  // Retries the relay socket while preserving the active Codex process and session id.
  function scheduleRelayReconnect(closeCode) {
    if (isShuttingDown) {
      return;
    }

    if (closeCode === 4000 || closeCode === 4001) {
      logConnectionStatus("disconnected");
      shutdown(codex, () => socket, prepareBridgeShutdown);
      return;
    }

    if (reconnectTimer) {
      return;
    }

    reconnectAttempt += 1;
    const baseDelayMs = Math.min(1_000 * reconnectAttempt, 5_000);
    const jitterMs = Math.floor(Math.random() * Math.min(baseDelayMs, 2_000));
    const delayMs = baseDelayMs + jitterMs;
    logConnectionStatus("connecting");
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connectRelay();
    }, delayMs);
  }

  function connectRelay() {
    if (isShuttingDown) {
      return;
    }

    logConnectionStatus("connecting");
    const nextSocket = new WebSocket(relaySessionUrl, {
      perMessageDeflate: {
        zlibDeflateOptions: { level: 6 },
        threshold: 256,
        concurrencyLimit: 4,
      },
      // The relay uses this per-session secret to authenticate the first push registration.
      headers: {
        "x-role": "mac",
        "x-notification-secret": notificationSecret,
        ...buildMacRegistrationHeaders(deviceState, pairingSession),
      },
    });
    socket = nextSocket;

    nextSocket.on("open", () => {
      markRelayActivity();
      clearReconnectTimer();
      reconnectAttempt = 0;
      startRelayWatchdog(nextSocket);
      logConnectionStatus("connected");
      secureTransport.bindLiveSendWireMessage(sendRelayWireMessage);
      sendRelayRegistrationUpdate(deviceState);
    });

    nextSocket.on("message", (data) => {
      markRelayActivity();
      const message = typeof data === "string" ? data : data.toString("utf8");
      if (secureTransport.handleIncomingWireMessage(message, {
        sendControlMessage(controlMessage) {
          if (nextSocket.readyState === WebSocket.OPEN) {
            nextSocket.send(JSON.stringify(controlMessage));
          }
        },
        onApplicationMessage(plaintextMessage) {
          handleApplicationMessage(plaintextMessage);
        },
      })) {
        return;
      }
    });

    nextSocket.on("ping", () => {
      markRelayActivity();
    });

    nextSocket.on("pong", () => {
      markRelayActivity();
    });

    nextSocket.on("close", (code) => {
      if (socket === nextSocket) {
        clearRelayWatchdog();
      }
      logConnectionStatus("disconnected");
      if (socket === nextSocket) {
        socket = null;
      }
      stopContextUsageWatcher();
      // Relay reconnects are transport-only: keep local live observers running
      // so their output can enter secure replay and catch up on the next resume.
      desktopRefresher.handleTransportReset();
      scheduleRelayReconnect(code);
    });

    nextSocket.on("error", () => {
      if (socket === nextSocket) {
        clearRelayWatchdog();
      }
      logConnectionStatus("disconnected");
    });
  }

  const pairingPayload = secureTransport.createPairingPayload();
  const pairingSession = {
    pairingPayload,
    pairingCode: createShortPairingCode({ length: SHORT_PAIRING_CODE_LENGTH }),
  };
  onPairingSession?.(pairingSession);
  if (printPairingQr) {
    printQR(pairingSession);
  }
  pushServiceClient.logUnavailable();
  connectRelay();

  codex.onMessage((message) => {
    // Streaming deltas make this the hottest path in the bridge: parse the
    // envelope once and share the read-only object with every observer.
    const parsedMessage = parseBridgeMessage(message);
    if (handleBridgeManagedCodexResponse(message, parsedMessage)) {
      return;
    }
    updatePendingAuthLoginFromCodexMessage(message, parsedMessage);
    trackCodexHandshakeState(message, parsedMessage);
    desktopRefresher.handleOutbound(message, parsedMessage);
    desktopIpcLiveOwner?.observeOutbound(message, parsedMessage);
    pushNotificationTracker.handleOutbound(message, parsedMessage);
    rememberThreadFromMessage("codex", message, parsedMessage);
    secureTransport.queueOutboundApplicationMessage(
      sanitizeRelayBoundCodexMessage(message, parsedMessage),
      sendRelayWireMessage
    );
  });

  codex.onClose(() => {
    const wasShuttingDown = isShuttingDown;
    clearRelayWatchdog();
    bridgeStatusPublisher.stopHeartbeat();
    logConnectionStatus("disconnected");
    const lastError = wasShuttingDown
      ? ""
      : "Codex transport closed unexpectedly.";
    publishBridgeStatus({
      state: wasShuttingDown ? "stopped" : "error",
      connectionStatus: "disconnected",
      pid: process.pid,
      lastError,
    });
    if (!wasShuttingDown) {
      console.error(`[remodex] ${lastError}`);
      process.exitCode = 1;
    }
    prepareBridgeShutdown();
    desktopRefresher.handleTransportReset();
    failBridgeManagedCodexRequests(new Error("Codex transport closed before the bridge request completed."));
    forwardedRequestMethodsById.clear();
    if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
      socket.close();
    }
  });

  process.on("SIGINT", () => shutdown(codex, () => socket, prepareBridgeShutdown));
  process.on("SIGTERM", () => shutdown(codex, () => socket, prepareBridgeShutdown));

  // Routes decrypted app payloads through the same bridge handlers as before.
  function handleApplicationMessage(rawMessage) {
    const parsedMessage = parseBridgeMessage(rawMessage);
    if (handleBridgeManagedHandshakeMessage(rawMessage, sendApplicationResponse, parsedMessage)) {
      return;
    }
    if (handleBridgeManagedAccountRequest(rawMessage, sendApplicationResponse, parsedMessage)) {
      return;
    }
    if (voiceHandler.handleVoiceRequest(rawMessage, sendApplicationResponse, parsedMessage)) {
      return;
    }
    if (handleThreadContextRequest(rawMessage, sendApplicationResponse, parsedMessage)) {
      return;
    }
    if (handleWorkspaceRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleProjectRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handlePetRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (notificationsHandler.handleNotificationsRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    if (handleDesktopRequest(rawMessage, sendApplicationResponse, {
      bundleId: config.codexBundleId,
      appPath: config.codexAppPath,
      readBridgePreferences,
      updateBridgePreferences,
      updateBridgePackageAndRestart,
    })) {
      return;
    }
    if (handleGitRequest(rawMessage, sendApplicationResponse, {
      codexAppPath: config.codexAppPath,
      onThreadNameSet: sendThreadNameUpdatedNotification,
    })) {
      return;
    }
    desktopRefresher.handleInbound(rawMessage, parsedMessage);
    rolloutLiveMirror?.observeInbound(rawMessage, parsedMessage);
    // Track the request method BEFORE follower interception: responses the
    // follower serves from projected Desktop state must hit the same relay
    // sanitize/trim budget as app-server responses, or heavy threads ship as
    // one oversized frame and kill the phone's websocket (EMSGSIZE).
    rememberForwardedRequestMethod(rawMessage);
    if (desktopIpcActionFollower?.observeInbound(rawMessage, parsedMessage)) {
      return;
    }
    observeDesktopIpcLiveOwnerInbound(rawMessage, parsedMessage);
    if (handleBridgeManagedThreadTurnsListRequest(rawMessage, sendApplicationResponse)) {
      return;
    }
    forwardInboundRequestToCodex(rawMessage);
  }

  function forwardInboundRequestToCodex(rawMessage) {
    const codexRequest = normalizeTurnStartForCodex(rawMessage);
    rememberForwardedRequestMethod(rawMessage);
    rememberThreadFromMessage("phone", codexRequest);
    codex.send(codexRequest);
  }

  // Held Desktop-ownership probes can later fall back locally, so observe each
  // phone request at most once in the live owner even if it passes both paths.
  function observeDesktopIpcLiveOwnerInbound(rawMessage, parsedMessage = null) {
    if (!desktopIpcLiveOwner) {
      return;
    }
    const inboundKey = desktopIpcLiveOwnerInboundKey(rawMessage, parsedMessage);
    if (inboundKey) {
      if (desktopIpcLiveOwnerObservedInboundKeys.has(inboundKey)) {
        return;
      }
      desktopIpcLiveOwnerObservedInboundKeys.add(inboundKey);
      evictOldestEntries(desktopIpcLiveOwnerObservedInboundKeys, FORWARDED_REQUEST_METHODS_MAX_SIZE);
    }
    desktopIpcLiveOwner.observeInbound(rawMessage, parsedMessage);
  }

  function desktopIpcLiveOwnerInboundKey(rawMessage, parsedMessage = null) {
    const parsed = parsedMessage ?? safeParseJSON(rawMessage);
    const method = typeof parsed?.method === "string" ? parsed.method : "";
    if (!method || parsed?.id == null) {
      return "";
    }
    // extractThreadId only understands turn/thread start and completion params;
    // archive, steer, interrupt, and compact requests need the generic fields so
    // same-id requests for different threads never share a dedupe key.
    const threadId = extractThreadId(method, parsed.params)
      || readString(parsed?.params?.threadId)
      || readString(parsed?.params?.thread_id)
      || readString(parsed?.params?.conversationId)
      || readString(parsed?.params?.conversation_id)
      || "";
    return `${method}:${threadId}:${String(parsed.id)}`;
  }

  function parseBridgeMessage(rawMessage) {
    try {
      return JSON.parse(rawMessage);
    } catch {
      return null;
    }
  }

  // Encrypts bridge-generated responses instead of letting the relay see plaintext.
  function sendApplicationResponse(rawMessage) {
    secureTransport.queueOutboundApplicationMessage(
      sanitizeRelayBoundCodexMessage(rawMessage),
      sendRelayWireMessage
    );
  }

  // Mirrors accepted local renames back to the phone using the existing push-event shape.
  function sendThreadNameUpdatedNotification(result) {
    const threadId = readString(result?.threadId || result?.thread_id);
    const name = readString(result?.name || result?.title);
    if (!threadId || !name) {
      return;
    }

    sendApplicationResponse(JSON.stringify({
      method: "thread/name/updated",
      params: {
        threadId,
        thread_id: threadId,
        name,
        title: name,
      },
    }));
  }

  function handleBridgeManagedThreadTurnsListRequest(rawMessage, sendResponse = sendApplicationResponse) {
    const request = parseAdaptiveThreadTurnsListRequest(rawMessage);
    if (!request) {
      return false;
    }

    rememberThreadFromMessage("phone", rawMessage);
    (async () => {
      let didRespond = false;
      const respondOnce = (payload) => {
        if (didRespond) {
          return;
        }
        didRespond = true;
        sendResponse(payload);
      };
      try {
        const selection = await threadTurnsListFastPageCoordinator.resolve(request, {
          fetchCanonical: (canonicalRequest) => fetchAdaptiveThreadTurnsListForRelay(canonicalRequest, {
            fetchPage: (params) => sendCodexRequest("thread/turns/list", params),
          }),
          readJsonl: (jsonlRequest) => maybeBuildJsonlThreadTurnsListFallback(jsonlRequest, null),
        });
        let responsePayload = selection.response;
        if (selection.source === "canonical" && selection.jsonlFallback?.response?.result) {
          responsePayload = maybeMergeLatestJsonlTurnIntoTurnsListResponse(
            request,
            selection.response,
            selection.jsonlFallback.response.result
          ) || selection.response;
        }
        sendBridgeManagedThreadTurnsListResponse(request, responsePayload, respondOnce, {
          skipJsonlArtifactAugmentation: selection.usesJsonl,
        });
      } catch (error) {
        const jsonlFallback = maybeBuildJsonlThreadTurnsListFallback(request, null);
        if (jsonlFallback?.response && isCoherentJsonlFirstPageResponse(jsonlFallback.response)) {
          sendBridgeManagedThreadTurnsListResponse(request, jsonlFallback.response, respondOnce, {
            skipJsonlArtifactAugmentation: true,
          });
          return;
        }
        respondOnce(createJsonRpcErrorResponse(
          request.id,
          error,
          "thread_turns_list_failed"
        ));
      }
    })();

    return true;
  }

  function sendBridgeManagedThreadTurnsListResponse(request, response, sendResponse, {
    skipJsonlArtifactAugmentation = false,
  } = {}) {
    response = annotateTurnStateProbeWithMirrorActiveTurn(
      request,
      response,
      (threadId) => rolloutLiveMirror?.getActiveTurnId(threadId) || null
    );
    const finalSanitizeContext = buildThreadTurnsListRelaySanitizeContext(request, {
      skipJsonlArtifactAugmentation,
    });
    relaySanitizedResponseMethodsById.set(String(request.id), {
      method: "thread/turns/list",
      ...finalSanitizeContext,
      createdAt: Date.now(),
    });
    sendResponse(sanitizeThreadHistoryImagesForRelay(
      JSON.stringify(response),
      "thread/turns/list",
      finalSanitizeContext
    ));
  }

  function maybeBuildJsonlThreadTurnsListFallback(request, response) {
    const params = request?.params || {};
    const threadId = normalizeNonEmptyString(params.threadId)
      || normalizeNonEmptyString(params.thread_id);
    if (!threadId || hasRelayCursor(params.cursor) || params.remodexRequireCanonical === true) {
      return null;
    }

    try {
      const responseIsEmpty = response == null || isEmptyTurnsListResponse(response);
      const rolloutPath = resolveJsonlTurnsListRolloutPathForFallback({
        threadId,
        responseIsEmpty,
        readCachedPath: readCachedJsonlTurnsListRolloutPath,
        findAndCachePath: findAndCacheJsonlTurnsListRolloutPath,
      });
      if (!rolloutPath) {
        return null;
      }

      // A first page is the local baseline for a newly opened thread. Honor a
      // caller's larger request, but never manufacture the old one-turn tail:
      // it has no room to preserve surrounding history while canonical data is
      // still catching up.
      const requestedLimit = Number.isInteger(params.limit) && params.limit > 0
        ? params.limit
        : RELAY_TURNS_LIST_MAX_INITIAL_LIMIT;
      const firstPageLimit = params.cursor == null
        ? Math.max(requestedLimit, RELAY_TURNS_LIST_MAX_INITIAL_LIMIT)
        : requestedLimit;
      const result = readThreadTurnsListPageFromSessionJsonl(rolloutPath, {
        threadId,
        limit: firstPageLimit,
        maxLimit: RELAY_TURNS_LIST_MAX_INITIAL_LIMIT,
        cursor: params.cursor,
      });
      const turnsKey = findTurnsListResultKey(result);
      if (!turnsKey || result[turnsKey].length === 0) {
        return null;
      }

      if (!responseIsEmpty) {
        const mergedResponse = maybeMergeLatestJsonlTurnIntoTurnsListResponse(request, response, result);
        return mergedResponse ? { response: mergedResponse, usesJsonl: true } : null;
      }

      return {
        response: {
          id: request.id,
          result,
        },
        usesJsonl: true,
      };
    } catch (error) {
      jsonlTurnsListRolloutCacheByThread.delete(threadId);
      console.warn(`[remodex] thread/turns/list jsonl fallback failed: ${error.message}`);
      return null;
    }
  }

  function findAndCacheJsonlTurnsListRolloutPath(threadId) {
    if (hasFreshJsonlTurnsListRolloutMiss(threadId)) {
      return "";
    }

    const rolloutPath = findRecentRolloutFileForContextRead(resolveSessionsRoot(), { threadId });
    if (rolloutPath) {
      jsonlTurnsListRolloutMissCacheByThread.delete(threadId);
      jsonlTurnsListRolloutCacheByThread.set(threadId, {
        rolloutPath,
        cachedAt: Date.now(),
      });
    } else {
      jsonlTurnsListRolloutMissCacheByThread.set(threadId, Date.now());
    }
    return rolloutPath;
  }

  function readCachedJsonlTurnsListRolloutPath(threadId) {
    const cached = jsonlTurnsListRolloutCacheByThread.get(threadId);
    if (!cached) {
      return "";
    }
    if (Date.now() - cached.cachedAt > RELAY_JSONL_TURNS_LIST_CACHE_TTL_MS) {
      jsonlTurnsListRolloutCacheByThread.delete(threadId);
      return "";
    }
    // Non-empty app-server pages only consult this positive cache to avoid
    // walking the sessions tree during ordinary pagination.
    return cached.rolloutPath;
  }

  function hasFreshJsonlTurnsListRolloutMiss(threadId) {
    const missedAt = jsonlTurnsListRolloutMissCacheByThread.get(threadId);
    if (!missedAt) {
      return false;
    }
    if (Date.now() - missedAt <= RELAY_JSONL_TURNS_LIST_CACHE_TTL_MS) {
      return true;
    }
    jsonlTurnsListRolloutMissCacheByThread.delete(threadId);
    return false;
  }

  // ─── Bridge-owned auth snapshot ─────────────────────────────

  // Handles the bridge-owned auth status wrappers without exposing tokens to the phone.
  // This dispatcher stays synchronous so non-account messages can continue down the normal routing chain.
  function handleBridgeManagedAccountRequest(rawMessage, sendResponse, parsedMessage = null) {
    const parsed = parsedMessage || parseBridgeMessage(rawMessage);
    if (!parsed) {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method !== "account/status/read"
      && method !== "getAuthStatus"
      && method !== "account/login/openOnMac"
      && method !== "voice/resolveAuth") {
      return false;
    }

    const requestId = parsed.id;
    const shouldRespond = requestId != null;
    readBridgeManagedAccountResult(method, parsed.params || {})
      .then((result) => {
        if (shouldRespond) {
          sendResponse(JSON.stringify({ id: requestId, result }));
        }
      })
      .catch((error) => {
        if (shouldRespond) {
          sendResponse(createJsonRpcErrorResponse(requestId, error, "auth_status_failed"));
        }
      });

    return true;
  }

  // Resolves bridge-owned account helpers like status reads and Mac-side browser opening.
  async function readBridgeManagedAccountResult(method, params) {
    switch (method) {
      case "account/status/read":
      case "getAuthStatus":
        return readSanitizedAuthStatus();
      case "account/login/openOnMac":
        return openPendingAuthLoginOnMac(params);
      case "voice/resolveAuth":
        return resolveVoiceAuth(sendCodexRequest);
      default:
        throw new Error(`Unsupported bridge-managed account method: ${method}`);
    }
  }

  // Combines account/read + getAuthStatus into one safe snapshot for the phone UI.
  // The two RPCs are settled independently so one transient failure does not hide the other.
  async function readSanitizedAuthStatus() {
    const [accountReadResult, authStatusResult, bridgeVersionInfoResult] = await Promise.allSettled([
      sendCodexRequest("account/read", {
        refreshToken: false,
      }),
      sendCodexRequest("getAuthStatus", {
        includeToken: true,
        refreshToken: true,
      }),
      readBridgePackageVersionStatus(),
    ]);

    return composeSanitizedAuthStatusFromSettledResults({
      accountReadResult: accountReadResult.status === "fulfilled"
        ? {
          status: "fulfilled",
          value: normalizeAccountRead(accountReadResult.value),
        }
        : accountReadResult,
      authStatusResult,
      loginInFlight: Boolean(pendingAuthLogin.loginId),
      bridgeVersionInfo: bridgeVersionInfoResult.status === "fulfilled"
        ? bridgeVersionInfoResult.value
        : null,
      transportMode: codex.mode,
      hostPlatform: process.platform,
    });
  }

  // Opens the ChatGPT sign-in URL in the default browser on the bridge Mac.
  async function openPendingAuthLoginOnMac(params) {
    if (process.platform !== "darwin") {
      const error = new Error("Opening ChatGPT sign-in on the bridge is only supported on macOS.");
      error.errorCode = "unsupported_platform";
      throw error;
    }

    const authUrl = readString(params?.authUrl) || pendingAuthLogin.authUrl;
    if (!authUrl) {
      const error = new Error("No pending ChatGPT sign-in URL is available on this bridge.");
      error.errorCode = "missing_auth_url";
      throw error;
    }

    await execFileAsync("open", [authUrl], { timeout: 15_000 });
    return {
      success: true,
      openedOnMac: true,
    };
  }

  function normalizeAccountRead(payload) {
    if (!payload || typeof payload !== "object") {
      return {
        account: null,
        requiresOpenaiAuth: true,
      };
    }

    return {
      account: payload.account && typeof payload.account === "object" ? payload.account : null,
      requiresOpenaiAuth: Boolean(payload.requiresOpenaiAuth),
    };
  }

  function createJsonRpcErrorResponse(requestId, error, defaultErrorCode) {
    return JSON.stringify({
      id: requestId,
      error: {
        code: -32000,
        message: error?.userMessage || error?.message || "Bridge request failed.",
        data: {
          errorCode: error?.errorCode || defaultErrorCode,
        },
      },
    });
  }

  function rememberForwardedRequestMethod(rawMessage) {
    const parsed = safeParseJSON(rawMessage);
    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    const requestId = parsed?.id;
    if (!method || requestId == null) {
      return;
    }

    pruneExpiredForwardedRequestMethods();
    if (trackedForwardedRequestMethods.has(method)) {
      forwardedRequestMethodsById.set(String(requestId), {
        method,
        createdAt: Date.now(),
      });
    }
    if (relaySanitizedRequestMethods.has(method)) {
      const trackedRequest = {
        method,
        threadId: method === "thread/turns/list" || method === "thread/read" || method === "thread/resume"
          ? threadIdFromRequestParams(parsed.params)
          : "",
        createdAt: Date.now(),
      };
      if (method === "thread/turns/list") {
        trackedRequest.skipJsonlArtifactAugmentation = false;
      }
      relaySanitizedResponseMethodsById.set(String(requestId), trackedRequest);
    }
  }

  // Replaces huge inline desktop-history images with lightweight references before relay encryption.
  function sanitizeRelayBoundCodexMessage(rawMessage, parsedMessage = null) {
    pruneExpiredForwardedRequestMethods();
    let normalizedMessage = normalizeRelayBoundJsonRpcMessage(rawMessage, {
      pendingRequestMethodsById: relaySanitizedResponseMethodsById,
      parsedMessage,
    });
    if (!normalizedMessage) {
      return null;
    }

    // Streaming deltas hit this path dozens of times per second; when the
    // envelope passed through normalization untouched, reuse the parse the
    // caller already paid for instead of re-parsing the same bytes.
    let parsed = normalizedMessage === rawMessage && parsedMessage
      ? parsedMessage
      : safeParseJSON(normalizedMessage);
    const sanitizedLiveMessage = sanitizeLiveUserNotification(parsed);
    if (!sanitizedLiveMessage) {
      return null;
    }
    if (sanitizedLiveMessage !== parsed) {
      parsed = sanitizedLiveMessage;
      normalizedMessage = JSON.stringify(parsed);
    }
    const responseId = parsed?.id;
    if (responseId == null) {
      return sanitizeLiveGeneratedImageMessageForRelay(normalizedMessage);
    }

    const trackedRequest = relaySanitizedResponseMethodsById.get(String(responseId));
    if (!trackedRequest) {
      return normalizedMessage;
    }
    relaySanitizedResponseMethodsById.delete(String(responseId));

    if (trackedRequest.method === "thread/list"
      || trackedRequest.method === "thread/read"
      || trackedRequest.method === "thread/resume") {
      threadRuntimeSettingsStore.enrichResponse(trackedRequest.method, parsed);
      normalizedMessage = JSON.stringify(parsed);
    }

    return sanitizeThreadHistoryImagesForRelay(normalizedMessage, trackedRequest.method, trackedRequest);
  }

  function updatePendingAuthLoginFromCodexMessage(rawMessage, parsedMessage = null) {
    pruneExpiredForwardedRequestMethods();
    const parsed = parsedMessage ?? safeParseJSON(rawMessage);
    const responseId = parsed?.id;
    if (responseId != null) {
      const trackedRequest = forwardedRequestMethodsById.get(String(responseId));
      if (trackedRequest) {
        forwardedRequestMethodsById.delete(String(responseId));
        const requestMethod = trackedRequest.method;

        if (requestMethod === "account/login/start") {
          const loginId = readString(parsed?.result?.loginId);
          const authUrl = readString(parsed?.result?.authUrl);
          if (!loginId || !authUrl) {
            clearPendingAuthLogin();
            return;
          }
          pendingAuthLogin.loginId = loginId || null;
          pendingAuthLogin.authUrl = authUrl || null;
          pendingAuthLogin.requestId = String(responseId);
          pendingAuthLogin.startedAt = Date.now();
          return;
        }

        if (requestMethod === "account/login/cancel" || requestMethod === "account/logout") {
          clearPendingAuthLogin();
          return;
        }
      }
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method === "account/login/completed") {
      clearPendingAuthLogin();
      return;
    }

    if (method === "account/updated") {
      clearPendingAuthLogin();
    }
  }

  function clearPendingAuthLogin() {
    pendingAuthLogin.loginId = null;
    pendingAuthLogin.authUrl = null;
    pendingAuthLogin.requestId = null;
    pendingAuthLogin.startedAt = 0;
  }

  function pruneExpiredForwardedRequestMethods(now = Date.now()) {
    const expiredForwarded = [];
    for (const [requestId, trackedRequest] of forwardedRequestMethodsById.entries()) {
      if (!trackedRequest || (now - trackedRequest.createdAt) >= forwardedRequestMethodTTLms) {
        expiredForwarded.push(requestId);
      }
    }
    for (const id of expiredForwarded) {
      forwardedRequestMethodsById.delete(id);
    }

    const expiredSanitized = [];
    for (const [requestId, trackedRequest] of relaySanitizedResponseMethodsById.entries()) {
      if (!trackedRequest || (now - trackedRequest.createdAt) >= forwardedRequestMethodTTLms) {
        expiredSanitized.push(requestId);
      }
    }
    for (const id of expiredSanitized) {
      relaySanitizedResponseMethodsById.delete(id);
    }

    evictOldestEntries(forwardedRequestMethodsById, FORWARDED_REQUEST_METHODS_MAX_SIZE);
    evictOldestEntries(relaySanitizedResponseMethodsById, FORWARDED_REQUEST_METHODS_MAX_SIZE);
    evictOldestEntries(jsonlArtifactItemsCacheByThread, RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES);
    evictOldestEntries(jsonlTurnsListRolloutCacheByThread, JSONL_ROLLOUT_PATH_CACHE_MAX_SIZE);
    evictOldestEntries(jsonlTurnsListRolloutMissCacheByThread, JSONL_ROLLOUT_PATH_CACHE_MAX_SIZE);
    evictOldestEntries(jsonlThreadCwdCacheByThread, JSONL_ROLLOUT_PATH_CACHE_MAX_SIZE);
  }

  function safeParseJSON(value) {
    try {
      return JSON.parse(value);
    } catch {
      return null;
    }
  }

  function rememberThreadFromMessage(source, rawMessage, parsedMessage = null) {
    const context = extractBridgeMessageContext(rawMessage, parsedMessage);
    if (!context.threadId) {
      return;
    }

    rememberActiveThread(context.threadId, source);
    if (shouldStartContextUsageWatcher(context)) {
      ensureContextUsageWatcher(context);
    }
  }

  // Mirrors CodexMonitor's persisted token_count fallback so the phone keeps
  // receiving context-window usage even when the runtime omits live thread usage.
  function ensureContextUsageWatcher({ threadId, turnId }) {
    const normalizedThreadId = readString(threadId);
    const normalizedTurnId = readString(turnId);
    if (!normalizedThreadId) {
      return;
    }

    const nextWatcherKey = `${normalizedThreadId}|${normalizedTurnId || "pending-turn"}`;
    if (watchedContextUsageKey === nextWatcherKey && contextUsageWatcher) {
      return;
    }

    stopContextUsageWatcher();
    watchedContextUsageKey = nextWatcherKey;
    contextUsageWatcher = createThreadRolloutActivityWatcher({
      threadId: normalizedThreadId,
      turnId: normalizedTurnId,
      onUsage: ({ threadId: usageThreadId, usage }) => {
        sendContextUsageNotification(usageThreadId, usage);
      },
      onIdle: () => {
        if (watchedContextUsageKey === nextWatcherKey) {
          stopContextUsageWatcher();
        }
      },
      onTimeout: () => {
        if (watchedContextUsageKey === nextWatcherKey) {
          stopContextUsageWatcher();
        }
      },
      onError: () => {
        if (watchedContextUsageKey === nextWatcherKey) {
          stopContextUsageWatcher();
        }
      },
    });
  }

  function stopContextUsageWatcher() {
    if (contextUsageWatcher) {
      contextUsageWatcher.stop();
    }

    contextUsageWatcher = null;
    watchedContextUsageKey = null;
  }

  function sendContextUsageNotification(threadId, usage) {
    if (!threadId || !usage) {
      return;
    }

    sendApplicationResponse(JSON.stringify({
      method: "thread/tokenUsage/updated",
      params: {
        threadId,
        usage,
      },
    }));
  }

  // The spawned/shared Codex app-server stays warm across phone reconnects.
  // When iPhone reconnects it sends initialize again, but forwarding that to the
  // already-initialized Codex transport only produces "Already initialized".
  function handleBridgeManagedHandshakeMessage(rawMessage, sendResponse = sendApplicationResponse, parsedMessage = null) {
    const parsed = parsedMessage || parseBridgeMessage(rawMessage);
    if (!parsed) {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (!method) {
      return false;
    }

    if (method === "initialize" && parsed.id != null) {
      const compatibilityError = bridgeManagedInitializeCompatibilityError(parsed.params || {});
      if (compatibilityError) {
        sendResponse(JSON.stringify({
          id: parsed.id,
          error: compatibilityError,
        }));
        return true;
      }

      if (codexHandshakeState !== "warm") {
        forwardedInitializeRequestIds.add(String(parsed.id));
        return false;
      }

      sendResponse(JSON.stringify({
        id: parsed.id,
        result: {
          bridgeManaged: true,
        },
      }));
      return true;
    }

    if (method === "initialized") {
      return codexHandshakeState === "warm";
    }

    return false;
  }

  // Blocks bridge/app version skew before the phone starts calling newer bridge APIs.
  function bridgeManagedInitializeCompatibilityError(params) {
    const clientInfo = params && typeof params === "object" ? params.clientInfo : null;
    const clientName = normalizeNonEmptyString(clientInfo?.name);
    const clientDeviceKind = classifyClientDeviceKind(clientName);
    if (clientDeviceKind) {
      deviceState = rememberLastSeenClientDeviceKind(deviceState, clientDeviceKind);
      if (activePhoneSummary?.connected) {
        activePhoneSummary = {
          ...activePhoneSummary,
          deviceKind: clientDeviceKind,
        };
        const lastPublishedBridgeStatus = bridgeStatusPublisher.latest();
        if (lastPublishedBridgeStatus) {
          publishBridgeStatus(lastPublishedBridgeStatus);
        }
      }
    }
    if (clientName !== "codexmobile_ios") {
      return null;
    }

    const clientVersion = normalizeVersionString(clientInfo?.version);
    if (clientVersion) {
      deviceState = rememberLastSeenPhoneAppVersion(deviceState, clientVersion);
    }

    const compatibility = buildIOSAppCompatibilitySnapshot({
      bridgeVersion: bridgePackageVersion,
      iosAppVersion: clientVersion,
    });
    if (!compatibility.requiresAppUpdate) {
      return null;
    }

    logIOSAppCompatibilityWarning(buildCachedIOSAppCompatibilityWarning({
      bridgeVersion: bridgePackageVersion,
      iosAppVersion: clientVersion,
    }));

    return {
      code: -32001,
      message: compatibility.message,
      data: {
        errorCode: "ios_app_update_required",
        minimumSupportedAppVersion: MINIMUM_SUPPORTED_IOS_APP_VERSION,
        bridgeVersion: normalizeVersionString(bridgePackageVersion) || null,
        clientVersion,
        compatibleBridgeVersion: compatibility.legacyBridgeVersion,
        downgradeCommand: compatibility.downgradeCommand,
      },
    };
  }

  function logIOSAppCompatibilityWarning(warning) {
    const normalizedWarning = typeof warning === "string" ? warning.trim() : "";
    if (!normalizedWarning || normalizedWarning === lastIOSAppCompatibilityWarning) {
      return;
    }

    lastIOSAppCompatibilityWarning = normalizedWarning;
    console.warn(normalizedWarning);
  }

  // Learns whether the underlying Codex transport has already completed its own MCP handshake.
  function trackCodexHandshakeState(rawMessage, parsedMessage = null) {
    const parsed = parsedMessage ?? safeParseJSON(rawMessage);
    if (!parsed) {
      return;
    }

    const responseId = parsed?.id;
    if (responseId == null) {
      return;
    }

    const responseKey = String(responseId);
    if (!forwardedInitializeRequestIds.has(responseKey)) {
      return;
    }

    forwardedInitializeRequestIds.delete(responseKey);

    if (parsed?.result != null) {
      codexHandshakeState = "warm";
      return;
    }

    const errorMessage = typeof parsed?.error?.message === "string"
      ? parsed.error.message.toLowerCase()
      : "";
    if (errorMessage.includes("already initialized")) {
      codexHandshakeState = "warm";
    }
  }

  // Runs bridge-private JSON-RPC calls against the local app-server so token-bearing responses
  // can power bridge features like transcription without ever reaching the phone.
  function sendCodexRequest(method, params) {
    const requestId = `bridge-managed-${randomBytes(12).toString("hex")}`;
    const payload = JSON.stringify({
      id: requestId,
      method,
      params,
    });

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        bridgeManagedCodexRequestWaiters.delete(requestId);
        reject(new Error(`Codex request timed out: ${method}`));
      }, 20_000);

      bridgeManagedCodexRequestWaiters.set(requestId, {
        method,
        resolve,
        reject,
        timeout,
      });

      try {
        codex.send(payload);
      } catch (error) {
        clearTimeout(timeout);
        bridgeManagedCodexRequestWaiters.delete(requestId);
        reject(error);
      }
    });
  }

  // Intercepts responses for bridge-private requests so only user-visible app-server traffic
  // is forwarded back through secure transport.
  function handleBridgeManagedCodexResponse(rawMessage, parsedMessage = null) {
    const parsed = parsedMessage ?? safeParseJSON(rawMessage);
    if (!parsed) {
      return false;
    }

    const responseId = typeof parsed?.id === "string" ? parsed.id : null;
    if (!responseId) {
      return false;
    }

    const waiter = bridgeManagedCodexRequestWaiters.get(responseId);
    if (!waiter) {
      return false;
    }

    bridgeManagedCodexRequestWaiters.delete(responseId);
    clearTimeout(waiter.timeout);

    if (parsed.error) {
      const error = new Error(parsed.error.message || `Codex request failed: ${waiter.method}`);
      error.code = parsed.error.code;
      error.data = parsed.error.data;
      waiter.reject(error);
      return true;
    }

    waiter.resolve(readBridgeManagedSuccessPayload(parsed));
    return true;
  }

  // Normalizes private app-server responses before the bridge re-wraps them for iOS.
  function readBridgeManagedSuccessPayload(parsed) {
    if (Object.prototype.hasOwnProperty.call(parsed, "result")) {
      return parsed.result ?? null;
    }
    if (Object.prototype.hasOwnProperty.call(parsed, "payload")) {
      return parsed.payload ?? null;
    }
    return null;
  }

  function failBridgeManagedCodexRequests(error) {
    for (const waiter of bridgeManagedCodexRequestWaiters.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
    bridgeManagedCodexRequestWaiters.clear();
  }

  function publishBridgeStatus(status) {
    bridgeStatusPublisher.publish({
      ...status,
      activeDevice: activePhoneSummary,
      activePhone: activePhoneSummary,
    });
  }

  // Refreshes the relay's trusted-mac index after the QR bootstrap locks in a phone identity.
  function sendRelayRegistrationUpdate(nextDeviceState) {
    deviceState = nextDeviceState;
    if (socket?.readyState !== WebSocket.OPEN) {
      return;
    }

    socket.send(JSON.stringify({
      kind: "relayMacRegistration",
      registration: buildMacRegistration(nextDeviceState, pairingSession),
    }));
  }

  function readBridgePreferences() {
    return {
      success: true,
      preferences: {
        keepMacAwake: config.keepMacAwakeEnabled !== false,
      },
      applied: bridgeWakeAssertion.active,
    };
  }

  function updateBridgePreferences(preferences = {}) {
    const nextKeepMacAwakeEnabled = preferences.keepMacAwake !== false;
    config.keepMacAwakeEnabled = nextKeepMacAwakeEnabled;
    bridgeWakeAssertion.setEnabled?.(nextKeepMacAwakeEnabled);

    try {
      persistBridgePreferences({
        keepMacAwakeEnabled: nextKeepMacAwakeEnabled,
      });
    } catch (error) {
      const nextError = new Error("Could not save the bridge preference on this Mac.");
      nextError.errorCode = "bridge_preferences_persist_failed";
      nextError.userMessage = nextError.message;
      nextError.cause = error;
      throw nextError;
    }

    return readBridgePreferences();
  }

  async function updateBridgePackageAndRestart() {
    if (process.platform !== "darwin") {
      const error = new Error("Bridge self-update is available only for the macOS bridge service.");
      error.errorCode = "unsupported_platform";
      error.userMessage = error.message;
      throw error;
    }

    try {
      await execFileAsync("/bin/zsh", [
        "-lc",
        [
          "export TERM=dumb",
          "source ~/.zshrc >/dev/null 2>/dev/null || true",
          BRIDGE_PACKAGE_UPDATE_COMMAND,
        ].join("; "),
      ], {
        timeout: BRIDGE_PACKAGE_UPDATE_TIMEOUT_MS,
        maxBuffer: 2 * 1024 * 1024,
      });
    } catch (error) {
      const nextError = new Error(
        truncateCommandOutput(error?.stderr || error?.stdout || error?.message)
          || "Could not update the Remodex bridge package on this Mac."
      );
      nextError.errorCode = "bridge_update_failed";
      nextError.userMessage = nextError.message;
      nextError.cause = error;
      throw nextError;
    }

    scheduleBridgeServiceRestartAfterUpdate();
    return {
      success: true,
      command: BRIDGE_PACKAGE_UPDATE_COMMAND,
      restartScheduled: true,
      restartDelayMs: BRIDGE_RESTART_AFTER_UPDATE_DELAY_MS,
    };
  }

  // Restarts after the RPC response has crossed the encrypted phone channel.
  function scheduleBridgeServiceRestartAfterUpdate() {
    const restartTimer = setTimeout(() => {
      const cliPath = path.join(__dirname, "..", "bin", "remodex.js");
      const child = spawn(process.execPath, [cliPath, "restart"], {
        detached: true,
        stdio: "ignore",
        env: process.env,
      });
      child.on?.("error", (error) => {
        console.warn(`[remodex] Failed to schedule the post-update bridge restart: ${error?.message || error}`);
      });
      child.unref?.();
    }, BRIDGE_RESTART_AFTER_UPDATE_DELAY_MS);
    restartTimer.unref?.();
  }

  return {
    stop: stopBridge,
  };
}

// Holds a single macOS idle-sleep assertion for as long as the bridge process stays alive.
function createMacOSBridgeWakeAssertion({
  platform = process.platform,
  pid = process.pid,
  spawnImpl = spawn,
  consoleImpl = console,
  enabled = true,
} = {}) {
  if (platform !== "darwin") {
    return {
      active: false,
      enabled: false,
      setEnabled() {
        return { active: false, enabled: false };
      },
      stop() {},
    };
  }

  let desiredEnabled = Boolean(enabled);
  let child = null;

  function stop() {
    if (!child || child.killed || typeof child.kill !== "function") {
      child = null;
      return;
    }

    try {
      child.kill();
    } catch {}
    child = null;
  }

  function start() {
    if (!desiredEnabled || child) {
      return;
    }

    try {
      const nextChild = spawnImpl("/usr/bin/caffeinate", ["-i", "-w", String(pid)], {
        stdio: "ignore",
      });

      nextChild.on?.("error", (error) => {
        consoleImpl.warn(`[remodex] Failed to hold the Mac awake while the bridge is active: ${error.message}`);
      });
      nextChild.on?.("exit", () => {
        if (child === nextChild) {
          child = null;
        }
      });
      nextChild.unref?.();
      child = nextChild;
    } catch (error) {
      consoleImpl.warn(
        `[remodex] Failed to start the bridge wake assertion: ${(error && error.message) || "unknown error"}`
      );
      child = null;
    }
  }

  function setEnabled(nextEnabled) {
    desiredEnabled = Boolean(nextEnabled);
    if (desiredEnabled) {
      start();
    } else {
      stop();
    }

    return {
      active: Boolean(child && !child.killed),
      enabled: desiredEnabled,
    };
  }

  start();

  return {
    get active() {
      return Boolean(child && !child.killed);
    },
    get enabled() {
      return desiredEnabled;
    },
    setEnabled,
    stop,
  };
}

// Registers the canonical Mac identity and the one trusted phone allowed for auto-resolve.
function buildMacRegistrationHeaders(deviceState, pairingSession) {
  const registration = buildMacRegistration(deviceState, pairingSession);
  const headers = {
    "x-mac-device-id": registration.macDeviceId,
    "x-mac-identity-public-key": registration.macIdentityPublicKey,
    "x-machine-name": registration.displayName,
    "x-pairing-code": registration.pairingCode,
    "x-pairing-version": registration.pairingVersion ? String(registration.pairingVersion) : "",
    "x-pairing-expires-at": registration.pairingExpiresAt ? String(registration.pairingExpiresAt) : "",
  };
  if (registration.trustedPhoneDeviceId && registration.trustedPhonePublicKey) {
    headers["x-trusted-phone-device-id"] = registration.trustedPhoneDeviceId;
    headers["x-trusted-phone-public-key"] = registration.trustedPhonePublicKey;
  }
  return headers;
}

function buildMacRegistration(deviceState, pairingSession) {
  const trustedPhoneEntry = Object.entries(deviceState?.trustedPhones || {})[0] || null;
  return {
    macDeviceId: normalizeNonEmptyString(deviceState?.macDeviceId),
    macIdentityPublicKey: normalizeNonEmptyString(deviceState?.macIdentityPublicKey),
    displayName: normalizeNonEmptyString(os.hostname()),
    trustedPhoneDeviceId: normalizeNonEmptyString(trustedPhoneEntry?.[0]),
    trustedPhonePublicKey: normalizeNonEmptyString(trustedPhoneEntry?.[1]),
    pairingCode: normalizeNonEmptyString(pairingSession?.pairingCode),
    pairingVersion: Number.isInteger(pairingSession?.pairingPayload?.v) ? pairingSession.pairingPayload.v : 0,
    pairingExpiresAt: Number.isFinite(pairingSession?.pairingPayload?.expiresAt)
      ? pairingSession.pairingPayload.expiresAt
      : 0,
  };
}

function buildActivePhoneSummary(session, deviceState = null) {
  const phoneFingerprint = shortFingerprint(session?.phoneDeviceId);
  if (!phoneFingerprint) {
    return null;
  }

  return {
    connected: true,
    phoneFingerprint,
    deviceKind: normalizeNonEmptyString(deviceState?.lastSeenDeviceKind) || null,
    handshakeMode: normalizeNonEmptyString(session?.handshakeMode) || null,
    keyEpoch: Number.isFinite(session?.keyEpoch) ? session.keyEpoch : null,
    updatedAt: new Date().toISOString(),
  };
}

function classifyClientDeviceKind(clientName) {
  const normalized = normalizeNonEmptyString(clientName).toLowerCase();
  if (!normalized) {
    return null;
  }
  if (normalized.includes("android")) {
    return "android";
  }
  if (normalized.includes("ios") || normalized.includes("iphone")) {
    return "iphone";
  }
  if (normalized.includes("macos") || normalized.includes("mac")) {
    return "mac";
  }
  return null;
}

function shortFingerprint(value) {
  const normalized = normalizeNonEmptyString(value);
  if (!normalized) {
    return null;
  }
  return createHash("sha256").update(normalized).digest("hex").slice(0, 8);
}

function shutdown(codex, getSocket, beforeExit = () => {}) {
  beforeExit();

  const socket = getSocket();
  if (socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
    socket.close();
  }

  codex.shutdown();

  setTimeout(() => process.exit(0), 100);
}

// Forces app-server summary generation off for models whose Responses API calls
// reject reasoning.summary, while leaving the phone-facing runtime choice intact.
function disableUnsupportedReasoningSummaryForTurnStart(rawMessage) {
  const parsed = parseBridgeJSON(rawMessage);
  if (!parsed || parsed.method !== "turn/start") {
    return rawMessage;
  }

  const params = parsed.params && typeof parsed.params === "object" && !Array.isArray(parsed.params)
    ? parsed.params
    : null;
  if (!params || params.summary === "none") {
    return rawMessage;
  }

  const model = readTurnStartModel(params);
  if (!MODELS_WITHOUT_REASONING_SUMMARY.has(model)) {
    return rawMessage;
  }

  return JSON.stringify({
    ...parsed,
    params: {
      ...params,
      summary: "none",
    },
  });
}

function normalizeTurnStartParamsForCodex(params) {
  const normalizedRawMessage = normalizeTurnStartForCodex(JSON.stringify({
    method: "turn/start",
    params,
  }));
  const parsed = parseBridgeJSON(normalizedRawMessage);
  return parsed?.params && typeof parsed.params === "object" && !Array.isArray(parsed.params)
    ? parsed.params
    : params;
}

// A turn/start can carry the same runtime choice twice: in the legacy top-level
// model/effort fields and in collaborationMode.settings. Codex treats the nested
// collaboration settings as authoritative, so a stale Desktop value there can
// silently override the model selected on the phone. Keep both representations
// aligned before either direct app-server forwarding or Desktop-follower routing.
function normalizeTurnStartForCodex(rawMessage) {
  const parsed = parseBridgeJSON(rawMessage);
  if (!parsed || parsed.method !== "turn/start") {
    return rawMessage;
  }

  const params = parsed.params && typeof parsed.params === "object" && !Array.isArray(parsed.params)
    ? parsed.params
    : null;
  if (!params) {
    return rawMessage;
  }

  const model = normalizeNonEmptyString(params.model);
  const effort = normalizeNonEmptyString(params.effort);
  let changed = false;
  let nextParams = params;

  for (const collaborationKey of ["collaborationMode", "collaboration_mode"]) {
    const collaborationMode = nextParams[collaborationKey];
    const settings = collaborationMode?.settings;
    if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
      continue;
    }

    const nextSettings = { ...settings };
    let settingsChanged = false;
    if (model && normalizeNonEmptyString(settings.model) !== model) {
      nextSettings.model = model;
      settingsChanged = true;
    }
    if (effort && normalizeNonEmptyString(settings.reasoning_effort) !== effort) {
      nextSettings.reasoning_effort = effort;
      settingsChanged = true;
    }
    if (!settingsChanged) {
      continue;
    }

    nextParams = {
      ...nextParams,
      [collaborationKey]: {
        ...collaborationMode,
        settings: nextSettings,
      },
    };
    changed = true;
  }

  const alignedRawMessage = changed
    ? JSON.stringify({ ...parsed, params: nextParams })
    : rawMessage;
  return disableUnsupportedReasoningSummaryForTurnStart(alignedRawMessage);
}

function readTurnStartModel(params) {
  return normalizeNonEmptyString(params?.model).toLowerCase()
    || normalizeNonEmptyString(params?.collaborationMode?.settings?.model).toLowerCase()
    || normalizeNonEmptyString(params?.collaboration_mode?.settings?.model).toLowerCase();
}

function extractBridgeMessageContext(rawMessage, parsedMessage = null) {
  const parsed = parsedMessage ?? parseBridgeJSON(rawMessage);
  if (!parsed) {
    return { method: "", threadId: null, turnId: null };
  }

  const method = parsed?.method;
  const params = parsed?.params;
  const threadId = extractThreadId(method, params);
  const turnId = extractTurnId(method, params);

  return {
    method: typeof method === "string" ? method : "",
    threadId,
    turnId,
  };
}

function shouldStartContextUsageWatcher(context) {
  if (!context?.threadId) {
    return false;
  }

  return context.method === "turn/start"
    || context.method === "turn/started";
}

function extractThreadId(method, params) {
  if (method === "turn/start" || method === "turn/started") {
    return (
      readString(params?.threadId)
      || readString(params?.thread_id)
      || readString(params?.turn?.threadId)
      || readString(params?.turn?.thread_id)
    );
  }

  if (method === "thread/start" || method === "thread/started") {
    return (
      readString(params?.threadId)
      || readString(params?.thread_id)
      || readString(params?.thread?.id)
      || readString(params?.thread?.threadId)
      || readString(params?.thread?.thread_id)
    );
  }

  if (method === "turn/completed") {
    return (
      readString(params?.threadId)
      || readString(params?.thread_id)
      || readString(params?.turn?.threadId)
      || readString(params?.turn?.thread_id)
    );
  }

  return null;
}

function extractTurnId(method, params) {
  if (method === "turn/started" || method === "turn/completed") {
    return (
      readString(params?.turnId)
      || readString(params?.turn_id)
      || readString(params?.id)
      || readString(params?.turn?.id)
      || readString(params?.turn?.turnId)
      || readString(params?.turn?.turn_id)
    );
  }

  return null;
}

function readString(value) {
  return typeof value === "string" && value ? value : null;
}

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function truncateCommandOutput(value, maxChars = 1_200) {
  const normalized = normalizeNonEmptyString(value);
  if (!normalized || normalized.length <= maxChars) {
    return normalized;
  }
  return `...${normalized.slice(-maxChars)}`;
}

function parseAdaptiveThreadTurnsListRequest(rawMessage) {
  const parsed = parseBridgeJSON(rawMessage);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }

  if (parsed.method !== "thread/turns/list") {
    return null;
  }

  if (parsed.id == null) {
    return null;
  }

  const params = parsed.params;
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    return null;
  }

  if (!Number.isInteger(params.limit) || params.limit <= 0) {
    return null;
  }

  return parsed;
}

function threadIdFromRequestParams(params) {
  return normalizeNonEmptyString(params?.threadId)
    || normalizeNonEmptyString(params?.thread_id)
    || normalizeNonEmptyString(params?.id)
    || "";
}

function buildThreadTurnsListRelaySanitizeContext(request, {
  skipJsonlArtifactAugmentation = false,
} = {}) {
  return {
    threadId: threadIdFromRequestParams(request?.params || {}),
    skipJsonlArtifactAugmentation,
  };
}

async function fetchAdaptiveThreadTurnsListForRelay(request, {
  fetchPage,
  now = Date.now,
  targetBudgetMs = RELAY_TURNS_LIST_TARGET_BUDGET_MS,
  budgetReserveMs = RELAY_TURNS_LIST_BUDGET_RESERVE_MS,
  rawPageSoftLimitBytes = RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES,
  payloadSoftLimitBytes = RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES,
  sanitizeForRelay = sanitizeThreadHistoryImagesForRelay,
} = {}) {
  if (typeof fetchPage !== "function") {
    throw new Error("fetchPage is required for adaptive turns-list pagination.");
  }

  const params = request?.params;
  const requestedLimit = Number.isInteger(params?.limit) && params.limit > 0
    ? Math.min(params.limit, RELAY_TURNS_LIST_MAX_INITIAL_LIMIT)
    : 1;
  const sanitizeContext = buildThreadTurnsListRelaySanitizeContext(request, {
    skipJsonlArtifactAugmentation: true,
  });
  const startedAt = now();
  let nextCursor = params?.cursor;
  let turnsKey = null;
  let firstResult = null;
  let lastResult = null;
  let combinedTurns = [];
  let response = null;

  while (combinedTurns.length < requestedLimit) {
    const remaining = requestedLimit - combinedTurns.length;
    const pageLimit = selectAdaptiveTurnsListBatchLimit(combinedTurns.length, remaining);
    const pageParams = buildAdaptiveTurnsListPageParams(params, pageLimit, nextCursor);
    const responseBeforePage = response;
    let page;

    try {
      page = await fetchMeasuredAdaptiveTurnsListPage(fetchPage, pageParams, now);
    } catch (error) {
      if (response) {
        return response;
      }
      return await fetchSafeThreadTurnsListFallback(request, {
        fetchPage,
        now,
        sanitizeForRelay,
        sanitizeContext,
        payloadSoftLimitBytes,
      });
    }

    const pageResult = unwrapAppServerPayloadResult(page.result);
    const pageTurnsKey = findTurnsListResultKey(pageResult);
    if (!pageTurnsKey) {
      if (!response) {
        return await fetchSafeThreadTurnsListFallback(request, {
          fetchPage,
          now,
          sanitizeForRelay,
          sanitizeContext,
          payloadSoftLimitBytes,
        });
      }
      return response;
    }

    if (!turnsKey) {
      turnsKey = pageTurnsKey;
    }
    if (!firstResult) {
      firstResult = pageResult;
    }
    lastResult = pageResult;

    const pageTurns = pageResult[pageTurnsKey];
    combinedTurns = combinedTurns.concat(pageTurns);
    response = buildSafeTurnsListResponse(request.id, firstResult, lastResult, turnsKey, combinedTurns);

    if (measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) >= payloadSoftLimitBytes) {
      if (responseBeforePage) {
        // The server cursor belongs after the entire oversized batch. Return
        // the previous complete cursor boundary instead of slicing turns out
        // of this batch and making them unreachable.
        response = responseBeforePage;
        break;
      }
      if (pageTurns.length > pageLimit) {
        const completeResponse = buildCompactedCompleteTurnsListResponse({
          requestId: request.id,
          firstResult,
          lastResult,
          turnsKey,
          turns: pageTurns,
          sanitizeForRelay,
          sanitizeContext,
          payloadSoftLimitBytes,
        });
        if (!completeResponse) {
          throw new Error("thread/turns/list returned an oversized batch without a safe cursor boundary.");
        }
        response = completeResponse;
        break;
      }
      const boundedResponse = buildLargestSafeTurnsListResponse({
        requestId: request.id,
        firstResult,
        lastResult,
        turnsKey,
        turns: combinedTurns,
        maxTurns: RELAY_TURNS_LIST_SAFE_RETRY_LIMIT,
        sanitizeForRelay,
        sanitizeContext,
        payloadSoftLimitBytes,
      });
      if (!boundedResponse) {
        throw new Error("The newest chat turn is too large to relay safely.");
      }
      response = boundedResponse;
      break;
    }

    nextCursor = readTurnsListNextCursor(pageResult);
    if (combinedTurns.length >= requestedLimit || !hasRelayCursor(nextCursor) || pageTurns.length === 0) {
      break;
    }

    const rawPageBytes = jsonByteLength(pageResult);
    const sanitizedResponseBytes = measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext);
    const elapsedMs = Math.max(0, now() - startedAt);
    const remainingBudgetMs = Math.max(0, targetBudgetMs - elapsedMs);
    if (
      rawPageBytes >= rawPageSoftLimitBytes
      || sanitizedResponseBytes >= payloadSoftLimitBytes
      || page.elapsedMs >= Math.max(0, targetBudgetMs - budgetReserveMs)
      || remainingBudgetMs <= budgetReserveMs
    ) {
      break;
    }
  }

  if (!response) {
    throw new Error("thread/turns/list completed without a relayable page.");
  }
  return response;
}

function isEmptyTurnsListResponse(response) {
  const turnsKey = findTurnsListResultKey(response?.result);
  return Boolean(turnsKey) && response.result[turnsKey].length === 0;
}

// Non-empty app-server pages can be stale for Mac-started runs, so the first page
// still gets one JSONL lookup when the positive rollout cache is cold.
function resolveJsonlTurnsListRolloutPathForFallback({
  threadId,
  responseIsEmpty,
  readCachedPath,
  findAndCachePath,
}) {
  if (!threadId || typeof findAndCachePath !== "function") {
    return "";
  }

  if (responseIsEmpty) {
    return findAndCachePath(threadId);
  }

  return typeof readCachedPath === "function"
    ? readCachedPath(threadId) || findAndCachePath(threadId)
    : findAndCachePath(threadId);
}

function maybeMergeLatestJsonlTurnIntoTurnsListResponse(request, response, jsonlResult) {
  const responseResult = response?.result;
  const responseTurnsKey = findTurnsListResultKey(responseResult);
  const jsonlTurnsKey = findTurnsListResultKey(jsonlResult);
  if (!responseTurnsKey || !jsonlTurnsKey) {
    return null;
  }

  const responseTurns = responseResult[responseTurnsKey];
  const jsonlTurn = jsonlResult[jsonlTurnsKey]?.[0];
  const jsonlTurnId = turnListTurnIdentifier(jsonlTurn);
  if (!jsonlTurnId || responseTurns.some((turn) => turnListTurnIdentifier(turn) === jsonlTurnId)) {
    return null;
  }

  if (!shouldMergeLatestJsonlTurn(jsonlTurn)) {
    return null;
  }

  // Keep the canonical page intact. Slicing this back to the requested limit
  // can retain the newer JSONL turn while dropping the canonical cursor anchor,
  // making that canonical turn permanently unreachable.
  const mergedTurns = [jsonlTurn, ...responseTurns];
  return {
    id: request.id,
    result: {
      ...responseResult,
      [responseTurnsKey]: mergedTurns,
      remodexJsonlMergedLatest: true,
      remodexJsonlFallback: true,
    },
  };
}

function shouldMergeLatestJsonlTurn(turn) {
  if (!turn || typeof turn !== "object") {
    return false;
  }

  const status = normalizeHistoryItemToken(turn.status);
  if (status === "running" || status === "inprogress" || status === "active") {
    return true;
  }

  return Array.isArray(turn.items) && turn.items.some((item) => {
    const type = normalizeHistoryItemToken(item?.type);
    return type === "plan" || type === "filechange";
  });
}

function turnListTurnIdentifier(turn) {
  return normalizeNonEmptyString(turn?.id)
    || normalizeNonEmptyString(turn?.turnId)
    || normalizeNonEmptyString(turn?.turn_id);
}

function isSyntheticJsonlHistoryTurnId(turnId) {
  return normalizeNonEmptyString(turnId).startsWith("turn-line-");
}

async function fetchSafeThreadTurnsListFallback(request, {
  fetchPage,
  now,
  sanitizeForRelay,
  sanitizeContext = {},
  payloadSoftLimitBytes,
}) {
  const params = request?.params;
  const requestedLimit = Number.isInteger(params?.limit) && params.limit > 0
    ? params.limit
    : RELAY_TURNS_LIST_SAFE_RETRY_LIMIT;
  const safeLimit = Math.min(requestedLimit, RELAY_TURNS_LIST_SAFE_RETRY_LIMIT);
  const safeParams = buildAdaptiveTurnsListPageParams(params, safeLimit, params?.cursor);

  const page = await fetchMeasuredAdaptiveTurnsListPage(fetchPage, safeParams, now);
  const pageResult = unwrapAppServerPayloadResult(page.result);
  const turnsKey = findTurnsListResultKey(pageResult);
  if (!turnsKey) {
    throw new Error("thread/turns/list returned no turns array.");
  }

  // If the normal pagination path returns a bad first page, retry once with a small page.
  // The retry response is intentionally minimal so Swift does not decode stale server metadata.
  const response = buildCompactedCompleteTurnsListResponse({
    requestId: request.id,
    firstResult: pageResult,
    lastResult: pageResult,
    turnsKey,
    turns: pageResult[turnsKey],
    sanitizeForRelay,
    sanitizeContext,
    payloadSoftLimitBytes,
  });
  if (response) {
    return response;
  }
  throw new Error("thread/turns/list returned a page that is too large to relay safely.");
}

async function fetchMeasuredAdaptiveTurnsListPage(fetchPage, params, now) {
  const startedAt = now();
  const result = await fetchPage(params);
  const elapsedMs = Math.max(0, now() - startedAt);
  return {
    result,
    elapsedMs,
  };
}

function selectAdaptiveTurnsListBatchLimit(fetchedTurnCount, remainingTurnCount) {
  if (fetchedTurnCount <= 0) {
    return Math.min(1, remainingTurnCount);
  }
  if (fetchedTurnCount <= 1) {
    return Math.min(4, remainingTurnCount);
  }
  return remainingTurnCount;
}

function buildAdaptiveTurnsListPageParams(baseParams, limit, cursor) {
  const params = {
    ...baseParams,
    limit,
  };
  if (hasRelayCursor(cursor)) {
    params.cursor = cursor;
  } else {
    delete params.cursor;
  }
  return params;
}

function findTurnsListResultKey(result) {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return null;
  }
  return RELAY_TURNS_LIST_RESULT_KEYS.find((key) => Array.isArray(result[key])) || null;
}

function buildSafeTurnsListResponse(requestId, firstResult, lastResult, turnsKey, turns) {
  return {
    id: requestId,
    result: buildAdaptiveTurnsListResult(firstResult, lastResult, turnsKey, turns),
  };
}

function buildCompactedCompleteTurnsListResponse({
  requestId,
  firstResult,
  lastResult,
  turnsKey,
  turns,
  sanitizeForRelay,
  sanitizeContext = {},
  payloadSoftLimitBytes,
}) {
  const response = buildSafeTurnsListResponse(
    requestId,
    firstResult,
    lastResult,
    turnsKey,
    turns
  );
  if (measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) < payloadSoftLimitBytes) {
    return response;
  }

  for (const maxChars of [
    RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS,
    Math.floor(RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS / 4),
    1_000,
    0,
  ]) {
    const compacted = buildSafeTurnsListResponse(
      requestId,
      firstResult,
      lastResult,
      turnsKey,
      turns.map((turn) => compactTurnsListTurnForRelay(turn, maxChars))
    );
    compacted.result.remodexPageCompactedForRelay = true;
    if (measureSanitizedTurnsListResponseBytes(compacted, sanitizeForRelay, sanitizeContext) < payloadSoftLimitBytes) {
      return compacted;
    }
  }
  return null;
}

// Trims oversized history pages progressively: normal page -> 5 turns -> ... -> 1 turn.
function buildLargestSafeTurnsListResponse({
  requestId,
  firstResult,
  lastResult,
  turnsKey,
  turns,
  maxTurns,
  sanitizeForRelay,
  sanitizeContext = {},
  payloadSoftLimitBytes,
}) {
  const sliceLimit = Math.min(turns.length, maxTurns);
  for (let count = sliceLimit; count > 0; count -= 1) {
    const response = buildSafeTurnsListResponse(
      requestId,
      firstResult,
      lastResult,
      turnsKey,
      turns.slice(0, count)
    );
    if (measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) < payloadSoftLimitBytes) {
      return response;
    }
  }
  return buildEmergencySingleTurnResponse({
    requestId,
    lastResult,
    turnsKey,
    turn: turns[0],
    sanitizeForRelay,
    sanitizeContext,
    payloadSoftLimitBytes,
  });
}

function buildEmergencySingleTurnResponse({
  requestId,
  lastResult,
  turnsKey,
  turn,
  sanitizeForRelay,
  sanitizeContext = {},
  payloadSoftLimitBytes,
}) {
  if (!turn || typeof turn !== "object" || Array.isArray(turn)) {
    return null;
  }

  for (const maxItems of [16, 4, 1]) {
    for (const maxChars of [
      RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS,
      Math.floor(RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS / 4),
      1_000,
      0,
    ]) {
      const response = {
        id: requestId,
        result: {
          ...buildAdaptiveTurnsListResult({}, lastResult, turnsKey, [
            compactEmergencySingleTurnForRelay(turn, maxChars, maxItems),
          ]),
          remodexEmergencySingleTurnForRelay: true,
        },
      };
      if (measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) < payloadSoftLimitBytes) {
        return response;
      }
    }
  }

  return null;
}

function compactEmergencySingleTurnForRelay(turn, maxChars, maxItems) {
  const safeTurn = {};
  for (const key of [
    "id",
    "turnId",
    "turn_id",
    "threadId",
    "thread_id",
    "createdAt",
    "created_at",
    "completedAt",
    "completed_at",
    "timeZoneIdentifier",
    "timeZone",
    "timezone",
    "time_zone",
    "status",
    "role",
    "kind",
  ]) {
    const value = turn[key];
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      safeTurn[key] = value;
    }
  }

  const items = Array.isArray(turn.items) ? turn.items : [];
  safeTurn.items = selectEmergencyHistoryItemsForRelay(items, maxItems)
    .map((item) => compactHistoryItemForRelay(item, maxChars));
  safeTurn.remodexEmergencySingleTurnForRelay = true;
  safeTurn.remodexPageCompactedForRelay = true;
  return safeTurn;
}

function selectEmergencyHistoryItemsForRelay(items, maxItems) {
  if (!Array.isArray(items) || items.length <= maxItems) {
    return Array.isArray(items) ? items : [];
  }

  const selectedIndices = new Set();
  const firstUserIndex = items.findIndex((item) => isUserRoleItem(item));
  if (firstUserIndex >= 0) {
    selectedIndices.add(firstUserIndex);
  }
  for (let index = items.length - 1; index >= 0 && selectedIndices.size < maxItems; index -= 1) {
    const type = normalizeHistoryItemToken(items[index]?.type);
    if (type === "plan" || type === "filechange") {
      selectedIndices.add(index);
    }
  }
  for (let index = items.length - 1; index >= 0 && selectedIndices.size < maxItems; index -= 1) {
    selectedIndices.add(index);
  }
  return [...selectedIndices]
    .sort((left, right) => left - right)
    .map((index) => items[index]);
}

function buildAdaptiveTurnsListResult(firstResult, lastResult, turnsKey, turns) {
  const result = {};
  result[turnsKey] = turns;

  for (const key of RELAY_TURNS_LIST_PAGINATION_RESULT_KEYS) {
    const sourceResult = RELAY_TURNS_LIST_PREVIOUS_PAGINATION_RESULT_KEYS.has(key)
      ? firstResult
      : lastResult;
    if (Object.prototype.hasOwnProperty.call(sourceResult, key)) {
      result[key] = sourceResult[key];
    } else {
      delete result[key];
    }
  }

  return result;
}

function readTurnsListNextCursor(result) {
  if (!result || typeof result !== "object") {
    return undefined;
  }
  if (hasRelayCursor(result.nextCursor)) {
    return result.nextCursor;
  }
  if (hasRelayCursor(result.next_cursor)) {
    return result.next_cursor;
  }
  return undefined;
}

function hasRelayCursor(cursor) {
  return cursor !== undefined && cursor !== null && cursor !== "";
}

function jsonByteLength(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value), "utf8");
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, requestContext = {}) {
  try {
    const rawResponse = JSON.stringify(response);
    const sanitizedResponse = sanitizeForRelay(rawResponse, "thread/turns/list", requestContext);
    return Buffer.byteLength(sanitizedResponse, "utf8");
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

// Keeps app-server responses in the JSON-RPC shape that the App Store iOS client decodes.
function normalizeRelayBoundJsonRpcMessage(rawMessage, {
  pendingRequestMethodsById = null,
  // Optional pre-parsed envelope shared by the caller; treated as read-only.
  parsedMessage = null,
} = {}) {
  const parsed = parsedMessage ?? parseBridgeJSON(rawMessage);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }

  const hasMethod = typeof parsed.method === "string" && parsed.method.length > 0;
  const hasResponseId = parsed.id !== undefined && parsed.id !== null;
  const hasResult = Object.prototype.hasOwnProperty.call(parsed, "result");
  const hasError = Object.prototype.hasOwnProperty.call(parsed, "error");
  const hasPayload = Object.prototype.hasOwnProperty.call(parsed, "payload");
  if (hasResponseId && !hasMethod && !hasResult && !hasError && hasPayload) {
    const { payload, ...rest } = parsed;
    return JSON.stringify({
      ...rest,
      result: payload ?? null,
    });
  }

  if (hasResponseId && !hasMethod && hasResult && !hasError) {
    const unwrappedResult = unwrapAppServerPayloadResult(parsed.result);
    if (unwrappedResult !== parsed.result) {
      return JSON.stringify({
        ...parsed,
        result: unwrappedResult,
      });
    }
  }

  if (hasMethod && hasResponseId && !isRelayBoundServerRequestMethod(parsed.method)) {
    const trackedRequest = pendingRequestMethodsById?.get(String(parsed.id));
    const isTrackedResponse = trackedRequest?.method === parsed.method
      && (hasResult || hasError || hasPayload);
    if (isTrackedResponse) {
      const { method, payload, ...rest } = parsed;
      if (!hasResult && !hasError && hasPayload) {
        return JSON.stringify({
          ...rest,
          result: payload ?? null,
        });
      }
      if (hasResult && !hasError) {
        return JSON.stringify({
          ...rest,
          result: unwrapAppServerPayloadResult(rest.result),
        });
      }
      return JSON.stringify(rest);
    }

    return null;
  }

  if (!hasMethod && !hasResponseId) {
    return null;
  }

  return rawMessage;
}

function unwrapAppServerPayloadResult(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return value;
  }
  if (!Object.prototype.hasOwnProperty.call(value, "payload")) {
    return value;
  }

  const payload = value.payload;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return value;
  }

  const directPayloadKeys = [
    "data",
    "items",
    "threads",
    "turns",
    "thread",
  ];
  const hasDirectResultPayload = directPayloadKeys.some((key) => (
    Object.prototype.hasOwnProperty.call(payload, key)
  ));
  if (!hasDirectResultPayload) {
    return value;
  }

  return {
    ...value,
    ...payload,
  };
}

function isRelayBoundServerRequestMethod(method) {
  return method === "item/tool/requestUserInput"
    || method === "tool/requestUserInput"
    || method.endsWith("requestApproval");
}

// Shrinks thread history snapshots/pages for mobile relay delivery.
// This elides bulky blobs and replaces oversized older history with a compact marker.
function sanitizeThreadHistoryImagesForRelay(rawMessage, requestMethod, requestContext = {}) {
  if (requestMethod === "thread/turns/list") {
    return sanitizeThreadTurnsListForRelay(rawMessage, requestContext);
  }

  if (requestMethod !== "thread/read" && requestMethod !== "thread/resume") {
    return rawMessage;
  }

  const parsed = parseBridgeJSON(rawMessage);
  const thread = parsed?.result?.thread;
  if (!thread || typeof thread !== "object" || !Array.isArray(thread.turns)) {
    return rawMessage;
  }

  const threadId = normalizeNonEmptyString(requestContext?.threadId)
    || normalizeNonEmptyString(thread.id)
    || normalizeNonEmptyString(thread.threadId)
    || normalizeNonEmptyString(thread.thread_id);

  // Oversized histories get their turn window trimmed before the per-turn sanitize
  // and augment passes so full-history work is not spent on turns the payload
  // budget discards anyway. The byte-budget trim below still enforces the cap.
  const didPreTrimTurnWindow = Buffer.byteLength(rawMessage, "utf8") > RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES
    && thread.turns.length > RELAY_HISTORY_RECENT_TURN_TARGET;
  const workingTurns = didPreTrimTurnWindow
    ? thread.turns.slice(-RELAY_HISTORY_RECENT_TURN_TARGET)
    : thread.turns;
  const workingThread = didPreTrimTurnWindow ? { ...thread, turns: workingTurns } : thread;
  const trimOptions = didPreTrimTurnWindow
    ? {
      preOmittedTurnCount: thread.turns.length - workingTurns.length,
      compactionIdSource: thread.turns[0],
    }
    : {};

  const { turns: sanitizedTurns, didSanitize } = sanitizeRelayHistoryTurns(workingTurns, threadId);
  const { thread: threadWithJsonlMetadata, didAugment: didAugmentThreadMetadata } = augmentRelayThreadWithJsonlMetadata(workingThread, threadId);
  const { turns: augmentedTurns, didAugment } = augmentRelayHistoryTurnsWithJsonlArtifacts(
    sanitizedTurns,
    threadId,
    { includeHistoryItems: true }
  );

  if (!didSanitize && !didAugment && !didAugmentThreadMetadata && !didPreTrimTurnWindow) {
    const trimmedPayload = trimThreadPayloadForRelay(parsed, thread);
    return trimmedPayload == null ? rawMessage : trimmedPayload;
  }

  const sanitizedPayload = JSON.stringify({
    ...parsed,
    result: {
      ...parsed.result,
      thread: {
        ...threadWithJsonlMetadata,
        turns: augmentedTurns,
      },
    },
  });

  return trimThreadPayloadForRelay(parseBridgeJSON(sanitizedPayload), null, trimOptions) ?? sanitizedPayload;
}

function sanitizeThreadTurnsListForRelay(rawMessage, requestContext = {}) {
  const parsed = parseBridgeJSON(rawMessage);
  const result = parsed?.result;
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return rawMessage;
  }

  const turnsKey = ["data", "items", "turns"].find((key) => Array.isArray(result[key]));
  if (!turnsKey) {
    return rawMessage;
  }

  const threadId = normalizeNonEmptyString(requestContext?.threadId)
    || normalizeNonEmptyString(result.threadId)
    || normalizeNonEmptyString(result.thread_id)
    || normalizeNonEmptyString(result.thread?.id)
    || normalizeNonEmptyString(result.thread?.threadId)
    || normalizeNonEmptyString(result.thread?.thread_id)
    || inferThreadIdFromTurns(result[turnsKey]);
  const { turns: sanitizedTurns, didSanitize } = sanitizeRelayHistoryTurns(result[turnsKey], threadId);
  const shouldAugmentJsonlArtifacts = requestContext?.skipJsonlArtifactAugmentation !== true;
  const { turns: augmentedTurns, didAugment } = shouldAugmentJsonlArtifacts
    ? augmentRelayHistoryTurnsWithJsonlArtifacts(sanitizedTurns, threadId)
    : { turns: sanitizedTurns, didAugment: false };
  const didChange = didSanitize || didAugment;
  const sanitizedParsed = didChange
    ? {
      ...parsed,
      result: {
        ...result,
        [turnsKey]: augmentedTurns,
      },
    }
    : parsed;

  return trimTurnsListPayloadForRelay(sanitizedParsed, turnsKey, didChange ? null : rawMessage);
}

function augmentRelayThreadWithJsonlMetadata(thread, threadId = "") {
  const cwd = readJsonlThreadCwd(threadId);
  if (!cwd || !thread || typeof thread !== "object") {
    return { thread, didAugment: false };
  }

  if (normalizeNonEmptyString(thread.cwd) === cwd
    && normalizeNonEmptyString(thread.current_working_directory) === cwd) {
    return { thread, didAugment: false };
  }

  return {
    thread: {
      ...thread,
      cwd,
      current_working_directory: cwd,
    },
    didAugment: true,
  };
}

function readJsonlThreadCwd(threadId) {
  const normalizedThreadId = normalizeNonEmptyString(threadId);
  if (!normalizedThreadId) {
    return "";
  }

  const sessionsRoot = resolveSessionsRoot();
  const cacheKey = buildJsonlThreadCacheKey(sessionsRoot, normalizedThreadId);

  try {
    const rolloutPath = findRecentRolloutFileForContextRead(sessionsRoot, { threadId: normalizedThreadId });
    if (!rolloutPath) {
      return "";
    }

    const cached = readCachedJsonlThreadCwd(cacheKey, rolloutPath);
    if (cached) {
      return cached.cwd;
    }

    return readAndCacheJsonlThreadCwd(cacheKey, rolloutPath);
  } catch {
    return "";
  }
}

function readCachedJsonlThreadCwd(cacheKey, rolloutPath) {
  const cached = jsonlThreadCwdCacheByThread.get(cacheKey);
  if (!cached || cached.rolloutPath !== rolloutPath) {
    return null;
  }

  const stat = statJsonlRollout(rolloutPath);
  if (!stat) {
    jsonlThreadCwdCacheByThread.delete(cacheKey);
    return null;
  }

  if (stat.mtimeMs !== cached.mtimeMs || stat.size !== cached.size) {
    return null;
  }

  const ttl = cached.cwd ? RELAY_JSONL_THREAD_CWD_CACHE_TTL_MS : RELAY_JSONL_THREAD_EMPTY_CWD_CACHE_TTL_MS;
  if (Date.now() - cached.checkedAt > ttl) {
    return null;
  }

  return { cwd: cached.cwd };
}

function readAndCacheJsonlThreadCwd(cacheKey, rolloutPath, stat = null) {
  const rolloutStat = stat || statJsonlRollout(rolloutPath);
  if (!rolloutStat) {
    jsonlThreadCwdCacheByThread.delete(cacheKey);
    return "";
  }

  let cwd = "";
  try {
    const metadata = readSessionJsonlMetadataFromFile(rolloutPath);
    const parsedCwd = normalizeNonEmptyString(metadata?.cwd);
    cwd = parsedCwd && path.isAbsolute(parsedCwd) ? parsedCwd : "";
  } catch {
    cwd = "";
  }

  rememberJsonlThreadCwdCache(cacheKey, {
    rolloutPath,
    cwd,
    mtimeMs: rolloutStat.mtimeMs,
    size: rolloutStat.size,
    checkedAt: Date.now(),
  });
  return cwd;
}

function rememberJsonlThreadCwdCache(cacheKey, entry) {
  jsonlThreadCwdCacheByThread.set(cacheKey, entry);
  while (jsonlThreadCwdCacheByThread.size > JSONL_ROLLOUT_PATH_CACHE_MAX_SIZE) {
    const oldestKey = jsonlThreadCwdCacheByThread.keys().next().value;
    if (oldestKey == null) {
      break;
    }
    jsonlThreadCwdCacheByThread.delete(oldestKey);
  }
}

function augmentRelayHistoryTurnsWithJsonlArtifacts(turns, threadId = "", {
  includeHistoryItems = false,
} = {}) {
  const normalizedThreadId = normalizeNonEmptyString(threadId);
  if (!normalizedThreadId || !Array.isArray(turns) || turns.length === 0) {
    return { turns, didAugment: false };
  }

  const requestedTurnIds = new Set(turns.map((turn) => (
    normalizeNonEmptyString(turn?.id)
      || normalizeNonEmptyString(turn?.turnId)
      || normalizeNonEmptyString(turn?.turn_id)
  )).filter(Boolean));
  const jsonlArtifactsByTurnId = readJsonlArtifactItemsByTurnId(
    normalizedThreadId,
    requestedTurnIds
  );
  if (jsonlArtifactsByTurnId.size === 0) {
    return { turns, didAugment: false };
  }

  let didAugment = false;
  const augmentedTurns = turns.map((turn) => {
    const turnId = normalizeNonEmptyString(turn?.id)
      || normalizeNonEmptyString(turn?.turnId)
      || normalizeNonEmptyString(turn?.turn_id);
    const artifacts = turnId ? jsonlArtifactsByTurnId.get(turnId) : null;
    if (!artifacts || !turn || typeof turn !== "object") {
      return turn;
    }

    const items = Array.isArray(turn.items) ? turn.items : [];
    const merged = mergeRelayHistoryItemsWithJsonlItems(
      items,
      artifacts.timelineItems,
      normalizedThreadId,
      {
        includeJsonlItem: includeHistoryItems
          ? () => true
          : isJsonlHistoryArtifactItem,
      }
    );
    const nextItems = merged.items;

    if (nextItems === items) {
      return turn;
    }

    didAugment = true;
    return {
      ...turn,
      items: nextItems,
    };
  });

  return { turns: didAugment ? augmentedTurns : turns, didAugment };
}

function readJsonlArtifactItemsByTurnId(threadId, requestedTurnIds = new Set()) {
  const emptyArtifactsByTurnId = new Map();
  const normalizedThreadId = normalizeNonEmptyString(threadId);
  if (!normalizedThreadId) {
    return emptyArtifactsByTurnId;
  }

  const sessionsRoot = resolveSessionsRoot();
  const cacheKey = buildJsonlArtifactItemsCacheKey(sessionsRoot, normalizedThreadId);
  const cachedArtifacts = readCachedJsonlArtifactItems(
    cacheKey,
    normalizedThreadId,
    requestedTurnIds
  );
  if (cachedArtifacts) {
    return cachedArtifacts;
  }

  try {
    const rolloutPath = findRecentRolloutFileForContextRead(sessionsRoot, { threadId: normalizedThreadId });
    if (!rolloutPath) {
      jsonlArtifactItemsCacheByThread.delete(cacheKey);
      return emptyArtifactsByTurnId;
    }

    return readAndCacheJsonlArtifactItems(
      cacheKey,
      rolloutPath,
      normalizedThreadId,
      null,
      requestedTurnIds
    );
  } catch (error) {
    jsonlArtifactItemsCacheByThread.delete(cacheKey);
    console.warn(`[remodex] history jsonl artifact augmentation failed for ${normalizedThreadId}: ${error.message}`);
  }

  return emptyArtifactsByTurnId;
}

function buildJsonlArtifactItemsCacheKey(sessionsRoot, threadId) {
  return buildJsonlThreadCacheKey(sessionsRoot, threadId);
}

function buildJsonlThreadCacheKey(sessionsRoot, threadId) {
  return `${sessionsRoot}\0${threadId}`;
}

function readCachedJsonlArtifactItems(cacheKey, threadId, requestedTurnIds = new Set()) {
  const cached = jsonlArtifactItemsCacheByThread.get(cacheKey);
  if (!cached) {
    return null;
  }

  const stat = statJsonlRollout(cached.rolloutPath);
  if (!stat) {
    jsonlArtifactItemsCacheByThread.delete(cacheKey);
    return null;
  }

  if (stat.mtimeMs !== cached.mtimeMs || stat.size !== cached.size) {
    try {
      return readAndCacheJsonlArtifactItems(
        cacheKey,
        cached.rolloutPath,
        threadId,
        stat,
        requestedTurnIds
      );
    } catch (error) {
      jsonlArtifactItemsCacheByThread.delete(cacheKey);
      console.warn(`[remodex] history jsonl artifact cache refresh failed for ${threadId}: ${error.message}`);
      return null;
    }
  }

  const now = Date.now();
  const coversRequestedTurns = cached.coversEntireRollout
    || [...requestedTurnIds].every((turnId) => cached.coveredTurnIds?.has(turnId));
  if (!coversRequestedTurns) {
    return null;
  }
  if (now - cached.checkedAt <= RELAY_JSONL_ARTIFACT_CACHE_TTL_MS) {
    return cached.artifactsByTurnId;
  }

  cached.checkedAt = now;
  return null;
}

function readAndCacheJsonlArtifactItems(
  cacheKey,
  rolloutPath,
  threadId,
  stat = null,
  requestedTurnIds = new Set()
) {
  const rolloutStat = stat || fs.statSync(rolloutPath);
  const artifactsByTurnId = new Map();
  let coveredTurnIds = new Set();
  let coversEntireRollout = false;
  try {
    const recent = readRecentSessionJsonlTurns(rolloutPath, {
      threadId,
      limit: RELAY_TURNS_LIST_SAFE_RETRY_LIMIT,
    });
    let turns = recent?.turns || [];
    coversEntireRollout = recent ? !recent.hasOlderTurns : false;
    coveredTurnIds = new Set(turns.map((turn) => normalizeNonEmptyString(turn?.id)).filter(Boolean));
    const missesRequestedTurn = [...requestedTurnIds].some((turnId) => !coveredTurnIds.has(turnId));

    // Preserve the old exact artifact behavior for files V8 can safely decode,
    // but only pay that cost when an older cursor page actually asks for a turn
    // outside the fast tail. Multi-gigabyte files never enter this path.
    if (!coversEntireRollout
        && missesRequestedTurn
        && rolloutStat.size <= RELAY_JSONL_FULL_ARTIFACT_FALLBACK_MAX_BYTES) {
      turns = parseSessionJsonlTurns(fs.readFileSync(rolloutPath, "utf8"), { threadId });
      coversEntireRollout = true;
      coveredTurnIds = new Set(turns.map((turn) => normalizeNonEmptyString(turn?.id)).filter(Boolean));
    }
    for (const turn of turns) {
      const turnId = normalizeNonEmptyString(turn?.id);
      const turnItems = Array.isArray(turn?.items) ? turn.items : [];
      if (!turnId || turnItems.length === 0) {
        continue;
      }

      const timelineItems = buildOrderedJsonlTimelineItems(turnItems, turnId);
      if (timelineItems.length > 0) {
        artifactsByTurnId.set(turnId, { timelineItems });
      }
    }
  } catch (error) {
    jsonlArtifactItemsCacheByThread.delete(cacheKey);
    throw error;
  }

  rememberJsonlArtifactItemsCache(cacheKey, {
    rolloutPath,
    mtimeMs: rolloutStat.mtimeMs,
    size: rolloutStat.size,
    checkedAt: Date.now(),
    artifactsByTurnId,
    coveredTurnIds,
    coversEntireRollout,
  });
  return artifactsByTurnId;
}

function statJsonlRollout(rolloutPath) {
  try {
    return fs.statSync(rolloutPath);
  } catch {
    return null;
  }
}

function rememberJsonlArtifactItemsCache(cacheKey, entry) {
  jsonlArtifactItemsCacheByThread.set(cacheKey, entry);
  while (jsonlArtifactItemsCacheByThread.size > RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES) {
    const oldestKey = jsonlArtifactItemsCacheByThread.keys().next().value;
    if (oldestKey == null) {
      break;
    }
    jsonlArtifactItemsCacheByThread.delete(oldestKey);
  }
}

// Keeps JSONL-only rows in rollout order while treating app-server rows as the
// authoritative spine. Matching anchors let us place missing rows without ever
// moving server-only findings, messages, or richer tool records to the tail.
function mergeRelayHistoryItemsWithJsonlItems(existingItems, jsonlItems, threadId = "", {
  includeJsonlItem = () => true,
} = {}) {
  if (!Array.isArray(existingItems) || !Array.isArray(jsonlItems) || jsonlItems.length === 0) {
    return { items: existingItems, didMerge: false };
  }

  const sanitizedJsonlItems = jsonlItems
    .map((item) => sanitizeJsonlHistoryItemForRelayMerge(item, threadId))
    .filter(Boolean);
  if (sanitizedJsonlItems.length === 0) {
    return { items: existingItems, didMerge: false };
  }

  if (existingItems.length === 0) {
    const insertedItems = sanitizedJsonlItems.filter(includeJsonlItem);
    return insertedItems.length > 0
      ? { items: insertedItems, didMerge: true }
      : { items: existingItems, didMerge: false };
  }

  const usedExistingIndices = new Set();
  const resolvedExistingItems = existingItems.slice();
  const insertionsBefore = new Map();
  const insertionsAfter = new Map();
  let pendingItems = [];
  let previousMatchedIndex = null;
  let matchedAnchorCount = 0;
  let didReplaceMatchedItem = false;

  // The rollout's turn+text alias is the only identity shared across the
  // live-owner (item_N) and rollout (msg_...) views of one assistant reply.
  // Carrying it onto the matched server row lets the phone join this item
  // with its other-source representations instead of duplicating it.
  const adoptJsonlSourceAlias = (index, jsonlItem) => {
    const sourceKey = normalizeNonEmptyString(jsonlItem?.remodexSourceItemKey);
    const existing = resolvedExistingItems[index];
    if (!sourceKey || !existing || typeof existing !== "object"
      || normalizeNonEmptyString(existing.remodexSourceItemKey)) {
      return;
    }
    resolvedExistingItems[index] = { ...existing, remodexSourceItemKey: sourceKey };
    didReplaceMatchedItem = true;
  };

  const placePendingItems = () => {
    if (pendingItems.length === 0) {
      return;
    }
    if (previousMatchedIndex == null) {
      insertionsBefore.set(0, pendingItems);
    } else {
      const existing = insertionsAfter.get(previousMatchedIndex) || [];
      insertionsAfter.set(previousMatchedIndex, existing.concat(pendingItems));
    }
    pendingItems = [];
  };

  for (const jsonlItem of sanitizedJsonlItems) {
    const unusedMatch = (candidate, index) => !usedExistingIndices.has(index);
    const eligibleMatch = (candidate, index) => (
      (previousMatchedIndex == null || index > previousMatchedIndex)
      && unusedMatch(candidate, index)
    );
    let existingIndex = findRelayHistoryExactMatchIndex(existingItems, jsonlItem, eligibleMatch);
    if (existingIndex === -1) {
      // Exact identity remains authoritative even when server and rollout order
      // disagree. Consume that occurrence before considering a later semantic
      // lookalike, otherwise repeated rows can bind to the wrong server item.
      const representedExactIndex = findRelayHistoryExactMatchIndex(
        existingItems,
        jsonlItem,
        unusedMatch
      );
      if (representedExactIndex !== -1) {
        usedExistingIndices.add(representedExactIndex);
        if (isProgressPlanItem(jsonlItem)) {
          resolvedExistingItems[representedExactIndex] = resolvedProgressPlanHistoryItem(
            existingItems[representedExactIndex],
            jsonlItem
          );
          didReplaceMatchedItem = true;
        }
        adoptJsonlSourceAlias(representedExactIndex, jsonlItem);
        continue;
      }
      existingIndex = findRelayHistorySemanticMatchIndex(existingItems, jsonlItem, eligibleMatch);
    }
    if (existingIndex === -1) {
      // The row can already exist before the monotonic placement frontier when
      // server and rollout order disagree. Consume each represented occurrence
      // once; an extra identical JSONL occurrence must remain visible instead
      // of repeatedly matching the same server row and disappearing.
      const representedIndex = findRelayHistorySemanticMatchIndex(
        existingItems,
        jsonlItem,
        unusedMatch
      );
      if (representedIndex !== -1) {
        usedExistingIndices.add(representedIndex);
        if (isProgressPlanItem(jsonlItem)) {
          resolvedExistingItems[representedIndex] = resolvedProgressPlanHistoryItem(
            existingItems[representedIndex],
            jsonlItem
          );
          didReplaceMatchedItem = true;
        }
        adoptJsonlSourceAlias(representedIndex, jsonlItem);
        continue;
      }
      if (includeJsonlItem(jsonlItem)) {
        pendingItems.push(jsonlItem);
      }
      continue;
    }

    placePendingItems();
    usedExistingIndices.add(existingIndex);
    if (isProgressPlanItem(jsonlItem)) {
      resolvedExistingItems[existingIndex] = resolvedProgressPlanHistoryItem(
        existingItems[existingIndex],
        jsonlItem
      );
      didReplaceMatchedItem = true;
    }
    adoptJsonlSourceAlias(existingIndex, jsonlItem);
    previousMatchedIndex = existingIndex;
    matchedAnchorCount += 1;
  }

  if (matchedAnchorCount === 0) {
    const unanchoredArtifacts = sanitizedJsonlItems.filter((item) => (
      includeJsonlItem(item) && isJsonlHistoryArtifactItem(item)
    ));
    if (unanchoredArtifacts.length === 0) {
      return { items: existingItems, didMerge: false };
    }
    const firstAssistantIndex = existingItems.findIndex(isRelayAssistantHistoryItem);
    const insertionIndex = firstAssistantIndex === -1 ? existingItems.length : firstAssistantIndex;
    return {
      items: existingItems.slice(0, insertionIndex)
        .concat(unanchoredArtifacts, existingItems.slice(insertionIndex)),
      didMerge: true,
    };
  }
  if (pendingItems.length > 0 && previousMatchedIndex != null) {
    const existing = insertionsAfter.get(previousMatchedIndex) || [];
    insertionsAfter.set(previousMatchedIndex, existing.concat(pendingItems));
  }

  if (insertionsBefore.size === 0 && insertionsAfter.size === 0 && !didReplaceMatchedItem) {
    return { items: existingItems, didMerge: false };
  }

  const mergedItems = [];
  for (const [index, item] of resolvedExistingItems.entries()) {
    mergedItems.push(...(insertionsBefore.get(index) || []));
    mergedItems.push(item);
    mergedItems.push(...(insertionsAfter.get(index) || []));
  }
  return { items: mergedItems, didMerge: true };
}

function buildOrderedJsonlTimelineItems(turnItems, turnId) {
  if (!Array.isArray(turnItems) || turnItems.length === 0) {
    return [];
  }

  let latestProgressPlanIndex = -1;
  for (const [index, item] of turnItems.entries()) {
    if (isProgressPlanItem(item)) {
      latestProgressPlanIndex = index;
    }
  }

  let imageViewIndex = 0;
  return turnItems.flatMap((item, index) => {
    if (!shouldIncludeJsonlTimelineItem(item)) {
      return [];
    }
    if (isProgressPlanItem(item) && index !== latestProgressPlanIndex) {
      return [];
    }

    const itemType = normalizeHistoryItemToken(item?.type);
    if (isProgressPlanItem(item)) {
      return [{
        ...item,
        id: normalizeNonEmptyString(item?.id) || `remodex-jsonl-progress-plan-${turnId}`,
        remodexProgressPlan: true,
        remodexJsonlProgressPlan: true,
      }];
    }
    if (itemType === "imageview") {
      imageViewIndex += 1;
      return [{
        ...item,
        id: normalizeNonEmptyString(item?.id)
          || `remodex-jsonl-image-view-${turnId}-${imageViewIndex}`,
      }];
    }
    return [item];
  });
}

function shouldIncludeJsonlTimelineItem(item) {
  const itemType = normalizeHistoryItemToken(item?.type);
  return Boolean(itemType)
    && itemType !== "toolcalloutput"
    && itemType !== "functioncalloutput"
    && itemType !== "customtoolcalloutput";
}

function isJsonlHistoryArtifactItem(item) {
  const itemType = normalizeHistoryItemToken(item?.type);
  return itemType === "filechange"
    || itemType === "imageview"
    || isProgressPlanItem(item);
}

function isProgressPlanItem(item) {
  const itemType = normalizeHistoryItemToken(item?.type);
  return (itemType === "plan" || itemType === "todolist")
    && (item?.remodexJsonlProgressPlan === true || item?.remodexProgressPlan === true);
}

function resolvedProgressPlanHistoryItem(existingItem, jsonlItem) {
  return {
    ...existingItem,
    text: jsonlItem.text,
    explanation: jsonlItem.explanation,
    plan: jsonlItem.plan,
    remodexProgressPlan: true,
    remodexJsonlProgressPlan: true,
  };
}

function findRelayHistoryExactMatchIndex(items, incomingItem, predicate = () => true) {
  return items.findIndex((candidate, index) => (
    predicate(candidate, index) && relayHistoryItemsHaveExactIdentity(candidate, incomingItem)
  ));
}

function findRelayHistorySemanticMatchIndex(items, incomingItem, predicate = () => true) {
  return items.findIndex((candidate, index) => (
    predicate(candidate, index) && areEquivalentRelayHistoryItems(candidate, incomingItem)
  ));
}

function relayHistoryItemsHaveExactIdentity(first, second) {
  const firstIdentity = relayHistoryItemIdentity(first);
  const secondIdentity = relayHistoryItemIdentity(second);
  if (firstIdentity && secondIdentity && firstIdentity === secondIdentity) {
    return true;
  }
  const firstCallId = relayHistoryItemCallId(first);
  const secondCallId = relayHistoryItemCallId(second);
  return Boolean(firstCallId && secondCallId && firstCallId === secondCallId);
}

function isRelayAssistantHistoryItem(item) {
  const role = normalizeNonEmptyString(item?.role).toLowerCase();
  const itemType = normalizeHistoryItemToken(item?.type);
  return role === "assistant"
    || itemType === "assistantmessage"
    || itemType === "agentmessage"
    || (itemType === "message" && role !== "user");
}

function sanitizeJsonlHistoryItemForRelayMerge(item, threadId) {
  const sanitizedTurn = sanitizeRelayHistoryTurn({ items: [item] }, threadId);
  return sanitizedTurn?.items?.[0] || item;
}

function areEquivalentRelayHistoryItems(first, second) {
  const firstIdentity = relayHistoryItemIdentity(first);
  const secondIdentity = relayHistoryItemIdentity(second);
  if (firstIdentity && secondIdentity && firstIdentity === secondIdentity) {
    return true;
  }

  const firstCallId = relayHistoryItemCallId(first);
  const secondCallId = relayHistoryItemCallId(second);
  if (firstCallId && secondCallId && firstCallId === secondCallId) {
    return true;
  }

  if (isProgressPlanItem(first) && isProgressPlanItem(second)) {
    return true;
  }

  // JSONL line ids are source-local fallbacks, not provider identities. They
  // may reconcile semantically with a real app-server id; occurrence tracking
  // in the merge keeps intentional repeated rows distinct. Assistant messages
  // are exempt from the two-stable-ids refusal: the live-owner state keys them
  // by app-server event id (item_N) while the rollout records the provider id
  // (msg_...), so the same reply legitimately carries two stable identities.
  if (relayHistoryIdentityIsStable(firstIdentity)
    && relayHistoryIdentityIsStable(secondIdentity)
    && !(isRelayAssistantHistoryItem(first) && isRelayAssistantHistoryItem(second))) {
    return false;
  }
  if (relayHistoryIdentityIsStable(firstCallId)
    && relayHistoryIdentityIsStable(secondCallId)) {
    return false;
  }

  const firstType = normalizeHistoryItemToken(first?.type);
  const secondType = normalizeHistoryItemToken(second?.type);
  if (firstType === "imageview" && secondType === "imageview") {
    const firstPath = normalizeImageViewPathKey(first);
    const secondPath = normalizeImageViewPathKey(second);
    if (firstPath && firstPath === secondPath) {
      return true;
    }
  }
  if (firstType === "filechange" && secondType === "filechange") {
    const firstPaths = fileChangePathSet(first);
    const secondPaths = fileChangePathSet(second);
    if (firstPaths.size > 0
      && firstPaths.size === secondPaths.size
      && Array.from(firstPaths).every((pathKey) => secondPaths.has(pathKey))) {
      return true;
    }
  }

  const firstText = relayHistoryItemText(first);
  const secondText = relayHistoryItemText(second);
  if (!firstText || !secondText || firstText !== secondText) {
    return false;
  }

  return relayHistoryItemKindsCompatible(first, second);
}

function relayHistoryItemKindsCompatible(first, second) {
  const firstType = normalizeHistoryItemToken(first?.type);
  const secondType = normalizeHistoryItemToken(second?.type);
  if (firstType && secondType && firstType === secondType) {
    return true;
  }

  const firstRole = normalizeNonEmptyString(first?.role).toLowerCase();
  const secondRole = normalizeNonEmptyString(second?.role).toLowerCase();
  if (firstRole && secondRole && firstRole === secondRole) {
    return true;
  }

  return isRelayMessageLikeHistoryType(firstType) && isRelayMessageLikeHistoryType(secondType);
}

function isRelayMessageLikeHistoryType(itemType) {
  return itemType === "message"
    || itemType === "assistantmessage"
    || itemType === "agentmessage"
    || itemType === "usermessage";
}

function relayHistoryItemIdentity(item) {
  return normalizeNonEmptyString(item?.id)
    || normalizeNonEmptyString(item?.itemId)
    || normalizeNonEmptyString(item?.item_id);
}

function relayHistoryIdentityIsStable(identity) {
  const normalizedIdentity = normalizeNonEmptyString(identity);
  if (!normalizedIdentity) {
    return false;
  }
  return !/^(?:user-message-line|response-item-line|apply-patch-line)-\d+$/.test(normalizedIdentity);
}

function relayHistoryItemCallId(item) {
  return normalizeNonEmptyString(item?.call_id)
    || normalizeNonEmptyString(item?.callId);
}

function relayHistoryItemText(item) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    return "";
  }

  for (const key of ["text", "message", "summary", "output", "outputText", "output_text", "command"]) {
    const value = normalizeNonEmptyString(item[key]);
    if (value) {
      return value;
    }
  }

  if (Array.isArray(item.content)) {
    return item.content
      .map(relayHistoryItemText)
      .filter(Boolean)
      .join("\n");
  }

  return "";
}

function normalizeImageViewPathKey(item) {
  return normalizeNonEmptyString(item?.path)
    || normalizeNonEmptyString(item?.saved_path)
    || normalizeNonEmptyString(item?.savedPath)
    || normalizeNonEmptyString(item?.file_path)
    || normalizeNonEmptyString(item?.filePath);
}

function fileChangePathSet(item) {
  const paths = new Set();
  const changes = Array.isArray(item?.changes) ? item.changes : [];
  for (const change of changes) {
    const pathKey = normalizeFileChangePathKey(change?.path || change?.file || change?.filePath || change?.file_path);
    if (pathKey) {
      paths.add(pathKey);
    }
  }
  return paths;
}

function normalizeFileChangePathKey(value) {
  return normalizeNonEmptyString(value).replace(/\\/g, "/").replace(/^\/+/, "").toLowerCase();
}

function inferThreadIdFromTurns(turns) {
  if (!Array.isArray(turns)) {
    return "";
  }
  for (const turn of turns) {
    const threadId = normalizeNonEmptyString(turn?.threadId)
      || normalizeNonEmptyString(turn?.thread_id)
      || normalizeNonEmptyString(turn?.thread?.id)
      || normalizeNonEmptyString(turn?.thread?.threadId)
      || normalizeNonEmptyString(turn?.thread?.thread_id);
    if (threadId) {
      return threadId;
    }
  }
  return "";
}

function sanitizeRelayHistoryTurns(turns, threadId = "") {
  let didSanitize = false;
  const sanitizedTurns = turns.map((turn) => {
    const sanitizedTurn = sanitizeRelayHistoryTurn(turn, threadId);
    if (sanitizedTurn !== turn) {
      didSanitize = true;
    }
    return sanitizedTurn;
  });

  return { turns: sanitizedTurns, didSanitize };
}

function sanitizeRelayHistoryTurn(turn, threadId = "") {
  if (!turn || typeof turn !== "object" || !Array.isArray(turn.items)) {
    return turn;
  }

  let turnDidChange = false;
  const turnThreadId = normalizeNonEmptyString(threadId)
    || normalizeNonEmptyString(turn.threadId)
    || normalizeNonEmptyString(turn.thread_id);
  const sanitizedItems = turn.items.map((item) => {
    if (!item || typeof item !== "object") {
      return item;
    }

    let itemDidChange = false;
    let sanitizedItem = sanitizeUserRoleItem(item);
    if (!sanitizedItem) {
      turnDidChange = true;
      return null;
    }
    if (sanitizedItem !== item) {
      itemDidChange = true;
    }

    sanitizedItem = convertApplyPatchHistoryItem(sanitizedItem) || sanitizedItem;
    if (sanitizedItem !== item) {
      itemDidChange = true;
    }

    sanitizedItem = annotateImageGenerationHistoryItem(sanitizedItem, turnThreadId);
    if (sanitizedItem !== item) {
      itemDidChange = true;
    }

    if (Array.isArray(sanitizedItem.content)) {
      const sanitizedContent = sanitizedItem.content.map((contentItem) => {
        const sanitizedEntry = sanitizeInlineHistoryImageContentItem(contentItem);
        if (sanitizedEntry !== contentItem) {
          itemDidChange = true;
        }
        return sanitizedEntry;
      });

      if (itemDidChange) {
        sanitizedItem = {
          ...sanitizedItem,
          content: sanitizedContent,
        };
      }
    }

    const sanitizedCompactionItem = sanitizeCompactionHistoryItem(sanitizedItem);
    if (sanitizedCompactionItem !== sanitizedItem) {
      sanitizedItem = sanitizedCompactionItem;
      itemDidChange = true;
    }

    if (itemDidChange) {
      turnDidChange = true;
    }

    return itemDidChange ? sanitizedItem : item;
  }).filter(Boolean);

  return turnDidChange
    ? {
      ...turn,
      items: sanitizedItems,
    }
    : turn;
}

// Compatibility predicate for callers that only need a drop/no-drop decision.
// The full sanitizer below also rewrites mixed items without losing attachments.
const LIVE_ITEM_LIFECYCLE_METHODS = new Set([
  "item/started",
  "item/updated",
  "item/completed",
]);

function isContextualUserItemNotification(parsed) {
  const method = typeof parsed?.method === "string" ? parsed.method : "";
  if (!LIVE_ITEM_LIFECYCLE_METHODS.has(method)) {
    return false;
  }
  const item = parsed?.params?.item;
  if (!isUserRoleItem(item)) {
    return false;
  }
  return isContextualUserText(readUserItemText(item));
}

// Sanitizes both raw app-server item events and fallback user_message events
// before they can become mobile bubbles. Structured attachments stay intact.
function sanitizeLiveUserNotification(parsed) {
  if (!parsed || typeof parsed !== "object") {
    return parsed;
  }
  const method = typeof parsed.method === "string" ? parsed.method : "";
  if (LIVE_ITEM_LIFECYCLE_METHODS.has(method)) {
    const item = parsed?.params?.item;
    if (!isUserRoleItem(item)) {
      return parsed;
    }
    const sanitizedItem = sanitizeUserRoleItem(item);
    if (!sanitizedItem) {
      return null;
    }
    return sanitizedItem === item ? parsed : {
      ...parsed,
      params: { ...parsed.params, item: sanitizedItem },
    };
  }

  if (method !== "codex/event/user_message") {
    return parsed;
  }
  const key = typeof parsed?.params?.message === "string"
    ? "message"
    : (typeof parsed?.params?.text === "string" ? "text" : "");
  if (!key) {
    return parsed;
  }
  const visible = visibleUserPromptText(parsed.params[key]);
  if (!visible) {
    return null;
  }
  return visible === parsed.params[key] ? parsed : {
    ...parsed,
    params: { ...parsed.params, [key]: visible },
  };
}

function convertApplyPatchHistoryItem(item) {
  const itemType = normalizeHistoryItemToken(item?.type);
  const toolName = normalizeNonEmptyString(item?.name);
  if (toolName !== "apply_patch" || itemType !== "customtoolcall") {
    return null;
  }

  const fileChangeItem = buildApplyPatchFileChangeItem({
    callId: normalizeNonEmptyString(item.call_id) || normalizeNonEmptyString(item.callId) || normalizeNonEmptyString(item.id),
    patch: normalizeNonEmptyString(item.input),
    status: normalizeNonEmptyString(item.status) || "completed",
    idFallback: normalizeNonEmptyString(item.id) || "history-apply-patch-file-change",
  });
  return fileChangeItem ? { ...item, ...fileChangeItem } : null;
}

function normalizeHistoryItemToken(value) {
  return normalizeNonEmptyString(value).toLowerCase().replace(/[\s_-]+/g, "");
}

// Annotates live image-generation notifications so the phone can render a local-file
// preview and does not receive the bulky inline base64 result over the relay.
function sanitizeLiveGeneratedImageMessageForRelay(rawMessage) {
  const parsed = parseBridgeJSON(rawMessage);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return rawMessage;
  }

  const params = parsed.params;
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    return rawMessage;
  }

  const sanitizedParams = sanitizeLiveGeneratedImageParams(params);
  if (sanitizedParams === params) {
    return rawMessage;
  }

  return JSON.stringify({
    ...parsed,
    params: sanitizedParams,
  });
}

function sanitizeLiveGeneratedImageParams(params) {
  const threadId = liveGeneratedImageThreadId(params);
  let nextParams = params;
  let didChange = false;

  const item = params.item;
  if (item && typeof item === "object" && !Array.isArray(item)) {
    const sanitizedItem = annotateImageGenerationPayload(item, threadId);
    if (sanitizedItem !== item) {
      nextParams = { ...nextParams, item: sanitizedItem };
      didChange = true;
    }
  }

  const event = params.event;
  if (event && typeof event === "object" && !Array.isArray(event)) {
    const sanitizedEvent = sanitizeNestedGeneratedImagePayloads(event, threadId);
    if (sanitizedEvent !== event) {
      nextParams = { ...nextParams, event: sanitizedEvent };
      didChange = true;
    }
  }

  const sanitizedDirectParams = annotateImageGenerationPayload(nextParams, threadId);
  if (sanitizedDirectParams !== nextParams) {
    nextParams = sanitizedDirectParams;
    didChange = true;
  }

  return didChange ? nextParams : params;
}

function sanitizeNestedGeneratedImagePayloads(value, threadId) {
  let nextValue = annotateImageGenerationPayload(value, threadId);
  let didChange = nextValue !== value;

  for (const key of ["item", "payload", "data"]) {
    const nested = nextValue?.[key];
    if (!nested || typeof nested !== "object" || Array.isArray(nested)) {
      continue;
    }
    const sanitizedNested = sanitizeNestedGeneratedImagePayloads(nested, threadId);
    if (sanitizedNested !== nested) {
      if (!didChange) {
        nextValue = { ...nextValue };
        didChange = true;
      }
      nextValue[key] = sanitizedNested;
    }
  }

  return didChange ? nextValue : value;
}

// Drops huge replacement-history blobs from compaction items because the phone only needs
// the compacted marker itself, not the entire pre-compaction transcript snapshot.
function sanitizeCompactionHistoryItem(item) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    return item;
  }

  let sanitizedItem = omitCompactionReplacementHistory(item);
  const payload = sanitizedItem.payload;
  if (payload && typeof payload === "object" && !Array.isArray(payload)) {
    const sanitizedPayload = omitCompactionReplacementHistory(payload);
    if (sanitizedPayload !== payload) {
      sanitizedItem = {
        ...sanitizedItem,
        payload: sanitizedPayload,
      };
    }
  }

  return sanitizedItem;
}

function omitCompactionReplacementHistory(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return value;
  }

  let nextValue = value;
  let didChange = false;
  for (const key of ["replacement_history", "replacementHistory"]) {
    if (Object.prototype.hasOwnProperty.call(nextValue, key)) {
      if (!didChange) {
        nextValue = { ...nextValue };
        didChange = true;
      }
      delete nextValue[key];
    }
  }

  return didChange ? nextValue : value;
}

function annotateImageGenerationHistoryItem(item, threadId) {
  if (!item || typeof item !== "object") {
    return item;
  }

  const normalizedType = normalizeRelayHistoryContentType(item.type);
  if (!isGeneratedImageRelayType(normalizedType)) {
    return item;
  }

  return annotateImageGenerationPayload(item, threadId);
}

function annotateImageGenerationPayload(item, threadId) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    return item;
  }

  const normalizedType = normalizeRelayHistoryContentType(item.type);
  if (!isGeneratedImageRelayType(normalizedType)) {
    return item;
  }

  let nextItem = item;
  let didChange = false;
  const existingPath = normalizeNonEmptyString(item.saved_path)
    || normalizeNonEmptyString(item.savedPath)
    || normalizeNonEmptyString(item.path)
    || normalizeNonEmptyString(item.file_path);
  const generatedPath = existingPath || generatedImagePathForHistoryItem(item, threadId);
  if (generatedPath && !existingPath) {
    nextItem = {
      ...nextItem,
      saved_path: generatedPath,
    };
    didChange = true;
  }

  if (typeof nextItem.result === "string" && nextItem.result.length > 0) {
    const {
      result: _result,
      ...withoutInlineResult
    } = nextItem;
    nextItem = {
      ...withoutInlineResult,
      result_elided_for_relay: true,
    };
    didChange = true;
  }

  return didChange ? nextItem : item;
}

function generatedImagePathForHistoryItem(item, threadId) {
  const resolvedThreadId = normalizeNonEmptyString(threadId);
  const normalizedType = normalizeRelayHistoryContentType(item.type);
  const callId = normalizedType === "imagegenerationend"
    ? normalizeNonEmptyString(item.call_id)
      || normalizeNonEmptyString(item.callId)
      || normalizeNonEmptyString(item.itemId)
      || normalizeNonEmptyString(item.item_id)
      || normalizeNonEmptyString(item.id)
    : normalizeNonEmptyString(item.id)
      || normalizeNonEmptyString(item.call_id)
      || normalizeNonEmptyString(item.callId)
      || normalizeNonEmptyString(item.itemId)
      || normalizeNonEmptyString(item.item_id);
  if (!resolvedThreadId || !callId) {
    return "";
  }

  return path.join(resolveCodexGeneratedImagesRoot(), resolvedThreadId, `${callId}.png`);
}

function isGeneratedImageRelayType(normalizedType) {
  return normalizedType === "imagegeneration"
    || normalizedType === "imagegenerationcall"
    || normalizedType === "imagegenerationend"
    || normalizedType === "imageview";
}

function liveGeneratedImageThreadId(params) {
  const event = params?.event && typeof params.event === "object" && !Array.isArray(params.event)
    ? params.event
    : null;
  const item = params?.item && typeof params.item === "object" && !Array.isArray(params.item)
    ? params.item
    : null;

  return normalizeNonEmptyString(params?.threadId)
    || normalizeNonEmptyString(params?.thread_id)
    || normalizeNonEmptyString(params?.conversationId)
    || normalizeNonEmptyString(params?.conversation_id)
    || normalizeNonEmptyString(event?.threadId)
    || normalizeNonEmptyString(event?.thread_id)
    || normalizeNonEmptyString(event?.conversationId)
    || normalizeNonEmptyString(event?.conversation_id)
    || normalizeNonEmptyString(item?.threadId)
    || normalizeNonEmptyString(item?.thread_id)
    || "";
}

// Converts `data:image/...` history content into a tiny placeholder the iPhone can render safely.
function sanitizeInlineHistoryImageContentItem(contentItem) {
  if (!contentItem || typeof contentItem !== "object") {
    return contentItem;
  }

  const normalizedType = normalizeRelayHistoryContentType(contentItem.type);
  if (!isRelayHistoryImageContentType(normalizedType)) {
    return contentItem;
  }

  const hasInlineUrl = hasInlineHistoryImageDataURL(contentItem.url)
    || hasInlineHistoryImageDataURL(contentItem.image_url)
    || hasInlineHistoryImageDataURL(contentItem.path);
  if (!hasInlineUrl) {
    return contentItem;
  }

  const {
    url: _url,
    image_url: _imageUrl,
    path: _path,
    ...rest
  } = contentItem;

  return {
    ...rest,
    url: RELAY_HISTORY_IMAGE_REFERENCE_URL,
  };
}

function normalizeRelayHistoryContentType(value) {
  return typeof value === "string"
    ? value.toLowerCase().replace(/[\s_-]+/g, "")
    : "";
}

// Covers Codex history variants such as image, local_image, and input_image.
function isRelayHistoryImageContentType(normalizedType) {
  return normalizedType === "image"
    || normalizedType === "localimage"
    || normalizedType === "inputimage"
    || normalizedType === "outputimage";
}

function hasInlineHistoryImageDataURL(value) {
  if (typeof value === "string") {
    return value.toLowerCase().startsWith("data:image");
  }

  if (Array.isArray(value)) {
    return value.some(hasInlineHistoryImageDataURL);
  }

  if (value && typeof value === "object") {
    return Object.values(value).some(hasInlineHistoryImageDataURL);
  }

  return false;
}

function parseBridgeJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function trimThreadPayloadForRelay(parsed, explicitThread = undefined, options = {}) {
  const thread = explicitThread ?? parsed?.result?.thread;
  if (!parsed || !thread || typeof thread !== "object" || !Array.isArray(thread.turns)) {
    return null;
  }

  // Callers that pre-trimmed the turn window pass the dropped count and the original
  // first turn here so compaction markers keep reporting whole-thread numbers.
  const preOmittedTurnCount = Math.max(0, options.preOmittedTurnCount ?? 0);
  const compactionIdSource = options.compactionIdSource ?? null;

  let workingThread = thread;
  let encoded = encodeRelayThreadPayload(parsed, workingThread);
  if (encoded == null) {
    return null;
  }

  if (Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
    if (preOmittedTurnCount <= 0) {
      return explicitThread === undefined ? null : encoded;
    }
    const compactedThread = buildRelayHistoryCompactedThread(
      thread,
      buildRelayCompactedHistoryTurns(thread.turns, thread.turns, preOmittedTurnCount, compactionIdSource),
      preOmittedTurnCount,
      thread.turns.length
    );
    return encodeRelayThreadPayload(parsed, compactedThread) ?? encoded;
  }

  const turns = thread.turns;
  let trimmedTurns = turns.length > RELAY_HISTORY_RECENT_TURN_TARGET
    ? turns.slice(-RELAY_HISTORY_RECENT_TURN_TARGET)
    : turns.slice();
  while (trimmedTurns.length > 1) {
    if (trimmedTurns.length === turns.length) {
      trimmedTurns = trimmedTurns.slice(1);
    }
    const candidateThread = buildRelayHistoryCompactedThread(
      thread,
      buildRelayCompactedHistoryTurns(turns, trimmedTurns, preOmittedTurnCount, compactionIdSource),
      preOmittedTurnCount + Math.max(0, turns.length - trimmedTurns.length),
      trimmedTurns.length
    );
    encoded = encodeRelayThreadPayload(parsed, candidateThread);
    if (encoded != null && Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
      return encoded;
    }
    workingThread = candidateThread;
    trimmedTurns = trimmedTurns.slice(1);
  }

  const newestTurn = trimmedTurns[0];
  if (!newestTurn || typeof newestTurn !== "object" || !Array.isArray(newestTurn.items)) {
    return encodeRelayThreadPayload(parsed, workingThread);
  }

  let trimmedItems = newestTurn.items.slice();
  while (trimmedItems.length > 1) {
    trimmedItems = trimmedItems.slice(1);
    const compactedTurnPrefix = buildRelayHistoryCompactionTurn(
      preOmittedTurnCount + Math.max(0, turns.length - 1),
      1,
      compactionIdSource ?? thread
    );
    const candidateThread = buildRelayHistoryCompactedThread(
      thread,
      compactedTurnPrefix ? [compactedTurnPrefix, {
        ...newestTurn,
        items: trimmedItems,
      }] : [{
        ...newestTurn,
        items: trimmedItems,
      }],
      preOmittedTurnCount + Math.max(0, turns.length - 1),
      1
    );
    encoded = encodeRelayThreadPayload(parsed, candidateThread);
    if (encoded != null && Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
      return encoded;
    }
    workingThread = candidateThread;
  }

  const mostRecentItem = trimmedItems[0];
  if (!mostRecentItem || typeof mostRecentItem !== "object") {
    return encodeRelayThreadPayload(parsed, workingThread);
  }

  const truncatedItem = truncateHistoryItemTextForRelay(
    mostRecentItem,
    RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS
  );
  let candidateThread = buildRelayHistoryCompactedThread(
    thread,
    [
      ...buildRelayCompactedHistoryTurns(turns, [newestTurn], preOmittedTurnCount, compactionIdSource).slice(0, -1),
      {
        ...newestTurn,
        items: [truncatedItem],
      },
    ],
    preOmittedTurnCount + Math.max(0, turns.length - 1),
    1
  );
  encoded = encodeRelayThreadPayload(parsed, candidateThread);
  if (encoded != null && Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
    return encoded;
  }

  candidateThread = buildRelayHistoryCompactedThread(
    thread,
    [
      ...buildRelayCompactedHistoryTurns(turns, [newestTurn], preOmittedTurnCount, compactionIdSource).slice(0, -1),
      {
        ...newestTurn,
        items: [compactHistoryItemForRelay(mostRecentItem, RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS)],
      },
    ],
    preOmittedTurnCount + Math.max(0, turns.length - 1),
    1
  );
  return encodeRelayThreadPayload(parsed, candidateThread);
}

function trimTurnsListPayloadForRelay(parsed, turnsKey, originalRawMessage = null) {
  const result = parsed?.result;
  const turns = result?.[turnsKey];
  if (!parsed || !result || !Array.isArray(turns)) {
    return originalRawMessage ?? JSON.stringify(parsed);
  }

  const encoded = JSON.stringify(parsed);
  if (Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
    return originalRawMessage ?? encoded;
  }

  let fallbackCompactedPayload = null;
  for (const maxChars of [
    RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS,
    Math.floor(RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS / 4),
    1_000,
    0,
  ]) {
    const compactedTurns = turns.map((turn) => compactTurnsListTurnForRelay(turn, maxChars));
    const compactedPayload = JSON.stringify({
      ...parsed,
      result: {
        ...result,
        [turnsKey]: compactedTurns,
        remodexPageCompactedForRelay: true,
      },
    });
    fallbackCompactedPayload = compactedPayload;
    if (Buffer.byteLength(compactedPayload, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
      return compactedPayload;
    }
  }

  // A bounded JSONL first page can still describe one exceptionally large
  // turn with many small items. Keep that provisional response relay-safe while
  // preserving its handoff flags/cursor; the canonical background page will
  // replace it with the authoritative history.
  if (result.remodexJsonlFallback === true) {
    for (const maxItems of [64, 16, 4, 1]) {
      for (const maxChars of [1_000, 0]) {
        const emergencyTurns = turns.map((turn) => (
          compactEmergencySingleTurnForRelay(turn, maxChars, maxItems)
        ));
        const emergencyPayload = JSON.stringify({
          ...parsed,
          result: {
            ...result,
            [turnsKey]: emergencyTurns,
            remodexPageCompactedForRelay: true,
            remodexEmergencyJsonlPageForRelay: true,
          },
        });
        if (Buffer.byteLength(emergencyPayload, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
          return emergencyPayload;
        }
      }
    }
  }

  return fallbackCompactedPayload ?? (originalRawMessage ?? encoded);
}

function compactTurnsListTurnForRelay(turn, maxChars) {
  if (!turn || typeof turn !== "object" || !Array.isArray(turn.items)) {
    return turn;
  }

  return {
    ...turn,
    items: turn.items.map((item) => compactHistoryItemForRelay(item, maxChars)),
    remodexPageCompactedForRelay: true,
  };
}

function buildRelayHistoryCompactedThread(thread, turns, omittedTurnCount, keptTurnCount) {
  return {
    ...thread,
    turns,
    historyTailTruncatedForRelay: true,
    remodexHistoryCompacted: omittedTurnCount > 0,
    remodexOmittedTurnCount: omittedTurnCount,
    remodexKeptTurnCount: keptTurnCount,
  };
}

function buildRelayCompactedHistoryTurns(allTurns, keptTurns, preOmittedTurnCount = 0, idSourceOverride = null) {
  const omittedTurnCount = preOmittedTurnCount + Math.max(0, allTurns.length - keptTurns.length);
  const compactionTurn = buildRelayHistoryCompactionTurn(
    omittedTurnCount,
    keptTurns.length,
    idSourceOverride ?? allTurns[0]
  );
  return compactionTurn ? [compactionTurn, ...keptTurns] : keptTurns;
}

function buildRelayHistoryCompactionTurn(omittedTurnCount, keptTurnCount, idSource = {}) {
  if (omittedTurnCount <= 0) {
    return null;
  }

  const baseId = normalizeNonEmptyString(idSource?.id)
    || normalizeNonEmptyString(idSource?.turnId)
    || normalizeNonEmptyString(idSource?.turn_id)
    || "history";
  const text = [
    "Earlier conversation compacted for mobile loading.",
    "",
    `Older turns omitted: ${omittedTurnCount}`,
    `Recent turns kept: ${keptTurnCount}`,
    "Full history remains available on the Mac runtime.",
  ].join("\n");

  return {
    id: `remodex-history-compacted-${baseId}`,
    // A status-less turn reads as interruptible/running to the phone's
    // turn-state snapshot, flagging idle heavy threads as "thinking".
    status: "completed",
    remodexSynthetic: true,
    remodexHistoryCompacted: true,
    remodexOmittedTurnCount: omittedTurnCount,
    remodexKeptTurnCount: keptTurnCount,
    items: [
      {
        id: `remodex-history-compacted-item-${baseId}`,
        type: "assistant_message",
        role: "assistant",
        text,
        remodexSynthetic: true,
        remodexHistoryCompacted: true,
      },
    ],
  };
}

function encodeRelayThreadPayload(parsed, thread) {
  try {
    return JSON.stringify({
      ...parsed,
      result: {
        ...parsed.result,
        thread,
      },
    });
  } catch {
    return null;
  }
}

function truncateHistoryItemTextForRelay(item, maxChars) {
  if (!item || typeof item !== "object" || Array.isArray(item)) {
    return item;
  }

  let didChange = false;
  let nextItem = item;
  const textKeys = ["text", "message", "summary", "output", "outputText", "output_text"];

  for (const key of textKeys) {
    if (typeof item[key] === "string" && item[key].length > maxChars) {
      nextItem = {
        ...nextItem,
        [key]: truncateRelayTextTail(item[key], maxChars),
      };
      didChange = true;
    }
  }

  if (Array.isArray(item.content)) {
    const nextContent = item.content.map((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        return entry;
      }

      const truncatedEntry = truncateHistoryItemTextForRelay(entry, maxChars);
      if (truncatedEntry !== entry) {
        didChange = true;
      }
      return truncatedEntry;
    });

    if (didChange) {
      nextItem = {
        ...nextItem,
        content: nextContent,
      };
    }
  }

  return didChange
    ? {
      ...nextItem,
      relayTextTailTruncated: true,
    }
    : item;
}

function compactHistoryItemForRelay(item, maxChars) {
  const compactItem = {
    id: typeof item?.id === "string" ? item.id : undefined,
    type: typeof item?.type === "string" ? item.type : "relay_truncated_item",
    role: typeof item?.role === "string" ? item.role : undefined,
    itemId: typeof item?.itemId === "string" ? item.itemId : undefined,
    turnId: typeof item?.turnId === "string" ? item.turnId : undefined,
    turn_id: typeof item?.turn_id === "string" ? item.turn_id : undefined,
    createdAt: relayScalarHistoryMetadata(item?.createdAt),
    created_at: relayScalarHistoryMetadata(item?.created_at),
    startedAt: relayScalarHistoryMetadata(item?.startedAt),
    started_at: relayScalarHistoryMetadata(item?.started_at),
    completedAt: relayScalarHistoryMetadata(item?.completedAt),
    completed_at: relayScalarHistoryMetadata(item?.completed_at),
    timestamp: relayScalarHistoryMetadata(item?.timestamp),
    time: relayScalarHistoryMetadata(item?.time),
    timeZoneIdentifier: relayScalarHistoryMetadata(item?.timeZoneIdentifier),
    timeZone: relayScalarHistoryMetadata(item?.timeZone),
    timezone: relayScalarHistoryMetadata(item?.timezone),
    time_zone: relayScalarHistoryMetadata(item?.time_zone),
    relayPayloadTruncated: true,
  };
  const tailText = maxChars > 0 ? firstRelayTextTail(item, maxChars) : "";
  if (tailText) {
    compactItem.text = tailText;
  }

  return Object.fromEntries(
    Object.entries(compactItem).filter(([, value]) => value !== undefined)
  );
}

function relayScalarHistoryMetadata(value) {
  return typeof value === "string" || typeof value === "number" ? value : undefined;
}

function firstRelayTextTail(value, maxChars) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return "";
  }

  for (const key of ["text", "message", "summary", "output", "outputText", "output_text"]) {
    if (typeof value[key] === "string" && value[key].trim()) {
      return truncateRelayTextTail(value[key], maxChars);
    }
  }

  if (Array.isArray(value.content)) {
    for (const entry of value.content) {
      const tail = firstRelayTextTail(entry, maxChars);
      if (tail) {
        return tail;
      }
    }
  }

  return "";
}

function truncateRelayTextTail(value, maxChars) {
  if (typeof value !== "string" || value.length <= maxChars) {
    return value;
  }

  const tail = value.slice(-maxChars).trimStart();
  return `…\n${tail}`;
}

function persistBridgePreferences(
  {
    keepMacAwakeEnabled,
  },
  {
    readDaemonConfigImpl = readDaemonConfig,
    writeDaemonConfigImpl = writeDaemonConfig,
  } = {}
) {
  writeDaemonConfigImpl({
    ...(readDaemonConfigImpl() || {}),
    keepMacAwakeEnabled,
  });
}

function shouldSuppressRolloutMirrorForThread(
  threadId,
  { desktopIpcActionFollower = null, desktopIpcLiveOwner = null } = {},
  { fallbackActivityAt = 0 } = {}
) {
  // Desktop ownership is an expiring live lease, not a permanent boolean. A
  // stale IPC snapshot used to mute an actively growing rollout forever.
  const followerIsFresh = typeof desktopIpcActionFollower?.hasFreshLiveThreadState === "function"
    ? desktopIpcActionFollower.hasFreshLiveThreadState(threadId, { fallbackActivityAt })
    : desktopIpcActionFollower?.hasLiveThreadState(threadId);
  const ownerIsFresh = typeof desktopIpcLiveOwner?.isFreshThreadOwned === "function"
    ? desktopIpcLiveOwner.isFreshThreadOwned(threadId)
    : false;
  return Boolean(followerIsFresh) || Boolean(ownerIsFresh);
}

module.exports = {
  annotateTurnStateProbeWithMirrorActiveTurn,
  buildThreadTurnsListRelaySanitizeContext,
  buildHeartbeatBridgeStatus,
  canonicalThreadTurnsListRequest,
  createMacOSBridgeWakeAssertion,
  createThreadTurnsListFastPageCoordinator,
  disableUnsupportedReasoningSummaryForTurnStart,
  fetchAdaptiveThreadTurnsListForRelay,
  hasRelayConnectionGoneStale,
  isContextualUserItemNotification,
  maybeMergeLatestJsonlTurnIntoTurnsListResponse,
  normalizeTurnStartForCodex,
  normalizeRelayBoundJsonRpcMessage,
  persistBridgePreferences,
  resolveJsonlTurnsListRolloutPathForFallback,
  sanitizeLiveGeneratedImageMessageForRelay,
  sanitizeLiveUserNotification,
  sanitizeThreadHistoryImagesForRelay,
  shouldSuppressRolloutMirrorForThread,
  startBridge,
};
