// FILE: project-registry-integration.test.js
// Purpose: Verifies project/knownProjects reads the durable file-backed project registry.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createProjectRegistry } = require("../src/project-registry");
const {
  projectKnownProjects,
  projectRememberKnownProject,
} = require("../src/project-handler");

test("file registry round-trips through projectKnownProjects", async () => {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-known-projects-"));
  const storagePath = path.join(homeDir, "remodex", "known-projects.json");
  const projectRegistry = createProjectRegistry({ storagePath, homeDir });
  const projectDir = path.join(homeDir, "workspace", "demo-repo");
  fs.mkdirSync(projectDir, { recursive: true });

  projectRegistry.rememberProjectPath(projectDir, {
    source: "codex-thread-list",
    provider: "codex",
    label: "Demo Repo",
  });

  const listed = await projectKnownProjects({ projectRegistry });
  assert.equal(listed.projects.length, 1);
  assert.equal(listed.projects[0].path, fs.realpathSync(projectDir));
  assert.equal(listed.projects[0].label, "Demo Repo");
  assert.deepEqual(listed.projects[0].sources, ["codex-thread-list"]);
  assert.deepEqual(listed.projects[0].providerHints, ["codex"]);
});

test("projectRememberKnownProject writes through file registry", async () => {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-known-projects-"));
  const storagePath = path.join(homeDir, "remodex", "known-projects.json");
  const projectRegistry = createProjectRegistry({ storagePath, homeDir });
  const projectDir = path.join(homeDir, "workspace", "picked-repo");
  fs.mkdirSync(projectDir, { recursive: true });

  const remembered = await projectRememberKnownProject(
    { path: projectDir, name: "Picked", provider: "opencode" },
    { homeDir, projectRegistry },
  );

  assert.equal(remembered.project.path, fs.realpathSync(projectDir));
  assert.equal(remembered.project.label, "Picked");
  assert.equal(remembered.project.source, "ios-picker");

  const listed = await projectKnownProjects({ projectRegistry });
  assert.equal(listed.projects.length, 1);
  assert.equal(listed.projects[0].path, fs.realpathSync(projectDir));
  assert.ok(fs.existsSync(storagePath));
  assert.equal(fs.statSync(storagePath).mode & 0o777, 0o600);
});