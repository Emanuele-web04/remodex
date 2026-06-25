const path = require("path");
const { readString, resolvedParam } = require("./normalize");
const { normalizeCommandNameForSdk, normalizeCommandTokenForAllowlist } = require("./opencode-client");
const { deriveRequiresArguments, normalizeArgumentFields, serializeCommandArguments } = require("./opencode-command-arguments");
const { readThreadId } = require("./opencode-models");
const {
  ERROR_CODES,
  createOpenCodeSessionExpiredError,
  formatStructuredError,
  isInvalidOpenCodeSessionError,
  resolveAllowedDirectory,
  threadNotFoundError,
} = require("./opencode-provider-shared");

function createOpenCodeCommandExecute(ctx) {

  function commandExecuteDedupeKey(threadId, allowlistToken, clientCommandId) {
    const tid = readString(threadId);
    const token = readString(allowlistToken);
    const cid = readString(clientCommandId);
    if (!tid || !token || !cid) {
      return "";
    }
    return `${tid}\0${token}\0${cid}`;
  }


  function pruneCommandExecuteDedupe(now = Date.now()) {
    for (const [key, seenAt] of ctx.commandExecuteDedupeByKey.entries()) {
      if (now - seenAt >= ctx.COMMAND_EXECUTE_DEDUPE_TTL_MS) {
        ctx.commandExecuteDedupeByKey.delete(key);
      }
    }
  }


  async function commandExecute(request) {
    const params = request?.params || {};
    const threadId = readThreadId(params);
    const commandToken = readString(params.command);
    const commandSdk = normalizeCommandNameForSdk(commandToken);
    const allowlistToken = normalizeCommandTokenForAllowlist(commandToken);

    if (!allowlistToken) {
      const error = new Error("command/execute requires a slash command token.");
      error.errorCode = "command_required";
      ctx.logCommandExecute({ commandToken, commandSdk, ok: false, errorCode: error.errorCode, threadId });
      throw error;
    }

    let thread;
    try {
      thread = await ctx.ensureThreadSession(await ctx.requireThread(threadId));
    } catch (error) {
      ctx.logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: readString(error?.errorCode) || "command_execute_failed",
        threadId,
        clientCommandId: readString(params.clientCommandId),
      });
      throw error;
    }

    const clientCommandId = readString(params.clientCommandId);
    const dedupeKey = ctx.commandExecuteDedupeKey(thread.id, allowlistToken, clientCommandId);
    if (dedupeKey) {
      ctx.pruneCommandExecuteDedupe();
      const seenAt = ctx.commandExecuteDedupeByKey.get(dedupeKey);
      if (seenAt && Date.now() - seenAt < ctx.COMMAND_EXECUTE_DEDUPE_TTL_MS) {
        ctx.logCommandExecute({
          commandToken,
          commandSdk,
          ok: true,
          threadId: thread.id,
          sessionId: thread.sessionId,
          clientCommandId,
          deduped: true,
        });
        return { ok: true, sessionId: thread.sessionId, deduped: true };
      }
    }

    const explicitDirectory = readString(params.directory || params.cwd);
    const directoryCandidate = explicitDirectory || readString(thread.cwd) || process.cwd();
    let directory = directoryCandidate;
    const skipPathValidation =
      !explicitDirectory &&
      !thread.hasProjectCwd &&
      path.resolve(directoryCandidate) === path.resolve(process.cwd());
    if (!skipPathValidation) {
      directory = await resolveAllowedDirectory(directoryCandidate);
    }
    const allowedCommands = await ctx.listCommands(directory);
    const allowedTokens = new Set(
      allowedCommands.map((entry) => normalizeCommandTokenForAllowlist(entry.token)),
    );
    if (!allowedTokens.has(allowlistToken)) {
      const error = new Error(`Slash command not allowed: ${commandToken}`);
      error.errorCode = "command_not_allowed";
      ctx.logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: error.errorCode,
        threadId: thread.id,
        directory,
      });
      throw error;
    }

    await ctx.ensureStarted();
    if (!ctx.client || typeof ctx.client.sessionCommand !== "function") {
      const error = new Error("OpenCode session.command is unavailable.");
      error.errorCode = ERROR_CODES.OPENCODE_SERVER_UNREACHABLE.errorCode;
      ctx.logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: error.errorCode,
        threadId: thread.id,
      });
      throw error;
    }

    if (!readString(thread.sessionId)) {
      const sessionId = await ctx.client.createSession({ cwd: directory });
      if (!readString(sessionId)) {
        const error = new Error(
          "OpenCode createSession returned no session id; cannot execute slash command.",
        );
        error.errorCode = ERROR_CODES.OPENCODE_TURN_FAILED.errorCode;
        ctx.logCommandExecute({
          commandToken,
          commandSdk,
          ok: false,
          errorCode: error.errorCode,
          threadId: thread.id,
        });
        throw error;
      }
      thread.sessionId = sessionId;
      ctx.persistSessionRecord(thread);
    }

    const matchedCommand =
      allowedCommands.find(
        (entry) => normalizeCommandTokenForAllowlist(entry.token) === allowlistToken,
      ) || null;
    const template =
      readString(params.template) || readString(matchedCommand?.template) || "";
    const hints = Array.isArray(params.hints)
      ? params.hints.map((entry) => readString(entry)).filter(Boolean)
      : Array.isArray(matchedCommand?.hints)
        ? matchedCommand.hints.map((entry) => readString(entry)).filter(Boolean)
        : [];
    const argumentFields = normalizeArgumentFields(params.argumentFields);
    const requiresArguments =
      matchedCommand?.requiresArguments === true ||
      deriveRequiresArguments(template, hints);

    let args = readString(params.arguments) || readString(params.args) || "";
    if (argumentFields.length > 0) {
      args = serializeCommandArguments({ template, hints, fields: argumentFields });
    } else if (requiresArguments && !readString(args)) {
      const error = new Error(
        "command/execute requires argumentFields for slash commands that need input.",
      );
      error.errorCode = "command_arguments_required";
      ctx.logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: error.errorCode,
        threadId: thread.id,
        directory,
      });
      throw error;
    }

    try {
      await ctx.client.sessionCommand({
        sessionID: thread.sessionId,
        command: commandToken,
        arguments: args,
        cwd: directory,
        model: thread.model,
        agent: thread.agent,
      });
      if (dedupeKey) {
        ctx.commandExecuteDedupeByKey.set(dedupeKey, Date.now());
      }
      ctx.markUserStartedInProcess(thread);
      thread.updatedAt = new Date().toISOString();
      ctx.threads.set(thread.id, thread);
      ctx.logCommandExecute({
        commandToken,
        commandSdk,
        ok: true,
        threadId: thread.id,
        sessionId: thread.sessionId,
        directory,
        clientCommandId,
      });
      return { ok: true, sessionId: thread.sessionId };
    } catch (error) {
      if (dedupeKey) {
        ctx.commandExecuteDedupeByKey.delete(dedupeKey);
      }
      if (isInvalidOpenCodeSessionError(error)) {
        const expired = createOpenCodeSessionExpiredError(thread.id);
        ctx.logCommandExecute({
          commandToken,
          commandSdk,
          ok: false,
          errorCode: expired.errorCode,
          threadId: thread.id,
        });
        throw expired;
      }
      const failed = new Error(
        readString(error?.message) || "OpenCode slash command execution failed.",
      );
      failed.errorCode = readString(error?.errorCode) || ERROR_CODES.OPENCODE_TURN_FAILED.errorCode;
      ctx.logCommandExecute({
        commandToken,
        commandSdk,
        ok: false,
        errorCode: failed.errorCode,
        threadId: thread.id,
      });
      throw failed;
    }
  }


  function logCommandExecute({
    commandToken,
    commandSdk,
    ok,
    errorCode = null,
    threadId = null,
    sessionId = null,
    directory = null,
    clientCommandId = null,
    deduped = false,
  } = {}) {
    const payload = {
      event: deduped === true ? "opencode_command_execute_deduped" : "opencode_command_execute",
      commandToken: readString(commandToken) || null,
      commandSdk: readString(commandSdk) || null,
      ok: ok === true,
      errorCode: readString(errorCode) || null,
      threadId: readString(threadId) || null,
      sessionId: readString(sessionId) || null,
      directory: readString(directory) || null,
      clientCommandId: readString(clientCommandId) || null,
    };
    if (deduped === true) {
      payload.deduped = true;
    }
    console.log(JSON.stringify(payload));
  }

  return {
    commandExecuteDedupeKey,
    pruneCommandExecuteDedupe,
    commandExecute,
    logCommandExecute,
  };
}

module.exports = { createOpenCodeCommandExecute };
