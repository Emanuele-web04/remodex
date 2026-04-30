// FILE: bridge.test.js
// Purpose: Verifies relay watchdog helpers used to recover from stale sleep/wake sockets.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/bridge

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
  buildHeartbeatBridgeStatus,
  createMacOSBridgeWakeAssertion,
  hasRelayConnectionGoneStale,
  persistBridgePreferences,
  sanitizeLiveGeneratedImageMessageForRelay,
  sanitizeThreadHistoryImagesForRelay,
} = require("../src/bridge");

test("hasRelayConnectionGoneStale returns true once the relay silence crosses the timeout", () => {
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
      now: 71_000,
      staleAfterMs: 70_000,
    }),
    true
  );
});

test("hasRelayConnectionGoneStale returns false for fresh or missing activity timestamps", () => {
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
      now: 70_999,
      staleAfterMs: 70_000,
    }),
    false
  );
  assert.equal(hasRelayConnectionGoneStale(Number.NaN), false);
});

test("hasRelayConnectionGoneStale default threshold tolerates a full quiet minute", () => {
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
      now: 60_999,
    }),
    false
  );
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
      now: 71_000,
    }),
    true
  );
});

test("buildHeartbeatBridgeStatus downgrades stale connected snapshots", () => {
  assert.deepEqual(
    buildHeartbeatBridgeStatus(
      {
        state: "running",
        connectionStatus: "connected",
        pid: 123,
        lastError: "",
      },
      1_000,
      {
        now: 26_500,
        staleAfterMs: 25_000,
        staleMessage: "Relay heartbeat stalled; reconnect pending.",
      }
    ),
    {
      state: "running",
      connectionStatus: "disconnected",
      pid: 123,
      lastError: "Relay heartbeat stalled; reconnect pending.",
    }
  );
});

test("buildHeartbeatBridgeStatus leaves fresh or already-disconnected snapshots unchanged", () => {
  const freshStatus = {
    state: "running",
    connectionStatus: "connected",
    pid: 123,
    lastError: "",
  };
  assert.deepEqual(
    buildHeartbeatBridgeStatus(freshStatus, 1_000, {
      now: 20_000,
      staleAfterMs: 25_000,
    }),
    freshStatus
  );

  const disconnectedStatus = {
    state: "running",
    connectionStatus: "disconnected",
    pid: 123,
    lastError: "",
  };
  assert.deepEqual(buildHeartbeatBridgeStatus(disconnectedStatus, 1_000), disconnectedStatus);
});

test("sanitizeThreadHistoryImagesForRelay replaces inline history images with lightweight references", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-read",
    result: {
      thread: {
        id: "thread-images",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-user",
                type: "user_message",
                content: [
                  {
                    type: "input_text",
                    text: "Look at this screenshot",
                  },
                  {
                    type: "image",
                    image_url: "data:image/png;base64,AAAA",
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const content = sanitized.result.thread.turns[0].items[0].content;

  assert.deepEqual(content[0], {
    type: "input_text",
    text: "Look at this screenshot",
  });
  assert.deepEqual(content[1], {
    type: "image",
    url: "remodex://history-image-elided",
  });
});

test("sanitizeThreadHistoryImagesForRelay replaces input_image history data URLs", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-input-image",
    result: {
      thread: {
        id: "thread-input-image",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-user",
                type: "user_message",
                content: [
                  {
                    type: "input_image",
                    image_url: {
                      url: "data:image/png;base64,AAAA",
                    },
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const content = sanitized.result.thread.turns[0].items[0].content;

  assert.deepEqual(content[0], {
    type: "input_image",
    url: "remodex://history-image-elided",
  });
});

test("sanitizeThreadHistoryImagesForRelay annotates generated image calls with local paths", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-generated-image",
    result: {
      thread: {
        id: "thread-generated-image",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "ig_123",
                type: "image_generation_call",
                status: "generating",
                result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(
    item.saved_path,
    path.join(os.homedir(), ".codex", "generated_images", "thread-generated-image", "ig_123.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay annotates image generation items with local paths", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-image-generation",
    result: {
      thread: {
        id: "thread-image-generation",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "ig_generation",
                type: "image_generation",
                result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(
    item.saved_path,
    path.join(os.homedir(), ".codex", "generated_images", "thread-image-generation", "ig_generation.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay annotates image end history with local paths", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-generated-image-end",
    result: {
      thread: {
        id: "thread-generated-image-end",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "turn-1",
                type: "image_generation_end",
                call_id: "ig_end",
                result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(
    item.saved_path,
    path.join(os.homedir(), ".codex", "generated_images", "thread-generated-image-end", "ig_end.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay uses CODEX_HOME for generated image fallbacks", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const rawMessage = JSON.stringify({
    id: "req-thread-generated-image-codex-home",
    result: {
      thread: {
        id: "thread-generated-image-home",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "ig_home",
                type: "imageView",
                result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(
    item.saved_path,
    path.join(codexHome, "generated_images", "thread-generated-image-home", "ig_home.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay preserves generated image file_path without saved_path", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-generated-image-file-path",
    result: {
      thread: {
        id: "thread-generated-image",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "ig_123",
                type: "image_generation_call",
                file_path: "/tmp/real-generated-image.png",
                status: "completed",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(item.file_path, "/tmp/real-generated-image.png");
  assert.equal(item.saved_path, undefined);
});

test("sanitizeLiveGeneratedImageMessageForRelay annotates completed image items", () => {
  const rawMessage = JSON.stringify({
    method: "item/completed",
    params: {
      threadId: "thread-live-image",
      turnId: "turn-1",
      item: {
        id: "ig_live",
        type: "image_generation_call",
        result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
      },
    },
  });

  const sanitized = JSON.parse(sanitizeLiveGeneratedImageMessageForRelay(rawMessage));
  const item = sanitized.params.item;

  assert.equal(
    item.saved_path,
    path.join(os.homedir(), ".codex", "generated_images", "thread-live-image", "ig_live.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeLiveGeneratedImageMessageForRelay elides nested completed image items", () => {
  const rawMessage = JSON.stringify({
    method: "item/completed",
    params: {
      threadId: "thread-live-nested-image",
      turnId: "turn-1",
      event: {
        type: "item_completed",
        item: {
          id: "ig_nested",
          type: "image_generation",
          result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
        },
      },
    },
  });

  const sanitized = JSON.parse(sanitizeLiveGeneratedImageMessageForRelay(rawMessage));
  const item = sanitized.params.event.item;

  assert.equal(
    item.saved_path,
    path.join(os.homedir(), ".codex", "generated_images", "thread-live-nested-image", "ig_nested.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeLiveGeneratedImageMessageForRelay uses call id for image end events", () => {
  const rawMessage = JSON.stringify({
    method: "image_generation_end",
    params: {
      type: "image_generation_end",
      threadId: "thread-live-event",
      id: "turn-1",
      call_id: "ig_event",
      result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
    },
  });

  const sanitized = JSON.parse(sanitizeLiveGeneratedImageMessageForRelay(rawMessage));

  assert.equal(
    sanitized.params.saved_path,
    path.join(os.homedir(), ".codex", "generated_images", "thread-live-event", "ig_event.png")
  );
  assert.equal(sanitized.params.result, undefined);
  assert.equal(sanitized.params.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay leaves unrelated RPC payloads unchanged", () => {
  const rawMessage = JSON.stringify({
    id: "req-other",
    result: {
      ok: true,
    },
  });

  assert.equal(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "turn/start"),
    rawMessage
  );
});

test("createMacOSBridgeWakeAssertion spawns a macOS caffeinate idle-sleep assertion tied to the bridge pid", () => {
  const spawnCalls = [];
  const fakeChild = {
    killed: false,
    on() {},
    unref() {},
    kill() {
      this.killed = true;
    },
  };

  const assertion = createMacOSBridgeWakeAssertion({
    platform: "darwin",
    pid: 4242,
    spawnImpl(command, args, options) {
      spawnCalls.push({ command, args, options });
      return fakeChild;
    },
  });

  assert.equal(assertion.active, true);
  assert.deepEqual(spawnCalls, [{
    command: "/usr/bin/caffeinate",
    args: ["-i", "-w", "4242"],
    options: { stdio: "ignore" },
  }]);

  assertion.stop();
  assert.equal(fakeChild.killed, true);
});

test("createMacOSBridgeWakeAssertion can toggle the caffeinate assertion on and off live", () => {
  const spawnCalls = [];
  const children = [];

  const assertion = createMacOSBridgeWakeAssertion({
    platform: "darwin",
    pid: 9001,
    enabled: false,
    spawnImpl(command, args, options) {
      const child = {
        killed: false,
        on() {},
        unref() {},
        kill() {
          this.killed = true;
        },
      };
      children.push(child);
      spawnCalls.push({ command, args, options });
      return child;
    },
  });

  assert.equal(assertion.active, false);
  assert.equal(assertion.enabled, false);
  assert.deepEqual(spawnCalls, []);

  assertion.setEnabled(true);
  assert.equal(assertion.enabled, true);
  assert.equal(assertion.active, true);
  assert.equal(spawnCalls.length, 1);

  assertion.setEnabled(false);
  assert.equal(assertion.enabled, false);
  assert.equal(assertion.active, false);
  assert.equal(children[0].killed, true);
});

test("createMacOSBridgeWakeAssertion is a no-op outside macOS", () => {
  let didSpawn = false;
  const assertion = createMacOSBridgeWakeAssertion({
    platform: "linux",
    spawnImpl() {
      didSpawn = true;
      throw new Error("should not spawn");
    },
  });

  assert.equal(assertion.active, false);
  assertion.stop();
  assert.equal(didSpawn, false);
});

test("persistBridgePreferences only saves the daemon preference field", () => {
  const writes = [];

  persistBridgePreferences(
    { keepMacAwakeEnabled: false },
    {
      readDaemonConfigImpl() {
        return {
          relayUrl: "ws://127.0.0.1:9000/relay",
          refreshEnabled: true,
        };
      },
      writeDaemonConfigImpl(config) {
        writes.push(config);
      },
    }
  );

  assert.deepEqual(writes, [{
    relayUrl: "ws://127.0.0.1:9000/relay",
    refreshEnabled: true,
    keepMacAwakeEnabled: false,
  }]);
});

test("sanitizeThreadHistoryImagesForRelay strips bulky compaction replacement history", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-resume",
    result: {
      thread: {
        id: "thread-compaction",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-compaction",
                type: "context_compaction",
                payload: {
                  message: "",
                  replacement_history: [
                    {
                      type: "message",
                      role: "assistant",
                      content: [{ type: "output_text", text: "very old transcript" }],
                    },
                  ],
                },
              },
              {
                id: "item-compaction-camel",
                type: "contextCompaction",
                replacementHistory: [
                  {
                    type: "message",
                    role: "user",
                    content: [{ type: "input_text", text: "older prompt" }],
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/resume")
  );
  const items = sanitized.result.thread.turns[0].items;

  assert.deepEqual(items[0], {
    id: "item-compaction",
    type: "context_compaction",
    payload: {
      message: "",
    },
  });
  assert.deepEqual(items[1], {
    id: "item-compaction-camel",
    type: "contextCompaction",
  });
});

test("sanitizeThreadHistoryImagesForRelay trims oversized history down to the newest turn tail", () => {
  const largeText = "A".repeat(4 * 1024 * 1024);
  const rawMessage = JSON.stringify({
    id: "req-thread-tail",
    result: {
      thread: {
        id: "thread-large-history",
        turns: [
          {
            id: "turn-old",
            items: [
              {
                id: "item-old",
                type: "assistant_message",
                text: largeText,
              },
            ],
          },
          {
            id: "turn-new",
            items: [
              {
                id: "item-new",
                type: "assistant_message",
                text: "latest reply",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );

  assert.equal(sanitized.result.thread.historyTailTruncatedForRelay, true);
  assert.deepEqual(
    sanitized.result.thread.turns.map((turn) => turn.id),
    ["turn-new"]
  );
});

test("sanitizeThreadHistoryImagesForRelay truncates the newest oversized text item to its tail", () => {
  const largeText = `header\n${"B".repeat(4 * 1024 * 1024)}`;
  const rawMessage = JSON.stringify({
    id: "req-thread-text-tail",
    result: {
      thread: {
        id: "thread-large-item",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-1",
                type: "assistant_message",
                text: largeText,
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(sanitized.result.thread.historyTailTruncatedForRelay, true);
  assert.equal(item.relayTextTailTruncated, true);
  assert.equal(item.text.startsWith("…\n"), true);
  assert.equal(item.text.includes("header"), false);
});
