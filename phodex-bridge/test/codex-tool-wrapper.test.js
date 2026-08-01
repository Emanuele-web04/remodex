// FILE: codex-tool-wrapper.test.js
// Purpose: Verifies safe projection of Codex exec/wait orchestration wrappers.

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  expandExecWrapperToolCall,
  isOrchestrationWaitCall,
} = require("../src/codex-tool-wrapper");

test("exec wrapper projects a nested command with its real command and cwd", () => {
  const [projected] = expandExecWrapperToolCall({
    type: "custom_tool_call",
    name: "exec",
    call_id: "outer-command",
    status: "completed",
    input: [
      "const result = await tools.exec_command({",
      "  cmd: \"gh run view 123 --json status\",",
      "  workdir: '/repo',",
      "  yield_time_ms: 10000,",
      "});",
      "text(result.output);",
    ].join("\n"),
  });

  assert.equal(projected.type, "function_call");
  assert.equal(projected.name, "exec_command");
  assert.equal(projected.call_id, "outer-command");
  assert.deepEqual(JSON.parse(projected.arguments), {
    cmd: "gh run view 123 --json status",
    workdir: "/repo",
    yield_time_ms: 10000,
  });
});

test("exec wrapper resolves literal variables used by patches and command shorthand", () => {
  const patch = "*** Begin Patch\n*** Update File: app.js\n@@\n-old\n+new\n*** End Patch";
  const projected = expandExecWrapperToolCall({
    type: "custom_tool_call",
    name: "exec",
    call_id: "outer-variable",
    input: [
      `const patch = ${JSON.stringify(patch)};`,
      "const cmd = 'git status --short';",
      "text(await tools.apply_patch(patch));",
      "const result = await tools.exec_command({cmd, workdir: \"/repo\"});",
      "text(result.output);",
    ].join("\n"),
  });

  assert.equal(projected.length, 2);
  assert.equal(projected[0].type, "custom_tool_call");
  assert.equal(projected[0].name, "apply_patch");
  assert.equal(projected[0].input, patch);
  assert.equal(projected[0].call_id, "outer-variable");
  assert.equal(projected[1].call_id, "outer-variable:nested:2");
  assert.deepEqual(JSON.parse(projected[1].arguments), {
    cmd: "git status --short",
    workdir: "/repo",
  });
});

test("exec wrapper keeps every real nested tool call and structured plan", () => {
  const projected = expandExecWrapperToolCall({
    type: "custom_tool_call",
    name: "exec",
    call_id: "outer-parallel",
    input: [
      "const results = await Promise.all([",
      "  tools.exec_command({cmd: \"git status\", workdir: \"/repo\"}),",
      "  tools.update_plan({explanation: \"Done\", plan:[",
      "    {step: \"Inspect\", status: \"completed\"},",
      "  ]}),",
      "]);",
      "for (const result of results) text(result.output);",
    ].join("\n"),
  });

  assert.deepEqual(projected.map((item) => item.name), ["exec_command", "update_plan"]);
  assert.deepEqual(JSON.parse(projected[1].arguments), {
    explanation: "Done",
    plan: [{ step: "Inspect", status: "completed" }],
  });
});

test("exec wrapper ignores tool-like text in strings and comments", () => {
  const payload = {
    type: "custom_tool_call",
    name: "exec",
    call_id: "outer-fallback",
    input: [
      "const example = 'tools.exec_command({cmd: \\\"false hit\\\"})';",
      "// tools.write_stdin({session_id: 1});",
      "text(example);",
    ].join("\n"),
  };

  assert.deepEqual(expandExecWrapperToolCall(payload), [payload]);
});

test("exec wrapper keeps source indexes aligned after unicode strings", () => {
  const [projected] = expandExecWrapperToolCall({
    type: "custom_tool_call",
    name: "exec",
    call_id: "outer-unicode",
    input: [
      "const label = 'release ready 🚀';",
      "const result = await tools.exec_command({cmd: \"git status\"});",
      "text(result.output);",
    ].join("\n"),
  });

  assert.equal(projected.name, "exec_command");
  assert.equal(JSON.parse(projected.arguments).cmd, "git status");
});

test("only cell-backed wait calls are orchestration noise", () => {
  assert.equal(isOrchestrationWaitCall({
    name: "wait",
    arguments: JSON.stringify({ cell_id: "42", yield_time_ms: 30000 }),
  }), true);
  assert.equal(isOrchestrationWaitCall({
    name: "wait",
    arguments: JSON.stringify({ duration: 2 }),
  }), false);
  assert.equal(isOrchestrationWaitCall({
    name: "browser_wait",
    arguments: JSON.stringify({ cell_id: "42" }),
  }), false);
});
