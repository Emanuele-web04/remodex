const test=require("node:test");const assert=require("node:assert/strict");const fs=require("fs");const os=require("os");const path=require("path");const {createHash}=require("crypto");const {buildThreadTurnsListRelaySanitizeContext,sanitizeLiveGeneratedImageMessageForRelay,sanitizeThreadHistoryImagesForRelay,expectedGeneratedImagePath}=require("./relay-history-sanitize.harness");

test("final thread turns-list relay sanitize context keeps JSONL artifact augmentation enabled", () => {
  const request = {
    id: "req-turns-list-final-context",
    method: "thread/turns/list",
    params: {
      threadId: "thread-final-context",
      limit: 1,
    },
  };

  assert.deepEqual(buildThreadTurnsListRelaySanitizeContext(request), {
    threadId: "thread-final-context",
    skipJsonlArtifactAugmentation: false,
  });
  assert.deepEqual(buildThreadTurnsListRelaySanitizeContext(request, {
    skipJsonlArtifactAugmentation: true,
  }), {
    threadId: "thread-final-context",
    skipJsonlArtifactAugmentation: true,
  });
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


test("sanitizeThreadHistoryImagesForRelay converts desktop apply_patch history to fileChange", () => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: Sources/App.swift",
    "@@",
    "-let title = \"Old\"",
    "+let title = \"New\"",
    "*** End Patch",
    "",
  ].join("\n");
  const rawMessage = JSON.stringify({
    id: "req-thread-patch",
    result: {
      thread: {
        id: "thread-patch",
        turns: [
          {
            id: "turn-patch",
            items: [
              {
                id: "call-patch",
                type: "custom_tool_call",
                status: "completed",
                name: "apply_patch",
                call_id: "call-patch",
                input: patch,
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

  assert.equal(item.type, "fileChange");
  assert.equal(item.id, "call-patch");
  assert.deepEqual(item.changes.map((change) => ({
    path: change.path,
    kind: change.kind,
    additions: change.additions,
    deletions: change.deletions,
  })), [{
    path: "Sources/App.swift",
    kind: "update",
    additions: 1,
    deletions: 1,
  }]);
});


test("sanitizeThreadHistoryImagesForRelay augments app-server history with JSONL fileChange blocks", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-"));
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

  const threadId = "thread-jsonl-filechange";
  const turnId = "turn-jsonl-filechange";
  const cwd = "/Users/test/Project";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-05-19T19-40-00-${threadId}.jsonl`),
    [
      JSON.stringify({
        type: "session_meta",
        payload: {
          id: threadId,
          cwd,
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "task_started",
          turn_id: turnId,
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "custom_tool_call",
          status: "completed",
          name: "apply_patch",
          call_id: "call-jsonl-patch",
          input: [
            "*** Begin Patch",
            `*** Update File: ${cwd}/Sources/App.swift`,
            "@@",
            "-let title = \"Old\"",
            "+let title = \"New\"",
            "*** End Patch",
            "",
          ].join("\n"),
        },
      }),
    ].join("\n"),
    "utf8"
  );

  const rawMessage = JSON.stringify({
    id: "req-thread-jsonl",
    result: {
      thread: {
        id: threadId,
        turns: [
          {
            id: turnId,
            items: [
              {
                id: "assistant-jsonl",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Done." }],
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
  const items = sanitized.result.thread.turns[0].items;

  assert.equal(sanitized.result.thread.cwd, cwd);
  assert.equal(sanitized.result.thread.current_working_directory, cwd);
  assert.equal(items.length, 2);
  assert.equal(items[1].type, "fileChange");
  assert.equal(items[1].remodexJsonlFileChangeAggregate, true);
  assert.deepEqual(items[1].changes.map((change) => ({
    path: change.path,
    kind: change.kind,
    additions: change.additions,
    deletions: change.deletions,
  })), [{
    path: "Sources/App.swift",
    kind: "update",
    additions: 1,
    deletions: 1,
  }]);

  const turnsPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-turns-jsonl",
    result: {
      threadId,
      data: [
        {
          id: turnId,
          items: [
            {
              id: "assistant-jsonl-page",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
          ],
        },
      ],
    },
  }), "thread/turns/list"));

  assert.equal(turnsPage.result.data[0].items.length, 2);
  assert.equal(turnsPage.result.data[0].items[1].type, "fileChange");

  const hintedTurnsPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-turns-jsonl-hinted",
    result: {
      data: [
        {
          id: turnId,
          items: [
            {
              id: "assistant-jsonl-page-hinted",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
          ],
        },
      ],
    },
  }), "thread/turns/list", { threadId }));

  assert.equal(hintedTurnsPage.result.data[0].items.length, 2);
  assert.equal(hintedTurnsPage.result.data[0].items[1].type, "fileChange");

  const skippedTurnsPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-turns-jsonl-skip",
    result: {
      data: [
        {
          id: turnId,
          items: [
            {
              id: "assistant-jsonl-page-skip",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
          ],
        },
      ],
    },
  }), "thread/turns/list", {
    threadId,
    skipJsonlArtifactAugmentation: true,
  }));

  assert.equal(skippedTurnsPage.result.data[0].items.length, 1);
});


test("sanitizeThreadHistoryImagesForRelay caches JSONL artifact scans until the rollout changes", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-cache-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  const originalReadFileSync = fs.readFileSync;
  t.after(() => {
    fs.readFileSync = originalReadFileSync;
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-cache";
  const firstTurnId = "turn-jsonl-cache-one";
  const secondTurnId = "turn-jsonl-cache-two";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  const rolloutPath = path.join(sessionsDir, `rollout-2026-05-19T19-40-00-${threadId}.jsonl`);
  fs.mkdirSync(sessionsDir, { recursive: true });

  const buildPatchCall = (turnId, callId, fileName) => [
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: turnId,
      },
    }),
    JSON.stringify({
      type: "response_item",
      payload: {
        type: "custom_tool_call",
        status: "completed",
        name: "apply_patch",
        call_id: callId,
        input: [
          "*** Begin Patch",
          `*** Update File: Sources/${fileName}`,
          "@@",
          "-let title = \"Old\"",
          "+let title = \"New\"",
          "*** End Patch",
          "",
        ].join("\n"),
      },
    }),
  ].join("\n");

  fs.writeFileSync(
    rolloutPath,
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId },
      }),
      buildPatchCall(firstTurnId, "call-jsonl-cache-one", "One.swift"),
    ].join("\n"),
    "utf8"
  );

  let rolloutReads = 0;
  fs.readFileSync = function readFileSyncWithRolloutCounter(filePath, ...args) {
    if (path.resolve(String(filePath)) === rolloutPath) {
      rolloutReads += 1;
    }
    return originalReadFileSync.call(this, filePath, ...args);
  };

  const makeTurnsPage = (turnId, requestId) => JSON.stringify({
    id: requestId,
    result: {
      threadId,
      data: [
        {
          id: turnId,
          items: [
            {
              id: `${requestId}-assistant`,
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
          ],
        },
      ],
    },
  });

  const firstPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(
    makeTurnsPage(firstTurnId, "req-jsonl-cache-one"),
    "thread/turns/list"
  ));
  const secondPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(
    makeTurnsPage(firstTurnId, "req-jsonl-cache-two"),
    "thread/turns/list"
  ));

  assert.equal(firstPage.result.data[0].items[1].type, "fileChange");
  assert.equal(secondPage.result.data[0].items[1].type, "fileChange");
  assert.equal(rolloutReads, 1);

  fs.appendFileSync(
    rolloutPath,
    `\n${buildPatchCall(secondTurnId, "call-jsonl-cache-two", "Two.swift")}`,
    "utf8"
  );

  const changedPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(
    makeTurnsPage(secondTurnId, "req-jsonl-cache-three"),
    "thread/turns/list"
  ));

  assert.equal(changedPage.result.data[0].items[1].type, "fileChange");
  assert.equal(changedPage.result.data[0].items[1].changes[0].path, "Sources/Two.swift");
  assert.equal(rolloutReads, 2);
});


test("sanitizeThreadHistoryImagesForRelay restores JSONL update_plan as progress plan history", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-plan-"));
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

  const threadId = "thread-jsonl-plan";
  const turnId = "turn-jsonl-plan";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-05-19T19-41-00-${threadId}.jsonl`),
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "task_started",
          turn_id: turnId,
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "update_plan",
          call_id: "call-jsonl-plan",
          arguments: JSON.stringify({
            explanation: "Keep the plan visible.",
            plan: [
              { step: "Inspect plan rendering", status: "completed" },
              { step: "Patch the bridge", status: "in_progress" },
            ],
          }),
        },
      }),
    ].join("\n"),
    "utf8"
  );

  const rawMessage = JSON.stringify({
    id: "req-thread-jsonl-plan",
    result: {
      thread: {
        id: threadId,
        turns: [
          {
            id: turnId,
            items: [
              {
                id: "assistant-jsonl-plan",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Done." }],
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
  const items = sanitized.result.thread.turns[0].items;

  assert.equal(items.length, 2);
  assert.equal(items[0].id, "assistant-jsonl-plan");
  assert.equal(items[1].type, "plan");
  assert.equal(items[1].id, "call-jsonl-plan");
  assert.equal(items[1].remodexJsonlProgressPlan, true);
  assert.equal(items[1].explanation, "Keep the plan visible.");
  assert.deepEqual(items[1].plan, [
    { step: "Inspect plan rendering", status: "completed" },
    { step: "Patch the bridge", status: "in_progress" },
  ]);
});


test("sanitizeThreadHistoryImagesForRelay restores JSONL view_image output previews", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-image-"));
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

  const threadId = "thread-jsonl-image";
  const turnId = "turn-jsonl-image";
  const imagePath = "/Users/test/Library/Application Support/CleanShot/media/screenshot.png";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-05-19T19-42-00-${threadId}.jsonl`),
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "task_started",
          turn_id: turnId,
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "view_image",
          call_id: "call-jsonl-image",
          arguments: JSON.stringify({ path: imagePath }),
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: "call-jsonl-image",
          output: [
            {
              type: "input_image",
              image_url: "data:image/png;base64,AAAA",
            },
          ],
        },
      }),
    ].join("\n"),
    "utf8"
  );

  const rawMessage = JSON.stringify({
    id: "req-thread-jsonl-image",
    result: {
      thread: {
        id: threadId,
        turns: [
          {
            id: turnId,
            items: [
              {
                id: "assistant-jsonl-image",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "I opened it." }],
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
  const items = sanitized.result.thread.turns[0].items;

  assert.equal(items.length, 2);
  assert.equal(items[1].type, "imageView");
  assert.equal(items[1].path, imagePath);
  assert.equal(items[1].remodexJsonlToolOutputImage, true);
  assert.equal(Object.hasOwn(items[1], "output"), false);
});


test("sanitizeThreadHistoryImagesForRelay restores JSONL cwd without file changes", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-cwd-"));
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

  const threadId = "thread-jsonl-cwd";
  const cwd = "/Users/test/Project";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-05-19T19-45-00-${threadId}.jsonl`),
    JSON.stringify({
      type: "session_meta",
      payload: {
        id: threadId,
        cwd,
      },
    }),
    "utf8"
  );

  const sanitized = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-thread-cwd",
    result: {
      thread: {
        id: threadId,
        cwd: "/tmp/stale",
        turns: [
          {
            id: "turn-cwd",
            items: [
              {
                id: "assistant-cwd",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Done." }],
              },
            ],
          },
        ],
      },
    },
  }), "thread/read"));

  assert.equal(sanitized.result.thread.cwd, cwd);
  assert.equal(sanitized.result.thread.current_working_directory, cwd);
  assert.equal(sanitized.result.thread.turns[0].items.length, 1);
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
    expectedGeneratedImagePath("thread-generated-image", "ig_123.png")
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
    expectedGeneratedImagePath("thread-image-generation", "ig_generation.png")
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
    expectedGeneratedImagePath("thread-generated-image-end", "ig_end.png")
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
    expectedGeneratedImagePath("thread-live-image", "ig_live.png")
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
    expectedGeneratedImagePath("thread-live-nested-image", "ig_nested.png")
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
    expectedGeneratedImagePath("thread-live-event", "ig_event.png")
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


test("sanitizeThreadHistoryImagesForRelay strips bulky compaction history from turns pages", () => {
  const rawMessage = JSON.stringify({
    id: "req-turns-list",
    result: {
      data: [
        {
          id: "turn-1",
          items: [
            {
              id: "item-compacted",
              type: "compacted",
              message: "",
              replacement_history: [
                {
                  type: "message",
                  role: "assistant",
                  content: [{ type: "output_text", text: "A".repeat(2 * 1024 * 1024) }],
                },
              ],
            },
          ],
        },
      ],
      nextCursor: "cursor-2",
    },
  });

  const sanitizedRaw = sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/turns/list");
  const sanitized = JSON.parse(sanitizedRaw);

  assert.equal(Buffer.byteLength(sanitizedRaw, "utf8") < 16 * 1024, true);
  assert.deepEqual(sanitized.result.data[0].items[0], {
    id: "item-compacted",
    type: "compacted",
    message: "",
  });
  assert.equal(sanitized.result.nextCursor, "cursor-2");
});


test("sanitizeThreadHistoryImagesForRelay compacts oversized turns pages", () => {
  const rawMessage = JSON.stringify({
    id: "req-turns-list-large",
    result: {
      items: [
        {
          id: "turn-1",
          items: [
            {
              id: "item-1",
              type: "assistant_message",
              turnId: "turn-1",
              createdAt: "2026-05-24T19:43:11.933Z",
              timestamp: "2026-05-24T19:43:11.933Z",
              text: "B".repeat(4 * 1024 * 1024),
            },
          ],
        },
      ],
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/turns/list")
  );
  const item = sanitized.result.items[0].items[0];

  assert.equal(sanitized.result.remodexPageCompactedForRelay, true);
  assert.deepEqual(
    sanitized.result.items.map((turn) => turn.id),
    ["turn-1"]
  );
  assert.equal(
    sanitized.result.items.some((turn) => turn.id.startsWith("remodex-history-compacted-")),
    false
  );
  assert.equal(sanitized.result.items[0].remodexPageCompactedForRelay, true);
  assert.equal(item.relayPayloadTruncated, true);
  assert.equal(item.turnId, "turn-1");
  assert.equal(item.createdAt, "2026-05-24T19:43:11.933Z");
  assert.equal(item.timestamp, "2026-05-24T19:43:11.933Z");
  assert.equal(item.text.startsWith("…\n"), true);
  assert.equal(item.text.length < 120_000, true);
});


test("sanitizeThreadHistoryImagesForRelay preserves oversized turns pages instead of replacing them with a marker", () => {
  const turns = Array.from({ length: 5 }, (_, turnIndex) => ({
    id: `turn-${turnIndex + 1}`,
    items: Array.from({ length: 900 }, (_, itemIndex) => ({
      id: `item-${turnIndex + 1}-${itemIndex + 1}`,
      type: "function_call_output",
      role: "tool",
      itemId: `call-${turnIndex + 1}-${itemIndex + 1}`,
      text: "C".repeat(1_500),
      payload: {
        blob: "D".repeat(1_200),
      },
    })),
  }));
  const rawMessage = JSON.stringify({
    id: "req-turns-list-impossible",
    result: {
      data: turns,
      nextCursor: "cursor-after-huge-page",
    },
  });

  const sanitizedRaw = sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/turns/list");
  const sanitized = JSON.parse(sanitizedRaw);

  assert.equal(Buffer.byteLength(sanitizedRaw, "utf8") <= 4 * 1024 * 1024, true);
  assert.deepEqual(
    sanitized.result.data.map((turn) => turn.id),
    turns.map((turn) => turn.id)
  );
  assert.equal(
    sanitized.result.data.some((turn) => turn.id.startsWith("remodex-history-compacted-")),
    false
  );
  assert.equal(sanitized.result.nextCursor, "cursor-after-huge-page");
  assert.equal(sanitized.result.data.every((turn) => turn.items.length === 900), true);
  assert.equal(
    sanitized.result.data.every((turn) => turn.items.every((item) => item.relayPayloadTruncated === true)),
    true
  );
});


test("sanitizeThreadHistoryImagesForRelay compacts oversized history before the newest turn tail", () => {
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
  assert.equal(sanitized.result.thread.remodexHistoryCompacted, true);
  assert.equal(sanitized.result.thread.remodexOmittedTurnCount, 1);
  assert.equal(sanitized.result.thread.remodexKeptTurnCount, 1);
  assert.deepEqual(
    sanitized.result.thread.turns.map((turn) => turn.id),
    ["remodex-history-compacted-turn-old", "turn-new"]
  );
  assert.equal(
    sanitized.result.thread.turns[0].items[0].text.includes("Older turns omitted: 1"),
    true
  );
});


test("sanitizeThreadHistoryImagesForRelay keeps the newest forty turns when compacting", () => {
  const largeText = "A".repeat(900 * 1024);
  const turns = Array.from({ length: 45 }, (_, index) => ({
    id: `turn-${index + 1}`,
    items: [
      {
        id: `item-${index + 1}`,
        type: "assistant_message",
        text: index < 5 ? largeText : `reply ${index + 1}`,
      },
    ],
  }));
  const rawMessage = JSON.stringify({
    id: "req-thread-recent-window",
    result: {
      thread: {
        id: "thread-recent-window",
        turns,
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );

  assert.equal(sanitized.result.thread.remodexHistoryCompacted, true);
  assert.equal(sanitized.result.thread.remodexOmittedTurnCount, 5);
  assert.equal(sanitized.result.thread.remodexKeptTurnCount, 40);
  assert.deepEqual(
    sanitized.result.thread.turns.map((turn) => turn.id),
    [
      "remodex-history-compacted-turn-1",
      ...turns.slice(5).map((turn) => turn.id),
    ]
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

