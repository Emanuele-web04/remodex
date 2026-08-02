// FILE: rollout-live-mirror.test.js
// Purpose: Verifies desktop-origin rollout replay/live tailing emits thinking and tool-call notifications for iPhone only.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/rollout-live-mirror

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");
const { setTimeout: wait } = require("node:timers/promises");

const {
  createRolloutLiveMirrorController,
  isDesktopRolloutOrigin,
} = require("../src/rollout-live-mirror");

test("desktop-origin active runs replay thinking and exec command activity on resume", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-desktop",
    originator: "Codex Desktop",
    source: "vscode",
    lines: [
      taskStarted("turn-live"),
      functionCall("call-1", "exec_command", {
        cmd: "git status",
        workdir: "/repo",
      }),
      functionCallOutput("call-1", "On branch main"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-desktop",
    },
  }));

  await wait(30);

  assert.equal(rolloutPath.includes("thread-desktop"), true);
  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "codex/event/exec_command_begin",
      "codex/event/exec_command_output_delta",
      "codex/event/exec_command_end",
      "turn/activity",
    ]
  );
  assert.equal(outbound[1].params.delta, "Thinking...");
  assert.equal(outbound[0].params.remodexDesktopMirror, true);
  assert.equal(outbound[2].params.command, "git status");
  assert.equal(outbound[3].params.chunk, "On branch main");
  // Bootstrap replay is tagged as catch-up so the phone can batch-apply it,
  // and the trailing marker closes the burst while keeping the run active.
  for (const message of outbound.slice(0, 5)) {
    assert.equal(message.params.remodexRolloutBootstrapReplay, true);
  }
  assert.equal(outbound[5].params.remodexRolloutBootstrapComplete, true);
  assert.equal(outbound[5].params.turnId, "turn-live");
  assert.equal(outbound[5].params.remodexRolloutBootstrapReplay, undefined);
});

test("desktop-origin exec wrappers mirror nested commands and hide cell waits", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-wrapped-command",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-wrapped-command"),
      customToolCall("outer-exec", "exec", [
        "const result = await tools.exec_command({",
        "  cmd: \"gh run view 30709849174 --json status,conclusion\",",
        "  workdir: \"/repo\",",
        "});",
        "text(result.output);",
      ].join("\n")),
      customToolCallOutput("outer-exec", [
        { type: "input_text", text: "Script completed\nWall time 0.2 seconds\nOutput:\n" },
        { type: "input_text", text: "{\"status\":\"completed\"}" },
      ]),
      functionCall("outer-wait", "wait", {
        cell_id: "382",
        yield_time_ms: 30000,
      }),
      functionCallOutput("outer-wait", "completed"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-wrapped-command" },
  }));

  await wait(30);

  assert.deepEqual(outbound.map((message) => message.method), [
    "turn/started",
    "item/reasoning/textDelta",
    "codex/event/exec_command_begin",
    "codex/event/exec_command_output_delta",
    "codex/event/exec_command_end",
    "turn/activity",
  ]);
  assert.equal(outbound[2].params.command, "gh run view 30709849174 --json status,conclusion");
  assert.equal(outbound[2].params.cwd, "/repo");
  assert.equal(outbound[3].params.chunk, "{\"status\":\"completed\"}");
  assert.equal(outbound.some((message) => /(?:exec|wait)/i.test(message.params?.message || "")), false);
});

test("desktop-origin exec wrappers complete every nested parallel tool", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-wrapped-parallel",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-wrapped-parallel"),
      customToolCall("outer-parallel", "exec", [
        "const results = await Promise.all([",
        "  tools.exec_command({cmd: \"git status --short\", workdir: \"/repo\"}),",
        "  tools.write_stdin({session_id: 33518, chars: \"\"}),",
        "]);",
        "for (const result of results) text(result.output);",
      ].join("\n")),
      customToolCallOutput("outer-parallel", [
        { type: "input_text", text: "Script completed\nWall time 0.2 seconds\nOutput:\n" },
        { type: "input_text", text: "clean" },
      ]),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-wrapped-parallel" },
  }));

  await wait(30);

  assert.deepEqual(outbound.map((message) => message.method), [
    "turn/started",
    "item/reasoning/textDelta",
    "codex/event/exec_command_begin",
    "codex/event/background_event",
    "codex/event/exec_command_output_delta",
    "codex/event/exec_command_end",
    "codex/event/background_event",
    "turn/activity",
  ]);
  assert.equal(outbound[2].params.command, "git status --short");
  assert.equal(outbound[3].params.message, "Writing to terminal");
  assert.equal(outbound[3].params.itemId, "outer-parallel:nested:2");
  assert.equal(outbound[3].params.status, "inProgress");
  assert.equal(outbound[4].params.chunk, "clean");
  assert.equal(outbound[6].params.message, "Wrote to terminal");
  assert.equal(outbound[6].params.itemId, "outer-parallel:nested:2");
  assert.equal(outbound[6].params.status, "completed");
});

test("desktop-origin active runs emit activity heartbeat while rollout is quiet", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-heartbeat",
    originator: "Codex Desktop",
    source: "vscode",
    lines: [
      taskStarted("turn-heartbeat"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 80,
    activityHeartbeatMs: 15,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-heartbeat",
    },
  }));

  await wait(45);

  const heartbeat = outbound.find((message) => message.method === "turn/activity");
  assert.ok(heartbeat);
  assert.equal(heartbeat.params.threadId, "thread-heartbeat");
  assert.equal(heartbeat.params.turnId, "turn-heartbeat");
  assert.equal(heartbeat.params.remodexDesktopMirror, true);
  assert.equal(outbound.at(-1).params.remodexRolloutLiveMirror, true);
});

test("desktop-origin bootstrap replays the pending user message and final assistant text", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-chat",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      userMessage("Please review this diff"),
      taskStarted("turn-chat"),
      agentMessage("Review complete", "final_answer"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-chat",
    },
  }));

  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "codex/event/user_message",
      "item/reasoning/textDelta",
      "codex/event/agent_message",
      "turn/activity",
    ]
  );
  assert.equal(outbound[0].params.remodexRolloutLiveMirror, true);
  assert.equal(outbound.at(-1).params.remodexRolloutBootstrapComplete, true);
  assert.equal(outbound[1].params.message, "Please review this diff");
  assert.equal(outbound[1].params.turnId, "turn-chat");
  assert.equal(outbound[1].params.createdAt, "2026-03-15T19:47:36.500Z");
  assert.equal(outbound[1].params.timestamp, "2026-03-15T19:47:36.500Z");
  assert.equal(outbound[3].params.message, "Review complete");
  assert.equal(
    outbound[3].params.itemId,
    "rollout-agent-message:thread-chat:turn-chat:2026-03-15T19:47:40.000Z:73e01b91e228"
  );
});

test("desktop-origin bootstrap hides injected context and strips prompt wrappers", async (t) => {
  const agentsContext = "# AGENTS.md instructions for /Users/me/proj\n\n<INSTRUCTIONS>\n## Skills\n- check-code\n</INSTRUCTIONS>";
  const wrappedPrompt = "Some IDE context here\n\n## My request for Codex:\nreview the diff please";
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-context-filter",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      userMessage(agentsContext),
      userMessage(wrappedPrompt),
      taskStarted("turn-context-filter"),
      agentMessage("Done", "final_answer"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-context-filter",
    },
  }));

  await wait(30);

  const userMessages = outbound.filter((message) => message.method === "codex/event/user_message");
  assert.equal(userMessages.length, 1);
  assert.equal(userMessages[0].params.message, "review the diff please");
});

test("rollout mirror suppression silences threads owned by another live source", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-suppressed",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      userMessage("hello there"),
      taskStarted("turn-suppressed"),
      agentMessage("streaming", "final_answer"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  let suppressed = true;
  let fallbackActivityAt = 0;
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
    shouldSuppressThread: (_threadId, context = {}) => {
      fallbackActivityAt = context.fallbackActivityAt || fallbackActivityAt;
      return suppressed;
    },
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-suppressed",
    },
  }));

  await wait(30);
  assert.deepEqual(outbound, []);
  assert.equal(fallbackActivityAt, 0, "suppressed mirrors should not stat the rollout");
});

test("rollout mirror defers its first filesystem scan until after observeInbound returns", (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-deferred-scan",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [taskStarted("turn-deferred-scan")],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  const trackedFs = createTrackedMirrorFs();
  let firstTick = null;
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse() {},
    fsModule: trackedFs,
    setIntervalFn() {
      return 1;
    },
    clearIntervalFn() {},
    setImmediateFn(callback) {
      firstTick = callback;
      return 2;
    },
    clearImmediateFn() {},
  });
  t.after(() => {
    controller.stopAll();
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-deferred-scan" },
  }));

  assert.equal(trackedFs.readdirCalls, 0);
  assert.ok(firstTick);
  firstTick();
  assert.ok(trackedFs.readdirCalls > 0);
});

test("rollout mirror performs no filesystem scan or bootstrap while suppressed", (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-suppressed-scan",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [taskStarted("turn-suppressed-scan")],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  const trackedFs = createTrackedMirrorFs();
  let firstTick = null;
  let intervalTick = null;
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse() {},
    fsModule: trackedFs,
    shouldSuppressThread: () => true,
    setIntervalFn(callback) {
      intervalTick = callback;
      return 1;
    },
    clearIntervalFn() {},
    setImmediateFn(callback) {
      firstTick = callback;
      return 2;
    },
    clearImmediateFn() {},
  });
  t.after(() => {
    controller.stopAll();
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-suppressed-scan" },
  }));
  firstTick();
  intervalTick();

  assert.equal(trackedFs.readdirCalls, 0);
  assert.equal(trackedFs.statCalls, 0);
  assert.equal(trackedFs.readCalls, 0);
});

test("suppression lift re-bootstraps the muted tail so a running thread recovers", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-unmute",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      userMessage("keep going"),
      taskStarted("turn-unmute"),
      agentMessage("still streaming", "final_answer"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  let suppressed = true;
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 200,
    shouldSuppressThread: () => suppressed,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-unmute",
    },
  }));

  // A muted tail does not scan or parse the rollout, and must not leak a turn
  // through the state probe: that is the state another live source owns.
  await wait(30);
  assert.deepEqual(outbound, []);
  assert.equal(controller.getActiveTurnId("thread-unmute"), null);

  // The other live source went stale: the mirror must re-run its bootstrap
  // catch-up so the phone backfills the gap and sees the run as active again,
  // instead of staying frozen on a cursor past content it never mirrored.
  suppressed = false;
  await wait(30);

  const methods = outbound.map((message) => message.method);
  assert.equal(methods.includes("turn/started"), true);
  assert.equal(methods.includes("codex/event/user_message"), true);
  const bootstrapComplete = outbound.find(
    (message) => message.params?.remodexRolloutBootstrapComplete === true
  );
  assert.ok(bootstrapComplete, "expected a bootstrap-complete activity marker after unmute");
  assert.equal(bootstrapComplete.params.turnId, "turn-unmute");
  assert.equal(controller.getActiveTurnId("thread-unmute"), "turn-unmute");
});

test("desktop-origin bootstrap emits terminal catch-up for completed runs", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-terminal-completed",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-terminal-completed"),
      agentMessage("Done", "final_answer"),
      taskComplete("turn-terminal-completed"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-terminal-completed" },
  }));

  await wait(30);

  assert.deepEqual(outbound.map((message) => message.method), ["turn/completed"]);
  assert.equal(outbound[0].params.threadId, "thread-terminal-completed");
  assert.equal(outbound[0].params.turnId, "turn-terminal-completed");
  assert.equal(outbound[0].params.remodexRolloutTerminalCatchUp, true);
  assert.equal(outbound[0].params.remodexRolloutBootstrapReplay, undefined);
});

test("desktop-origin bootstrap emits terminal catch-up for aborted runs", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-terminal-aborted",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-terminal-aborted"),
      turnAborted("turn-terminal-aborted"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-terminal-aborted" },
  }));

  await wait(30);

  assert.deepEqual(outbound.map((message) => message.method), ["turn/completed"]);
  assert.equal(outbound[0].params.turnId, "turn-terminal-aborted");
  assert.equal(outbound[0].params.status, "aborted");
  assert.equal(outbound[0].params.remodexRolloutTerminalCatchUp, true);
});

test("desktop-origin bootstrap emits terminal catch-up for failed runs", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-terminal-error",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-terminal-error"),
      errorEvent("turn-terminal-error", "desktop failed"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-terminal-error" },
  }));

  await wait(30);

  assert.deepEqual(outbound.map((message) => message.method), ["turn/completed"]);
  assert.equal(outbound[0].params.turnId, "turn-terminal-error");
  assert.equal(outbound[0].params.status, "failed");
  assert.deepEqual(outbound[0].params.error, { message: "desktop failed" });
  assert.equal(outbound[0].params.remodexRolloutTerminalCatchUp, true);
});

test("desktop-origin bootstrap terminal catch-up survives interleaved parallel-turn completions", async (t) => {
  // Regression: desktop can interleave parallel turns in one rollout. A sibling
  // turn's task_complete used to close the newest run's scan window, so the
  // newest turn's own task_complete was skipped and catch-up closed the wrong
  // turn, leaving the reopened thread pinned as running.
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-parallel-terminal",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-newest"),
      taskComplete("turn-older-sibling"),
      agentMessage("Newest turn final text", "final_answer"),
      taskComplete("turn-newest"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-parallel-terminal" },
  }));

  await wait(30);

  assert.deepEqual(outbound.map((message) => message.method), ["turn/completed"]);
  assert.equal(outbound[0].params.turnId, "turn-newest");
  assert.equal(outbound[0].params.remodexRolloutTerminalCatchUp, true);
});

test("desktop-origin live tail keeps the active run alive when a sibling turn completes", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-parallel-live",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-live-active"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-parallel-live" },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [
    taskComplete("turn-older-sibling"),
    agentMessage("Still streaming after sibling completed", "commentary"),
  ]);
  await wait(30);

  const siblingCompleted = outbound.find((message) => (
    message.method === "turn/completed"
    && message.params.turnId === "turn-older-sibling"
  ));
  assert.ok(siblingCompleted, "sibling completion should still be mirrored");

  const laterMessage = outbound.find((message) => (
    message.method === "codex/event/agent_message"
    && message.params.message === "Still streaming after sibling completed"
  ));
  assert.ok(laterMessage, "active turn should keep mirroring after sibling completion");
  assert.equal(laterMessage.params.turnId, "turn-live-active");

  const activeCompleted = outbound.find((message) => (
    message.method === "turn/completed"
    && message.params.turnId === "turn-live-active"
  ));
  assert.equal(activeCompleted, undefined, "active turn must not be closed by a sibling terminal");
});

test("desktop-origin mirror stops heartbeating when a crashed run's rollout stays frozen", async (t) => {
  // Regression guard: heartbeats refresh the idle clock (so quiet-but-alive
  // runs survive), but they must never outlive a desktop process that died
  // mid-run, or the phone stays pinned "running" forever.
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-crash-frozen",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-crash-frozen"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 10_000,
    activityHeartbeatMs: 10,
    staleActiveRunMaxAgeMs: 60,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-crash-frozen" },
  }));

  await wait(45);
  const heartbeatsBeforeStale = outbound.filter((message) => message.method === "turn/activity").length;
  assert.ok(heartbeatsBeforeStale >= 1, "heartbeats should flow while inside the stale window");

  await wait(80);
  const heartbeatsAfterStale = outbound.filter((message) => message.method === "turn/activity").length;

  await wait(40);
  const heartbeatsAtEnd = outbound.filter((message) => message.method === "turn/activity").length;
  assert.equal(
    heartbeatsAtEnd,
    heartbeatsAfterStale,
    "mirror must stop heartbeating once the frozen rollout crosses the stale window"
  );
});

test("desktop-origin mirror re-bootstraps after rollout truncation instead of replaying live", async (t) => {
  const longMessage = "x".repeat(600);
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-truncate",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-truncate-old"),
      agentMessage(longMessage, "commentary"),
      agentMessage(`${longMessage}-more`, "commentary"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 200,
    syntheticTerminalGraceMs: 80,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-truncate" },
  }));

  await wait(20);
  outbound.length = 0;

  // Desktop recovery rewrites the rollout smaller, now ending in a completed run.
  const header = JSON.stringify({
    timestamp: "2026-03-15T19:47:36.019Z",
    type: "session_meta",
    payload: { id: "thread-truncate", cwd: "/repo", originator: "Codex Desktop", source: "desktop" },
  });
  fs.writeFileSync(rolloutPath, [
    header,
    taskStarted("turn-truncate-new"),
    taskComplete("turn-truncate-new"),
    "",
  ].join("\n"));

  await wait(40);

  const terminalCatchUp = outbound.find((message) => (
    message.method === "turn/completed"
    && message.params.remodexRolloutTerminalCatchUp === true
  ));
  assert.ok(terminalCatchUp, "rewritten rollout should re-bootstrap into a terminal catch-up");
  assert.equal(terminalCatchUp.params.turnId, "turn-truncate-new");

  const untaggedLiveReplay = outbound.find((message) => (
    message.method === "codex/event/agent_message"
    && !message.params.remodexRolloutBootstrapReplay
  ));
  assert.equal(untaggedLiveReplay, undefined, "rewritten contents must not replay as untagged live events");
});

test("desktop-origin mirror dedupes the same assistant text across event and response_item shapes", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-dedupe-shapes",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-dedupe-shapes"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 200,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-dedupe-shapes" },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [
    agentMessage("Final answer text", "final_answer"),
    responseMessage("Final answer text", "", "msg-duplicate-shape"),
  ]);
  await wait(30);

  const duplicates = outbound.filter((message) => (
    message.method === "codex/event/agent_message"
    && message.params.message === "Final answer text"
  ));
  assert.equal(duplicates.length, 1, "event_msg and response_item copies of the same text must collapse");
  assert.match(
    duplicates[0].params.remodexSourceItemKey,
    /^turn-dedupe-shapes:[a-f0-9]{16}$/,
    "the source alias must survive a later response_item with a different provider id"
  );
});

test("desktop-origin mirror keeps repeated identical user steers while deduping their response copies", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-repeated-user-steers",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [taskStarted("turn-repeated-user-steers")],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 200,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-repeated-user-steers" },
  }));
  await wait(20);
  outbound.length = 0;

  appendRolloutLines(rolloutPath, [
    userMessage("keep going"),
    responseUserMessage("keep going", "user-steer-one"),
    userMessage("keep going"),
    responseUserMessage("keep going", "user-steer-two"),
  ]);
  await wait(30);

  const userMessages = outbound.filter((message) => (
    message.method === "codex/event/user_message"
    && message.params.message === "keep going"
  ));
  assert.equal(userMessages.length, 2);
});

// Phone/app-server-started turns persist the prompt pair in reverse order
// (response_item before event_msg); the occurrence pairing must fold that
// order too, or every prompt sent from the phone mirrors twice.
test("desktop-origin mirror dedupes the user prompt pair when response_item precedes event_msg", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-reversed-user-pair",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [taskStarted("turn-reversed-user-pair")],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 200,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-reversed-user-pair" },
  }));
  await wait(20);
  outbound.length = 0;

  appendRolloutLines(rolloutPath, [
    responseUserMessage("can you push to main", "user-reversed-pair"),
    userMessage("can you push to main"),
  ]);
  await wait(30);

  const userMessages = outbound.filter((message) => (
    message.method === "codex/event/user_message"
    && message.params.message === "can you push to main"
  ));
  assert.equal(userMessages.length, 1);
});

test("desktop-origin mirror dedupes cumulative reasoning summaries across rollout shapes", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-reasoning-dedupe-shapes",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [taskStarted("turn-reasoning-dedupe-shapes")],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 200,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-reasoning-dedupe-shapes" },
  }));

  await wait(20);
  outbound.length = 0;
  appendRolloutLines(rolloutPath, [
    agentReasoning("Testing notify command behavior"),
    agentReasoning("Analyzing notify hook JSON output format"),
    responseReasoning("reasoning-duplicate", [
      "Testing notify command behavior",
      "Analyzing notify hook JSON output format",
    ]),
    responseReasoning("reasoning-cumulative", [
      "Testing notify command behavior",
      "Analyzing notify hook JSON output format",
      "Planning parser fix",
    ]),
  ]);
  await wait(30);

  const deltas = outbound
    .filter((message) => message.method === "item/reasoning/textDelta")
    .map((message) => message.params.delta);
  assert.deepEqual(deltas, [
    "**Testing notify command behavior**\n\n<!-- -->",
    "\n\n**Analyzing notify hook JSON output format**\n\n<!-- -->",
    "\n\n**Planning parser fix**\n\n<!-- -->",
  ]);
  assert.equal(deltas.join("").includes("-->**"), false);
});

test("desktop-origin sibling terminal does not hijack a synthetic active turn", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-synthetic-sibling",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStartedWithoutTurnId(),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 200,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-synthetic-sibling" },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [
    taskComplete("turn-parallel-sibling"),
  ]);
  await wait(20);

  const prematureSyntheticCompleted = outbound.find((message) => (
    message.method === "turn/completed"
    && /^rollout-turn:/.test(String(message.params.turnId))
  ));
  assert.equal(prematureSyntheticCompleted, undefined, "synthetic turn should stay open during grace");

  appendRolloutLines(rolloutPath, [
    agentMessage("Synthetic run continues", "commentary"),
  ]);
  await wait(30);

  const siblingCompleted = outbound.find((message) => (
    message.method === "turn/completed"
    && message.params.turnId === "turn-parallel-sibling"
  ));
  assert.ok(siblingCompleted, "sibling completion should still be mirrored");

  const continuation = outbound.find((message) => (
    message.method === "codex/event/agent_message"
    && message.params.message === "Synthetic run continues"
  ));
  assert.ok(continuation, "synthetic run must keep mirroring after a sibling terminal");
  assert.match(continuation.params.turnId, /^rollout-turn:/);

  const syntheticCompleted = outbound.find((message) => (
    message.method === "turn/completed"
    && /^rollout-turn:/.test(String(message.params.turnId))
  ));
  assert.equal(syntheticCompleted, undefined, "sibling terminal must not close the synthetic run");
});

test("desktop-origin terminal-only real id closes the synthetic active turn", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-synthetic-terminal",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStartedWithoutTurnId(),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 200,
    syntheticTerminalGraceMs: 25,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-synthetic-terminal" },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [
    taskComplete("turn-real-terminal"),
  ]);
  await wait(70);

  const realCompleted = outbound.find((message) => (
    message.method === "turn/completed"
    && message.params.turnId === "turn-real-terminal"
  ));
  assert.ok(realCompleted, "terminal event should still complete the explicit real id");

  const syntheticCompleted = outbound.find((message) => (
    message.method === "turn/completed"
    && /^rollout-turn:/.test(String(message.params.turnId))
  ));
  assert.ok(syntheticCompleted, "terminal-only real id must also close the synthetic active turn");
});

test("desktop-origin mirror keeps commentary prose interleaved with tool calls", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-commentary",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-commentary"),
      agentMessage("Controllo i file toccati", "commentary"),
      functionCall("call-1", "exec_command", { cmd: "git status" }),
      agentMessage("Tutto verde, committo", "commentary"),
      agentMessage("Fatto: commit creato", "final_answer"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-commentary",
    },
  }));

  await wait(30);

  const agentMessages = outbound.filter((message) => message.method === "codex/event/agent_message");
  assert.deepEqual(
    agentMessages.map((message) => [message.params.message, message.params.phase]),
    [
      ["Controllo i file toccati", "commentary"],
      ["Tutto verde, committo", "commentary"],
      ["Fatto: commit creato", "final_answer"],
    ]
  );

  // Desktop renders prose between tool calls; the mirror must preserve that order.
  const flowMethods = outbound
    .filter((message) => (
      message.method === "codex/event/agent_message"
      || message.method === "codex/event/exec_command_begin"
    ))
    .map((message) => message.method);
  assert.deepEqual(flowMethods, [
    "codex/event/agent_message",
    "codex/event/exec_command_begin",
    "codex/event/agent_message",
    "codex/event/agent_message",
  ]);
});

test("desktop-origin mirror stays alive on heartbeat-only active runs", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-heartbeat-idle",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-heartbeat-idle"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 30,
    activityHeartbeatMs: 10,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-heartbeat-idle" },
  }));

  await wait(75);

  const heartbeats = outbound.filter((message) => message.method === "turn/activity");
  assert.ok(heartbeats.length >= 4, `expected heartbeat mirror to stay alive, got ${heartbeats.length}`);
});

test("desktop-origin mirror flushes a valid partial EOF line before stopping", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-partial-eof",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 25,
    activityHeartbeatMs: 100,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-partial-eof" },
  }));

  await wait(10);
  fs.appendFileSync(rolloutPath, taskStarted("turn-partial-eof"));
  await wait(45);

  assert.ok(outbound.some((message) => (
    message.method === "turn/started"
    && message.params.turnId === "turn-partial-eof"
  )));
});

test("desktop-origin mirror emits response_item assistant messages when event_msg is absent", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-response-message",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-response-message"),
      responseMessage("Only response item text", "final_answer", "msg-response-only"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-response-message" },
  }));

  await wait(30);

  const message = outbound.find((entry) => entry.method === "codex/event/agent_message");
  assert.ok(message);
  assert.equal(message.params.message, "Only response item text");
  assert.equal(message.params.phase, "final_answer");
  assert.equal(message.params.itemId, "msg-response-only");
});

test("desktop-origin mirror promotes synthetic turn id when a real id appears", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-promote-turn",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStartedWithoutTurnId(),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-promote-turn" },
  }));

  await wait(10);
  appendRolloutLines(rolloutPath, [
    responseMessage("Real turn arrived", "commentary", "msg-real-turn", "turn-real"),
    taskComplete("turn-real"),
  ]);
  await wait(30);

  const assistant = outbound.find((message) => message.method === "codex/event/agent_message");
  assert.ok(assistant);
  assert.equal(assistant.params.turnId, "turn-real");
  const completed = outbound.find((message) => message.method === "turn/completed");
  assert.ok(completed);
  assert.equal(completed.params.turnId, "turn-real");
});

test("desktop-origin live tail attaches pre-task user messages to the next turn", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-live-prelude",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-live-prelude",
    },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [userMessage("Start from Mac")]);
  await wait(20);
  assert.equal(outbound.length, 0);

  appendRolloutLines(rolloutPath, [taskStarted("turn-live-prelude")]);
  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "codex/event/user_message",
      "item/reasoning/textDelta",
    ]
  );
  assert.equal(outbound[1].params.message, "Start from Mac");
  assert.equal(outbound[1].params.turnId, "turn-live-prelude");
  assert.equal(outbound[1].params.createdAt, "2026-03-15T19:47:36.500Z");
  assert.equal(outbound[1].params.timestamp, "2026-03-15T19:47:36.500Z");
});

test("desktop-origin update_plan calls mirror as structured activity plan updates", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-plan",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-plan"),
      functionCall("call-plan", "update_plan", {
        explanation: "Break the work into safe slices.",
        plan: [
          { step: "Inspect plan rendering", status: "completed" },
          { step: "Keep it visible", status: "in_progress" },
        ],
      }),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-plan",
    },
  }));

  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "turn/plan/updated",
      "turn/activity",
    ]
  );
  assert.equal(outbound[1].params.turnId, "turn-plan");
  assert.equal(outbound[2].params.turnId, "turn-plan");
  assert.equal(outbound[2].params.explanation, "Break the work into safe slices.");
  assert.deepEqual(outbound[2].params.plan, [
    { step: "Inspect plan rendering", status: "completed" },
    { step: "Keep it visible", status: "in_progress" },
  ]);
  assert.equal(outbound[2].params.remodexDesktopMirror, true);
  assert.equal(
    outbound.some((message) => message.params?.message === "Running update_plan"),
    false
  );
});

test("desktop-origin plan mirror ignores empty updates but keeps explanation-only updates", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-plan-visibility",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-plan-visibility"),
      functionCall("call-empty-plan", "update_plan", { plan: [] }),
      functionCall("call-explanation-plan", "update_plan", {
        explanation: "Keep the last meaningful plan visible.",
        plan: [],
      }),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-plan-visibility" },
  }));
  await wait(30);

  const planUpdates = outbound.filter((message) => message.method === "turn/plan/updated");
  assert.equal(planUpdates.length, 1);
  assert.equal(planUpdates[0].params.explanation, "Keep the last meaningful plan visible.");
  assert.deepEqual(planUpdates[0].params.plan, []);
});

test("desktop-origin completed plan items mirror as final plan rows", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-plan-result",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-plan-result"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-plan-result",
    },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [
    planItemCompleted("turn-plan-result", "plan-result-1", "# Improve Dashboard\n\n- Tighten validation"),
    taskComplete("turn-plan-result"),
  ]);
  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "turn/activity",
      "item/completed",
      "turn/completed",
    ]
  );
  assert.equal(outbound[2].params.remodexRolloutBootstrapComplete, true);
  assert.equal(outbound[3].params.threadId, "thread-plan-result");
  assert.equal(outbound[3].params.turnId, "turn-plan-result");
  assert.equal(outbound[3].params.item.type, "Plan");
  assert.equal(outbound[3].params.item.id, "plan-result-1");
  assert.equal(outbound[3].params.item.text, "# Improve Dashboard\n\n- Tighten validation");
  // Live tail events after bootstrap must not carry the bootstrap replay tag.
  assert.equal(outbound[3].params.remodexRolloutBootstrapReplay, undefined);
  assert.equal(outbound[4].params.remodexRolloutBootstrapReplay, undefined);
});

test("desktop-origin task_started without turn_id still mirrors live file changes", async (t) => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: Sources/App.swift",
    "@@",
    "-let title = \"Old\"",
    "+let title = \"New\"",
    "*** End Patch",
    "",
  ].join("\n");
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-turnless-task",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-turnless-task",
    },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [
    taskStarted(),
    customToolCall("call-turnless-patch", "apply_patch", patch),
    patchApplyEnd("", "call-turnless-patch"),
    taskComplete(""),
  ]);
  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "codex/event/patch_apply_begin",
      "codex/event/background_event",
      "codex/event/patch_apply_end",
      "codex/event/patch_apply_end",
      "turn/completed",
    ]
  );
  const mirroredTurnId = outbound[0].params.turnId;
  assert.match(mirroredTurnId, /^rollout-turn:thread-turnless-task:/);
  assert.equal(outbound[2].params.turnId, mirroredTurnId);
  assert.equal(outbound[4].params.turnId, mirroredTurnId);
  assert.equal(outbound[5].params.turnId, mirroredTurnId);
  assert.equal(outbound[5].params.remodexTurnFileChangeSnapshot, true);
  assert.equal(outbound[6].params.turnId, mirroredTurnId);
  assert.equal(outbound[4].params.changes[0].path, "Sources/App.swift");
});

test("desktop-origin active runs mirror generated image previews", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-image",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-image"),
      imageGenerationCall("ig_123"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-image",
    },
  }));

  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "codex/event/image_generation_end",
      "turn/activity",
    ]
  );
  assert.equal(outbound[2].params.call_id, "ig_123");
  assert.equal(outbound[2].params.itemId, "ig_123");
  assert.equal(outbound[2].params.turnId, "turn-image");
  assert.equal(
    outbound[2].params.saved_path,
    path.join(homeDir, "generated_images", "thread-image", "ig_123.png")
  );
});

test("desktop-origin active runs mirror imageView items", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-image-view",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-image-view"),
      imageViewItem("view_123", "/tmp/generated view.png"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-image-view",
    },
  }));

  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "codex/event/image_generation_end",
      "turn/activity",
    ]
  );
  assert.equal(outbound[2].params.call_id, "view_123");
  assert.equal(outbound[2].params.saved_path, "/tmp/generated view.png");
});

test("desktop-origin active runs mirror image_generation items", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-image-generation",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-image-generation"),
      imageGenerationItem("ig_generation", "/tmp/generated item.png"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-image-generation",
    },
  }));

  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "codex/event/image_generation_end",
      "turn/activity",
    ]
  );
  assert.equal(outbound[2].params.call_id, "ig_generation");
  assert.equal(outbound[2].params.saved_path, "/tmp/generated item.png");
});

test("desktop-origin active runs mirror generated image end events without response items", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-image-event",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-image-event"),
      imageGenerationEnd("turn-image-event", "ig_event", "/tmp/generated event.png"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-image-event",
    },
  }));

  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "codex/event/image_generation_end",
      "turn/activity",
    ]
  );
  assert.equal(outbound[2].params.call_id, "ig_event");
  assert.equal(outbound[2].params.itemId, "ig_event");
  assert.equal(outbound[2].params.turnId, "turn-image-event");
  assert.equal(outbound[2].params.saved_path, "/tmp/generated event.png");
});

test("desktop-origin bootstrap only emits terminal catch-up for runs ended by turn_aborted", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-aborted",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      userMessage("Please stop midway"),
      taskStarted("turn-aborted"),
      agentMessage("Partial answer", "final_answer"),
      turnAborted("turn-aborted"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-aborted",
    },
  }));

  await wait(30);

  assert.deepEqual(outbound.map((message) => message.method), ["turn/completed"]);
  assert.equal(outbound[0].params.threadId, "thread-aborted");
  assert.equal(outbound[0].params.turnId, "turn-aborted");
  assert.equal(outbound[0].params.status, "aborted");
  assert.equal(outbound[0].params.remodexRolloutTerminalCatchUp, true);
  assert.equal(outbound[0].params.remodexRolloutBootstrapReplay, undefined);
});

test("desktop-origin bootstrap skips stale active runs whose rollout stopped growing", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-stale",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      userMessage("Long lost run"),
      taskStarted("turn-stale"),
      agentMessage("Working on it", "final_answer"),
    ],
  });
  const staleDate = new Date(Date.now() - 60 * 60_000);
  fs.utimesSync(rolloutPath, staleDate, staleDate);
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
    activityHeartbeatMs: 10,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-stale",
    },
  }));

  await wait(30);

  // No replay and no heartbeats: the hydrated-but-stale run must stay silent.
  assert.deepEqual(outbound, []);
});

test("desktop-origin stale runs resume live mirroring when the rollout grows again", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-stale-resume",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      userMessage("Long lost run"),
      taskStarted("turn-stale-resume"),
    ],
  });
  const staleDate = new Date(Date.now() - 60 * 60_000);
  fs.utimesSync(rolloutPath, staleDate, staleDate);
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
    activityHeartbeatMs: 10,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-stale-resume",
    },
  }));

  await wait(20);
  assert.deepEqual(outbound, []);

  appendRolloutLines(rolloutPath, [
    agentMessage("Back from the dead", "final_answer"),
  ]);
  await wait(40);

  const agentMessageNotification = outbound.find((message) => message.method === "codex/event/agent_message");
  assert.ok(agentMessageNotification);
  assert.equal(agentMessageNotification.params.turnId, "turn-stale-resume");
  const heartbeat = outbound.find((message) => (
    message.method === "turn/activity"
    && message.params.turnId === "turn-stale-resume"
    && message.params.remodexRolloutBootstrapComplete !== true
  ));
  assert.ok(heartbeat, "growth must re-enable heartbeats for the resumed coherent turn");
});

test("desktop-origin live tail closes mirrored turns on turn_aborted", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-live-abort",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-live-abort"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-live-abort",
    },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [turnAborted("turn-live-abort")]);
  await wait(30);

  const completed = outbound.find((message) => message.method === "turn/completed");
  assert.ok(completed);
  assert.equal(completed.params.turnId, "turn-live-abort");
  assert.equal(completed.params.status, "aborted");
});

test("desktop-origin live tail closes mirrored turns on fatal error", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-live-error",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-live-error"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-live-error",
    },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [errorEvent("turn-live-error", "Model stream disconnected")]);
  await wait(30);

  const completed = outbound.find((message) => message.method === "turn/completed");
  assert.ok(completed);
  assert.equal(completed.params.turnId, "turn-live-error");
  assert.equal(completed.params.status, "failed");
  assert.equal(completed.params.error.message, "Model stream disconnected");
});

test("desktop-origin live tail preserves abort status when finalizing a synthetic active turn", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-live-synthetic-abort",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted(),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
    syntheticTerminalGraceMs: 5,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-live-synthetic-abort",
    },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [turnAborted("turn-real-abort")]);
  await wait(40);

  const syntheticCompleted = outbound
    .filter((message) => message.method === "turn/completed")
    .find((message) => message.params.turnId.startsWith("rollout-turn:"));
  assert.ok(syntheticCompleted);
  assert.equal(syntheticCompleted.params.status, "aborted");
});

test("desktop-origin live tail preserves failed status when finalizing a synthetic active turn", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-live-synthetic-error",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted(),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
    syntheticTerminalGraceMs: 5,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-live-synthetic-error",
    },
  }));

  await wait(20);
  appendRolloutLines(rolloutPath, [errorEvent("turn-real-error", "Model stream disconnected")]);
  await wait(40);

  const syntheticCompleted = outbound
    .filter((message) => message.method === "turn/completed")
    .find((message) => message.params.turnId.startsWith("rollout-turn:"));
  assert.ok(syntheticCompleted);
  assert.equal(syntheticCompleted.params.status, "failed");
  assert.equal(syntheticCompleted.params.error.message, "Model stream disconnected");
});

test("phone-origin rollouts do not emit mirrored updates", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-phone",
    originator: "codexmobile_ios",
    source: "ios",
    lines: [
      taskStarted("turn-live"),
      functionCall("call-1", "exec_command", {
        cmd: "git status",
        workdir: "/repo",
      }),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/read",
    params: {
      threadId: "thread-phone",
    },
  }));

  await wait(30);

  assert.deepEqual(outbound, []);
});

test("desktop-origin idle watchers stream new rollout growth after the phone reopens the thread", async (t) => {
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-grow",
    originator: "codex_vscode",
    source: "vscode",
    lines: [],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-grow",
    },
  }));
  await wait(20);

  appendRolloutLines(rolloutPath, [
    taskStarted("turn-next"),
    functionCall("call-2", "apply_patch", {}),
  ]);
  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "codex/event/background_event",
    ]
  );
  assert.equal(outbound[2].params.message, "Applying patch");
});

test("desktop-origin rollouts mirror custom apply_patch as file-change lifecycle", async (t) => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: Sources/App.swift",
    "@@",
    "-let title = \"Old\"",
    "+let title = \"New\"",
    "*** End Patch",
    "",
  ].join("\n");
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-patch",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-patch"),
      customToolCall("call-patch", "apply_patch", patch),
      patchApplyEnd("turn-patch", "call-patch"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-patch",
    },
  }));

  await wait(30);

  assert.deepEqual(
    outbound.map((message) => message.method),
    [
      "turn/started",
      "item/reasoning/textDelta",
      "codex/event/patch_apply_begin",
      "codex/event/background_event",
      "codex/event/patch_apply_end",
      "turn/activity",
    ]
  );
  assert.equal(outbound[2].params.itemId, "call-patch");
  assert.equal(outbound[2].params.status, "inProgress");
  assert.equal(outbound[2].params.changes[0].path, "Sources/App.swift");
  assert.equal(outbound[3].params.itemId, undefined);
  assert.equal(outbound[3].params.status, undefined);
  assert.equal(outbound[4].params.itemId, "call-patch");
  assert.equal(outbound[4].params.changes[0].path, "Sources/App.swift");
  assert.equal(outbound[4].params.changes[0].kind, "update");
  assert.equal(outbound[4].params.changes[0].additions, 1);
  assert.equal(outbound[4].params.changes[0].deletions, 1);
  assert.match(outbound[4].params.changes[0].diff, /diff --git a\/Sources\/App.swift b\/Sources\/App.swift/);
});

test("desktop-origin rollouts emit turn-end file-change snapshot after final text", async (t) => {
  const firstPatch = [
    "*** Begin Patch",
    "*** Update File: Sources/App.swift",
    "@@",
    "-let title = \"Old\"",
    "+let title = \"New\"",
    "*** End Patch",
    "",
  ].join("\n");
  const secondPatch = [
    "*** Begin Patch",
    "*** Update File: Sources/Settings.swift",
    "@@",
    "-let enabled = false",
    "+let enabled = true",
    "*** End Patch",
    "",
  ].join("\n");
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId: "thread-patch-snapshot",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-patch-snapshot"),
      customToolCall("call-patch-1", "apply_patch", firstPatch),
      patchApplyEnd("turn-patch-snapshot", "call-patch-1"),
      customToolCall("call-patch-2", "apply_patch", secondPatch),
      patchApplyEnd("turn-patch-snapshot", "call-patch-2"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 50,
  });
  t.after(() => controller.stopAll());

  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: {
      threadId: "thread-patch-snapshot",
    },
  }));
  await wait(20);
  appendRolloutLines(rolloutPath, [
    agentMessage("Done editing.", "final_answer"),
    taskComplete("turn-patch-snapshot"),
  ]);
  await wait(40);

  const methods = outbound.map((message) => message.method);
  const aggregateIndex = outbound.findIndex((message) => (
    message.method === "codex/event/patch_apply_end"
    && message.params.remodexTurnFileChangeSnapshot === true
  ));
  const completedIndex = methods.lastIndexOf("turn/completed");
  const agentIndex = methods.lastIndexOf("codex/event/agent_message");

  assert.ok(agentIndex >= 0);
  assert.ok(aggregateIndex > agentIndex);
  assert.ok(completedIndex > aggregateIndex);
  assert.equal(outbound[aggregateIndex].params.itemId, "call-patch-2");
  assert.equal(outbound[aggregateIndex].params.changes.length, 2);
  assert.deepEqual(
    outbound[aggregateIndex].params.changes.map((change) => change.path),
    ["Sources/App.swift", "Sources/Settings.swift"]
  );
});

test("desktop-origin detection stays narrow", () => {
  assert.equal(isDesktopRolloutOrigin({ originator: "Codex Desktop", source: "vscode" }), true);
  assert.equal(isDesktopRolloutOrigin({ originator: "codex_vscode", source: "vscode" }), true);
  assert.equal(isDesktopRolloutOrigin({ originator: "codexmobile_ios", source: "ios" }), false);
});

test("desktop-origin bootstrap expands past an oversized opener instead of replaying a tail", async (t) => {
  const oversizedOpener = `OPENING-PROMPT:${"x".repeat((4 * 1024 * 1024) + 128)}`;
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-oversized-bootstrap-opener",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      taskStarted("turn-oversized-bootstrap-opener"),
      runtimeWorldState(),
      runtimeTurnContext(),
      userMessage(oversizedOpener),
      agentMessage("The complete active turn is present"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });

  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) {
      outbound.push(JSON.parse(message));
    },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
  });
  t.after(() => controller.stopAll());
  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-oversized-bootstrap-opener" },
  }));

  await wait(80);
  const opener = outbound.find((message) => (
    message.method === "codex/event/user_message"
    && message.params.turnId === "turn-oversized-bootstrap-opener"
  ));
  assert.ok(opener, "bootstrap must include the active turn opener");
  assert.equal(opener.params.message.startsWith("OPENING-PROMPT:"), true);
  assert.equal(
    outbound.some((message) => message.method === "codex/event/agent_message"),
    true
  );
});

test("desktop-origin bootstrap preserves response_item user openers exactly once", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-response-user-opener",
    originator: "Codex Desktop",
    source: "desktop",
    lines: [
      responseUserMessage("Response opener before start", "user-before"),
      taskStarted("turn-response-user-opener"),
      responseUserMessage("Response opener after start", "user-after"),
      agentMessage("Assistant after both openers"),
    ],
  });
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = homeDir;
  t.after(() => {
    restoreCodexHome(previousCodexHome);
    fs.rmSync(homeDir, { recursive: true, force: true });
  });
  const outbound = [];
  const controller = createRolloutLiveMirrorController({
    sendApplicationResponse(message) { outbound.push(JSON.parse(message)); },
    pollIntervalMs: 5,
    idleTimeoutMs: 100,
  });
  t.after(() => controller.stopAll());
  controller.observeInbound(JSON.stringify({
    method: "thread/resume",
    params: { threadId: "thread-response-user-opener" },
  }));

  await wait(40);
  const users = outbound.filter((message) => message.method === "codex/event/user_message");
  assert.deepEqual(users.map((message) => message.params.message), [
    "Response opener before start",
    "Response opener after start",
  ]);
  const assistantIndex = outbound.findIndex((message) => (
    message.method === "codex/event/agent_message"
  ));
  assert.ok(assistantIndex > outbound.indexOf(users[1]));
});

test("desktop-origin bootstrap represents an image-only response user opener", async (t) => {
  const { homeDir } = createTemporaryRolloutHome({
    threadId: "thread-response-image-opener", originator: "Codex Desktop", source: "desktop",
    lines: [responseImageUserMessage(), taskStarted("turn-response-image-opener"), agentMessage("image handled")],
  });
  const previousCodexHome = process.env.CODEX_HOME; process.env.CODEX_HOME = homeDir;
  t.after(() => { restoreCodexHome(previousCodexHome); fs.rmSync(homeDir, { recursive: true, force: true }); });
  const outbound = [];
  const controller = createRolloutLiveMirrorController({ sendApplicationResponse: (m) => outbound.push(JSON.parse(m)), pollIntervalMs: 5, idleTimeoutMs: 100 });
  t.after(() => controller.stopAll());
  controller.observeInbound(JSON.stringify({ method: "thread/resume", params: { threadId: "thread-response-image-opener" } }));
  await wait(40);
  assert.equal(outbound.find((m) => m.method === "codex/event/user_message")?.params.message, "Image attachment");
});

test("capped bootstrap attaches mid-turn growth under a synthetic turn without replaying the tail", async (t) => {
  const threadId = "thread-capped-attach";
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId, originator: "Codex Desktop", source: "desktop",
    lines: [taskStarted("turn-old"), userMessage("Old opener")],
  });
  // A single malformed sparse-like payload pushes the old boundary outside the
  // 64MB bounded bootstrap window without allocating parsed JSON objects.
  fs.appendFileSync(rolloutPath, `${"x".repeat((65 * 1024 * 1024) + 128)}\n${agentMessage("OLD ORPHAN")}\n`);
  const previousCodexHome = process.env.CODEX_HOME; process.env.CODEX_HOME = homeDir;
  t.after(() => { restoreCodexHome(previousCodexHome); fs.rmSync(homeDir, { recursive: true, force: true }); });
  let bytesRead = 0;
  const trackedFs = { ...fs, readSync(...args) { const count = fs.readSync(...args); bytesRead += count; return count; } };
  const outbound = [];
  const controller = createRolloutLiveMirrorController({ sendApplicationResponse: (m) => outbound.push(JSON.parse(m)), fsModule: trackedFs, pollIntervalMs: 5, idleTimeoutMs: 200 });
  t.after(() => controller.stopAll());
  controller.observeInbound(JSON.stringify({ method: "thread/resume", params: { threadId } }));
  await wait(80);
  // The unreachable tail is never replayed, but the attach announces the run
  // as live under a synthetic turn immediately.
  assert.equal(outbound.some((m) => m.params?.message === "OLD ORPHAN"), false);
  const attachActivity = outbound.find((m) => m.method === "turn/activity");
  assert.ok(attachActivity?.params.turnId.startsWith("rollout-turn:"), "attach must announce a synthetic live turn");
  // Synthetic ids are not actionable app-server turn ids: the probe
  // annotation must not advertise them.
  assert.equal(controller.getActiveTurnId(threadId), null);
  const afterBootstrap = bytesRead;
  appendRolloutLines(rolloutPath, [agentMessage("mid-turn delta after attach")]);
  await wait(30);
  assert.ok(bytesRead - afterBootstrap < 16 * 1024, "attached mode reads only the appended delta");
  const midTurnDelta = outbound.find((m) => m.params?.message === "mid-turn delta after attach");
  assert.ok(midTurnDelta, "growth after the attach point must mirror live");
  assert.ok(midTurnDelta.params.turnId.startsWith("rollout-turn:"));
  appendRolloutLines(rolloutPath, [userMessage("Recovered opener"), taskStarted("turn-recovered"), agentMessage("Recovered assistant")]);
  await wait(50);
  const methods = outbound.filter((m) => m.method === "codex/event/user_message" || m.method === "codex/event/agent_message");
  assert.deepEqual(methods.map((m) => m.params.message), ["mid-turn delta after attach", "Recovered opener", "Recovered assistant"]);
  assert.equal(methods[2].params.turnId, "turn-recovered");
});

test("capped bootstrap attaches to an openerless active turn visible inside the window", async (t) => {
  const threadId = "thread-capped-attach-real-turn";
  const { homeDir, rolloutPath } = createTemporaryRolloutHome({
    threadId, originator: "Codex Desktop", source: "desktop",
    lines: [userMessage("Old opener"), taskStarted("turn-old"), taskComplete("turn-old")],
  });
  fs.appendFileSync(rolloutPath, `${"x".repeat((65 * 1024 * 1024) + 128)}\n${taskStarted("turn-live")}\n${agentMessage("pre-attach output")}\n`);
  const previousCodexHome = process.env.CODEX_HOME; process.env.CODEX_HOME = homeDir;
  t.after(() => { restoreCodexHome(previousCodexHome); fs.rmSync(homeDir, { recursive: true, force: true }); });
  const outbound = [];
  const controller = createRolloutLiveMirrorController({ sendApplicationResponse: (m) => outbound.push(JSON.parse(m)), pollIntervalMs: 5, idleTimeoutMs: 200 });
  t.after(() => controller.stopAll());
  controller.observeInbound(JSON.stringify({ method: "thread/resume", params: { threadId } }));
  await wait(80);
  // Content before the attach point stays canonical-history territory, but the
  // hydrated run keeps its real turn id for everything that follows.
  assert.equal(outbound.some((m) => m.params?.message === "pre-attach output"), false);
  const attachActivity = outbound.find((m) => m.method === "turn/activity");
  assert.equal(attachActivity?.params.turnId, "turn-live");
  // A real hydrated turn id is advertised for the turn-state probe annotation.
  assert.equal(controller.getActiveTurnId(threadId), "turn-live");
  appendRolloutLines(rolloutPath, [agentMessage("post-attach output")]);
  await wait(30);
  const postAttach = outbound.find((m) => m.params?.message === "post-attach output");
  assert.ok(postAttach, "growth after the attach point must mirror live");
  assert.equal(postAttach.params.turnId, "turn-live");
  appendRolloutLines(rolloutPath, [taskComplete("turn-live")]);
  await wait(30);
  const completed = outbound.find((m) => m.method === "turn/completed");
  assert.equal(completed?.params.turnId, "turn-live");
  // Once the run closes the probe annotation goes quiet again.
  assert.equal(controller.getActiveTurnId(threadId), null);
});

function createTemporaryRolloutHome({ threadId, originator, source, lines }) {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "rollout-live-mirror-"));
  const threadDir = path.join(homeDir, "sessions", "2026", "03", "15");
  fs.mkdirSync(threadDir, { recursive: true });
  const rolloutPath = path.join(threadDir, `rollout-2026-03-15T19-47-36-${threadId}.jsonl`);
  const header = JSON.stringify({
    timestamp: "2026-03-15T19:47:36.019Z",
    type: "session_meta",
    payload: {
      id: threadId,
      cwd: "/repo",
      originator,
      source,
    },
  });
  fs.writeFileSync(rolloutPath, [header, ...lines, ""].join("\n"));
  return { homeDir, rolloutPath };
}

function appendRolloutLines(rolloutPath, lines) {
  fs.appendFileSync(rolloutPath, `${lines.join("\n")}\n`);
}

function createTrackedMirrorFs() {
  return {
    ...fs,
    readdirCalls: 0,
    statCalls: 0,
    readCalls: 0,
    readdirSync(...args) {
      this.readdirCalls += 1;
      return fs.readdirSync(...args);
    },
    statSync(...args) {
      this.statCalls += 1;
      return fs.statSync(...args);
    },
    readSync(...args) {
      this.readCalls += 1;
      return fs.readSync(...args);
    },
  };
}

function taskStarted(turnId) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:37.000Z",
    type: "event_msg",
    payload: {
      type: "task_started",
      turn_id: turnId,
      model_context_window: 258400,
    },
  });
}

function taskStartedWithoutTurnId() {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:37.000Z",
    type: "event_msg",
    payload: {
      type: "task_started",
      model_context_window: 258400,
    },
  });
}

function runtimeWorldState() {
  return JSON.stringify({ type: "world_state", payload: { version: 1 } });
}

function runtimeTurnContext() {
  return JSON.stringify({ type: "turn_context", payload: { source: "desktop" } });
}

function userMessage(message) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:36.500Z",
    type: "event_msg",
    payload: {
      type: "user_message",
      message,
    },
  });
}

function agentMessage(message, phase = "final_answer") {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:40.000Z",
    type: "event_msg",
    payload: {
      type: "agent_message",
      message,
      phase,
    },
  });
}

function agentReasoning(title) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:39.000Z",
    type: "event_msg",
    payload: {
      type: "agent_reasoning",
      text: `**${title}**\n\n<!-- -->`,
    },
  });
}

function responseReasoning(id, titles) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:39.500Z",
    type: "response_item",
    payload: {
      type: "reasoning",
      id,
      summary: titles.map((title) => ({
        type: "summary_text",
        text: `**${title}**\n\n<!-- -->`,
      })),
    },
  });
}

function responseMessage(message, phase = "final_answer", id = "msg-response", turnId = "") {
  const payload = {
    type: "message",
    id,
    role: "assistant",
    phase,
    content: [
      {
        type: "output_text",
        text: message,
      },
    ],
  };
  if (turnId) {
    payload.internal_chat_message_metadata_passthrough = {
      turn_id: turnId,
    };
  }
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:40.000Z",
    type: "response_item",
    payload,
  });
}

function responseUserMessage(message, id = "msg-response-user") {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:36.500Z",
    type: "response_item",
    payload: {
      type: "message",
      id,
      role: "user",
      content: [{ type: "input_text", text: message }],
    },
  });
}

function responseImageUserMessage() {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:36.500Z", type: "response_item",
    payload: { type: "message", id: "msg-response-image", role: "user", content: [{ type: "input_image", image_url: "data:image/png;base64,abc" }] },
  });
}

function planItemCompleted(turnId, itemId, text) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:40.500Z",
    type: "event_msg",
    payload: {
      type: "item_completed",
      turn_id: turnId,
      item: {
        type: "Plan",
        id: itemId,
        text,
      },
    },
  });
}

function functionCall(callId, name, argumentsObject) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:38.000Z",
    type: "response_item",
    payload: {
      type: "function_call",
      call_id: callId,
      name,
      arguments: JSON.stringify(argumentsObject),
    },
  });
}

function functionCallOutput(callId, output) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:39.000Z",
    type: "response_item",
    payload: {
      type: "function_call_output",
      call_id: callId,
      output,
    },
  });
}

function customToolCall(callId, name, input) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:38.500Z",
    type: "response_item",
    payload: {
      type: "custom_tool_call",
      status: "completed",
      call_id: callId,
      name,
      input,
    },
  });
}

function customToolCallOutput(callId, output) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:39.000Z",
    type: "response_item",
    payload: {
      type: "custom_tool_call_output",
      call_id: callId,
      output,
    },
  });
}

function patchApplyEnd(turnId, callId) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:38.750Z",
    type: "event_msg",
    payload: {
      type: "patch_apply_end",
      turn_id: turnId,
      call_id: callId,
      status: "completed",
      stdout: "Success. Updated the following files:\nM Sources/App.swift\n",
    },
  });
}

function taskComplete(turnId) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:41.000Z",
    type: "event_msg",
    payload: {
      type: "task_complete",
      turn_id: turnId,
    },
  });
}

function turnAborted(turnId) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:41.000Z",
    type: "event_msg",
    payload: {
      type: "turn_aborted",
      turn_id: turnId,
      reason: "user_interrupt",
    },
  });
}

function errorEvent(turnId, message) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:41.000Z",
    type: "event_msg",
    payload: {
      type: "error",
      turn_id: turnId,
      message,
    },
  });
}

function imageGenerationCall(itemId) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:39.500Z",
    type: "response_item",
    payload: {
      id: itemId,
      type: "image_generation_call",
      status: "completed",
      result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
    },
  });
}

function imageGenerationEnd(turnId, callId, savedPath) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:39.500Z",
    type: "event_msg",
    payload: {
      type: "image_generation_end",
      id: turnId,
      turn_id: turnId,
      call_id: callId,
      saved_path: savedPath,
      result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
    },
  });
}

function imageViewItem(itemId, imagePath) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:39.500Z",
    type: "response_item",
    payload: {
      id: itemId,
      type: "imageView",
      path: imagePath,
    },
  });
}

function imageGenerationItem(itemId, imagePath) {
  return JSON.stringify({
    timestamp: "2026-03-15T19:47:39.500Z",
    type: "response_item",
    payload: {
      id: itemId,
      type: "image_generation",
      path: imagePath,
      result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
    },
  });
}

function restoreCodexHome(previousCodexHome) {
  if (previousCodexHome == null) {
    delete process.env.CODEX_HOME;
    return;
  }
  process.env.CODEX_HOME = previousCodexHome;
}
