// FILE: claude-provider.js
// Purpose: Runs Claude Code turns through the official Agent SDK and adapts them to Remodex RPC events.
// Layer: Runtime provider
// Exports: createClaudeProvider
// Depends on: crypto, ../package.json, ./claude-models, ./claude-thread-store

const { randomBytes, randomUUID } = require("crypto");
const { version: PACKAGE_VERSION } = require("../package.json");
const {
  CLAUDE_MODELS,
  CLAUDE_PROVIDER_ID,
  normalizeClaudeEffort,
  normalizeClaudeModel,
  resolveClaudeCodeExecutable,
} = require("./claude-models");
const { createClaudeThreadStore } = require("./claude-thread-store");

const COMMAND_TOOLS = new Set(["Bash", "BashOutput", "KillShell"]);
const FILE_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);
const READ_TOOLS = new Set(["Read"]);

function createClaudeProvider({
  sendApplicationMessage,
  env = process.env,
  store = createClaudeThreadStore(),
  sdkLoader = () => require("@anthropic-ai/claude-agent-sdk"),
  executableResolver = resolveClaudeCodeExecutable,
  randomUUIDImpl = randomUUID,
  randomBytesImpl = randomBytes,
  logPrefix = "[remodex]",
} = {}) {
  return new ClaudeProvider({
    env,
    executableResolver,
    logPrefix,
    randomBytesImpl,
    randomUUIDImpl,
    sdkLoader,
    sendApplicationMessage,
    store,
  });
}

class ClaudeProvider {
  constructor({
    sendApplicationMessage,
    env,
    store,
    sdkLoader,
    executableResolver,
    randomUUIDImpl,
    randomBytesImpl,
    logPrefix,
  }) {
    this.sendApplicationMessage = sendApplicationMessage;
    this.env = env;
    this.store = store;
    this.sdkLoader = sdkLoader;
    this.executableResolver = executableResolver;
    this.randomUUID = randomUUIDImpl;
    this.randomBytes = randomBytesImpl;
    this.logPrefix = logPrefix;
    this.activeTurns = new Map();
    this.pendingApprovals = new Map();
    this.stoppedTurns = new Set();
    this.finalizedTurns = new Set();
    this.availabilityCache = null;
    this.warnedAvailabilityReason = "";
  }

  ownsThread(threadId) {
    return this.store.ownsThread(threadId);
  }

  listModels() {
    const availability = this.resolveAvailability();
    if (!availability.available) {
      this.warnUnavailable(availability.reason);
      return [];
    }
    return CLAUDE_MODELS;
  }

  listThreads(params = {}) {
    return this.store.listThreads({
      limit: params.limit,
      cursor: params.cursor,
      includeArchived: params.includeArchived === true || params.include_archived === true,
    });
  }

  async handleRequest(request) {
    const method = readString(request?.method);
    switch (method) {
      case "thread/start":
        return this.threadStart(request);
      case "thread/resume":
        return this.threadResume(request);
      case "thread/read":
        return this.threadRead(request);
      case "thread/turns/list":
        return this.threadTurnsList(request);
      case "turn/start":
        return this.turnStart(request);
      case "turn/interrupt":
        return this.turnInterrupt(request);
      case "thread/name/set":
        return this.threadNameSet(request);
      case "thread/archive":
        return this.threadArchive(request, true);
      case "thread/unarchive":
        return this.threadArchive(request, false);
      default:
        throw unsupportedMethodError(method);
    }
  }

  handleApplicationResponse(message) {
    const responseId = message?.id == null ? "" : String(message.id);
    if (!responseId || !this.pendingApprovals.has(responseId)) {
      return false;
    }

    const pending = this.pendingApprovals.get(responseId);
    this.pendingApprovals.delete(responseId);
    clearTimeout(pending.timeout);

    if (message.error) {
      pending.resolve({
        behavior: "deny",
        message: readString(message.error.message) || "Approval request failed.",
      });
      return true;
    }

    pending.resolve(permissionResultFromApprovalResponse(
      message.result,
      pending.input,
      pending.suggestions
    ));
    return true;
  }

  shutdown() {
    for (const active of this.activeTurns.values()) {
      try {
        active.abortController.abort();
      } catch {
        // Ignore shutdown races.
      }
    }
    this.activeTurns.clear();
    this.store.flush?.();
    for (const pending of this.pendingApprovals.values()) {
      clearTimeout(pending.timeout);
      pending.resolve({
        behavior: "deny",
        message: "Remodex bridge is shutting down.",
      });
    }
    this.pendingApprovals.clear();
  }

  threadStart(request) {
    const params = request.params || {};
    const thread = this.store.createThread({
      cwd: params.cwd || params.current_working_directory || params.working_directory,
      model: params.model,
      title: params.title,
    });

    return {
      thread,
    };
  }

  threadResume(request) {
    const threadId = readThreadId(request.params);
    const thread = this.store.getPublicThread(threadId);
    if (!thread) {
      throw threadNotFoundError(threadId);
    }
    return {
      thread,
    };
  }

  threadRead(request) {
    return this.store.readThread(readThreadId(request.params));
  }

  threadTurnsList(request) {
    const params = request.params || {};
    return this.store.listTurns(readThreadId(params), {
      limit: params.limit,
      cursor: params.cursor,
      sortDirection: params.sortDirection || params.sort_direction,
    });
  }

  async turnStart(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    const thread = this.store.getThread(threadId);
    if (!thread) {
      throw threadNotFoundError(threadId);
    }
    if (findActiveTurnEntryForThread(this.activeTurns, threadId)) {
      throw activeTurnError(threadId);
    }

    const model = normalizeClaudeModel(params.model || thread.model);
    const turnId = this.randomUUID();
    const { prompt, inputText } = buildPromptFromTurnInput(params.input);
    this.store.ensureTurn({
      threadId,
      turnId,
      inputText,
      model,
    });

    setImmediate(() => {
      this.runTurn({
        threadId,
        turnId,
        prompt,
        model,
        params,
      }).catch((error) => {
        this.failTurn({ threadId, turnId, error });
      });
    });

    this.emit("turn/started", {
      threadId,
      turnId,
      turn: {
        id: turnId,
        status: "running",
      },
    });

    return {
      turnId,
      turn: {
        id: turnId,
        status: "running",
      },
    };
  }

  async runTurn({ threadId, turnId, prompt, model, params }) {
    const availability = this.resolveAvailability();
    if (!availability.available) {
      throw availabilityError(availability.reason);
    }

    const sdk = this.sdkLoader();
    if (!sdk || typeof sdk.query !== "function") {
      throw availabilityError("Claude Agent SDK is installed but does not expose query().");
    }

    const abortController = new AbortController();
    const thread = this.store.getThread(threadId);
    const permissionMode = permissionModeFromParams(params);
    const options = {
      abortController,
      cwd: thread.cwd || process.cwd(),
      env: {
        ...this.env,
        CLAUDE_AGENT_SDK_CLIENT_APP: `remodex/${PACKAGE_VERSION}`,
      },
      effort: normalizeClaudeEffort(params.effort || params.reasoningEffort || params.reasoning_effort),
      includePartialMessages: true,
      model,
      pathToClaudeCodeExecutable: availability.path,
      permissionMode,
      settingSources: ["user", "project", "local"],
      systemPrompt: { type: "preset", preset: "claude_code" },
      tools: { type: "preset", preset: "claude_code" },
    };

    if (permissionMode === "bypassPermissions") {
      options.allowDangerouslySkipPermissions = true;
    } else {
      options.canUseTool = (toolName, input, approvalOptions) => this.requestToolApproval({
        threadId,
        turnId,
        toolName,
        input,
        approvalOptions,
      });
    }

    if (thread.sessionId) {
      options.resume = thread.sessionId;
    } else {
      options.sessionId = thread.id;
    }

    const query = sdk.query({
      prompt,
      options: removeUndefinedValues(options),
    });
    this.activeTurns.set(turnId, {
      abortController,
      query,
      threadId,
    });

    const streamState = {
      emittedAssistantTextBlocks: new Set(),
      emittedReasoningTextBlocks: new Set(),
      currentStreamMessage: null,
      nextContentItemIndex: 0,
      nextStreamedAssistantMessageIndex: 0,
      streamedAssistantMessages: [],
      toolUseItems: new Map(),
    };

    try {
      for await (const message of query) {
        if (message?.session_id) {
          this.store.rememberSessionId(threadId, message.session_id);
        }
        this.handleSdkMessage({
          message,
          model,
          streamState,
          threadId,
          turnId,
        });
      }
    } finally {
      this.activeTurns.delete(turnId);
    }
  }

  handleSdkMessage({ message, model, streamState, threadId, turnId }) {
    if (!message || typeof message !== "object") {
      return;
    }

    if (message.type === "system" && message.subtype === "init") {
      if (message.session_id) {
        this.store.rememberSessionId(threadId, message.session_id);
      }
      return;
    }

    if (message.type === "stream_event") {
      this.handleStreamEvent({
        event: message.event,
        streamState,
        threadId,
        turnId,
      });
      return;
    }

    if (message.type === "assistant") {
      this.handleAssistantMessage({
        message,
        streamState,
        threadId,
        turnId,
      });
      return;
    }

    if (message.type === "user") {
      this.handleUserReplayMessage({
        message,
        streamState,
        threadId,
        turnId,
      });
      return;
    }

    if (message.type === "result") {
      this.handleResultMessage({
        message,
        model,
        threadId,
        turnId,
      });
    }
  }

  handleStreamEvent({ event, streamState, threadId, turnId }) {
    if (!event || typeof event !== "object") {
      return;
    }

    if (event.type === "message_start") {
      beginStreamMessage(streamState);
      return;
    }

    if (event.type === "content_block_start") {
      ensureStreamBlockKey(streamState, event, { startsBlock: true });
      return;
    }

    if (event.type === "content_block_delta") {
      const delta = event.delta || {};
      const text = readString(delta.text || delta.thinking);
      if (!text) {
        return;
      }
      const blockKey = ensureStreamBlockKey(streamState, event);

      if (delta.type === "thinking_delta") {
        streamState.emittedReasoningTextBlocks.add(blockKey);
        this.emitItemDelta({
          method: "item/reasoning/textDelta",
          threadId,
          turnId,
          itemId: `claude-reasoning-${turnId}-${blockKey}`,
          delta: text,
          storeType: "reasoning",
        });
        return;
      }

      streamState.emittedAssistantTextBlocks.add(blockKey);
      this.emitItemDelta({
        method: "item/agentMessage/delta",
        threadId,
        turnId,
        itemId: `claude-agent-${turnId}-${blockKey}`,
        delta: text,
        storeType: "agentMessage",
        item: {
          phase: "final",
        },
      });
    }
  }

  handleAssistantMessage({ message, streamState, threadId, turnId }) {
    const content = Array.isArray(message.message?.content) ? message.message.content : [];
    const assistantMessageBlocks = takeAssistantMessageBlocks(streamState);
    for (const [index, block] of content.entries()) {
      if (!block || typeof block !== "object") {
        continue;
      }
      const blockKey = contentBlockKeyForAssistantMessage(streamState, assistantMessageBlocks, index);

      if (block.type === "text" && !streamState.emittedAssistantTextBlocks.has(blockKey)) {
        const text = readString(block.text);
        if (text) {
          this.emitItemDelta({
            method: "item/agentMessage/delta",
            threadId,
            turnId,
            itemId: `claude-agent-${turnId}-${blockKey}`,
            delta: text,
            storeType: "agentMessage",
            item: {
              phase: "final",
            },
          });
        }
        continue;
      }

      if (block.type === "thinking" && !streamState.emittedReasoningTextBlocks.has(blockKey)) {
        const text = readString(block.thinking || block.text);
        if (text) {
          this.emitItemDelta({
            method: "item/reasoning/textDelta",
            threadId,
            turnId,
            itemId: `claude-reasoning-${turnId}-${blockKey}`,
            delta: text,
            storeType: "reasoning",
          });
        }
        continue;
      }

      if (block.type === "tool_use") {
        const toolName = readString(block.name) || "Tool";
        const toolInput = block.input && typeof block.input === "object" ? block.input : {};
        const rendered = formatToolUse(toolName, toolInput);
        const classification = classifyTool(toolName);
        const toolUseId = readString(block.id) || blockKey;
        const itemId = `claude-tool-${turnId}-${toolUseId}`;
        streamState.toolUseItems.set(toolUseId, {
          itemId,
          method: classification.method,
          storeType: classification.storeType,
        });
        this.emitItemDelta({
          method: classification.method,
          threadId,
          turnId,
          itemId,
          delta: rendered,
          storeType: classification.storeType,
          item: {
            command: readString(toolInput.command),
            path: readString(toolInput.file_path || toolInput.path || toolInput.notebook_path),
            toolName,
          },
        });
      }
    }
  }

  handleUserReplayMessage({ message, streamState, threadId, turnId }) {
    const content = Array.isArray(message.message?.content) ? message.message.content : [];
    for (const [index, block] of content.entries()) {
      if (!block || typeof block !== "object" || block.type !== "tool_result") {
        continue;
      }
      const contentText = Array.isArray(block.content)
        ? block.content.map(readToolResultPart).filter(Boolean).join("\n")
        : readString(block.content);
      if (!contentText) {
        continue;
      }
      const toolUseId = readString(block.tool_use_id) || String(index);
      const toolUseItem = streamState?.toolUseItems?.get(toolUseId);
      const delta = toolUseItem ? ensureLeadingNewline(contentText) : contentText;
      this.emitItemDelta({
        method: toolUseItem?.method || "item/toolCall/outputDelta",
        threadId,
        turnId,
        itemId: toolUseItem?.itemId || `claude-tool-${turnId}-${toolUseId}`,
        delta,
        storeType: toolUseItem?.storeType || "toolCall",
      });
    }
  }

  handleResultMessage({ message, model, threadId, turnId }) {
    const isError = message.is_error === true || message.subtype !== "success";
    const wasStopped = this.stoppedTurns.has(turnId);
    this.stoppedTurns.delete(turnId);
    const status = wasStopped ? "stopped" : (isError ? "failed" : "completed");
    const errorMessage = status === "failed" ? resultErrorMessage(message) : "";
    this.completeAndEmitTurn({
      errorMessage,
      model,
      status,
      threadId,
      turnId,
    });
  }

  failTurn({ threadId, turnId, error }) {
    const wasAborted = this.activeTurns.get(turnId)?.abortController?.signal?.aborted === true
      || this.stoppedTurns.has(turnId);
    this.stoppedTurns.delete(turnId);
    this.activeTurns.delete(turnId);
    const status = wasAborted ? "stopped" : "failed";
    const errorMessage = wasAborted ? "" : (error?.message || "Claude turn failed.");
    this.completeAndEmitTurn({
      errorMessage,
      status,
      threadId,
      turnId,
    });
  }

  async turnInterrupt(request) {
    const params = request.params || {};
    const turnId = readString(params.turnId || params.turn_id);
    const threadId = readThreadId(params);
    const activeEntry = turnId
      ? [turnId, this.activeTurns.get(turnId)]
      : findActiveTurnEntryForThread(this.activeTurns, threadId);
    const active = activeEntry?.[1] || null;
    if (!active) {
      return {
        success: true,
        interrupted: false,
      };
    }

    try {
      if (typeof active.query?.interrupt === "function") {
        await active.query.interrupt();
      }
    } catch {
      // Fall through to abort; interrupt is best-effort for non-streaming SDK paths.
    }
    active.abortController.abort();
    const resolvedTurnId = activeEntry[0] || "";
    this.activeTurns.delete(resolvedTurnId);
    this.stoppedTurns.add(resolvedTurnId);
    if (resolvedTurnId) {
      const resolvedThreadId = active.threadId || threadId;
      this.completeAndEmitTurn({
        status: "stopped",
        threadId: resolvedThreadId,
        turnId: resolvedTurnId,
      });
    }
    return {
      success: true,
      interrupted: true,
    };
  }

  threadNameSet(request) {
    const params = request.params || {};
    const threadId = readThreadId(params);
    const name = params.name || params.title;
    const thread = this.store.renameThread(threadId, name);
    this.emit("thread/name/updated", {
      threadId,
      thread_id: threadId,
      name: thread.name || thread.title,
      title: thread.title,
    });
    return {
      thread,
    };
  }

  threadArchive(request, archived) {
    const thread = this.store.setArchived(readThreadId(request.params), archived);
    return {
      thread,
    };
  }

  async requestToolApproval({ threadId, turnId, toolName, input, approvalOptions = {} }) {
    if (toolName === "AskUserQuestion") {
      return {
        behavior: "deny",
        message: "Ask the user directly in the chat instead of using AskUserQuestion.",
      };
    }

    const requestId = `claude-approval-${this.randomBytes(12).toString("hex")}`;
    const approval = approvalRequestForTool({
      input,
      requestId,
      threadId,
      title: approvalOptions.title,
      toolName,
      turnId,
    });

    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        this.pendingApprovals.delete(requestId);
        resolve({
          behavior: "deny",
          message: "Approval timed out.",
        });
      }, 15 * 60_000);

      const abortHandler = () => {
        clearTimeout(timeout);
        this.pendingApprovals.delete(requestId);
        resolve({
          behavior: "deny",
          message: "Turn was interrupted before approval completed.",
        });
      };
      approvalOptions.signal?.addEventListener?.("abort", abortHandler, { once: true });

      this.pendingApprovals.set(requestId, {
        input,
        resolve,
        suggestions: Array.isArray(approvalOptions.suggestions) ? approvalOptions.suggestions : [],
        timeout,
      });
      this.sendApplicationMessage(JSON.stringify(approval));
    });
  }

  emitItemDelta({ method, threadId, turnId, itemId, delta, storeType, item }) {
    this.store.appendItemDelta({
      delta,
      item,
      itemId,
      threadId,
      turnId,
      type: storeType,
    });
    this.emit(method, {
      threadId,
      turnId,
      itemId,
      delta,
      textDelta: delta,
      item: {
        id: itemId,
        turnId,
        type: storeType,
        ...removeUndefinedValues(item || {}),
      },
    });
  }

  completeAndEmitTurn({ threadId, turnId, model, status, errorMessage = "" }) {
    if (this.finalizedTurns.has(turnId)) {
      return false;
    }
    this.finalizedTurns.add(turnId);
    pruneSet(this.finalizedTurns, 500);
    try {
      this.store.completeTurn({
        errorMessage,
        status,
        threadId,
        turnId,
      });
    } catch {
      // If the store is already gone, still tell the app the turn is terminal.
    }
    this.emit("turn/completed", {
      threadId,
      turnId,
      model,
      status,
      turn: {
        id: turnId,
        status,
        error: errorMessage ? { message: errorMessage } : undefined,
      },
    });
    return true;
  }

  emit(method, params) {
    this.sendApplicationMessage(JSON.stringify({
      method,
      params: removeUndefinedValues(params || {}),
    }));
  }

  resolveAvailability() {
    const cacheKey = [
      this.env.REMODEX_CLAUDE_CODE_ENABLED || "",
      this.env.REMODEX_CLAUDE_CODE_COMMAND || "",
    ].join("\0");
    if (this.availabilityCache?.key === cacheKey) {
      return this.availabilityCache.value;
    }
    try {
      const value = this.executableResolver({ env: this.env });
      this.availabilityCache = { key: cacheKey, value };
      return value;
    } catch (error) {
      const value = {
        available: false,
        command: "",
        path: "",
        reason: error?.message || "Failed to resolve Claude Code executable.",
      };
      this.availabilityCache = { key: cacheKey, value };
      return value;
    }
  }

  warnUnavailable(reason) {
    const normalizedReason = readString(reason);
    if (!normalizedReason || this.warnedAvailabilityReason === normalizedReason) {
      return;
    }
    this.warnedAvailabilityReason = normalizedReason;
    console.warn(`${this.logPrefix} Claude Code unavailable: ${normalizedReason}`);
  }
}

function buildPromptFromTurnInput(input) {
  if (typeof input === "string") {
    return {
      inputText: input,
      prompt: input,
    };
  }
  if (!Array.isArray(input)) {
    return {
      inputText: "",
      prompt: "",
    };
  }
  const contentBlocks = [];
  const inputTextParts = [];
  const fallbackTextParts = [];

  for (const item of input) {
    if (typeof item === "string") {
      const text = item.trim();
      if (text) {
        contentBlocks.push({ type: "text", text });
        inputTextParts.push(text);
      }
      continue;
    }
    if (!item || typeof item !== "object") {
      continue;
    }
    const type = readString(item.type).toLowerCase();
    if (type.includes("image")) {
      const imageBlock = imageContentBlockFromInput(item);
      if (imageBlock) {
        contentBlocks.push(imageBlock);
      } else {
        const imagePath = readString(item.path || item.url || item.image_url);
        fallbackTextParts.push(imagePath ? `[image attached: ${imagePath}]` : "[image attached]");
      }
      continue;
    }
    const text = readString(item.text || item.content || item.message);
    if (text) {
      contentBlocks.push({ type: "text", text });
      inputTextParts.push(text);
    }
  }

  for (const fallbackText of fallbackTextParts) {
    contentBlocks.push({ type: "text", text: fallbackText });
  }

  const inputText = inputTextParts.join("\n\n").trim()
    || (contentBlocks.some((block) => block.type === "image") ? "Image request" : fallbackTextParts.join("\n\n").trim());

  if (!contentBlocks.some((block) => block.type === "image")) {
    const promptText = [...inputTextParts, ...fallbackTextParts].join("\n\n").trim();
    return {
      inputText: inputText || promptText,
      prompt: promptText,
    };
  }

  return {
    inputText,
    prompt: singleUserPrompt(contentBlocks),
  };
}

async function* singleUserPrompt(contentBlocks) {
  yield {
    type: "user",
    message: {
      role: "user",
      content: contentBlocks,
    },
    parent_tool_use_id: null,
  };
}

function imageContentBlockFromInput(item) {
  const dataUrl = readString(item.image_url || item.url || item.dataURL || item.data_url);
  const parsed = parseImageDataUrl(dataUrl);
  if (!parsed) {
    return null;
  }
  return {
    type: "image",
    source: {
      type: "base64",
      media_type: parsed.mediaType,
      data: parsed.data,
    },
  };
}

function parseImageDataUrl(value) {
  const normalized = readString(value);
  const match = normalized.match(/^data:([^;,]+);base64,(.+)$/s);
  if (!match) {
    return null;
  }
  const mediaType = match[1].trim().toLowerCase();
  const data = match[2].replace(/\s/g, "");
  if (!mediaType.startsWith("image/") || !data) {
    return null;
  }
  return { mediaType, data };
}

function permissionModeFromParams(params) {
  const collaborationMode = readString(params?.collaborationMode?.mode || params?.collaboration_mode?.mode);
  if (collaborationMode === "plan") {
    return "plan";
  }

  const approvalPolicy = readString(params?.approvalPolicy || params?.approval_policy).toLowerCase();
  const sandbox = readString(params?.sandbox).toLowerCase();
  const sandboxPolicy = params?.sandboxPolicy || params?.sandbox_policy || {};
  const sandboxPolicyMode = readString(sandboxPolicy.mode || sandboxPolicy.type || sandboxPolicy.access).toLowerCase();
  if (approvalPolicy === "never"
    || sandbox === "danger-full-access"
    || sandboxPolicyMode === "danger-full-access"
    || sandboxPolicyMode === "full-access") {
    return "bypassPermissions";
  }

  return "default";
}

function approvalRequestForTool({ requestId, threadId, turnId, toolName, input, title }) {
  const classification = classifyTool(toolName);
  const command = readString(input?.command)
    || readString(input?.file_path || input?.path || input?.notebook_path)
    || toolName;
  return {
    id: requestId,
    method: classification.approvalMethod,
    params: {
      threadId,
      turnId,
      itemId: `claude-approval-${turnId}-${toolName}`,
      toolName,
      command,
      reason: readString(title) || `Claude wants to use ${toolName}.`,
      permissionSource: "claudeCodeSdk",
      input: sanitizeToolInput(input),
    },
  };
}

function permissionResultFromApprovalResponse(result, input, suggestions = []) {
  const decision = readString(result?.decision).toLowerCase();
  if (decision === "accept" || decision === "acceptforsession") {
    const permissionResult = {
      behavior: "allow",
      updatedInput: input,
    };
    if (decision === "acceptforsession" && suggestions.length > 0) {
      permissionResult.updatedPermissions = suggestions;
    }
    return permissionResult;
  }
  if (result?.permissions && Object.keys(result.permissions).length > 0) {
    const permissionResult = {
      behavior: "allow",
      updatedInput: input,
    };
    if (suggestions.length > 0) {
      permissionResult.updatedPermissions = suggestions;
    }
    return permissionResult;
  }
  return {
    behavior: "deny",
    message: "User denied permission.",
  };
}

function classifyTool(toolName) {
  if (COMMAND_TOOLS.has(toolName)) {
    return {
      approvalMethod: "item/commandExecution/requestApproval",
      method: "item/commandExecution/outputDelta",
      storeType: "commandExecution",
    };
  }
  if (FILE_TOOLS.has(toolName)) {
    return {
      approvalMethod: "item/fileChange/requestApproval",
      method: "item/fileChange/outputDelta",
      storeType: "fileChange",
    };
  }
  if (READ_TOOLS.has(toolName)) {
    return {
      approvalMethod: "item/fileRead/requestApproval",
      method: "item/toolCall/outputDelta",
      storeType: "toolCall",
    };
  }
  return {
    approvalMethod: "item/permissions/requestApproval",
    method: "item/toolCall/outputDelta",
    storeType: "toolCall",
  };
}

function formatToolUse(toolName, input) {
  if (COMMAND_TOOLS.has(toolName)) {
    const command = readString(input.command) || toolName;
    return `$ ${command}`;
  }
  if (FILE_TOOLS.has(toolName)) {
    const filePath = readString(input.file_path || input.path || input.notebook_path);
    return filePath ? `${toolName}: ${filePath}` : `${toolName}`;
  }
  const rendered = JSON.stringify(sanitizeToolInput(input));
  return rendered && rendered !== "{}" ? `${toolName}: ${rendered}` : `${toolName}`;
}

function ensureLeadingNewline(value) {
  return value.startsWith("\n") ? value : `\n${value}`;
}

function sanitizeToolInput(input) {
  if (!input || typeof input !== "object") {
    return {};
  }
  const result = {};
  for (const [key, value] of Object.entries(input)) {
    if (typeof value === "string") {
      result[key] = value.length > 4000 ? `${value.slice(0, 4000)}...` : value;
    } else if (typeof value === "number" || typeof value === "boolean" || value == null) {
      result[key] = value;
    } else {
      result[key] = JSON.stringify(value).slice(0, 4000);
    }
  }
  return result;
}

function readToolResultPart(part) {
  if (typeof part === "string") {
    return part;
  }
  if (!part || typeof part !== "object") {
    return "";
  }
  return readString(part.text || part.content || part.value);
}

function resultErrorMessage(message) {
  if (Array.isArray(message.errors) && message.errors.length > 0) {
    return message.errors.map(readString).filter(Boolean).join("\n");
  }
  return readString(message.result) || "Claude turn failed.";
}

function readThreadId(params = {}) {
  return readString(params.threadId || params.thread_id || params.id);
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function removeUndefinedValues(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined)
  );
}

function findActiveTurnEntryForThread(activeTurns, threadId) {
  for (const [turnId, active] of activeTurns.entries()) {
    if (active.threadId === threadId) {
      return [turnId, active];
    }
  }
  return null;
}

function beginStreamMessage(streamState) {
  const message = {
    blockKeysByIndex: new Map(),
    consumed: false,
  };
  streamState.currentStreamMessage = message;
  streamState.streamedAssistantMessages.push(message);
  return message;
}

function ensureCurrentStreamMessage(streamState, blockIndex, { startsBlock = false } = {}) {
  const current = streamState.currentStreamMessage;
  if (!current || current.consumed || (startsBlock && current.blockKeysByIndex.has(blockIndex))) {
    return beginStreamMessage(streamState);
  }
  return current;
}

function ensureStreamBlockKey(streamState, event, options = {}) {
  const blockIndex = contentBlockIndex(event, "0");
  const current = ensureCurrentStreamMessage(streamState, blockIndex, options);
  if (!current.blockKeysByIndex.has(blockIndex)) {
    current.blockKeysByIndex.set(blockIndex, nextContentBlockKey(streamState));
  }
  return current.blockKeysByIndex.get(blockIndex);
}

function takeAssistantMessageBlocks(streamState) {
  const message = streamState.streamedAssistantMessages[streamState.nextStreamedAssistantMessageIndex] || null;
  if (!message) {
    return null;
  }
  streamState.nextStreamedAssistantMessageIndex += 1;
  message.consumed = true;
  return message.blockKeysByIndex;
}

function contentBlockKeyForAssistantMessage(streamState, streamedBlocks, index) {
  const blockIndex = String(index);
  return streamedBlocks?.get(blockIndex) || nextContentBlockKey(streamState);
}

function nextContentBlockKey(streamState) {
  const key = String(streamState.nextContentItemIndex);
  streamState.nextContentItemIndex += 1;
  return key;
}

function contentBlockIndex(event, fallback) {
  const index = Number(event?.index);
  return Number.isInteger(index) && index >= 0 ? String(index) : fallback;
}

function pruneSet(set, maxSize) {
  while (set.size > maxSize) {
    const first = set.values().next().value;
    set.delete(first);
  }
}

function unsupportedMethodError(method) {
  const error = new Error(`Claude provider does not support ${method || "(missing method)"}.`);
  error.errorCode = "unsupported_method";
  return error;
}

function activeTurnError(threadId) {
  const error = new Error(`Claude thread already has an active turn: ${threadId || "(missing)"}`);
  error.errorCode = "turn_already_running";
  error.userMessage = "Claude is already running on this thread. Stop the current turn before starting another.";
  return error;
}

function threadNotFoundError(threadId) {
  const error = new Error(`Claude thread not found: ${threadId || "(missing)"}`);
  error.errorCode = "thread_not_found";
  return error;
}

function availabilityError(reason) {
  const error = new Error(reason || "Claude Code is unavailable.");
  error.errorCode = "claude_unavailable";
  return error;
}

module.exports = {
  createClaudeProvider,
  permissionModeFromParams,
};
