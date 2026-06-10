#!/usr/bin/env node
// One-shot repair for split OpenCode module imports (run after split generation).

const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..", "src");

function patch(file, replacements) {
  const p = path.join(root, file);
  let text = fs.readFileSync(p, "utf8");
  for (const [from, to] of replacements) {
    if (!text.includes(from) && !text.includes(to)) {
      console.warn(`skip ${file}: missing ${from.slice(0, 40)}...`);
      continue;
    }
    text = text.split(from).join(to);
  }
  fs.writeFileSync(p, text);
}

patch("opencode-thread-ops.js", [
  [
    `const { boundedPositiveInteger, compareThreadsByUpdatedAt, messagesToTurns, publicThread, readThreadId } = require("./opencode-models");`,
    `const { normalizeSessionMessagesResponse } = require("./opencode-client");
const {
  boundedPositiveInteger,
  compareThreadsByUpdatedAt,
  messagesToTurns,
  normalizeOpenCodeModel,
  OPENCODE_PROVIDER_ID,
  publicThread,
  readThreadId,
} = require("./opencode-models");`,
  ],
  [
    `const { ERROR_CODES, formatStructuredError, maybeLogOpenCodePruneOpsHint, paginateTurnList, parseDiscoveredThreadSessionId, resolveDiscoverSessionsCap, resolveListThreadsValidateCap, resolveListThreadsValidateCacheTtlMs, threadNotFoundError } = require("./opencode-provider-shared");`,
    `const {
  ERROR_CODES,
  assertOwnershipPersisted,
  formatStructuredError,
  maybeLogOpenCodePruneOpsHint,
  paginateTurnList,
  parseDiscoveredThreadSessionId,
  resolveAllowedDirectory,
  resolveDiscoverSessionsCap,
  resolveEnsureStartedListCapMs,
  resolveListThreadsValidateCap,
  resolveListThreadsValidateCacheTtlMs,
  threadNotFoundError,
} = require("./opencode-provider-shared");`,
  ],
]);

patch("opencode-command-execute.js", [
  [
    `const { readString, resolvedParam } = require("./normalize");`,
    `const path = require("path");
const { readString, resolvedParam } = require("./normalize");`,
  ],
  [
    `const { ERROR_CODES, formatStructuredError, threadNotFoundError } = require("./opencode-provider-shared");`,
    `const {
  ERROR_CODES,
  createOpenCodeSessionExpiredError,
  formatStructuredError,
  isInvalidOpenCodeSessionError,
  resolveAllowedDirectory,
  threadNotFoundError,
} = require("./opencode-provider-shared");`,
  ],
  [
    `    } catch (error) {
      if (isInvalidOpenCodeSessionError(error)) {`,
    `    } catch (error) {
      if (dedupeKey) {
        ctx.commandExecuteDedupeByKey.delete(dedupeKey);
      }
      if (isInvalidOpenCodeSessionError(error)) {`,
  ],
]);

patch("opencode-session-discovery.js", [
  [
    `const {
  compareThreadsByUpdatedAt,
  publicThread,
  readThreadId,
  removeUndefinedValues,
} = require("./opencode-models");`,
    `const {
  compareThreadsByUpdatedAt,
  normalizeOpenCodeModel,
  OPENCODE_PROVIDER_ID,
  publicThread,
  readThreadId,
  removeUndefinedValues,
} = require("./opencode-models");`,
  ],
  [
    `  resolveAllowedDirectory,
  resolveDiscoverSessionsCap,`,
    `  resolveAdoptMutexTimeoutMs,
  resolveAllowedDirectory,
  resolveDiscoverSessionsCap,`,
  ],
]);

const turnStreamPath = path.join(root, "opencode-turn-stream.js");
let turnText = fs.readFileSync(turnStreamPath);
turnText = Buffer.from(turnText.toString("binary").replace(/\0/g, ""));
turnText = turnText
  .toString("utf8")
  .replace(/OpenCode agent [^`]+ is not available/g, "OpenCode agent ${requestedAgent} is not available");
if (!turnText.includes('isAttachmentsEnabled')) {
  turnText = turnText.replace(
    `const { mapOpenCodeSessionToContextUsage } = require("./opencode-usage-mapper");`,
    `const { mapOpenCodeSessionToContextUsage } = require("./opencode-usage-mapper");
const { isAttachmentsEnabled } = require("./attachment-store");`,
  );
}
if (!turnText.includes("assertOwnershipPersisted,")) {
  turnText = turnText.replace(
    `  activeTurnError,
  createOpenCodeSessionExpiredError,`,
    `  activeTurnError,
  assertOwnershipPersisted,
  createOpenCodeSessionExpiredError,`,
  );
}
if (!turnText.includes("resolveEnsureStartedServeWakeCapMs,")) {
  turnText = turnText.replace(
    `  resolveAllowedDirectory,
  resolveOpenCodeTurnWatchdogMs,`,
    `  resolveAllowedDirectory,
  resolveEnsureStartedServeWakeCapMs,
  resolveOpenCodeTurnWatchdogMs,`,
  );
}
fs.writeFileSync(turnStreamPath, turnText);

const providerPath = path.join(root, "opencode-provider.js");
let provider = fs.readFileSync(providerPath, "utf8");
provider = provider.replace(
  "      archived: false,\n    };\n  }\n\n  async function validateOwnedThreadSession",
  "      archived: storeEntry?.archived === true,\n    };\n  }\n\n  async function validateOwnedThreadSession",
);
provider = provider.replace(
  "      return { ...catalogUnavailable };",
  "      return { ...ctx.catalogUnavailable };",
);
provider = provider.replace(
  "return ctx.lastModelListMeta ? { ...lastModelListMeta } : null;",
  "return ctx.lastModelListMeta ? { ...ctx.lastModelListMeta } : null;",
);
fs.writeFileSync(providerPath, provider);

console.log("fix-opencode-split-imports: done");
