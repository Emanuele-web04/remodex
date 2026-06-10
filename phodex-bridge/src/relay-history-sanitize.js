// FILE: relay-history-sanitize.js
// Purpose: Relay/history sanitization and adaptive turns-list helpers for mobile delivery.
// Layer: Bridge shared utility
// Depends on: fs, path, ./safe-json, ./rollout-watch, ./session-jsonl-history, ./apply-patch-changes, ./codex-home

const fs = require("fs");
const path = require("path");
const { safeParseJSON } = require("./safe-json");
const {
  findRecentRolloutFileForContextRead,
  resolveSessionsRoot,
} = require("./rollout-watch");
const { parseSessionJsonlMetadata, parseSessionJsonlTurns } = require("./session-jsonl-history");
const { buildApplyPatchFileChangeItem } = require("./apply-patch-changes");
const { resolveCodexGeneratedImagesRoot } = require("./codex-home");

const RELAY_HISTORY_IMAGE_REFERENCE_URL = "remodex://history-image-elided";
const RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES = 4 * 1024 * 1024;
const RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS = 24_000;
const RELAY_HISTORY_RECENT_TURN_TARGET = 40;
const RELAY_TURNS_LIST_TARGET_BUDGET_MS = 5_500;
const RELAY_TURNS_LIST_BUDGET_RESERVE_MS = 1_000;
const RELAY_TURNS_LIST_MAX_INITIAL_LIMIT = 5;
const RELAY_TURNS_LIST_SAFE_RETRY_LIMIT = 5;
const RELAY_JSONL_ARTIFACT_CACHE_TTL_MS = 2_000;
const RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES = 128;
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
const jsonlArtifactItemsCacheByThread = new Map();

function normalizeNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function parseBridgeJSON(value) {
  return safeParseJSON(value);
}

function threadIdFromRequestParams(params) {
  return (
    normalizeNonEmptyString(params?.threadId) ||
    normalizeNonEmptyString(params?.thread_id) ||
    normalizeNonEmptyString(params?.id) ||
    ""
  );
}

function buildThreadTurnsListRelaySanitizeContext(
  request,
  { skipJsonlArtifactAugmentation = false } = {},
) {
  return {
    threadId: threadIdFromRequestParams(request?.params || {}),
    skipJsonlArtifactAugmentation,
  };
}

async function fetchAdaptiveThreadTurnsListForRelay(
  request,
  {
    fetchPage,
    now = Date.now,
    targetBudgetMs = RELAY_TURNS_LIST_TARGET_BUDGET_MS,
    budgetReserveMs = RELAY_TURNS_LIST_BUDGET_RESERVE_MS,
    rawPageSoftLimitBytes = RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES,
    payloadSoftLimitBytes = RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES,
    sanitizeForRelay = sanitizeThreadHistoryImagesForRelay,
  } = {},
) {
  if (typeof fetchPage !== "function") {
    throw new Error("fetchPage is required for adaptive turns-list pagination.");
  }

  const params = request?.params;
  const requestedLimit =
    Number.isInteger(params?.limit) && params.limit > 0
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
    let page;

    try {
      page = await fetchMeasuredAdaptiveTurnsListPage(fetchPage, pageParams, now);
    } catch {
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
    response = buildSafeTurnsListResponse(
      request.id,
      firstResult,
      lastResult,
      turnsKey,
      combinedTurns,
    );

    if (
      measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) >=
      payloadSoftLimitBytes
    ) {
      response =
        buildLargestSafeTurnsListResponse({
          requestId: request.id,
          firstResult,
          lastResult,
          turnsKey,
          turns: combinedTurns,
          maxTurns: RELAY_TURNS_LIST_SAFE_RETRY_LIMIT,
          sanitizeForRelay,
          sanitizeContext,
          payloadSoftLimitBytes,
        }) ?? buildEmptyTurnsListResponse(request);
      break;
    }

    nextCursor = readTurnsListNextCursor(pageResult);
    if (
      combinedTurns.length >= requestedLimit ||
      !hasRelayCursor(nextCursor) ||
      pageTurns.length === 0
    ) {
      break;
    }

    const rawPageBytes = jsonByteLength(pageResult);
    const sanitizedResponseBytes = measureSanitizedTurnsListResponseBytes(
      response,
      sanitizeForRelay,
      sanitizeContext,
    );
    const elapsedMs = Math.max(0, now() - startedAt);
    const remainingBudgetMs = Math.max(0, targetBudgetMs - elapsedMs);
    if (
      rawPageBytes >= rawPageSoftLimitBytes ||
      sanitizedResponseBytes >= payloadSoftLimitBytes ||
      page.elapsedMs >= Math.max(0, targetBudgetMs - budgetReserveMs) ||
      remainingBudgetMs <= budgetReserveMs
    ) {
      break;
    }
  }

  return (
    response ?? {
      id: request.id,
      result: {
        data: [],
      },
    }
  );
}

function buildEmptyTurnsListResponse(request) {
  return {
    id: request.id,
    result: {
      data: [],
      nextCursor: null,
    },
  };
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

function maybeMergeLatestJsonlTurnIntoTurnsListResponse(
  request,
  response,
  jsonlResult,
  params = {},
) {
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

  const requestedLimit =
    Number.isInteger(params?.limit) && params.limit > 0 ? params.limit : responseTurns.length + 1;
  const mergedTurns = [jsonlTurn, ...responseTurns].slice(0, requestedLimit);
  return {
    id: request.id,
    result: {
      ...responseResult,
      [responseTurnsKey]: mergedTurns,
      remodexJsonlMergedLatest: true,
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

  return (
    Array.isArray(turn.items) &&
    turn.items.some((item) => {
      const type = normalizeHistoryItemToken(item?.type);
      return type === "plan" || type === "filechange";
    })
  );
}

function turnListTurnIdentifier(turn) {
  return (
    normalizeNonEmptyString(turn?.id) ||
    normalizeNonEmptyString(turn?.turnId) ||
    normalizeNonEmptyString(turn?.turn_id)
  );
}

async function fetchSafeThreadTurnsListFallback(
  request,
  { fetchPage, now, sanitizeForRelay, sanitizeContext = {}, payloadSoftLimitBytes },
) {
  const params = request?.params;
  const requestedLimit =
    Number.isInteger(params?.limit) && params.limit > 0
      ? params.limit
      : RELAY_TURNS_LIST_SAFE_RETRY_LIMIT;
  const safeLimit = Math.min(requestedLimit, RELAY_TURNS_LIST_SAFE_RETRY_LIMIT);
  const safeParams = buildAdaptiveTurnsListPageParams(params, safeLimit, params?.cursor);

  try {
    const page = await fetchMeasuredAdaptiveTurnsListPage(fetchPage, safeParams, now);
    const pageResult = unwrapAppServerPayloadResult(page.result);
    const turnsKey = findTurnsListResultKey(pageResult);
    if (!turnsKey) {
      return buildEmptyTurnsListResponse(request);
    }

    // If the normal pagination path returns a bad first page, retry once with a small page.
    // The retry response is intentionally minimal so Swift does not decode stale server metadata.
    const response = buildLargestSafeTurnsListResponse({
      requestId: request.id,
      firstResult: pageResult,
      lastResult: pageResult,
      turnsKey,
      turns: pageResult[turnsKey],
      maxTurns: safeLimit,
      sanitizeForRelay,
      sanitizeContext,
      payloadSoftLimitBytes,
    });
    if (response) {
      return response;
    }
  } catch {
    // Fall through to a valid empty page: the phone can keep the thread open instead of crashing.
  }

  return buildEmptyTurnsListResponse(request);
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
      turns.slice(0, count),
    );
    if (
      measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) <
      payloadSoftLimitBytes
    ) {
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
      if (
        measureSanitizedTurnsListResponseBytes(response, sanitizeForRelay, sanitizeContext) <
        payloadSoftLimitBytes
      ) {
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
  safeTurn.items = items.slice(-maxItems).map((item) => compactHistoryItemForRelay(item, maxChars));
  safeTurn.remodexEmergencySingleTurnForRelay = true;
  safeTurn.remodexPageCompactedForRelay = true;
  return safeTurn;
}

function buildAdaptiveTurnsListResult(firstResult, lastResult, turnsKey, turns) {
  const result = {};
  result[turnsKey] = turns;

  for (const key of RELAY_TURNS_LIST_PAGINATION_RESULT_KEYS) {
    if (Object.prototype.hasOwnProperty.call(lastResult, key)) {
      result[key] = lastResult[key];
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

  const directPayloadKeys = ["data", "items", "threads", "turns", "thread"];
  const hasDirectResultPayload = directPayloadKeys.some((key) =>
    Object.prototype.hasOwnProperty.call(payload, key),
  );
  if (!hasDirectResultPayload) {
    return value;
  }

  return {
    ...value,
    ...payload,
  };
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

  const threadId =
    normalizeNonEmptyString(requestContext?.threadId) ||
    normalizeNonEmptyString(thread.id) ||
    normalizeNonEmptyString(thread.threadId) ||
    normalizeNonEmptyString(thread.thread_id);
  const { turns: sanitizedTurns, didSanitize } = sanitizeRelayHistoryTurns(thread.turns, threadId);
  const { thread: threadWithJsonlMetadata, didAugment: didAugmentThreadMetadata } =
    augmentRelayThreadWithJsonlMetadata(thread, threadId);
  const { turns: augmentedTurns, didAugment } = augmentRelayHistoryTurnsWithJsonlArtifacts(
    sanitizedTurns,
    threadId,
  );

  if (!didSanitize && !didAugment && !didAugmentThreadMetadata) {
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

  return trimThreadPayloadForRelay(parseBridgeJSON(sanitizedPayload), null) ?? sanitizedPayload;
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

  const threadId =
    normalizeNonEmptyString(requestContext?.threadId) ||
    normalizeNonEmptyString(result.threadId) ||
    normalizeNonEmptyString(result.thread_id) ||
    normalizeNonEmptyString(result.thread?.id) ||
    normalizeNonEmptyString(result.thread?.threadId) ||
    normalizeNonEmptyString(result.thread?.thread_id) ||
    inferThreadIdFromTurns(result[turnsKey]);
  const { turns: sanitizedTurns, didSanitize } = sanitizeRelayHistoryTurns(
    result[turnsKey],
    threadId,
  );
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

  if (
    normalizeNonEmptyString(thread.cwd) === cwd &&
    normalizeNonEmptyString(thread.current_working_directory) === cwd
  ) {
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

  try {
    const rolloutPath = findRecentRolloutFileForContextRead(resolveSessionsRoot(), {
      threadId: normalizedThreadId,
    });
    if (!rolloutPath) {
      return "";
    }

    const metadata = parseSessionJsonlMetadata(fs.readFileSync(rolloutPath, "utf8"));
    const cwd = normalizeNonEmptyString(metadata?.cwd);
    return cwd && path.isAbsolute(cwd) ? cwd : "";
  } catch {
    return "";
  }
}

function augmentRelayHistoryTurnsWithJsonlArtifacts(turns, threadId = "") {
  const normalizedThreadId = normalizeNonEmptyString(threadId);
  if (!normalizedThreadId || !Array.isArray(turns) || turns.length === 0) {
    return { turns, didAugment: false };
  }

  const jsonlArtifactsByTurnId = readJsonlArtifactItemsByTurnId(normalizedThreadId);
  if (jsonlArtifactsByTurnId.size === 0) {
    return { turns, didAugment: false };
  }

  let didAugment = false;
  const augmentedTurns = turns.map((turn) => {
    const turnId =
      normalizeNonEmptyString(turn?.id) ||
      normalizeNonEmptyString(turn?.turnId) ||
      normalizeNonEmptyString(turn?.turn_id);
    const artifacts = turnId ? jsonlArtifactsByTurnId.get(turnId) : null;
    if (!artifacts || !turn || typeof turn !== "object") {
      return turn;
    }

    const items = Array.isArray(turn.items) ? turn.items : [];
    let nextItems = items;
    if (
      artifacts.fileChangeItem &&
      !hasEquivalentFileChangeItem(nextItems, artifacts.fileChangeItem)
    ) {
      nextItems = nextItems === items ? [...items] : nextItems;
      nextItems.push(artifacts.fileChangeItem);
    }
    for (const imageViewItem of artifacts.imageViewItems || []) {
      if (hasEquivalentImageViewItem(nextItems, imageViewItem)) {
        continue;
      }
      nextItems = nextItems === items ? [...items] : nextItems;
      nextItems.push(imageViewItem);
    }
    if (artifacts.progressPlanItem && !hasEquivalentProgressPlanItem(nextItems, artifacts.progressPlanItem)) {
      nextItems = nextItems === items ? [...items] : nextItems;
      nextItems.push(artifacts.progressPlanItem);
    }

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

function readJsonlArtifactItemsByTurnId(threadId) {
  const emptyArtifactsByTurnId = new Map();
  const normalizedThreadId = normalizeNonEmptyString(threadId);
  if (!normalizedThreadId) {
    return emptyArtifactsByTurnId;
  }

  const sessionsRoot = resolveSessionsRoot();
  const cacheKey = buildJsonlArtifactItemsCacheKey(sessionsRoot, normalizedThreadId);
  const cachedArtifacts = readCachedJsonlArtifactItems(cacheKey, normalizedThreadId);
  if (cachedArtifacts) {
    return cachedArtifacts;
  }

  try {
    const rolloutPath = findRecentRolloutFileForContextRead(sessionsRoot, {
      threadId: normalizedThreadId,
    });
    if (!rolloutPath) {
      jsonlArtifactItemsCacheByThread.delete(cacheKey);
      return emptyArtifactsByTurnId;
    }

    return readAndCacheJsonlArtifactItems(cacheKey, rolloutPath, normalizedThreadId);
  } catch (error) {
    jsonlArtifactItemsCacheByThread.delete(cacheKey);
    console.warn(
      `[remodex] history jsonl artifact augmentation failed for ${normalizedThreadId}: ${error.message}`,
    );
  }

  return emptyArtifactsByTurnId;
}

function buildJsonlArtifactItemsCacheKey(sessionsRoot, threadId) {
  return `${sessionsRoot}\0${threadId}`;
}

function readCachedJsonlArtifactItems(cacheKey, threadId) {
  const cached = jsonlArtifactItemsCacheByThread.get(cacheKey);
  if (!cached) {
    return null;
  }

  const stat = statJsonlArtifactRollout(cached.rolloutPath);
  if (!stat) {
    jsonlArtifactItemsCacheByThread.delete(cacheKey);
    return null;
  }

  if (stat.mtimeMs !== cached.mtimeMs || stat.size !== cached.size) {
    try {
      return readAndCacheJsonlArtifactItems(cacheKey, cached.rolloutPath, threadId, stat);
    } catch (error) {
      jsonlArtifactItemsCacheByThread.delete(cacheKey);
      console.warn(
        `[remodex] history jsonl artifact cache refresh failed for ${threadId}: ${error.message}`,
      );
      return null;
    }
  }

  const now = Date.now();
  if (now - cached.checkedAt <= RELAY_JSONL_ARTIFACT_CACHE_TTL_MS) {
    return cached.artifactsByTurnId;
  }

  cached.checkedAt = now;
  return null;
}

function readAndCacheJsonlArtifactItems(cacheKey, rolloutPath, threadId, stat = null) {
  const rolloutStat = stat || fs.statSync(rolloutPath);
  const artifactsByTurnId = new Map();
  try {
    const turns = parseSessionJsonlTurns(fs.readFileSync(rolloutPath, "utf8"), { threadId });
    for (const turn of turns) {
      const turnId = normalizeNonEmptyString(turn?.id);
      const turnItems = Array.isArray(turn?.items) ? turn.items : [];
      if (!turnId || turnItems.length === 0) {
        continue;
      }

      const fileChanges = turnItems.filter(
        (item) => normalizeHistoryItemToken(item?.type) === "filechange",
      );
      const progressPlan = turnItems.find(
        (item) =>
          normalizeHistoryItemToken(item?.type) === "plan" &&
          item?.remodexJsonlProgressPlan === true,
      );
      const imageViewItems = turnItems.filter(
        (item) => normalizeHistoryItemToken(item?.type) === "imageview",
      );
      const artifacts = {
        fileChangeItem: null,
        imageViewItems: [],
        progressPlanItem: null,
        imageViewItems,
      };

      const changes = [];
      for (const item of fileChanges) {
        if (Array.isArray(item.changes)) {
          changes.push(...item.changes);
        }
      }
      if (changes.length > 0) {
        artifacts.fileChangeItem = {
          id: `remodex-jsonl-file-change-${turnId}`,
          type: "fileChange",
          status: "completed",
          changes,
          remodexJsonlFileChangeAggregate: true,
        };
      }
      if (progressPlan) {
        artifacts.progressPlanItem = {
          ...progressPlan,
          id: normalizeNonEmptyString(progressPlan.id) || `remodex-jsonl-progress-plan-${turnId}`,
        };
      }
      artifacts.imageViewItems = turnItems
        .filter((item) => normalizeHistoryItemToken(item?.type) === "imageview")
        .map((item, index) => ({
          ...item,
          id: normalizeNonEmptyString(item.id) || `remodex-jsonl-image-view-${turnId}-${index + 1}`,
        }));

      if (artifacts.fileChangeItem || artifacts.progressPlanItem || artifacts.imageViewItems.length > 0) {
        artifactsByTurnId.set(turnId, artifacts);
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
  });
  return artifactsByTurnId;
}

function statJsonlArtifactRollout(rolloutPath) {
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

function hasEquivalentFileChangeItem(items, incomingItem) {
  const incomingId = normalizeNonEmptyString(incomingItem?.id);
  const incomingPaths = fileChangePathSet(incomingItem);
  return items.some((item) => {
    if (normalizeHistoryItemToken(item?.type) !== "filechange") {
      return false;
    }
    if (incomingId && normalizeNonEmptyString(item.id) === incomingId) {
      return true;
    }
    if (item.remodexJsonlFileChangeAggregate === true) {
      return true;
    }

    const existingPaths = fileChangePathSet(item);
    if (incomingPaths.size === 0 || existingPaths.size === 0) {
      return false;
    }
    for (const pathKey of incomingPaths) {
      if (!existingPaths.has(pathKey)) {
        return false;
      }
    }
    return true;
  });
}

function hasEquivalentProgressPlanItem(items, incomingItem) {
  const incomingId = normalizeNonEmptyString(incomingItem?.id);
  return items.some((item) => {
    if (normalizeHistoryItemToken(item?.type) !== "plan") {
      return false;
    }
    return (
      item.remodexJsonlProgressPlan === true ||
      (incomingId && normalizeNonEmptyString(item.id) === incomingId)
    );
  });
}

function hasEquivalentImageViewItem(items, incomingItem) {
  const incomingId = normalizeNonEmptyString(incomingItem?.id);
  const incomingPath = normalizeImageViewPathKey(incomingItem);
  return items.some((item) => {
    if (normalizeHistoryItemToken(item?.type) !== "imageview") {
      return false;
    }
    const itemId = normalizeNonEmptyString(item.id);
    if (incomingId && itemId === incomingId) {
      return true;
    }
    return incomingPath && normalizeImageViewPathKey(item) === incomingPath;
  });
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
    const pathKey = normalizeFileChangePathKey(
      change?.path || change?.file || change?.filePath || change?.file_path,
    );
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
    const threadId =
      normalizeNonEmptyString(turn?.threadId) ||
      normalizeNonEmptyString(turn?.thread_id) ||
      normalizeNonEmptyString(turn?.thread?.id) ||
      normalizeNonEmptyString(turn?.thread?.threadId) ||
      normalizeNonEmptyString(turn?.thread?.thread_id);
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
  const turnThreadId =
    normalizeNonEmptyString(threadId) ||
    normalizeNonEmptyString(turn.threadId) ||
    normalizeNonEmptyString(turn.thread_id);
  const sanitizedItems = turn.items.map((item) => {
    if (!item || typeof item !== "object") {
      return item;
    }

    let itemDidChange = false;
    let sanitizedItem = convertApplyPatchHistoryItem(item) || item;
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
  });

  return turnDidChange
    ? {
        ...turn,
        items: sanitizedItems,
      }
    : turn;
}

function convertApplyPatchHistoryItem(item) {
  const itemType = normalizeHistoryItemToken(item?.type);
  const toolName = normalizeNonEmptyString(item?.name);
  if (toolName !== "apply_patch" || itemType !== "customtoolcall") {
    return null;
  }

  const fileChangeItem = buildApplyPatchFileChangeItem({
    callId:
      normalizeNonEmptyString(item.call_id) ||
      normalizeNonEmptyString(item.callId) ||
      normalizeNonEmptyString(item.id),
    patch: normalizeNonEmptyString(item.input),
    status: normalizeNonEmptyString(item.status) || "completed",
    idFallback: normalizeNonEmptyString(item.id) || "history-apply-patch-file-change",
  });
  return fileChangeItem ? { ...item, ...fileChangeItem } : null;
}

function normalizeHistoryItemToken(value) {
  return normalizeNonEmptyString(value)
    .toLowerCase()
    .replace(/[\s_-]+/g, "");
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
  const existingPath =
    normalizeNonEmptyString(item.saved_path) ||
    normalizeNonEmptyString(item.savedPath) ||
    normalizeNonEmptyString(item.path) ||
    normalizeNonEmptyString(item.file_path);
  const generatedPath = existingPath || generatedImagePathForHistoryItem(item, threadId);
  if (generatedPath && !existingPath) {
    nextItem = {
      ...nextItem,
      saved_path: generatedPath,
    };
    didChange = true;
  }

  if (typeof nextItem.result === "string" && nextItem.result.length > 0) {
    const { result: _result, ...withoutInlineResult } = nextItem;
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
  const callId =
    normalizedType === "imagegenerationend"
      ? normalizeNonEmptyString(item.call_id) ||
        normalizeNonEmptyString(item.callId) ||
        normalizeNonEmptyString(item.itemId) ||
        normalizeNonEmptyString(item.item_id) ||
        normalizeNonEmptyString(item.id)
      : normalizeNonEmptyString(item.id) ||
        normalizeNonEmptyString(item.call_id) ||
        normalizeNonEmptyString(item.callId) ||
        normalizeNonEmptyString(item.itemId) ||
        normalizeNonEmptyString(item.item_id);
  if (!resolvedThreadId || !callId) {
    return "";
  }

  return path.join(resolveCodexGeneratedImagesRoot(), resolvedThreadId, `${callId}.png`);
}

function isGeneratedImageRelayType(normalizedType) {
  return (
    normalizedType === "imagegeneration" ||
    normalizedType === "imagegenerationcall" ||
    normalizedType === "imagegenerationend" ||
    normalizedType === "imageview"
  );
}

function liveGeneratedImageThreadId(params) {
  const event =
    params?.event && typeof params.event === "object" && !Array.isArray(params.event)
      ? params.event
      : null;
  const item =
    params?.item && typeof params.item === "object" && !Array.isArray(params.item)
      ? params.item
      : null;

  return (
    normalizeNonEmptyString(params?.threadId) ||
    normalizeNonEmptyString(params?.thread_id) ||
    normalizeNonEmptyString(params?.conversationId) ||
    normalizeNonEmptyString(params?.conversation_id) ||
    normalizeNonEmptyString(event?.threadId) ||
    normalizeNonEmptyString(event?.thread_id) ||
    normalizeNonEmptyString(event?.conversationId) ||
    normalizeNonEmptyString(event?.conversation_id) ||
    normalizeNonEmptyString(item?.threadId) ||
    normalizeNonEmptyString(item?.thread_id) ||
    ""
  );
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

  const hasInlineUrl =
    hasInlineHistoryImageDataURL(contentItem.url) ||
    hasInlineHistoryImageDataURL(contentItem.image_url) ||
    hasInlineHistoryImageDataURL(contentItem.path);
  if (!hasInlineUrl) {
    return contentItem;
  }

  const { url: _url, image_url: _imageUrl, path: _path, ...rest } = contentItem;

  return {
    ...rest,
    url: RELAY_HISTORY_IMAGE_REFERENCE_URL,
  };
}

function normalizeRelayHistoryContentType(value) {
  return typeof value === "string" ? value.toLowerCase().replace(/[\s_-]+/g, "") : "";
}

// Covers Codex history variants such as image, local_image, and input_image.
function isRelayHistoryImageContentType(normalizedType) {
  return (
    normalizedType === "image" ||
    normalizedType === "localimage" ||
    normalizedType === "inputimage" ||
    normalizedType === "outputimage"
  );
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
function trimThreadPayloadForRelay(parsed, explicitThread = undefined) {
  const thread = explicitThread ?? parsed?.result?.thread;
  if (!parsed || !thread || typeof thread !== "object" || !Array.isArray(thread.turns)) {
    return null;
  }

  let workingThread = thread;
  let encoded = encodeRelayThreadPayload(parsed, workingThread);
  if (encoded == null) {
    return null;
  }

  if (Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES) {
    return explicitThread === undefined ? null : encoded;
  }

  const turns = thread.turns;
  let trimmedTurns =
    turns.length > RELAY_HISTORY_RECENT_TURN_TARGET
      ? turns.slice(-RELAY_HISTORY_RECENT_TURN_TARGET)
      : turns.slice();
  while (trimmedTurns.length > 1) {
    if (trimmedTurns.length === turns.length) {
      trimmedTurns = trimmedTurns.slice(1);
    }
    const candidateThread = buildRelayHistoryCompactedThread(
      thread,
      buildRelayCompactedHistoryTurns(turns, trimmedTurns),
      Math.max(0, turns.length - trimmedTurns.length),
      trimmedTurns.length,
    );
    encoded = encodeRelayThreadPayload(parsed, candidateThread);
    if (
      encoded != null &&
      Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES
    ) {
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
      Math.max(0, turns.length - 1),
      1,
      thread,
    );
    const candidateThread = buildRelayHistoryCompactedThread(
      thread,
      compactedTurnPrefix
        ? [
            compactedTurnPrefix,
            {
              ...newestTurn,
              items: trimmedItems,
            },
          ]
        : [
            {
              ...newestTurn,
              items: trimmedItems,
            },
          ],
      Math.max(0, turns.length - 1),
      1,
    );
    encoded = encodeRelayThreadPayload(parsed, candidateThread);
    if (
      encoded != null &&
      Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES
    ) {
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
    RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS,
  );
  let candidateThread = buildRelayHistoryCompactedThread(
    thread,
    [
      ...buildRelayCompactedHistoryTurns(turns, [newestTurn]).slice(0, -1),
      {
        ...newestTurn,
        items: [truncatedItem],
      },
    ],
    Math.max(0, turns.length - 1),
    1,
  );
  encoded = encodeRelayThreadPayload(parsed, candidateThread);
  if (
    encoded != null &&
    Buffer.byteLength(encoded, "utf8") <= RELAY_THREAD_PAYLOAD_SOFT_LIMIT_BYTES
  ) {
    return encoded;
  }

  candidateThread = buildRelayHistoryCompactedThread(
    thread,
    [
      ...buildRelayCompactedHistoryTurns(turns, [newestTurn]).slice(0, -1),
      {
        ...newestTurn,
        items: [compactHistoryItemForRelay(mostRecentItem, RELAY_HISTORY_TEXT_TAIL_LIMIT_CHARS)],
      },
    ],
    Math.max(0, turns.length - 1),
    1,
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

  return fallbackCompactedPayload ?? originalRawMessage ?? encoded;
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

function buildRelayCompactedHistoryTurns(allTurns, keptTurns) {
  const omittedTurnCount = Math.max(0, allTurns.length - keptTurns.length);
  const compactionTurn = buildRelayHistoryCompactionTurn(
    omittedTurnCount,
    keptTurns.length,
    allTurns[0],
  );
  return compactionTurn ? [compactionTurn, ...keptTurns] : keptTurns;
}

function buildRelayHistoryCompactionTurn(omittedTurnCount, keptTurnCount, idSource = {}) {
  if (omittedTurnCount <= 0) {
    return null;
  }

  const baseId =
    normalizeNonEmptyString(idSource?.id) ||
    normalizeNonEmptyString(idSource?.turnId) ||
    normalizeNonEmptyString(idSource?.turn_id) ||
    "history";
  const text = [
    "Earlier conversation compacted for mobile loading.",
    "",
    `Older turns omitted: ${omittedTurnCount}`,
    `Recent turns kept: ${keptTurnCount}`,
    "Full history remains available on the Mac runtime.",
  ].join("\n");

  return {
    id: `remodex-history-compacted-${baseId}`,
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

  return Object.fromEntries(Object.entries(compactItem).filter(([, value]) => value !== undefined));
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

module.exports = {
  RELAY_HISTORY_IMAGE_REFERENCE_URL,
  RELAY_JSONL_ARTIFACT_CACHE_MAX_ENTRIES,
  buildEmptyTurnsListResponse,
  buildThreadTurnsListRelaySanitizeContext,
  fetchAdaptiveThreadTurnsListForRelay,
  fetchSafeThreadTurnsListFallback,
  findTurnsListResultKey,
  hasRelayCursor,
  isEmptyTurnsListResponse,
  jsonlArtifactItemsCacheByThread,
  maybeMergeLatestJsonlTurnIntoTurnsListResponse,
  resolveJsonlTurnsListRolloutPathForFallback,
  sanitizeLiveGeneratedImageMessageForRelay,
  sanitizeThreadHistoryImagesForRelay,
  threadIdFromRequestParams,
  unwrapAppServerPayloadResult,
};
