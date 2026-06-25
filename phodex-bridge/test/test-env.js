// FILE: test-env.js
// Purpose: Default test process env so unit tests do not spawn live OpenCode serve.
// Layer: Test harness preload (node -r ./test/test-env.js --test)
// Exports: none (side effects only)

if (!process.env.REMODEX_TEST) {
  process.env.REMODEX_TEST = "1";
}

// Tests that explicitly unset this flag opt into live OpenCode behavior.
if (!process.env.REMODEX_DISABLE_OPENCODE) {
  process.env.REMODEX_DISABLE_OPENCODE = "1";
}

// Default unit-test budget (production default is ~25s). Skipped when REMODEX_TEST_FULL=1.
if (
  !process.env.REMODEX_MODEL_LIST_OPENCODE_BUDGET_MS &&
  process.env.REMODEX_TEST_FULL !== "1"
) {
  process.env.REMODEX_MODEL_LIST_OPENCODE_BUDGET_MS = "100";
}

if (process.env.REMODEX_TEST_FULL !== "1") {
  if (!process.env.REMODEX_THREAD_LIST_CODEX_BUDGET_MS) {
    process.env.REMODEX_THREAD_LIST_CODEX_BUDGET_MS = "100";
  }
  if (!process.env.REMODEX_THREAD_LIST_OPENCODE_BUDGET_MS) {
    process.env.REMODEX_THREAD_LIST_OPENCODE_BUDGET_MS = "100";
  }
}

// Shorten opencode serve start/health waits in unit tests (production: 15s / 5s).
if (process.env.REMODEX_TEST_FULL !== "1") {
  if (!process.env.REMODEX_OPENCODE_START_TIMEOUT_MS) {
    process.env.REMODEX_OPENCODE_START_TIMEOUT_MS = "250";
  }
  if (!process.env.REMODEX_OPENCODE_HEALTH_TIMEOUT_MS) {
    process.env.REMODEX_OPENCODE_HEALTH_TIMEOUT_MS = "250";
  }
}