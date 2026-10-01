const assert = require("node:assert/strict");
const test = require("node:test");

const {
  normalizeThreadProjectClassification,
} = require("../src/thread-project-classification");

test("maps canonical projectless legacy home threads to a generated mobile Chats root", () => {
  const createdDirectories = [];
  const thread = {
    id: "legacy-mobile-chat",
    cwd: "/Users/me/",
    current_working_directory: "/Users/me",
    projectId: null,
    createdAt: 1_789_714_679,
    metadata: { cwd: "/Users/me", retained: "value" },
  };

  normalizeThreadProjectClassification(thread, {
    homeDir: "/Users/me",
    fsModule: { mkdirSync: (directory, options) => createdDirectories.push([directory, options]) },
  });

  const expected = "/Users/me/Documents/Codex/2026-09-18/legacy-legacy-m";
  assert.equal(thread.cwd, expected);
  assert.equal(thread.current_working_directory, expected);
  assert.equal(thread.metadata.cwd, expected);
  assert.equal(thread.metadata.retained, "value");
  assert.deepEqual(createdDirectories, [[expected, { recursive: true }]]);
});

test("keeps explicit projects and non-home working directories intact", () => {
  const assignedHome = { cwd: "/Users/me", projectId: "project-1" };
  const unassignedRepo = { cwd: "/Users/me/work/app", projectId: null };

  normalizeThreadProjectClassification(assignedHome, { homeDir: "/Users/me" });
  normalizeThreadProjectClassification(unassignedRepo, { homeDir: "/Users/me" });

  assert.equal(assignedHome.cwd, "/Users/me");
  assert.equal(unassignedRepo.cwd, "/Users/me/work/app");
});

test("keeps legacy server rows without canonical project data intact", () => {
  const thread = { cwd: "/Users/me" };

  normalizeThreadProjectClassification(thread, { homeDir: "/Users/me" });

  assert.equal(thread.cwd, "/Users/me");
});

test("uses the latest rollout cwd after Desktop moves a chat", () => {
  const thread = { cwd: "/Users/me/Documents/Codex/old-chat", projectId: null };

  normalizeThreadProjectClassification(thread, {
    homeDir: "/Users/me",
    latestCwd: "/Users/me/work/project",
  });

  assert.equal(thread.cwd, "/Users/me/work/project");
});
