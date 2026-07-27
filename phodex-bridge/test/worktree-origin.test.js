const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const { createWorktreeOriginEnricher } = require("../src/worktree-origin");

function makeCodexHomeWithWorktree({ token, repoName, checkoutRoot, worktreeName = repoName }) {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const worktreeRoot = path.join(codexHome, "worktrees", token, repoName);
  fs.mkdirSync(worktreeRoot, { recursive: true });
  fs.writeFileSync(
    path.join(worktreeRoot, ".git"),
    `gitdir: ${path.join(checkoutRoot, ".git", "worktrees", worktreeName)}\n`
  );
  return { codexHome, worktreeRoot };
}

test("groups managed worktree rows under the checkout that owns them", (t) => {
  const checkoutRoot = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkout-"));
  const { codexHome, worktreeRoot } = makeCodexHomeWithWorktree({
    token: "22f1",
    repoName: "synara",
    checkoutRoot,
    worktreeName: "synara6",
  });
  t.after(() => {
    fs.rmSync(codexHome, { recursive: true, force: true });
    fs.rmSync(checkoutRoot, { recursive: true, force: true });
  });

  const enricher = createWorktreeOriginEnricher({ codexHome });
  const envelope = {
    result: {
      data: [
        { id: "thread-local", cwd: checkoutRoot },
        { id: "thread-worktree", cwd: worktreeRoot },
      ],
    },
  };

  enricher.enrichResponse("thread/list", envelope);

  const [local, worktree] = envelope.result.data;
  assert.equal(local.worktreeOriginPath, undefined);
  assert.equal(worktree.worktreeOriginPath, checkoutRoot);
});

test("mirrors package-scoped worktree chats onto the matching checkout subpath", (t) => {
  const checkoutRoot = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkout-"));
  fs.mkdirSync(path.join(checkoutRoot, "packages", "app"), { recursive: true });
  const { codexHome, worktreeRoot } = makeCodexHomeWithWorktree({
    token: "45b5",
    repoName: "synara",
    checkoutRoot,
  });
  t.after(() => {
    fs.rmSync(codexHome, { recursive: true, force: true });
    fs.rmSync(checkoutRoot, { recursive: true, force: true });
  });

  const enricher = createWorktreeOriginEnricher({ codexHome });
  const envelope = {
    result: {
      thread: { id: "thread-scoped", cwd: path.join(worktreeRoot, "packages", "app") },
    },
  };

  enricher.enrichResponse("thread/read", envelope);

  assert.equal(envelope.result.thread.worktreeOriginPath, path.join(checkoutRoot, "packages", "app"));
});

test("falls back to the checkout root when the scoped subpath is missing there", (t) => {
  const checkoutRoot = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkout-"));
  const { codexHome, worktreeRoot } = makeCodexHomeWithWorktree({
    token: "58c8",
    repoName: "synara",
    checkoutRoot,
  });
  t.after(() => {
    fs.rmSync(codexHome, { recursive: true, force: true });
    fs.rmSync(checkoutRoot, { recursive: true, force: true });
  });

  const enricher = createWorktreeOriginEnricher({ codexHome });
  const thread = { id: "thread-scoped", cwd: path.join(worktreeRoot, "packages", "app") };

  enricher.attachToThread(thread);

  assert.equal(thread.worktreeOriginPath, checkoutRoot);
});

test("leaves rows alone outside managed worktrees, without an owner, or already resolved", (t) => {
  const checkoutRoot = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkout-"));
  const { codexHome, worktreeRoot } = makeCodexHomeWithWorktree({
    token: "606d",
    repoName: "synara",
    checkoutRoot,
  });
  const orphanWorktreeRoot = path.join(codexHome, "worktrees", "64e5", "synara");
  fs.mkdirSync(orphanWorktreeRoot, { recursive: true });
  t.after(() => {
    fs.rmSync(codexHome, { recursive: true, force: true });
    fs.rmSync(checkoutRoot, { recursive: true, force: true });
  });

  const enricher = createWorktreeOriginEnricher({ codexHome });
  const rows = [
    { id: "no-cwd" },
    { id: "outside", cwd: checkoutRoot },
    { id: "worktrees-root", cwd: path.join(codexHome, "worktrees") },
    { id: "orphan", cwd: orphanWorktreeRoot },
    { id: "resolved", cwd: worktreeRoot, worktreeOriginPath: "/already/known" },
  ];

  for (const row of rows) {
    enricher.attachToThread(row);
  }

  assert.deepEqual(rows.map((row) => row.worktreeOriginPath), [
    undefined,
    undefined,
    undefined,
    undefined,
    "/already/known",
  ]);
});

test("reads each managed worktree once across repeated list refreshes", (t) => {
  const checkoutRoot = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkout-"));
  const { codexHome, worktreeRoot } = makeCodexHomeWithWorktree({
    token: "2052",
    repoName: "Remodex",
    checkoutRoot,
  });
  t.after(() => {
    fs.rmSync(codexHome, { recursive: true, force: true });
    fs.rmSync(checkoutRoot, { recursive: true, force: true });
  });

  let readCount = 0;
  const fsModule = {
    ...fs,
    readFileSync(filePath, encoding) {
      if (String(filePath).endsWith(path.join(worktreeRoot, ".git"))) {
        readCount += 1;
      }
      return fs.readFileSync(filePath, encoding);
    },
  };

  const enricher = createWorktreeOriginEnricher({ codexHome, fsModule });
  for (let refresh = 0; refresh < 3; refresh += 1) {
    const thread = { id: "thread-worktree", cwd: worktreeRoot };
    enricher.attachToThread(thread);
    assert.equal(thread.worktreeOriginPath, checkoutRoot);
  }

  assert.equal(readCount, 1);
  assert.equal(enricher.cacheSize(), 1);
});

test("evicts the oldest managed worktree once the cache is full", (t) => {
  const checkoutRoot = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-checkout-"));
  const { codexHome } = makeCodexHomeWithWorktree({
    token: "337d",
    repoName: "synara",
    checkoutRoot,
  });
  t.after(() => {
    fs.rmSync(codexHome, { recursive: true, force: true });
    fs.rmSync(checkoutRoot, { recursive: true, force: true });
  });

  const enricher = createWorktreeOriginEnricher({ codexHome, maxEntries: 2 });
  for (const token of ["337d", "45b5", "52f5"]) {
    enricher.attachToThread({ id: token, cwd: path.join(codexHome, "worktrees", token, "synara") });
  }

  assert.equal(enricher.cacheSize(), 2);
});
