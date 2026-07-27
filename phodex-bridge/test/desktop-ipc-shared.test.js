// FILE: desktop-ipc-shared.test.js
// Purpose: Unit tests for the shared desktop IPC primitives (injected-context filters, socket path resolution).
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:fs, node:net, node:os, node:path, ../src/desktop-ipc-shared

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const {
  isContextualUserText,
  isThreadTurnStateProbeRequest,
  resolveDefaultIpcSocketPath,
  resolveIpcSocketPathCandidates,
  responseItemMessageText,
  sanitizeUserInputEntries,
  sanitizeUserRoleItem,
  visibleUserPromptText,
} = require("../src/desktop-ipc-shared");

test("response item text preserves nested data text parts", () => {
  assert.equal(
    responseItemMessageText({
      role: "assistant",
      content: [{ type: "output_text", data: { text: "Nested assistant text" } }],
    }),
    "Nested assistant text"
  );
});

// Payload shapes below are lifted verbatim from real rollout files, so these
// tests break when the runtime changes its injected-context format again.

test("filters AGENTS.md instructions without the legacy ' for <path>' suffix", () => {
  const text = "# AGENTS.md instructions\n\n<INSTRUCTIONS>\n## Skills\n- check-code: ...\n</INSTRUCTIONS>";
  assert.equal(isContextualUserText(text), true);
  assert.equal(visibleUserPromptText(text), "");
});

test("filters legacy AGENTS.md instructions with the ' for <path>' suffix", () => {
  const text = "# AGENTS.md instructions for /Users/me/proj\n\n<INSTRUCTIONS>\nrules\n</INSTRUCTIONS>";
  assert.equal(isContextualUserText(text), true);
});

test("filters AGENTS.md instructions concatenated with registered context fragments", () => {
  // Newer runtimes join several hidden fragments into one user item, so the
  // opening and closing markers may belong to different fragment kinds.
  const prefix = "# AGENTS.md instructions\n\n<INSTRUCTIONS>\nrules\n</INSTRUCTIONS>\n\n";
  const suffixes = [
    "<environment_context>\n  <cwd>/Users/me/proj</cwd>\n</environment_context>",
    "<skill>\n<name>check-code</name>\n</skill>",
    "<goal_context>\nContinue the active goal.\n</goal_context>",
  ];

  for (const suffix of suffixes) {
    const text = prefix + suffix;
    assert.equal(isContextualUserText(text), true, suffix);
    assert.equal(visibleUserPromptText(text), "", suffix);
  }
});

test("filters a desktop opener that chains several injected fragments", () => {
  // Verbatim shape of the first user item Codex Desktop writes for a new
  // thread: the blob opens with one fragment kind and closes with another, so
  // a single start/end pair check leaves the whole preamble visible.
  const text = [
    "<recommended_plugins>",
    "Here is a list of plugins that are available but not installed.",
    "",
    "- Figma (figma@openai-curated-remote)",
    "- Slack (slack@openai-curated-remote)",
    "</recommended_plugins>",
    "# AGENTS.md instructions for /Users/me/proj",
    "",
    "<INSTRUCTIONS>",
    "## Goal Mode",
    "</INSTRUCTIONS>",
    "<environment_context>",
    "  <cwd>/Users/me/proj</cwd>",
    "</environment_context>",
  ].join("\n");

  assert.equal(isContextualUserText(text), true);
  assert.equal(visibleUserPromptText(text), "");
});

test("keeps the real request that trails an injected preamble", () => {
  const preamble = "<recommended_plugins>\n- Figma (figma@openai-curated-remote)\n</recommended_plugins>\n"
    + "<environment_context>\n  <cwd>/Users/me/proj</cwd>\n</environment_context>\n\n";

  assert.equal(isContextualUserText(`${preamble}check the 0.6.1 release`), false);
  assert.equal(visibleUserPromptText(`${preamble}check the 0.6.1 release`), "check the 0.6.1 release");
  assert.equal(
    visibleUserPromptText("<skill>\n<name>release-check</name>\n</skill>\nrun it for 0.6.1"),
    "run it for 0.6.1"
  );
});

test("leaves an unterminated reserved marker visible instead of swallowing the message", () => {
  // Only bounded fragments are runtime-owned. A prompt that merely opens with
  // reserved markup is still the user's text.
  const text = "<environment_context> is this tag reserved? I want to use it in my docs";
  assert.equal(isContextualUserText(text), false);
  assert.equal(visibleUserPromptText(text), text);
});

test("does not expose a request delimiter that appears inside hidden context", () => {
  const hidden = [
    "# AGENTS.md instructions",
    "",
    "<INSTRUCTIONS>",
    "private runtime instructions",
    "## My request for Codex:",
    "this line is still part of AGENTS.md",
    "</INSTRUCTIONS>",
  ].join("\n");
  const mixed = `${hidden}\n\n## My request for Codex:\nshow only this request`;

  assert.equal(isContextualUserText(hidden), true);
  assert.equal(visibleUserPromptText(hidden), "");
  assert.equal(visibleUserPromptText(mixed), "show only this request");
});

test("filters turn_aborted interrupt records", () => {
  const text = "<turn_aborted>\nThe user interrupted the previous turn on purpose. "
    + "Any running unified exec processes may still be running in the background. "
    + "If any tools/commands were aborted, they may have partially executed.\n</turn_aborted>";
  assert.equal(isContextualUserText(text), true);
  assert.equal(visibleUserPromptText(text), "");
});

test("filters the canonical Codex contextual-user marker registry", () => {
  const hidden = [
    "<environment_context>\n<cwd>/tmp</cwd>\n</environment_context>",
    "<skill>\n<name>check-code</name>\n<path>/tmp/SKILL.md</path>\n</skill>",
    "<user_shell_command>\n<command>pwd</command>\n</user_shell_command>",
    "<subagent_notification>{}</subagent_notification>",
    "<recommended_plugins>\n- example\n</recommended_plugins>",
    "<goal_context>\nContinue the active goal.\n</goal_context>",
    "<user_action>\n<context>review state</context>\n</user_action>",
  ];

  for (const text of hidden) {
    assert.equal(isContextualUserText(text), true, text);
    assert.equal(visibleUserPromptText(text), "", text);
  }
});

test("filters attribute-bearing internal context and matching external context", () => {
  const internal = "<codex_internal_context source=\"goal\">\nsecret state\n</codex_internal_context>";
  const singleQuoted = "<codex_internal_context source='extension_2'>\nsecret state\n</codex_internal_context>";
  const external = "<external_calendar>\nprivate context\n</external_calendar>";

  assert.equal(isContextualUserText(internal), true);
  assert.equal(isContextualUserText(singleQuoted), true);
  assert.equal(isContextualUserText(external), true);
  assert.equal(visibleUserPromptText(internal), "");

  assert.equal(isContextualUserText(
    "<codex_internal_context source=\"Goal\">human XML</codex_internal_context>"
  ), false);
  assert.equal(isContextualUserText("<external_one>human XML</external_two>"), false);
});

test("filters legacy runtime warnings without matching ordinary warning prose", () => {
  assert.equal(isContextualUserText(
    "Warning: The maximum number of unified exec processes you can keep open is 4. Close one."
  ), true);
  assert.equal(isContextualUserText(
    "Warning: apply_patch was requested via exec_command. Use the apply_patch tool instead of exec_command."
  ), true);
  assert.equal(isContextualUserText("Warning: this is ordinary user-authored prose."), false);
});

test("unwraps visible runtime triggers instead of dropping their prompts", () => {
  const heartbeat = [
    "<heartbeat>",
    "  <automation_id>abc</automation_id>",
    "  <instructions>Check &lt;main&gt; &amp; report back.</instructions>",
    "</heartbeat>",
  ].join("\n");
  const delegation = [
    "<codex_delegation>",
    "  <source_thread_id>thread-secret</source_thread_id>",
    "  <input>Fix the login flow.</input>",
    "</codex_delegation>",
  ].join("\n");

  assert.equal(isContextualUserText(heartbeat), false);
  assert.equal(visibleUserPromptText(heartbeat), "Check <main> & report back.");
  assert.equal(isContextualUserText(delegation), false);
  assert.equal(visibleUserPromptText(delegation), "Fix the login flow.");
  assert.equal(
    visibleUserPromptText("<hook_prompt hook_run_id=\"hook-1\">Retry &amp; summarize.</hook_prompt>"),
    "Retry & summarize."
  );
  assert.equal(visibleUserPromptText("<heartbeat>hello</heartbeat>"), "<heartbeat>hello</heartbeat>");
});

test("preserves task and handoff prompts that Codex records as visible user messages", () => {
  const task = "<task>Investigate the stalled turn.</task>";
  const handoff = "<handoff_context>Imported user request.</handoff_context>";

  assert.equal(isContextualUserText(task), false);
  assert.equal(visibleUserPromptText(task), task);
  assert.equal(isContextualUserText(handoff), false);
  assert.equal(visibleUserPromptText(handoff), handoff);
});

test("extracts the real request from review-guideline prompts", () => {
  const text = "## Code review guidelines:\n# Review Guidelines\n\nYou are acting as a reviewer...\n"
    + "## My request for Codex:\nPlease review my uncommitted changes";
  assert.equal(isContextualUserText(text), false);
  assert.equal(visibleUserPromptText(text), "Please review my uncommitted changes");
});

test("keeps a real review prompt when its trailing request delimiter is empty", () => {
  const text = "# Diff comments:\n\nFix the invalid dependency.\n\n## My request for Codex:\n";
  assert.equal(isContextualUserText(text), false);
  assert.equal(visibleUserPromptText(text), "# Diff comments:\n\nFix the invalid dependency.");
});

test("does not leak hidden runtime context with an empty trailing request delimiter", () => {
  const hiddenEnvironment = "<environment_context>\n<cwd>/private</cwd>\n</environment_context>\n\n## My request for Codex:\n";
  const hiddenAgents = "# AGENTS.md instructions\n\n<INSTRUCTIONS>\nprivate rules\n</INSTRUCTIONS>\n\n## My request for Codex:\n";

  assert.equal(visibleUserPromptText(hiddenEnvironment), "");
  assert.equal(visibleUserPromptText(hiddenAgents), "");
});

test("keeps image-only user messages alive as attachment-only items", () => {
  // Attachments ride inside the same item as their "<image>"/"</image>" text
  // frames; classifying the placeholder text as context would drop the item
  // (and the image with it) in the relay and history paths.
  assert.equal(isContextualUserText("<image>\n</image>"), false);
  assert.equal(visibleUserPromptText("<image>\n</image>"), "");
  assert.equal(isContextualUserText("<image>\n</image>\n<image>\n</image>"), false);
  assert.equal(visibleUserPromptText("<image>\n</image>\n<image>\n</image>").trim(), "");
});

test("hides bare image frame tokens from per-entry sanitization", () => {
  assert.equal(visibleUserPromptText("<image>"), "");
  assert.equal(visibleUserPromptText("</image>"), "");
});

test("strips only the runtime image opener with name/path metadata", () => {
  const opener = "<image name=[Image #1] path=\"/tmp/private screenshot.png\">";
  assert.equal(visibleUserPromptText(opener), "");
  assert.equal(visibleUserPromptText(`${opener}\n</image>`).trim(), "");
  assert.equal(
    visibleUserPromptText("<image src=\"logo.png\">human XML</image>"),
    "<image src=\"logo.png\">human XML</image>"
  );
});

test("strips image placeholders from caption text", () => {
  const text = "ora? puoi controllare tu se le prende?\n<image>\n</image>";
  assert.equal(isContextualUserText(text), false);
  assert.equal(visibleUserPromptText(text).trim(), "ora? puoi controllare tu se le prende?");
});

test("keeps unknown wrapped text visible instead of treating arbitrary XML as context", () => {
  const text = "<memory_update>\nThe assistant should remember the user's timezone.\n</memory_update>";
  assert.equal(isContextualUserText(text), false);
  assert.equal(visibleUserPromptText(text), text);
  assert.equal(isContextualUserText("<div>hello</div>"), false);
  assert.equal(visibleUserPromptText("<request>fix login</request>"), "<request>fix login</request>");
});

test("keeps ordinary user prompts untouched", () => {
  assert.equal(isContextualUserText("fix them and exclude them"), false);
  assert.equal(visibleUserPromptText("fix them and exclude them"), "fix them and exclude them");
  // A prompt that merely mentions a marker must not be swallowed.
  assert.equal(isContextualUserText("what does <turn_aborted> mean?"), false);
  // Prose followed by pasted markup opens as free text, so it stays visible.
  assert.equal(isContextualUserText("look at this snippet:\n<div>hello</div>"), false);
  // Markup followed by a trailing question stays visible too.
  assert.equal(isContextualUserText("<div>hello</div>\nwhy does this overflow?"), false);
});

test("sanitizes mixed user entries without dropping prompts or attachments", () => {
  const entries = [
    { type: "input_text", text: "<environment_context>secret</environment_context>" },
    { type: "input_text", text: "Please inspect this image" },
    { type: "input_text", text: "<image name=[Image #1] path=\"/tmp/private.png\">" },
    { type: "input_image", image_url: "data:image/png;base64,AAAA" },
    { type: "input_text", text: "</image>" },
  ];

  assert.deepEqual(sanitizeUserInputEntries(entries), [
    { type: "input_text", text: "Please inspect this image" },
    { type: "input_image", image_url: "data:image/png;base64,AAAA" },
  ]);
});

test("drops fully contextual user items but preserves attachment-only items", () => {
  const hidden = {
    id: "hidden",
    type: "user_message",
    content: [{ type: "input_text", text: "<goal_context>secret</goal_context>" }],
  };
  const attachment = {
    id: "image",
    type: "user_message",
    content: [
      { type: "input_text", text: "<image>" },
      { type: "input_image", image_url: "data:image/png;base64,AAAA" },
      { type: "input_text", text: "</image>" },
    ],
  };

  assert.equal(sanitizeUserRoleItem(hidden), null);
  assert.deepEqual(sanitizeUserRoleItem(attachment)?.content, [
    { type: "input_image", image_url: "data:image/png;base64,AAAA" },
  ]);
});

test("turn-state probe detection matches the marker and the legacy probe shape only", () => {
  const probe = (params) => isThreadTurnStateProbeRequest({ method: "thread/turns/list", params });
  assert.equal(probe({ threadId: "t", remodexTurnStateOnly: true }), true);
  assert.equal(probe({ threadId: "t", limit: 8, sortDirection: "desc" }), true);
  assert.equal(probe({ threadId: "t", limit: 8 }), true);
  assert.equal(probe({ threadId: "t", limit: 5, sortDirection: "desc" }), false);
  assert.equal(probe({ threadId: "t", limit: 8, sortDirection: "asc" }), false);
  assert.equal(probe({ threadId: "t", limit: 8, sortDirection: "desc", cursor: "page-2" }), false);
  assert.equal(probe({ threadId: "t", limit: 8, remodexRequireCanonical: true }), false);
  // History pages and other methods never look like the probe.
  assert.equal(
    isThreadTurnStateProbeRequest({ method: "thread/read", params: { threadId: "t", limit: 8 } }),
    false
  );
});

test("filters an AGENTS.md header carrying several instruction blocks", () => {
  // Nested AGENTS.md files chain one <INSTRUCTIONS> block per file under a
  // single header; stopping at the first close leaked the rest into the bubble.
  const preamble = [
    "# AGENTS.md instructions for /Users/me/proj",
    "",
    "<INSTRUCTIONS>",
    "root rules",
    "</INSTRUCTIONS>",
    "<INSTRUCTIONS>",
    "nested package rules",
    "</INSTRUCTIONS>",
  ].join("\n");

  assert.equal(isContextualUserText(preamble), true);
  assert.equal(visibleUserPromptText(preamble), "");
  assert.equal(visibleUserPromptText(`${preamble}\n\nship 0.6.1`), "ship 0.6.1");
});

// The Codex bus moved from the temp directory into the Codex home directory,
// and both locations are still in the wild.
function withIsolatedIpcEnvironment(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-ipc-env-"));
  const codexHome = path.join(root, "codex-home");
  const tempDir = path.join(root, "tmp");
  fs.mkdirSync(codexHome, { recursive: true });
  fs.mkdirSync(tempDir, { recursive: true });

  const previous = { CODEX_HOME: process.env.CODEX_HOME, TMPDIR: process.env.TMPDIR };
  process.env.CODEX_HOME = codexHome;
  process.env.TMPDIR = tempDir;
  t.after(() => {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
    fs.rmSync(root, { recursive: true, force: true });
  });

  const [codexHomeSocket, legacySocket] = resolveIpcSocketPathCandidates();
  return { codexHomeSocket, legacySocket };
}

async function listenOnSocket(t, socketPath) {
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });
  const server = net.createServer();
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
}

test("resolves the Codex home socket before the legacy temp socket", { skip: process.platform === "win32" }, (t) => {
  const { codexHomeSocket, legacySocket } = withIsolatedIpcEnvironment(t);

  assert.equal(codexHomeSocket, path.join(process.env.CODEX_HOME, "ipc", "ipc.sock"));
  assert.equal(legacySocket, path.join(os.tmpdir(), "codex-ipc", `ipc-${process.getuid()}.sock`));
  // With no bus running, the fallback router listens on the current location so
  // a desktop starting later finds it.
  assert.equal(resolveDefaultIpcSocketPath(), codexHomeSocket);
});

test("joins the legacy temp socket when only that bus is listening", { skip: process.platform === "win32" }, async (t) => {
  const { legacySocket } = withIsolatedIpcEnvironment(t);

  await listenOnSocket(t, legacySocket);

  assert.equal(resolveDefaultIpcSocketPath(), legacySocket);
});

test("prefers the Codex home bus when both sockets are listening", { skip: process.platform === "win32" }, async (t) => {
  const { codexHomeSocket, legacySocket } = withIsolatedIpcEnvironment(t);

  await listenOnSocket(t, legacySocket);
  await listenOnSocket(t, codexHomeSocket);

  assert.equal(resolveDefaultIpcSocketPath(), codexHomeSocket);
});
