const { readString, resolvedParam } = require("./normalize");
const { readThreadId } = require("./opencode-models");
const { ERROR_CODES, SENSITIVE_PERMISSION_ARG_KEYS, formatStructuredError, resolveOpenCodeTurnWatchdogMs, threadNotFoundError } = require("./opencode-provider-shared");

function createOpenCodePermissions(ctx) {

  function isOpenCodePermissionsUIEnabled(currentEnv = ctx.env) {
    const raw = readString(currentEnv?.REMODEX_OPENCODE_PERMISSIONS_UI);
    return raw !== "0" && raw?.toLowerCase() !== "false";
  }


  function redactPermissionArgs(args) {
    if (!args || typeof args !== "object") {
      return "";
    }
    const lines = Object.entries(args).map(([key, value]) => {
      const rendered = typeof value === "string" ? value : JSON.stringify(value);
      if (/^[A-Z0-9_]+$/.test(key) || SENSITIVE_PERMISSION_ARG_KEYS.has(key.toLowerCase())) {
        return `${key}=***`;
      }
      return `${key}=${rendered}`;
    });
    let summary = lines.join("\n");
    if (summary.length > 500) {
      summary = `${summary.slice(0, 500)}…(truncated)`;
    }
    return summary;
  }


  function clearPermissionWatchdog(entry) {
    if (entry?.watchdog) {
      clearTimeout(entry.watchdog);
      entry.watchdog = null;
    }
  }


  function clearAllPendingPermissions() {
    for (const pending of ctx.pendingPermissions.values()) {
      ctx.clearPermissionWatchdog(pending);
    }
    ctx.pendingPermissions.clear();
  }


  function evictOldestPendingPermission() {
    const oldestPermissionId = ctx.pendingPermissions.keys().next().value;
    if (!oldestPermissionId) {
      return null;
    }

    const evicted = ctx.pendingPermissions.get(oldestPermissionId);
    ctx.clearPermissionWatchdog(evicted);
    ctx.pendingPermissions.delete(oldestPermissionId);
    void (async () => {
      try {
        await ctx.ensureStarted();
        await ctx.client.replyToPermission(oldestPermissionId, false);
      } catch (error) {
        const context = evicted ? {
          permissionId: oldestPermissionId,
          threadId: evicted.threadId,
          turnId: evicted.turnId,
          sessionId: evicted.sessionId,
        } : { permissionId: oldestPermissionId };
        console.error(formatStructuredError(
          ctx.logPrefix,
          "permission cap eviction auto-deny failed",
          { ...context, error: error.message }
        ));
      }
    })();
    return evicted;
  }


  function armPermissionWatchdog(entry, payload) {
    ctx.clearPermissionWatchdog(entry);
    entry.watchdog = setTimeout(() => {
      void (async () => {
        ctx.pendingPermissions.delete(payload.permissionId);
        try {
          await ctx.ensureStarted();
          await ctx.client.replyToPermission(payload.permissionId, false);
          ctx.emit("turn/failed", {
            threadId: payload.threadId,
            turnId: payload.turnId,
            message: "Permission required — update Remodex to respond.",
            errorCode: ERROR_CODES.OPENCODE_PERMISSION_TIMEOUT.errorCode,
          });
        } catch (error) {
          console.error(formatStructuredError(
            ctx.logPrefix,
            "permission auto-deny failed",
            {
              permissionId: payload.permissionId,
              threadId: payload.threadId,
              turnId: payload.turnId,
              sessionId: payload.sessionId,
              error: error.message,
            }
          ));
        }
      })();
    }, ctx.PERMISSION_WATCHDOG_MS);
    if (readString(process.env.REMODEX_TEST) === "1" && typeof entry.watchdog?.unref === "function") {
      entry.watchdog.unref();
    }
  }


  function handlePermissionRequestEvent(active, params) {
    const permissionId = readString(params.permissionId || params.permission_id || params.requestId);
    const tool = readString(params.tool || params.toolName) || "tool";
    const sessionId = readString(params.sessionId || params.session_id || active.sessionId);
    if (!permissionId) {
      return;
    }

    if (sessionId) {
      const grants = ctx.sessionPermissionGrants.get(sessionId);
      if (grants?.has(tool)) {
        void (async () => {
          try {
            await ctx.ensureStarted();
            await ctx.client.replyToPermission(permissionId, true);
          } catch (error) {
            console.error(formatStructuredError(
              ctx.logPrefix,
              "auto-allow permission failed",
              {
                permissionId,
                threadId: active.thread?.id,
                turnId: active.turn?.id,
                sessionId,
                tool,
                error: error.message,
              }
            ));
          }
        })();
        return;
      }
    }

    const requestedAt = new Date().toISOString();
    const payload = {
      permissionId,
      threadId: readString(params.threadId || active.thread.id),
      turnId: readString(params.turnId || active.turn.id),
      sessionId: sessionId || null,
      tool,
      args: params.args && typeof params.args === "object" ? params.args : {},
      cwd: readString(params.cwd || active.thread.cwd) || null,
      requestedAt,
    };

    const existing = ctx.pendingPermissions.get(permissionId);
    ctx.clearPermissionWatchdog(existing);
    if (!existing) {
      while (ctx.pendingPermissions.size >= ctx.MAX_PENDING_PERMISSIONS) {
        ctx.evictOldestPendingPermission();
      }
    }
    const entry = { ...payload, watchdog: null };
    ctx.pendingPermissions.set(permissionId, entry);

    if (!ctx.isOpenCodePermissionsUIEnabled()) {
      ctx.armPermissionWatchdog(entry, payload);
      return;
    }

    ctx.emit("permission/request", {
      permissionId: payload.permissionId,
      threadId: payload.threadId,
      turnId: payload.turnId,
      sessionId: payload.sessionId,
      tool: payload.tool,
      cwd: payload.cwd,
      requestedAt: payload.requestedAt,
      argsSummary: ctx.redactPermissionArgs(payload.args),
    });
    ctx.armPermissionWatchdog(entry, payload);
  }


  function testSeedPendingPermission(permissionId, fields = {}) {
    ctx.pendingPermissions.set(permissionId, {
      permissionId,
      threadId: readString(fields.threadId) || "test-thread",
      turnId: readString(fields.turnId) || null,
      sessionId: readString(fields.sessionId) || null,
      tool: readString(fields.tool) || "bash",
      requestedAt: new Date().toISOString(),
      watchdog: null,
    });
  }


  function getObservabilityMetrics() {
    return {
      sseReconnectCount: ctx.sseReconnectCount,
      permissionPendingCount: ctx.pendingPermissions.size,
      catalogRefreshMs: ctx.lastModelListMeta?.refreshMs ?? null,
    };
  }


  async function permissionReply(request) {
    const params = request.params || {};
    const permissionId = readString(
      params.permissionId || params.permission_id || params.requestId,
    );
    const allow = params.allow === true || params.approved === true || params.accept === true;
    const scope = readString(params.scope) || "once";
    const sessionId = readString(params.sessionId || params.session_id);
    if (!permissionId) {
      return { success: false, reason: "Missing permission ID" };
    }

    const pending = ctx.pendingPermissions.get(permissionId);
    if (!pending) {
      console.log(
        JSON.stringify({
          event: "permission_reply_rejected",
          permissionId,
          reason: "unknown_or_expired",
        }),
      );
      return { success: false, reason: "Unknown or expired permission ID" };
    }

    const replyThreadId = readThreadId(params);
    if (!replyThreadId) {
      console.log(
        JSON.stringify({
          event: "permission_reply_rejected",
          permissionId,
          reason: "missing_thread_id",
        }),
      );
      return { success: false, reason: "Missing thread ID" };
    }
    if (replyThreadId !== pending.threadId) {
      console.log(
        JSON.stringify({
          event: "permission_reply_rejected",
          permissionId,
          reason: "thread_id_mismatch",
          expectedThreadId: pending.threadId,
          replyThreadId,
        }),
      );
      return { success: false, reason: "Permission thread ID does not match" };
    }

    if (sessionId && sessionId !== readString(pending.sessionId)) {
      console.log(
        JSON.stringify({
          event: "permission_reply_rejected",
          permissionId,
          reason: "session_id_mismatch",
          expectedSessionId: pending.sessionId,
          replySessionId: sessionId,
        }),
      );
      return { success: false, reason: "Permission session ID does not match" };
    }

    ctx.clearPermissionWatchdog(pending);

    try {
      await ctx.ensureStarted();
      await ctx.client.replyToPermission(permissionId, allow);

      if (allow && scope === "session") {
        const resolvedSessionId = sessionId || pending.sessionId;
        const tool = readString(pending.tool);
        if (resolvedSessionId && tool) {
          const grants = ctx.sessionPermissionGrants.get(resolvedSessionId) || new Set();
          grants.add(tool);
          ctx.sessionPermissionGrants.set(resolvedSessionId, grants);
        }
      }

      ctx.pendingPermissions.delete(permissionId);
      return { success: true, permissionId, allow, scope };
    } catch (error) {
      ctx.pendingPermissions.set(permissionId, pending);
      if (!ctx.isOpenCodePermissionsUIEnabled()) {
        ctx.armPermissionWatchdog(pending, {
          permissionId,
          threadId: pending.threadId,
          turnId: pending.turnId,
        });
      }
      return { success: false, reason: error.message };
    }
  }

  return {
    isOpenCodePermissionsUIEnabled,
    redactPermissionArgs,
    clearPermissionWatchdog,
    clearAllPendingPermissions,
    evictOldestPendingPermission,
    armPermissionWatchdog,
    handlePermissionRequestEvent,
    testSeedPendingPermission,
    getObservabilityMetrics,
    permissionReply,
  };
}

module.exports = { createOpenCodePermissions };
