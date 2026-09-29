// FILE: push-notification-completion-dedupe.test.js
// Purpose: Verifies the production bound and persistence of completion receipts.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, node:fs, node:os, node:path

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const {
  createPushNotificationCompletionDedupe,
} = require("../src/push-notification-completion-dedupe");

test("successful completion identities persist across restarts within a fixed bound", (t) => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-completion-dedupe-"));
  const statePath = path.join(tempDir, "state.json");
  t.after(() => fs.rmSync(tempDir, { recursive: true, force: true }));
  const first = createPushNotificationCompletionDedupe({ statePath });

  for (let index = 0; index <= 1_000; index += 1) {
    first.commitNotification(`completion-${index}`);
  }
  assert.equal(first.hasSuccessfulNotification("completion-0"), false);

  const restarted = createPushNotificationCompletionDedupe({ statePath });
  assert.equal(restarted.hasSuccessfulNotification("completion-0"), false);
  assert.equal(restarted.hasSuccessfulNotification("completion-1"), true);
  assert.equal(restarted.hasSuccessfulNotification("completion-1000"), true);
});
