// FILE: project-known-projects.test.js
// Purpose: Verifies project/knownProjects and project/rememberKnownProject RPCs.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  projectKnownProjects,
  projectRememberKnownProject,
  createKnownProjectsRegistry,
} = require("../src/project-handler");

test("rememberKnownProject and knownProjects round-trip", async () => {
  const homeDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-known-projects-"));
  const registry = createKnownProjectsRegistry();
  const projectDir = fs.mkdtempSync(path.join(homeDir, "project-"));

  const remembered = await projectRememberKnownProject(
    { path: projectDir, name: "Docs", provider: "opencode" },
    { homeDir, knownProjectsRegistry: registry },
  );

  assert.equal(remembered.project.name, "Docs");
  assert.equal(remembered.project.provider, "opencode");

  const listed = await projectKnownProjects({ knownProjectsRegistry: registry });
  assert.equal(listed.projects.length, 1);
  assert.equal(listed.projects[0].path, remembered.project.path);
});