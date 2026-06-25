// FILE: opencode-structured-skills.test.js
// Purpose: Verifies structured skill/mention turn input maps to OpenCode session.prompt parts.
//          (PR14/RP-SKILL-3: bridge now also includes skills[] conditionally in prompt payload for
//          when flag+SDK support; verification showed no, flag stays false + documented.)
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-models, ../src/opencode-provider, ../src/provider-capabilities

const test = require("node:test");
const assert = require("node:assert/strict");
const os = require("os");
const { pathToFileURL } = require("url");
const path = require("path");

const TEST_PROJECT = path.join(os.homedir(), ".remodex-test-project");
const {
  buildPromptFromTurnInput,
  skillItemToPromptPart,
  mentionItemToPromptPart,
} = require("../src/opencode-models");
const { createOpenCodeProvider } = require("../src/opencode-provider");
const {
  CAPABILITIES,
  CODEX_CAPABILITIES,
  OPENCODE_CAPABILITIES,
  resolveModelCapabilities,
} = require("../src/provider-capabilities");

test("CAPABILITIES includes skill and attachment flags", () => {
  assert.equal(CAPABILITIES.length, 20);
  assert.equal(CAPABILITIES[11], "supportsSlashCommandExecute");
  assert.equal(CAPABILITIES[14], "supportsStructuredSkillInput");
  assert.equal(CAPABILITIES[15], "supportsSkillFileInjection");
  assert.equal(CAPABILITIES[16], "supportsImageAttachments");
});

test("Codex enables structured skill input; OpenCode defaults false (RP-SKILL-3 verification: no SDK skills[] support; gated)", () => {
  assert.equal(CODEX_CAPABILITIES.supportsStructuredSkillInput, true);
  assert.equal(OPENCODE_CAPABILITIES.supportsStructuredSkillInput, false);
  assert.equal(resolveModelCapabilities("opencode", {}).supportsStructuredSkillInput, false);
});

test("skill with path maps to file part for session.prompt", () => {
  const skillPath = "/tmp/project/.agents/skills/review/SKILL.md";
  const part = skillItemToPromptPart({
    type: "skill",
    id: "review",
    name: "review",
    path: skillPath,
  });

  assert.equal(part.type, "file");
  assert.equal(part.mime, "text/markdown");
  assert.equal(part.filename, "review");
  assert.equal(part.url, pathToFileURL(skillPath).href);
});

test("skill without path maps to $name text fallback", () => {
  const part = skillItemToPromptPart({ type: "skill", id: "deploy", name: "deploy" });
  assert.deepEqual(part, { type: "text", text: "$deploy" });
});

test("mention with path maps to file part", () => {
  const mentionPath = "/tmp/project/src/auth.ts";
  const part = mentionItemToPromptPart({
    type: "mention",
    name: "auth.ts",
    path: mentionPath,
  });

  assert.equal(part.type, "file");
  assert.equal(part.filename, "auth.ts");
  assert.equal(part.url, pathToFileURL(mentionPath).href);
});

test("buildPromptFromTurnInput preserves user text and attaches skill files", () => {
  const skillPath = path.join("/tmp/project", ".agents/skills/review/SKILL.md");
  const { inputText, prompt, parts, skills } = buildPromptFromTurnInput([
    { type: "text", text: "Please review this change" },
    { type: "skill", id: "review", name: "review", path: skillPath },
  ]);

  assert.equal(inputText, "Please review this change");
  assert.equal(prompt, "Please review this change");
  assert.equal(parts.length, 2);
  assert.equal(parts[0].type, "text");
  assert.equal(parts[0].text, "Please review this change");
  assert.equal(parts[1].type, "file");
  assert.equal(parts[1].filename, "review");
  assert.equal(parts[1].url, pathToFileURL(skillPath).href);
  assert.ok(Array.isArray(skills) && skills.length === 1 && skills[0].id === "review"); // from updated buildPromptFromTurnInput for RP-SKILL-3
});

test("skill-only structured input still produces prompt parts", () => {
  const skillPath = "/tmp/project/.agents/skills/plan/SKILL.md";
  const { prompt, parts } = buildPromptFromTurnInput([
    { type: "skill", id: "plan", name: "plan", path: skillPath },
  ]);

  assert.equal(prompt, "");
  assert.equal(parts.length, 2);
  assert.equal(parts[0].type, "text");
  assert.equal(parts[1].type, "file");
});

test("turn/start forwards structured parts to OpenCode session.prompt", async () => {
  const prompts = [];
  const provider = createOpenCodeProvider({
    sendApplicationMessage: () => {},
    serverFactory: () => ({
      get baseUrl() {
        return "http://127.0.0.1:4291";
      },
      get isRunning() {
        return true;
      },
      start: async () => {},
      stop: async () => {},
    }),
    clientFactory: async () => ({
      listModels: async () => [],
      listAgents: async () => [],
      createSession: async () => "ses_skill_test",
      getSession: async () => ({}),
      prompt: async (payload) => {
        prompts.push(payload);
      },

      abort: async () => {},
      fork: async () => "ses_fork",
      getMessages: async () => [],
      replyToPermission: async () => {},
      subscribeToEvents: () => () => {},
    }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { cwd: TEST_PROJECT },
  });

  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: {
      threadId: start.thread.id,
      input: [
        { type: "text", text: "Run the skill" },
        {
          type: "skill",
          id: "review",
          name: "review",
          path: "/tmp/project/.agents/skills/review/SKILL.md",
        },
      ],
    },
  });

  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(prompts.length, 1);
  assert.ok(Array.isArray(prompts[0].parts));
  assert.equal(prompts[0].parts.length, 2);
  assert.equal(prompts[0].parts[0].type, "text");
  assert.equal(prompts[0].parts[1].type, "file");
  assert.equal(prompts[0].parts[1].filename, "review");
  // RP-SKILL-3: verify conditional skills[] included in (wrapped) prompt payload for structured input
  assert.ok(Array.isArray(prompts[0].skills));
  assert.equal(prompts[0].skills.length, 1);
  assert.equal(prompts[0].skills[0].id, "review");
  assert.equal(prompts[0].skills[0].path, "/tmp/project/.agents/skills/review/SKILL.md");
});