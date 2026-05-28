#!/usr/bin/env bash
set -euo pipefail

# FILE: test-performance-script-usage.sh
# Purpose: Verifies performance script preflight/help paths without invoking xcodebuild.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected output to contain: $needle" >&2
    echo "Actual output:" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_template_keys() {
  local script_path="$1"
  shift
  local template_json
  template_json="$("$script_path" --print-baseline-template)"

  python3 - "$template_json" "$@" <<'PY'
import json
import sys

template = json.loads(sys.argv[1])
expected_keys = sys.argv[2:]
metrics = template.get("metrics", {})
missing = [key for key in expected_keys if key not in metrics]
if missing:
    raise SystemExit(f"Missing template metric keys: {', '.join(missing)}")
if not isinstance(template.get("max_regression_percent"), (int, float)):
    raise SystemExit("max_regression_percent must be numeric")
PY
}

assert_missing_baseline_message() {
  local script_path="$1"
  local output
  local missing_path
  missing_path="$(mktemp -u)"

  set +e
  output="$(BASELINE_PATH="$missing_path" "$script_path" 2>&1)"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "Expected $script_path to fail when BASELINE_PATH is missing." >&2
    exit 1
  fi

  assert_contains "$output" "Baseline file not found: $missing_path"
  assert_contains "$output" "BASELINE_PATH=/path/to"
  assert_contains "$output" "--print-baseline-template"
}

sidebar_script="$SCRIPT_DIR/check-sidebar-badge-performance.sh"
turnview_script="$SCRIPT_DIR/check-turnview-performance.sh"

assert_contains "$("$sidebar_script" --help)" "BASELINE_PATH"
assert_contains "$("$turnview_script" --help)" "BASELINE_PATH"

assert_template_keys \
  "$sidebar_script" \
  "snapshot_clock_s" \
  "snapshot_cpu_time_s" \
  "large_timeline_clock_s" \
  "large_timeline_cpu_time_s"

assert_template_keys \
  "$turnview_script" \
  "scroll_duration_s" \
  "stream_clock_s" \
  "stream_cpu_time_s" \
  "stream_peak_memory_kb"

assert_missing_baseline_message "$sidebar_script"
assert_missing_baseline_message "$turnview_script"

echo "Performance script usage checks passed."
