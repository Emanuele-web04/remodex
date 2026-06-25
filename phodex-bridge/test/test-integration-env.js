// FILE: test-integration-env.js
// Purpose: Enable live OpenCode serve for integration tests

if (!process.env.REMODEX_TEST) {
  process.env.REMODEX_TEST = "1";
}

// Explicitly opt into live OpenCode behavior for integration tests
if (!process.env.REMODEX_DISABLE_OPENCODE) {
  process.env.REMODEX_DISABLE_OPENCODE = "0";
}