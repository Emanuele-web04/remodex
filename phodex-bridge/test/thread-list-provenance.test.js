const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  createThreadListProvenanceEnricher,
} = require("../src/thread-list-provenance");

function writeRollout(directory, name, sessionMeta) {
  const filePath = path.join(directory, name);
  fs.writeFileSync(filePath, `${[
    JSON.stringify({ timestamp: "2026-07-25T17:06:51.387Z", type: "session_meta", payload: sessionMeta }),
    JSON.stringify({ type: "turn_context", payload: { cwd: sessionMeta.cwd } }),
  ].join("\n")}\n`);
  return filePath;
}

test("fills fork and automation provenance app-server leaves null on thread rows", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-thread-provenance-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const originPath = writeRollout(directory, "rollout-origin.jsonl", {
    id: "thread-origin",
    cwd: "/repo",
    thread_source: "user",
  });
  const forkPath = writeRollout(directory, "rollout-fork.jsonl", {
    id: "thread-fork",
    cwd: "/repo",
    forked_from_id: "thread-origin",
    thread_source: "pull_request_fix_automation",
  });

  const enricher = createThreadListProvenanceEnricher();
  const envelope = {
    result: {
      data: [
        { id: "thread-origin", name: "Add Auto approval mode", path: originPath, forkedFromId: null, threadSource: null },
        { id: "thread-fork", name: "Add Auto approval mode", path: forkPath, forkedFromId: null, threadSource: null },
      ],
    },
  };

  enricher.enrichResponse("thread/list", envelope);

  const [origin, fork] = envelope.result.data;
  assert.equal(origin.forkedFromId, null);
  assert.equal(origin.threadSource, "user");
  assert.equal(fork.forkedFromId, "thread-origin");
  assert.equal(fork.threadSource, "pull_request_fix_automation");
});

test("keeps resolved provenance, reads each rollout once, and survives unreadable files", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-thread-provenance-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const forkPath = writeRollout(directory, "rollout-fork.jsonl", {
    id: "thread-fork",
    cwd: "/repo",
    forked_from_id: "thread-origin",
    thread_source: "pull_request_fix_automation",
  });

  let opens = 0;
  const fsModule = {
    ...fs,
    openSync: (...args) => {
      opens += 1;
      return fs.openSync(...args);
    },
  };
  const enricher = createThreadListProvenanceEnricher({ fsModule });

  // Rows app-server already resolved are left untouched and never hit the disk.
  const resolved = { id: "thread-fork", path: forkPath, forkedFromId: "other-origin", threadSource: "user" };
  enricher.attachToThread(resolved);
  assert.equal(resolved.forkedFromId, "other-origin");
  assert.equal(opens, 0);

  const first = { id: "thread-fork", path: forkPath, forkedFromId: null, threadSource: null };
  const second = { id: "thread-fork", path: forkPath, forkedFromId: null, threadSource: null };
  enricher.attachToThread(first);
  enricher.attachToThread(second);
  assert.equal(second.forkedFromId, "thread-origin");
  assert.equal(opens, 1, "session_meta is immutable, so one head read per thread is enough");

  const missingPath = path.join(directory, "pending.jsonl");
  const missing = { id: "thread-pending", path: missingPath, forkedFromId: null };
  enricher.attachToThread(missing);
  assert.equal(missing.forkedFromId, null);

  // A rollout that was unreadable (still being written, rotated) must be retried:
  // caching that miss would strand a fresh fork without provenance until restart.
  writeRollout(directory, "pending.jsonl", {
    id: "thread-pending",
    cwd: "/repo",
    forked_from_id: "thread-origin",
    thread_source: "pull_request_fix_automation",
  });
  const retried = { id: "thread-pending", path: missingPath, forkedFromId: null, threadSource: null };
  enricher.attachToThread(retried);
  assert.equal(retried.forkedFromId, "thread-origin");
  assert.equal(retried.threadSource, "pull_request_fix_automation");
});

test("bounds the provenance cache and enriches single-thread reads", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-thread-provenance-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const enricher = createThreadListProvenanceEnricher({ maxEntries: 2 });
  for (let index = 0; index < 5; index += 1) {
    const filePath = writeRollout(directory, `rollout-${index}.jsonl`, {
      id: `thread-${index}`,
      cwd: "/repo",
      thread_source: "automation",
    });
    enricher.attachToThread({ id: `thread-${index}`, path: filePath, forkedFromId: null, threadSource: null });
  }
  assert.equal(enricher.cacheSize(), 2);

  const readPath = writeRollout(directory, "rollout-read.jsonl", {
    id: "thread-read",
    cwd: "/repo",
    forked_from_id: "thread-origin",
    thread_source: "pull_request_fix_automation",
  });
  const envelope = {
    result: { thread: { id: "thread-read", path: readPath, forkedFromId: null, threadSource: null } },
  };
  enricher.enrichResponse("thread/read", envelope);
  assert.equal(envelope.result.thread.forkedFromId, "thread-origin");
  assert.equal(envelope.result.thread.threadSource, "pull_request_fix_automation");
});
