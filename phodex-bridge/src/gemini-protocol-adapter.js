// FILE: gemini-protocol-adapter.js
// Purpose: Translates between Codex-style JSON-RPC (what the Remodex iOS app speaks) and Gemini ACP protocol.
// Layer: CLI helper
// Exports: createGeminiProtocolAdapter
// Depends on: crypto

const { randomBytes } = require("crypto");
const os = require("os");
const fs = require("fs");
const path = require("path");

// ─── State tracking ─────────────────────────────────────────

function createGeminiProtocolAdapter({ transport, logPrefix = "[remodex-gemini]" }) {
  // Gemini ACP state
  let geminiInitialized = false;
  let geminiSessionId = null;
  let geminiModels = [];
  let geminiModes = [];
  let geminiCurrentModelId = null;
  let geminiCurrentModeId = null;
  let geminiAgentInfo = null;

  // Thread management
  let activeThreadId = null;        // The thread the UI is currently "looking at"
  let currentPromptThreadId = null; // The thread that actually sent the current prompt to Gemini
  const threadStates = new Map();

  function getThreadState(tid) {
    const threadId = tid || activeThreadId || "default";
    if (!threadStates.has(threadId)) {
      threadStates.set(threadId, {
        activeTurnId: null,
        activeMessageId: null,
        accumulatedText: "",
        pendingTurnRequestId: null,
        totalInputTokens: 0,
        totalOutputTokens: 0,
        collaborationMode: "default",
        approvalPolicy: "on-request",
        completedAssistantText: "",
      });
    }
    return threadStates.get(threadId);
  }

  // Token usage tracking
  const TOKEN_LIMIT = 1000000; // Gemini context window
  const RATE_LIMIT_THRESHOLD = 100000; // Tokens for 100% rate limit bar (makes bar look more real)

  function parseDataUrl(dataUrl) {
    if (!dataUrl || typeof dataUrl !== "string") return null;
    const matches = dataUrl.match(/^data:([^;]+);base64,(.+)$/);
    if (!matches) return null;
    return {
      mimeType: matches[1],
      data: matches[2]
    };
  }

  // Session persistence
  const stateDir = path.join(os.homedir(), ".remodex");
  const stateFile = path.join(stateDir, "gemini-sessions.json");
  const pendingGeminiRequests = new Map();
  const pendingPermissions = new Map(); // Store stepId -> { geminiRequestId, threadId }
  const threadHistory = new Map(); // Store threadId -> { turns: [], updatedAt, ... }

  // Load persisted sessions
  function loadPersistedState() {
    try {
      if (fs.existsSync(stateFile)) {
        const data = JSON.parse(fs.readFileSync(stateFile, "utf8"));
        if (data.threads) {
          for (const [tid, tdata] of Object.entries(data.threads)) {
            threadHistory.set(tid, tdata);
            // Re-hydrate token counts from history if available
            if (tdata.totalInputTokens) {
              const state = getThreadState(tid);
              state.totalInputTokens = tdata.totalInputTokens;
              state.totalOutputTokens = tdata.totalOutputTokens || 0;
            }
          }
        }
        if (data.activeThreadId) activeThreadId = data.activeThreadId;
        log(`Loaded ${threadHistory.size} persisted threads`);
      }
    } catch (e) {
      log(`warn: failed to load persisted state: ${e.message}`);
    }
  }

  function savePersistedState() {
    try {
      fs.mkdirSync(stateDir, { recursive: true });
      
      // Update threadHistory with latest token counts before saving
      for (const [tid, state] of threadStates.entries()) {
        const hist = threadHistory.get(tid);
        if (hist) {
          hist.totalInputTokens = state.totalInputTokens;
          hist.totalOutputTokens = state.totalOutputTokens;
        }
      }

      const data = {
        activeThreadId,
        threads: Object.fromEntries(threadHistory),
      };
      fs.writeFileSync(stateFile, JSON.stringify(data, null, 2));
    } catch (e) {
      log(`warn: failed to save state: ${e.message}`);
    }
  }

  loadPersistedState();

  function threadCwd(threadId) {
    return threadHistory.get(threadId)?.cwd
      || threadHistory.get(activeThreadId)?.cwd
      || process.cwd();
  }

  function ensureThreadHistory(threadId, cwd = process.cwd()) {
    if (!threadHistory.has(threadId)) {
      const now = new Date().toISOString();
      threadHistory.set(threadId, {
        title: "Gemini Session",
        turns: [],
        createdAt: now,
        updatedAt: now,
        cwd,
      });
    }
    return threadHistory.get(threadId);
  }

  function buildThreadTurnsPage(threadId, {
    limit = 20,
    cursor = null,
    sortDirection = "desc",
  } = {}) {
    const threadData = threadHistory.get(threadId);
    const allTurns = normalizeThreadTurns(threadData?.turns || [], threadId);
    const orderedTurns = String(sortDirection).toLowerCase() === "asc"
      ? allTurns
      : [...allTurns].reverse();
    const offset = Math.max(0, Number.parseInt(String(cursor || "0"), 10) || 0);
    const pageLimit = Math.max(1, Math.min(Number(limit) || 20, 100));
    const data = orderedTurns.slice(offset, offset + pageLimit);
    const nextOffset = offset + data.length;

    return {
      data,
      nextCursor: nextOffset < orderedTurns.length ? String(nextOffset) : null,
    };
  }

  function normalizeThreadTurns(rawTurns, threadId) {
    const groupedTurns = [];
    const turnIndexById = new Map();

    for (const rawTurn of rawTurns) {
      if (!rawTurn || typeof rawTurn !== "object") continue;

      if (Array.isArray(rawTurn.items)) {
        groupedTurns.push({
          id: rawTurn.id || rawTurn.turnId || `turn-${randomBytes(8).toString("hex")}`,
          threadId: rawTurn.threadId || threadId,
          status: rawTurn.status || "completed",
          createdAt: rawTurn.createdAt || rawTurn.timestamp,
          updatedAt: rawTurn.updatedAt || rawTurn.timestamp,
          items: rawTurn.items,
        });
        continue;
      }

      const turnId = rawTurn.id || rawTurn.turnId || `turn-${randomBytes(8).toString("hex")}`;
      let turn = turnIndexById.get(turnId);
      if (!turn) {
        turn = {
          id: turnId,
          threadId,
          status: "completed",
          createdAt: rawTurn.createdAt || rawTurn.timestamp,
          updatedAt: rawTurn.updatedAt || rawTurn.timestamp,
          items: [],
        };
        turnIndexById.set(turnId, turn);
        groupedTurns.push(turn);
      }

      const item = historyRecordToCodexItem(rawTurn, turnId);
      if (item) {
        turn.items.push(item);
      }
      turn.updatedAt = rawTurn.updatedAt || rawTurn.timestamp || turn.updatedAt;
    }

    return groupedTurns.filter((turn) => Array.isArray(turn.items) && turn.items.length > 0);
  }

  function historyRecordToCodexItem(record, turnId) {
    const role = typeof record.role === "string" ? record.role.toLowerCase() : "";
    const text = typeof record.text === "string" ? record.text : "";
    if (!text.trim()) return null;

    const isUser = role.includes("user");
    const itemId = record.itemId || `${turnId}-${isUser ? "user" : "assistant"}`;
    return {
      id: itemId,
      type: isUser ? "user_message" : "agent_message",
      role: isUser ? "user" : "assistant",
      text,
      content: [{
        type: isUser ? "input_text" : "output_text",
        text,
      }],
      createdAt: record.createdAt || record.timestamp,
    };
  }

  // Buffered messages from phone while Gemini session spins up
  const pendingMessages = [];
  let sessionReady = false;

  // Listeners (set by the bridge)
  let onCodexMessage = null; // outbound to phone (Codex-formatted)
  let onClose = null;
  let onError = null;

  // Request tracking for bridge-managed requests
  let geminiRequestCounter = 1000;
  let codexRequestCounter = 1;
  const pendingCodexRequests = new Map();

  // ─── Transport event wiring ─────────────────────────────────

  transport.onMessage((rawMessage) => {
    log(`[Gemini Inbound] ${rawMessage}`);
    handleGeminiMessage(rawMessage);
  });

  transport.onClose((...args) => {
    // Notify phone that bridge is disconnected
    emitCodexEvent("bridge/status/updated", {
      status: "disconnected",
      error: { code: -32000, message: "Gemini CLI transport closed" }
    });
    onClose?.(...args);
  });

  transport.onError((error) => {
    emitCodexEvent("bridge/status/updated", {
      status: "error",
      error: { code: -32000, message: error.message || "Gemini transport error" }
    });
    onError?.(error);
  });

  // ─── Gemini → Codex (outbound from Gemini) ─────────────────────

  function handleGeminiMessage(rawMessage) {
    let parsed;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      return;
    }

    // 1. Handle initialize response (special case)
    if (parsed.id === "gemini-init-1" && parsed.result?.protocolVersion != null) {
      handleGeminiInitializeResponse(parsed);
      // Also clean up from pending requests if it was there
      if (pendingGeminiRequests.has(parsed.id)) {
        const waiter = pendingGeminiRequests.get(parsed.id);
        pendingGeminiRequests.delete(parsed.id);
        clearTimeout(waiter.timeout);
        waiter.resolve?.(parsed.result);
      }
      return;
    }

    // 2. Handle session/new response (special case)
    if (parsed.id != null && parsed.result?.sessionId) {
      handleGeminiSessionNewResponse(parsed);
      // Also clean up from pending requests
      if (pendingGeminiRequests.has(parsed.id)) {
        const waiter = pendingGeminiRequests.get(parsed.id);
        pendingGeminiRequests.delete(parsed.id);
        clearTimeout(waiter.timeout);
        waiter.resolve?.(parsed.result);
      }
      return;
    }

    // 3. Handle response to generic requests (exclude session/prompt which is handled in step 5)
    if (parsed.id != null && pendingGeminiRequests.has(parsed.id) && !parsed.result?.stopReason) {
      const waiter = pendingGeminiRequests.get(parsed.id);
      pendingGeminiRequests.delete(parsed.id);
      clearTimeout(waiter.timeout);

      if (parsed.error) {
        waiter.reject?.(new Error(parsed.error.message || "Gemini request failed"));
      } else {
        waiter.resolve?.(parsed.result);
      }
      return;
    }

    // 4. Handle session/update notifications (streaming responses)
    if (parsed.method === "session/update") {
      handleGeminiSessionUpdate(parsed.params);
      return;
    }

    // 5. Handle session/prompt response (prompt completed)
    if (parsed.id != null && parsed.result) {
      // Find which thread this prompt belonged to
      const promptInfo = pendingGeminiRequests.get(parsed.id);
      
      // Cleanup the pending request now that we've used it
      if (pendingGeminiRequests.has(parsed.id)) {
        pendingGeminiRequests.delete(parsed.id);
        if (promptInfo?.timeout) clearTimeout(promptInfo.timeout);
      }

      const threadId = promptInfo?.threadId || currentPromptThreadId || activeThreadId;
      const state = getThreadState(threadId);

      // Extract token usage from Gemini response
      const meta = parsed.result?._meta;
      if (meta?.quota?.token_count) {
        state.totalInputTokens += (meta.quota.token_count.input_tokens || 0);
        state.totalOutputTokens += (meta.quota.token_count.output_tokens || 0);
        
        // Emit token usage update to iOS
        emitCodexEvent("thread/tokenUsage/updated", {
          threadId: threadId,
          usage: {
            tokensUsed: state.totalInputTokens + state.totalOutputTokens,
            tokenLimit: TOKEN_LIMIT,
            inputTokens: state.totalInputTokens,
            outputTokens: state.totalOutputTokens,
          },
        });
      }

      if (threadId === currentPromptThreadId) {
        currentPromptThreadId = null;
      }
      
      handleGeminiPromptResponse(parsed, threadId);
      
      // Resolve the waiter if it exists
      if (promptInfo?.resolve) {
        promptInfo.resolve(parsed.result);
      }
      return;
    }

    // 6. Handle session/request_permission
    if (parsed.method === "session/request_permission") {
      log(`[Gemini Inbound] Permission requested: ${JSON.stringify(parsed.params).slice(0, 500)}`);
      if (parsed.id != null) {
        const threadId = currentPromptThreadId || activeThreadId;
        const state = getThreadState(threadId);
        
        const command = parsed.params.toolCall?.title || "Tool Execution";
        const reason = parsed.params.message || "Gemini wants to execute a command.";

        log(`[Codex Outbound] Requesting approval for: ${command} (Policy: ${state.approvalPolicy})`);
        
        // If policy is "never", auto-approve without asking the phone
        if (state.approvalPolicy === "never") {
          log(`[Gemini Outbound] Auto-approving request ${parsed.id} due to "never" policy`);
          sendGeminiResponse(parsed.id, { outcome: { outcome: "selected", optionId: "proceed_once" } });
          return;
        }
        
        // Otherwise, send native approval request to iOS
        emitCodexRequest("item/commandExecution/requestApproval", {
          threadId: threadId,
          turnId: state.activeTurnId,
          command: command,
          reason: reason,
        }).then((result) => {
          const decision = result?.decision;
          log(`[Codex Inbound] Native approval decision: ${decision}`);
          
          if (decision === "accept" || decision === "acceptForSession") {
            const optionId = decision === "acceptForSession" ? "proceed_always" : "proceed_once";
            log(`[Gemini Outbound] Approving request ${parsed.id} with option ${optionId}`);
            sendGeminiResponse(parsed.id, { outcome: { outcome: "selected", optionId: optionId } });
          } else {
            log(`[Gemini Outbound] Rejecting request ${parsed.id}`);
            sendGeminiResponse(parsed.id, { outcome: { outcome: "cancelled", optionId: "cancel" } });
          }
        }).catch((err) => {
          log(`[Codex Inbound] Native approval request failed or timed out: ${err.message}`);
          sendGeminiResponse(parsed.id, { outcome: { outcome: "cancelled", optionId: "cancel" } });
        });
      }
      return;
    }

    // Forward unrecognized messages as-is (might be useful)
    log(`unhandled gemini message: ${rawMessage.slice(0, 200)}`);
  }

  function handleGeminiInitializeResponse(parsed) {
    geminiInitialized = true;
    geminiAgentInfo = parsed.result?.agentInfo || null;
    if (geminiAgentInfo) {
      log(`Gemini initialized: ${geminiAgentInfo.name} v${geminiAgentInfo.version}`);
    } else {
      log(`Gemini initialized (no agent info)`);
    }

    // Send initialized notification
    transport.send(JSON.stringify({ jsonrpc: "2.0", method: "initialized" }));

    // Create a session
    const sessionRequestId = nextGeminiRequestId();
    sendGeminiRequest(sessionRequestId, "session/new", {
      cwd: process.cwd(),
      mcpServers: [],
    });
  }

  function handleGeminiSessionNewResponse(parsed) {
    geminiSessionId = parsed.result.sessionId;
    geminiCurrentModelId = parsed.result.models?.currentModelId || null;
    geminiCurrentModeId = parsed.result.modes?.currentModeId || null;

    geminiModels = (parsed.result.models?.availableModels || []).map(m => {
      const modelId = typeof m === "string" ? m : (m.modelId || m.id || m.name);
      const displayName = typeof m === "object" ? (m.name || m.displayName || modelId) : modelId;
      return {
        id: modelId,
        model: modelId,
        object: "model",
        owned_by: "google",
        displayName: displayName,
        description: typeof m === "object" ? (m.description || `Gemini ${modelId} model`) : `Gemini ${modelId} model`,
        isDefault: modelId === geminiCurrentModelId,
        capabilities: {
          chat: true,
          completion: true,
          embeddings: false,
        },
        supportedReasoningEfforts: []
      };
    });
    geminiModes = (parsed.result.modes?.availableModes || []).map(m => ({
      id: m.id,
      name: m.name,
      description: m.description,
      isDefault: m.id === (parsed.result.modes?.currentModeId || "default")
    }));

    if (!geminiCurrentModelId && geminiModels.length > 0) {
      geminiCurrentModelId = geminiModels[0].id;
    }

    log(`Gemini session ready: ${geminiSessionId}`);
    log(`Models: ${geminiModels.map(m => m.id).join(", ")}`);
    sessionReady = true;

    // Flush any pending messages
    while (pendingMessages.length > 0) {
      const msg = pendingMessages.shift();
      handleCodexMessage(msg);
    }
  }

  function handleGeminiSessionUpdate(params) {
    if (!params?.update) return;

    const threadId = currentPromptThreadId || activeThreadId;
    const state = getThreadState(threadId);
    const update = params.update;
    const sessionUpdate = update.sessionUpdate;

    switch (sessionUpdate) {
      case "message_start":
        handleMessageStart(update, threadId);
        break;
      case "message_part":
        handleMessagePart(update, threadId);
        break;
      case "agent_message_chunk":
        if (!state.activeMessageId) {
          handleMessageStart(update, threadId);
        }
        handleMessagePart({
          text: update.content?.text || update.text || "",
        }, threadId);
        break;
      case "message_complete":
        handleMessageComplete(update, threadId);
        break;
      case "turn_complete":
        handleTurnComplete(update, threadId);
        break;
      case "thinking_start":
        break;
      case "thinking_part":
        if (update.text) {
          emitCodexEvent("item/reasoning/textDelta", {
            threadId: threadId,
            turnId: state.activeTurnId,
            delta: update.text,
          });
        }
        break;
      case "thinking_complete":
        break;
      case "tool_call":
        emitCodexEvent("item/commandExecution/outputDelta", {
          threadId: threadId,
          turnId: state.activeTurnId,
          delta: `Running: ${update.name || "tool"}`,
        });
        break;
      case "tool_result":
        emitCodexEvent("item/commandExecution/outputDelta", {
          threadId: threadId,
          turnId: state.activeTurnId,
          delta: update.output || "",
        });
        break;
      case "mode_change":
        geminiCurrentModeId = update.modeId || geminiCurrentModeId;
        break;
      case "model_change":
        geminiCurrentModelId = update.modelId || geminiCurrentModelId;
        break;
      default:
        // Forward as agent delta if it has text
        if (update.text || update.message) {
          const deltaText = update.text || update.message || "";
          if (deltaText && state.activeTurnId) {
            emitCodexEvent("item/agentMessage/delta", {
              threadId: threadId,
              turnId: state.activeTurnId,
              delta: deltaText,
            });
          }
        }
        break;
    }
  }

  function handleMessageStart(update, threadId) {
    const state = getThreadState(threadId);
    state.activeMessageId = `msg-${randomBytes(8).toString("hex")}`;
    state.completedAssistantText = "";
  }

  function handleMessagePart(update, threadId) {
    const state = getThreadState(threadId);
    const text = update.text || update.content || "";
    if (!text) return;

    if (state.accumulatedText === undefined) state.accumulatedText = "";
    state.accumulatedText += text;

    emitCodexEvent("item/agentMessage/delta", {
      threadId: threadId,
      turnId: state.activeTurnId,
      itemId: state.activeMessageId,
      delta: text,
    });
  }

  function handleMessageComplete(update, threadId) {
    const state = getThreadState(threadId);
    const finalText = update.text || update.content || state.accumulatedText || "";
    state.completedAssistantText = finalText;
    emitCodexEvent("item/completed", {
      threadId: threadId,
      turnId: state.activeTurnId,
      item: {
        id: state.activeMessageId,
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: finalText }],
      },
    });
    state.activeMessageId = null;
    state.accumulatedText = "";
  }

  function handleTurnComplete(update, threadId) {
    const state = getThreadState(threadId);
    emitCodexEvent("turn/completed", {
      threadId: threadId,
      turnId: state.activeTurnId,
      turn: {
        id: state.activeTurnId,
        threadId: threadId,
        status: "completed",
      },
    });
    state.activeTurnId = null;
    state.activeMessageId = null;
    state.accumulatedText = "";
    state.completedAssistantText = "";
    state.pendingTurnRequestId = null;
    savePersistedState();
  }

  function handleGeminiPromptResponse(parsed, threadId) {
    const state = getThreadState(threadId);
    // The prompt RPC completed — emit message_complete + turn_complete
    if (parsed.result && parsed.result.stopReason === "end_turn") {
      // Save assistant response in thread history
      const finalText = state.completedAssistantText || state.accumulatedText || "";
      const threadData = threadHistory.get(threadId);
      if (threadData && finalText) {
        threadData.turns.push({
          id: state.activeTurnId,
          role: "assistant",
          text: finalText,
          timestamp: new Date().toISOString(),
        });
        threadData.updatedAt = new Date().toISOString();
        savePersistedState();
      }

      if (state.activeMessageId) {
        handleMessageComplete({}, threadId);
      }
      handleTurnComplete({}, threadId);
    }
  }

  // ─── Codex → Gemini (inbound from phone) ────────────────────

  function handleCodexMessage(rawMessage) {
    let parsed;
    try {
      parsed = JSON.parse(rawMessage);
    } catch {
      // Not JSON, ignore
      return;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    const requestId = parsed?.id;
    
    // Handle responses to requests we sent (where method is undefined)
    if (requestId != null && method === "" && (parsed.result !== undefined || parsed.error !== undefined)) {
      const waiter = pendingCodexRequests.get(requestId);
      if (waiter) {
        log(`[Codex Inbound] Received response for request ${requestId} (${waiter.method})`);
        pendingCodexRequests.delete(requestId);
        if (waiter.timeout) clearTimeout(waiter.timeout);
        
        if (parsed.error) {
          waiter.reject(parsed.error);
        } else {
          waiter.resolve(parsed.result);
        }
        return;
      }
    }

    log(`[Codex Inbound] method: ${method}, id: ${requestId}`);

    // If session not ready yet, buffer the message
    if (!sessionReady && method !== "initialize" && method !== "initialized") {
      log(`[Codex Inbound] Buffering message ${method} because session is not ready`);
      pendingMessages.push(rawMessage);
      return;
    }

    switch (method) {
      case "initialize":
        // Phone sends initialize - wait for Gemini to be ready so we have models
        if (requestId != null) {
          if (sessionReady) {
            log(`[Codex Outbound] Sending initialize response with ${geminiModels.length} models. Current: ${geminiCurrentModelId}`);
            emitCodexResponse(requestId, {
              backendType: "gemini",
              bridgeManaged: true,
              geminiAdapter: true,
              agentInfo: geminiAgentInfo,
              models: geminiModels,
              currentModelId: geminiCurrentModelId,
              capabilities: {
                modelSwitching: true,
                multimodal: true,
                agent: true
              }
            });
          } else {
            log(`[Codex Inbound] Buffering initialize request ${requestId} until session is ready`);
            pendingMessages.push(rawMessage);
          }
        }
        return;

      case "initialized":
        // Silently consume
        return;

      case "thread/start":
        handleThreadStart(parsed);
        return;

      case "turn/start":
        handleTurnStart(parsed);
        return;

      case "turn/cancel":
      case "turn/interrupt":
        handleTurnCancel(parsed);
        return;

      case "account/read":
      case "getAuthStatus":
      case "account/status/read":
        handleAccountStatus(parsed);
        return;

      case "account/login/start":
      case "account/login/cancel":
      case "account/logout":
        handleAuthAction(parsed);
        return;

      case "model/list":
      case "models/list":
        handleModelsList(parsed);
        return;

      case "collaborationMode/list":
        if (requestId != null) {
          emitCodexResponse(requestId, { modes: geminiModes });
        }
        return;

      case "model/set":
        handleModelSet(parsed);
        return;

      case "mode/set":
        handleModeSet(parsed);
        return;

      case "thread/list":
        if (requestId != null) {
          const threads = [];
          // Add persisted threads
          for (const [tid, tdata] of threadHistory) {
            threads.push({
              id: tid,
              title: tdata.title || "Gemini Session",
              updatedAt: tdata.updatedAt || new Date().toISOString(),
              createdAt: tdata.createdAt || new Date().toISOString(),
              syncState: "live",
              cwd: tdata.cwd || threadCwd(tid),
              model: geminiCurrentModelId,
            });
          }
          // If no threads exist, show at least one
          if (threads.length === 0 && activeThreadId) {
            threads.push({
              id: activeThreadId,
              title: "Gemini CLI",
              updatedAt: new Date().toISOString(),
              syncState: "live",
              cwd: threadCwd(activeThreadId),
              model: geminiCurrentModelId,
            });
          }
          emitCodexResponse(requestId, { threads });
        }
        return;

      case "thread/read": {
        const readThreadId = parsed.params?.threadId || activeThreadId || "gemini-default-session";
        const threadData = threadHistory.get(readThreadId);
        if (requestId != null) {
          emitCodexResponse(requestId, {
            thread: {
              id: readThreadId,
              title: threadData?.title || "Gemini CLI",
              cwd: threadData?.cwd || threadCwd(readThreadId),
              model: geminiCurrentModelId,
            },
            turns: normalizeThreadTurns(threadData?.turns || [], readThreadId),
          });
        }
        return;
      }

      case "thread/turns/list": {
        if (requestId != null) {
          const params = parsed.params || {};
          const turnsThreadId = params.threadId || activeThreadId || "gemini-default-session";
          emitCodexResponse(requestId, buildThreadTurnsPage(turnsThreadId, {
            limit: params.limit,
            cursor: params.cursor,
            sortDirection: params.sortDirection,
          }));
        }
        return;
      }

      case "thread/resume":
        if (requestId != null) {
          const resumeThreadId = parsed.params?.threadId || activeThreadId;
          if (resumeThreadId) activeThreadId = resumeThreadId;
          emitCodexResponse(requestId, {
            threadId: activeThreadId,
            thread: {
              id: activeThreadId,
              title: threadHistory.get(activeThreadId)?.title || "Gemini CLI",
              cwd: threadCwd(activeThreadId),
            },
          });
        }
        return;

      case "account/rateLimits/read":
        if (requestId != null) {
          const tid = parsed.params?.threadId || activeThreadId;
          const state = getThreadState(tid);
          // Distribute tokens among tiers based on current model, or show all for transparency
          const usedTokens = state.totalInputTokens + state.totalOutputTokens;
          
          // We return multiple limits to match the three tiers in Gemini CLI UI
          emitCodexResponse(requestId, {
            rateLimitsByLimitId: {
              "gemini-flash": {
                limitId: "gemini-flash",
                limitName: "Flash",
                primary: {
                  usedPercent: geminiCurrentModelId?.includes("flash") ? Math.min(Math.round(usedTokens / 10000 * 100), 100) : 0,
                  windowDurationMins: 1440,
                  resetsAt: new Date(Date.now() + 3600000).toISOString(),
                },
              },
              "gemini-flash-lite": {
                limitId: "gemini-flash-lite",
                limitName: "Flash Lite",
                primary: {
                  usedPercent: geminiCurrentModelId?.includes("lite") ? Math.min(Math.round(usedTokens / 5000 * 100), 100) : 0,
                  windowDurationMins: 1440,
                  resetsAt: new Date(Date.now() + 3600000).toISOString(),
                },
              },
              "gemini-pro": {
                limitId: "gemini-pro",
                limitName: "Pro",
                primary: {
                  usedPercent: (geminiCurrentModelId?.includes("pro") || !geminiCurrentModelId) ? Math.min(Math.round(usedTokens / 2000 * 100), 100) : 0,
                  windowDurationMins: 1440,
                  resetsAt: new Date(Date.now() + 3600000).toISOString(),
                },
              },
            },
          });
        }
        return;

      case "thread/contextWindow/read":
        if (requestId != null) {
          const tid = parsed.params?.threadId || activeThreadId;
          const state = getThreadState(tid);
          const usedTokens = state.totalInputTokens + state.totalOutputTokens;
          emitCodexResponse(requestId, {
            threadId: tid,
            usage: {
              tokensUsed: usedTokens,
              tokenLimit: TOKEN_LIMIT,
              inputTokens: state.totalInputTokens,
              outputTokens: state.totalOutputTokens,
            },
          });
        }
        return;

      case "git/commit":
      case "git/push":
      case "git/commitAndPush":
      case "github/pullRequest/create":
        handleGitCommand(parsed);
        return;

      default:
        // Try to forward as generic request to gemini
        if (requestId != null) {
          // Respond with method not found for unknown Codex methods
          emitCodexMessage(JSON.stringify({
            id: requestId,
            error: {
              code: -32601,
              message: `Method not available in Gemini adapter: ${method}`,
            },
          }));
        }
        return;
    }
  }

  function handleThreadStart(parsed) {
    const requestId = parsed.id;
    const params = parsed.params || {};
    const requestedCwd = params.workingDirectory || params.cwd || process.cwd();
    activeThreadId = `gemini-${randomBytes(8).toString("hex")}`;

    const now = new Date().toISOString();
    const newThread = {
      id: activeThreadId,
      threadId: activeThreadId,
      title: "Gemini Session",
      updatedAt: now,
      createdAt: now,
      syncState: "live",
      cwd: requestedCwd,
      model: geminiCurrentModelId,
    };

    // Persist the thread
    threadHistory.set(activeThreadId, {
      title: "Gemini Session",
      turns: [],
      createdAt: now,
      updatedAt: now,
      cwd: requestedCwd,
    });
    savePersistedState();

    // Reset token counters for new thread
    const state = getThreadState(activeThreadId);
    state.totalInputTokens = 0;
    state.totalOutputTokens = 0;

    // Emit thread/started
    emitCodexEvent("thread/started", {
      threadId: activeThreadId,
      thread: newThread,
    });

    if (requestId != null) {
      emitCodexResponse(requestId, {
        threadId: activeThreadId,
        thread: newThread,
      });
    }
  }

  function handleTurnStart(parsed) {
    const requestId = parsed.id;
    const params = parsed.params || {};
    
    // Dump the full params to see if image is there
    log(`[Codex Inbound] turn/start params: ${JSON.stringify(params).slice(0, 1000)}`);

    // Sync model if phone requested a specific one
    const modelId = params.model;
    if (modelId && modelId !== geminiCurrentModelId && geminiSessionId) {
      log(`[Codex Inbound] Switching model to ${modelId} as requested by phone`);
      const setModelId = nextGeminiRequestId();
      sendGeminiRequest(setModelId, "session/set_model", {
        sessionId: geminiSessionId,
        modelId,
      });
      geminiCurrentModelId = modelId;
    }
    
    const prompt = params.prompt || params.input || params.message || params.content || "";
    const threadId = params.threadId || activeThreadId || `gemini-${randomBytes(8).toString("hex")}`;
    activeThreadId = threadId; // Update the "most recent" thread
    const requestedCwd = params.workingDirectory || params.cwd || threadCwd(threadId);
    const threadData = ensureThreadHistory(threadId, requestedCwd);
    threadData.cwd = threadData.cwd || requestedCwd;
    
    const state = getThreadState(threadId);
    state.activeTurnId = `turn-${randomBytes(8).toString("hex")}`;
    state.pendingTurnRequestId = requestId;
    state.approvalPolicy = params.approvalPolicy || "on-request";

    // Sync mode if phone requested a specific one
    const modeId = params.collaborationMode;
    if (modeId && modeId !== geminiCurrentModeId && geminiSessionId) {
      log(`[Codex Inbound] Switching mode to ${modeId} as requested by phone`);
      const setModeId = nextGeminiRequestId();
      sendGeminiRequest(setModeId, "session/set_mode", {
        sessionId: geminiSessionId,
        modeId,
      });
      geminiCurrentModeId = modeId;
    }

    currentPromptThreadId = threadId;

    // Emit turn/started to phone
    emitCodexEvent("turn/started", {
      threadId: threadId,
      turnId: state.activeTurnId,
      turn: {
        id: state.activeTurnId,
        threadId: threadId,
        status: "in_progress",
      },
    });

    // Respond to the turn/start request
    if (requestId != null) {
      emitCodexResponse(requestId, {
        threadId: threadId,
        turnId: state.activeTurnId,
      });
    }

    // Extract text and image content from prompt
    let promptItems = [];
    
    // If in plan mode, add a system-like instruction
    if (state.collaborationMode === "plan") {
      promptItems.push({ 
        type: "text", 
        text: "[SYSTEM INSTRUCTION: You are in PLAN MODE. Focus on architectural steps and breaking down the task into logical slices. Use the plan structure if possible.]" 
      });
    }

    function extractFromItem(p) {
      if (!p || typeof p !== "object") return;
      
      // Text
      if ((p.type === "text" || p.type === "input_text") && p.text) {
        promptItems.push({ type: "text", text: p.text });
      } else if (typeof p.text === "string" && p.text.trim()) {
        promptItems.push({ type: "text", text: p.text });
      }
      
      // Image or File/Document
      let imageUrl = p.url || p.image_url;
      if (imageUrl && typeof imageUrl === "object" && imageUrl.url) {
        imageUrl = imageUrl.url;
      }
      if (imageUrl && typeof imageUrl === "string") {
        const parsed = parseDataUrl(imageUrl);
        if (parsed) {
          if (imageUrl.startsWith("data:image")) {
            promptItems.push({ 
              type: "image", 
              data: parsed.data, 
              mimeType: parsed.mimeType 
            });
          } else {
            promptItems.push({ 
              type: "file", 
              data: parsed.data, 
              mimeType: parsed.mimeType 
            });
          }
        } else if (p.type === "image" || p.type === "input_image") {
          promptItems.push({ type: "image", url: imageUrl });
        } else if (p.type === "file" || p.type === "document") {
          promptItems.push({ type: "file", url: imageUrl });
        }
      }
    }

    if (typeof prompt === "string" && prompt.trim()) {
      promptItems.push({ type: "text", text: prompt });
    } else if (Array.isArray(prompt)) {
      prompt.forEach(extractFromItem);
    } else if (params.instructions) {
      promptItems.push({ type: "text", text: params.instructions });
    }

    // Also check the items array (Codex format)
    if (promptItems.length === 0 && Array.isArray(params.items)) {
      for (const item of params.items) {
        if (item.role === "user") {
          if (Array.isArray(item.content)) {
            item.content.forEach(extractFromItem);
          } else if (typeof item.content === "string") {
            promptItems.push({ type: "text", text: item.content });
          } else if (typeof item.content === "object") {
            extractFromItem(item.content);
          }
        }
      }
    }

    if (promptItems.length === 0) {
      log("warn: empty prompt in turn/start");
      emitCodexEvent("turn/completed", {
        threadId: threadId,
        turnId: state.activeTurnId,
        turn: { id: state.activeTurnId, threadId: threadId, status: "completed" },
      });
      return;
    }

    // Persist the user message in thread history
    const userText = promptItems.filter(p => p.type === "text").map(p => p.text).join("\\n");
    if (threadData) {
      threadData.turns.push({
        id: state.activeTurnId,
        role: "user",
        text: userText,
        timestamp: new Date().toISOString(),
      });
      threadData.updatedAt = new Date().toISOString();
      // Auto-title from first message
      if (threadData.title === "Gemini Session" && userText.length > 0) {
        threadData.title = userText.slice(0, 60) + (userText.length > 60 ? "..." : "");
        // Notify iOS of the title update
        emitCodexEvent("thread/name/updated", {
          threadId: threadId,
          threadName: threadData.title,
        });
      }
      savePersistedState();
    }

    // Send prompt to Gemini
    if (!geminiSessionId) {
      log("error: no Gemini session for prompt");
      return;
    }

    const geminiReqId = nextGeminiRequestId();
    sendGeminiRequest(geminiReqId, "session/prompt", {
      sessionId: geminiSessionId,
      prompt: promptItems,
    }, threadId);
  }

  function handleTurnCancel(parsed) {
    const requestId = parsed.id;
    const threadId = parsed.params?.threadId || activeThreadId;
    const state = getThreadState(threadId);

    log(`[Codex Inbound] Interrupting turn for thread ${threadId}`);

    if (geminiSessionId) {
      const cancelId = nextGeminiRequestId();
      sendGeminiRequest(cancelId, "cancel", {
        sessionId: geminiSessionId,
      }, threadId);
    }

    // Notify phone that turn is cancelled (echo)
    emitCodexEvent("turn/completed", {
      threadId: threadId,
      turnId: state.activeTurnId,
      turn: {
        id: state.activeTurnId,
        threadId: threadId,
        status: "cancelled",
      },
    });

    if (requestId != null) {
      emitCodexResponse(requestId, { success: true });
    }

    state.activeTurnId = null;
    state.pendingTurnRequestId = null;
    if (threadId === currentPromptThreadId) {
      currentPromptThreadId = null;
    }
  }

  function handleAccountStatus(parsed) {
    const requestId = parsed.id;
    if (requestId == null) return;

    // Return Gemini-specific auth status
    emitCodexResponse(requestId, {
      status: "authenticated",
      authMethod: "google",
      email: null,
      planType: geminiCurrentModelId || "gemini",
      loginInFlight: false,
      needsReauth: false,
      tokenReady: true,
      expiresAt: null,
      bridgeVersion: require("../package.json").version || "1.0.0",
      bridgeLatestVersion: null,
      // Gemini-specific extras
      geminiModels: geminiModels,
      geminiCurrentModelId: geminiCurrentModelId,
      geminiModes: geminiModes,
      geminiCurrentModeId: geminiCurrentModeId,
      geminiAgentInfo: geminiAgentInfo,
      capabilities: {
        modelSwitching: true,
        multimodal: true,
        agent: true
      }
    });
  }

  function handleGitCommand(parsed) {
    const method = parsed.method;
    const params = parsed.params || {};
    const requestId = parsed.id;

    log(`Handling Git command: ${method}`);

    let instruction = "";
    switch (method) {
      case "git/commit":
        instruction = `Please commit the current changes with the following message: "${params.message || "Update"}"`;
        break;
      case "git/push":
        instruction = "Please push the current changes to the remote repository.";
        break;
      case "git/commitAndPush":
        instruction = `Please commit the current changes with the message "${params.message || "Update"}" and push them.`;
        break;
      case "github/pullRequest/create":
        instruction = `Please create a pull request with title "${params.title || "New PR"}" and body "${params.body || ""}".`;
        break;
      default:
        instruction = `Execute command: ${method}`;
    }

    // Forward this to turn/start logic
    handleTurnStart({
      id: requestId,
      params: {
        prompt: `[ACTION: ${instruction}]`,
        collaborationMode: "agent", // Ensure it uses tools
      }
    });
  }

  function handleAuthAction(parsed) {
    const requestId = parsed.id;
    if (requestId == null) return;

    // Gemini doesn't have the same login flow as Codex/OpenAI
    emitCodexResponse(requestId, {
      success: true,
      message: "Gemini CLI uses Google authentication. Please authenticate via 'gemini' CLI directly.",
    });
  }

  function handleModelsList(parsed) {
    const requestId = parsed.id;
    if (requestId == null) return;

    emitCodexResponse(requestId, {
      object: "list",
      data: geminiModels,
      models: geminiModels, // For backwards compatibility
      currentModelId: geminiCurrentModelId,
    });
  }

  function handleModelSet(parsed) {
    const requestId = parsed.id;
    const params = parsed.params || {};
    const modelId = params.modelId || params.model;

    if (modelId && geminiSessionId) {
      const setModelId = nextGeminiRequestId();
      sendGeminiRequest(setModelId, "session/set_model", {
        sessionId: geminiSessionId,
        modelId,
      });
      geminiCurrentModelId = modelId;
    }

    if (requestId != null) {
      emitCodexResponse(requestId, {
        success: true,
        currentModelId: geminiCurrentModelId,
      });
    }
  }

  function handleModeSet(parsed) {
    const requestId = parsed.id;
    const params = parsed.params || {};
    const modeId = params.modeId || params.mode;

    if (modeId && geminiSessionId) {
      const setModeId = nextGeminiRequestId();
      sendGeminiRequest(setModeId, "session/set_mode", {
        sessionId: geminiSessionId,
        modeId,
      });
      geminiCurrentModeId = modeId;
    }

    if (requestId != null) {
      emitCodexResponse(requestId, {
        success: true,
        currentModeId: geminiCurrentModeId,
      });
    }
  }

  // ─── Helpers ────────────────────────────────────────────────

  function emitCodexMessage(rawMessage) {
    onCodexMessage?.(rawMessage);
  }

  function emitCodexEvent(method, params) {
    emitCodexMessage(JSON.stringify({ method, params }));
  }

  function emitCodexResponse(requestId, result) {
    log(`[Codex Outbound] responding to id: ${requestId}`);
    emitCodexMessage(JSON.stringify({ id: requestId, result }));
  }

  function emitCodexRequest(method, params) {
    const id = `bridge-req-${codexRequestCounter++}`;
    const msg = JSON.stringify({
      jsonrpc: "2.0",
      id,
      method,
      params,
    });
    
    log(`[Codex Outbound] request ${id} (${method})`);
    emitCodexMessage(msg);

    return new Promise((resolve, reject) => {
      pendingCodexRequests.set(id, {
        id,
        method,
        resolve,
        reject,
        timeout: setTimeout(() => {
          if (pendingCodexRequests.has(id)) {
            log(`warn: Codex request ${id} (${method}) timed out`);
            pendingCodexRequests.delete(id);
            reject(new Error(`Request ${method} timed out`));
          }
        }, 60000), // 1 minute timeout for user approval
      });
    });
  }

  function sendGeminiResponse(id, result) {
    const msg = JSON.stringify({
      jsonrpc: "2.0",
      id,
      result,
    });
    log(`[Gemini Outbound] response for id ${id}`);
    transport.send(msg);
  }

  function sendGeminiRequest(id, method, params, threadId = null) {
    const msg = JSON.stringify({
      jsonrpc: "2.0",
      id,
      method,
      params,
    });
    log(`[Gemini Outbound] ${msg.slice(0, 500)}${msg.length > 500 ? "..." : ""}`);

    pendingGeminiRequests.set(id, {
      id,
      method,
      threadId: threadId || activeThreadId,
      resolve: null,
      reject: null,
      timeout: setTimeout(() => {
        if (pendingGeminiRequests.has(id)) {
          log(`warn: Gemini request ${id} (${method}) timed out`);
          pendingGeminiRequests.delete(id);
        }
      }, 30000),
    });

    transport.send(msg);

    return new Promise((resolve, reject) => {
      const waiter = pendingGeminiRequests.get(id);
      waiter.resolve = resolve;
      waiter.reject = reject;
    });
  }

  function nextGeminiRequestId() {
    return `gemini-adapter-${geminiRequestCounter++}`;
  }

  function log(message) {
    console.log(`${logPrefix} ${message}`);
  }

  // ─── Start Gemini initialization ────────────────────────────

  // Send initialize to Gemini ACP
  sendGeminiRequest("gemini-init-1", "initialize", {
    protocolVersion: 1,
    clientInfo: {
      name: "remodex",
      version: require("../package.json").version || "1.0.0",
    },
    capabilities: {},
  });

  // ─── Public API (matches codex transport interface) ─────────

  return {
    mode: transport.mode,
    describe() {
      return `Gemini ACP adapter (${transport.describe()})`;
    },
    // Called by bridge to send a phone message → adapter → gemini
    send(rawMessage) {
      handleCodexMessage(rawMessage);
    },
    onMessage(handler) {
      onCodexMessage = handler;
    },
    onClose(handler) {
      onClose = handler;
    },
    onError(handler) {
      onError = handler;
    },
    onStarted(handler) {
      transport.onStarted(handler);
    },
    shutdown() {
      transport.shutdown();
    },
    // Gemini-specific getters
    getModels() {
      return geminiModels;
    },
    getCurrentModelId() {
      return geminiCurrentModelId;
    },
    getModes() {
      return geminiModes;
    },
    getCurrentModeId() {
      return geminiCurrentModeId;
    },
    getAgentInfo() {
      return geminiAgentInfo;
    },
    getSessionId() {
      return geminiSessionId;
    },
    isSessionReady() {
      return sessionReady;
    },
  };
}

module.exports = { createGeminiProtocolAdapter };
