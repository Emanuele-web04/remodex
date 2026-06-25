// FILE: opencode-provider-shared.js
// Purpose: Shared constants, env resolvers, error factories, and helpers used by
//          opencode-provider.js and opencode-thread-ops.js / opencode-turn-stream.js.
// Layer: Bridge runtime shared helpers
// Depends on: ./normalize, ./opencode-models, ./opencode-server, ./opencode-client, ./project-path-policy

const path = require("path");
const { readString, resolvedParam } = require("./normalize");
const { createOpenCodeServer } = require("./opencode-server");
const {
  buildStaticSlashCommands,
  createOpenCodeClient,
  normalizeCommandNameForSdk,
  normalizeCommandTokenForAllowlist,
  normalizeSessionMessagesResponse,
} = require("./opencode-client");
const {
  deriveRequiresArguments,
  normalizeArgumentFields,
  serializeCommandArguments,
} = require("./opencode-command-arguments");
const {
  DEFAULT_OPENCODE_MODEL,
  OPENCODE_PROVIDER_ID,
  appendNonEmpty,
  boundedPositiveInteger,
  buildPromptFromTurnInput,
  compareThreadsByUpdatedAt,
  messagesToTurns,
  extractOpenCodeMessageText,
  isOpenCodeAssistantMessage,
  normalizeOpenCodeModel,
  publicThread,
  readThreadId,
  removeUndefinedValues,
  textContent,
} = require("./opencode-models");
const { createThreadOwnershipStore } = require("./thread-ownership-store");
const { createOpenCodeSessionStore } = require("./opencode-session-store");
const {
  buildOpenCodeRuntimeStatus,
  isVersionBelowMinimum,
  OPENCODE_MIN_CLI_VERSION,
} = require("./opencode-runtime-status");
const { isOpenCodeHandoffEnabled } = require("./opencode-handoff");
const { resolveDefaultOpenCodeAgent } = require("./opencode-runtime-policy");
const { parseOpenCodeModelSlug } = require("./opencode-model-slug");
const { resolveOpenCodeVariantForPrompt } = require("./opencode-variant-resolve");
const { createOpenCodeAuthErrorNotifier } = require("./opencode-auth-error-handler");
const { mapOpenCodeSessionToContextUsage } = require("./opencode-usage-mapper");
const { createAttachmentStore, isAttachmentsEnabled } = require("./attachment-store");
const { validateDirectory } = require("./project-path-policy");
const { resolveDiscoverSessionsEnabled } = require("./opencode-discovery-policy");

const ERROR_CODES = {
  OPENCODE_NOT_INSTALLED: { errorCode: "opencode_not_installed", action: "show_install_instructions" },
  OPENCODE_SERVER_UNREACHABLE: { errorCode: "opencode_server_unreachable", action: "show_retry" },
  OPENCODE_MODEL_UNAVAILABLE: { errorCode: "opencode_model_unavailable", action: "pick_different_model" },
  OPENCODE_AGENT_UNAVAILABLE: { errorCode: "opencode_agent_unavailable", action: "pick_different_agent" },
  OPENCODE_SESSION_EXPIRED: { errorCode: "opencode_session_expired", action: "restart_thread" },
  OPENCODE_TURN_FAILED: { errorCode: "opencode_turn_failed", action: "show_retry" },
  OPENCODE_PERMISSION_TIMEOUT: { errorCode: "opencode_permission_timeout", action: "show_timeout" },
};

const HEALTH_RESTART_WINDOW_MS = 5 * 60 * 1000;
const HEALTH_MAX_RESTARTS = 3;
const HEALTH_IDLE_SHUTDOWN_MS = 10 * 60 * 1000;
const LIST_THREADS_SESSION_VALIDATE_CAP = 20;
const STARTUP_PRUNE_SESSION_VALIDATE_CAP = 20;
const DEFAULT_DISCOVER_SESSIONS_CAP = 30;
const DEFAULT_DISCOVER_SESSIONS_TTL_MS = 60_000;
const DEFAULT_LIST_THREADS_VALIDATE_CACHE_TTL_MS = 60_000;
const DEFAULT_ENSURE_STARTED_LIST_CAP_MS = 4_000;
const DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS = 8_000;
const DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN = 120;
const DISCOVERED_THREAD_ID_PREFIX = "opencode-session-";
const DEFAULT_OPENCODE_TURN_WATCHDOG_MS = 120 * 1000;
const ADOPT_MUTEX_TIMEOUT_MS = 30_000;
const OPENCODE_PRUNE_OPS_HINT =
  "node phodex-bridge/scripts/prune-opencode-ownership.js --apply";

function resolveListThreadsValidateCap(env = process.env) {
  const fromEnv = Number(env?.REMODEX_LIST_THREADS_VALIDATE_CAP);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return boundedPositiveInteger(fromEnv, LIST_THREADS_SESSION_VALIDATE_CAP);
  }
  return LIST_THREADS_SESSION_VALIDATE_CAP;
}

function resolveDiscoverSessionsCap(env = process.env) {
  const fromEnv = Number(env?.REMODEX_LIST_THREADS_DISCOVER_CAP);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return boundedPositiveInteger(fromEnv, DEFAULT_DISCOVER_SESSIONS_CAP);
  }
  return DEFAULT_DISCOVER_SESSIONS_CAP;
}

function resolveDiscoverSessionsTtlMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_DISCOVER_TTL_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_DISCOVER_SESSIONS_TTL_MS;
}

function resolveEnsureStartedListCapMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_ENSURE_STARTED_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_ENSURE_STARTED_LIST_CAP_MS;
}

function resolveEnsureStartedServeWakeCapMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_SERVE_WAKE_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS;
}

function resolveValidationRpcLimitPerMin(env = process.env) {
  const fromEnv = Number(env?.REMODEX_VALIDATION_RPC_LIMIT_PER_MIN);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN;
}

function createValidationRpcTokenBucket({
  limitPerMin = DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN,
  now = () => Date.now(),
} = {}) {
  let tokens = limitPerMin;
  let lastRefillAt = now();

  return {
    tryConsume(cost = 1) {
      const normalizedCost = Number.isFinite(cost) && cost > 0 ? cost : 1;
      const current = now();
      const elapsed = current - lastRefillAt;
      if (elapsed > 0) {
        tokens = Math.min(limitPerMin, tokens + (elapsed / 60_000) * limitPerMin);
        lastRefillAt = current;
      }
      if (tokens < normalizedCost) {
        return false;
      }
      tokens -= normalizedCost;
      return true;
    },
    getAvailableTokens() {
      const current = now();
      const elapsed = current - lastRefillAt;
      if (elapsed > 0) {
        tokens = Math.min(limitPerMin, tokens + (elapsed / 60_000) * limitPerMin);
        lastRefillAt = current;
      }
      return tokens;
    },
    reset() {
      tokens = limitPerMin;
      lastRefillAt = now();
    },
  };
}

function resolveListThreadsValidateCacheTtlMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_LIST_THREADS_VALIDATE_CACHE_TTL_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_LIST_THREADS_VALIDATE_CACHE_TTL_MS;
}

function parseDiscoveredThreadSessionId(threadId) {
  const normalized = readString(threadId);
  if (!normalized || !normalized.startsWith(DISCOVERED_THREAD_ID_PREFIX)) {
    return "";
  }
  return readString(normalized.slice(DISCOVERED_THREAD_ID_PREFIX.length));
}

function maybeLogOpenCodePruneOpsHint({ materializationBlocked = 0, prunedCount = 0 } = {}) {
  if (materializationBlocked > 50 || prunedCount > 50) {
    console.log(
      JSON.stringify({
        event: "opencode_prune_ops_hint",
        hint: `Run: ${OPENCODE_PRUNE_OPS_HINT}`,
        materialization_blocked: materializationBlocked,
        pruned_count: prunedCount,
      }),
    );
  }
}

function resolveOpenCodeTurnWatchdogMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_TURN_WATCHDOG_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return DEFAULT_OPENCODE_TURN_WATCHDOG_MS;
}

function resolveAdoptMutexTimeoutMs(env = process.env) {
  const fromEnv = Number(env?.REMODEX_OPENCODE_ADOPT_TIMEOUT_MS);
  if (Number.isFinite(fromEnv) && fromEnv > 0) {
    return fromEnv;
  }
  return ADOPT_MUTEX_TIMEOUT_MS;
}

function assertOwnershipPersisted(ok, threadId) {
  if (ok) {
    return;
  }
  const error = new Error(`Failed to persist thread ownership for ${threadId}`);
  error.errorCode = "thread_ownership_persist_failed";
  throw error;
}

function pathNotAllowedError() {
  const error = new Error("That folder is outside the allowed local project locations.");
  error.errorCode = "path_not_allowed";
  error.userMessage = error.message;
  return error;
}

async function resolveAllowedDirectory(candidatePath) {
  const validation = await validateDirectory(candidatePath);
  if (!validation.isAllowed) {
    throw pathNotAllowedError();
  }
  return validation.path;
}

const SENSITIVE_PERMISSION_ARG_KEYS = new Set(["command", "script", "token", "secret", "password"]);
const ATTACHMENT_CLEANUP_INTERVAL_MS = 60 * 60 * 1000;

// iOS plan toggle sends turn/start collaborationMode {mode:"plan"} (snake_case
// accepted for legacy callers); anything else means the thread's normal agent.
function isPlanModeRequested(params) {
  const mode = params?.collaborationMode?.mode ?? params?.collaboration_mode?.mode;
  return readString(mode) === "plan";
}

function formatStructuredError(logPrefix, message, context = {}) {
  const structuredContext = {
    timestamp: new Date().toISOString(),
    ...context,
  };
  return `${logPrefix} ${message} ${JSON.stringify(structuredContext)}`;
}


function isInvalidOpenCodeSessionError(error) {
  if (!error || typeof error !== "object") {
    return false;
  }

  const status = Number(error.status ?? error.statusCode ?? error.response?.status);
  if (status === 404) {
    return true;
  }

  const message = readString(error.message).toLowerCase();
  if (!message) {
    return false;
  }

  return (
    message.includes("session not found") ||
    message.includes("unknown session") ||
    message.includes("invalid session") ||
    message.includes("session does not exist") ||
    message.includes("session id not found")
  );
}

function createOpenCodeSessionExpiredError(threadId) {
  const expired = new Error(
    `OpenCode session expired for thread ${threadId}. Start a new thread.`,
  );
  expired.errorCode = ERROR_CODES.OPENCODE_SESSION_EXPIRED.errorCode;
  expired.action = ERROR_CODES.OPENCODE_SESSION_EXPIRED.action;
  expired.reasonCode = "opencode_session_expired";
  return expired;
}

function unsupportedMethodError(method) {
  const error = new Error(`Unsupported OpenCode provider method: ${method || "unknown"}`);
  error.errorCode = "unsupported_opencode_method";
  return error;
}

function threadNotFoundError(threadId) {
  const error = new Error(`OpenCode thread not found: ${threadId || "unknown"}`);
  error.errorCode = "thread_not_found";
  return error;
}

function activeTurnError(threadId) {
  const error = new Error(`OpenCode thread already has a running turn: ${threadId}`);
  error.errorCode = "thread_turn_active";
  return error;
}

function paginateTurnList(turns, { limit, sortDirection, cursor }) {
  const ordered = [...turns];
  if (sortDirection === "desc") {
    ordered.reverse();
  }
  const offset = Math.max(0, Number.parseInt(readString(cursor), 10) || 0);
  const page = ordered.slice(offset, offset + limit);
  const nextOffset = offset + page.length;
  const nextCursor = nextOffset < ordered.length ? String(nextOffset) : null;
  return { data: page, nextCursor };
}

module.exports = {
  resolveListThreadsValidateCap,
  resolveDiscoverSessionsCap,
  resolveDiscoverSessionsTtlMs,
  resolveEnsureStartedListCapMs,
  resolveEnsureStartedServeWakeCapMs,
  resolveValidationRpcLimitPerMin,
  createValidationRpcTokenBucket,
  resolveListThreadsValidateCacheTtlMs,
  parseDiscoveredThreadSessionId,
  maybeLogOpenCodePruneOpsHint,
  resolveOpenCodeTurnWatchdogMs,
  resolveAdoptMutexTimeoutMs,
  assertOwnershipPersisted,
  pathNotAllowedError,
  resolveAllowedDirectory,
  isPlanModeRequested,
  formatStructuredError,
  isInvalidOpenCodeSessionError,
  createOpenCodeSessionExpiredError,
  unsupportedMethodError,
  threadNotFoundError,
  activeTurnError,
  paginateTurnList,
  ERROR_CODES,
  HEALTH_RESTART_WINDOW_MS,
  HEALTH_MAX_RESTARTS,
  HEALTH_IDLE_SHUTDOWN_MS,
  LIST_THREADS_SESSION_VALIDATE_CAP,
  STARTUP_PRUNE_SESSION_VALIDATE_CAP,
  DEFAULT_DISCOVER_SESSIONS_CAP,
  DEFAULT_DISCOVER_SESSIONS_TTL_MS,
  DEFAULT_LIST_THREADS_VALIDATE_CACHE_TTL_MS,
  DEFAULT_ENSURE_STARTED_LIST_CAP_MS,
  DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS,
  DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN,
  DISCOVERED_THREAD_ID_PREFIX,
  DEFAULT_OPENCODE_TURN_WATCHDOG_MS,
  ADOPT_MUTEX_TIMEOUT_MS,
  OPENCODE_PRUNE_OPS_HINT,
  SENSITIVE_PERMISSION_ARG_KEYS,
  ATTACHMENT_CLEANUP_INTERVAL_MS,
};
