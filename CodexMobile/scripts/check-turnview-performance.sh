#!/usr/bin/env bash
set -euo pipefail

# FILE: check-turnview-performance.sh
# Purpose: Runs TurnView UI perf tests and fails if key metrics regress beyond baseline.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexMobile.xcodeproj"
SCHEME="${SCHEME:-CodexMobile}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
BASELINE_PATH="${BASELINE_PATH:-$ROOT_DIR/Docs/TurnView-Performance-Baseline.json}"
MAX_REGRESSION_PERCENT="${MAX_REGRESSION_PERCENT:-}"

if [[ ! -f "$BASELINE_PATH" ]]; then
  echo "Baseline file not found: $BASELINE_PATH"
  exit 1
fi

run_log="$(mktemp)"
metrics_json="$(mktemp)"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  test \
  -only-testing:CodexMobileUITests/CodexMobileUITests/testTurnTimelineScrollingPerformance \
  -only-testing:CodexMobileUITests/CodexMobileUITests/testTurnStreamingAppendPerformance \
  2>&1 | tee "$run_log"

xcresult_path="$(awk '/Test session results, code coverage, and logs:/{getline; gsub(/^[[:space:]]+/, "", $0); print $0; exit}' "$run_log")"

if [[ -z "$xcresult_path" || ! -d "$xcresult_path" ]]; then
  echo "Unable to locate xcresult path from xcodebuild output."
  exit 1
fi

xcrun xcresulttool get test-results metrics --path "$xcresult_path" > "$metrics_json"

python3 - "$metrics_json" "$BASELINE_PATH" "$MAX_REGRESSION_PERCENT" <<'PY'
import json
import statistics
import sys

metrics_path, baseline_path, override = sys.argv[1:4]
metrics = json.load(open(metrics_path, 'r', encoding='utf-8'))
baseline = json.load(open(baseline_path, 'r', encoding='utf-8'))

max_regression_percent = float(override) if override else float(baseline.get("max_regression_percent", 5.0))
allowed_multiplier = 1.0 + (max_regression_percent / 100.0)

TARGETS = {
    "scroll_duration_s": {
        "test_id": "testTurnTimelineScrollingPerformance",
        "metric_id": "com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration",
    },
    "stream_clock_s": {
        "test_id": "testTurnStreamingAppendPerformance",
        "metric_id": "com.apple.dt.XCTMetric_Clock.time.monotonic",
    },
    "stream_cpu_time_s": {
        "test_id": "testTurnStreamingAppendPerformance",
        "metric_id": "com.apple.dt.XCTMetric_CPU.time",
    },
    "stream_peak_memory_kb": {
        "test_id": "testTurnStreamingAppendPerformance",
        "metric_id": "com.apple.dt.XCTMetric_Memory.physical_peak",
    },
}

def find_average(test_name_fragment: str, metric_identifier: str) -> float:
    for test_entry in metrics:
        test_identifier = test_entry.get("testIdentifier", "")
        if test_name_fragment not in test_identifier:
            continue
        for run in test_entry.get("testRuns", []):
            for metric in run.get("metrics", []):
                if metric.get("identifier") == metric_identifier:
                    samples = metric.get("measurements", [])
                    if not samples:
                        raise RuntimeError(f"No measurements for {test_name_fragment} / {metric_identifier}")
                    return statistics.fmean(samples)
    raise RuntimeError(f"Metric not found for {test_name_fragment} / {metric_identifier}")

failures = []
print("TurnView performance check")
print(f"Allowed regression: {max_regression_percent:.2f}%")

for key, target in TARGETS.items():
    baseline_value = float(baseline["metrics"][key])
    current_value = find_average(target["test_id"], target["metric_id"])
    threshold_value = baseline_value * allowed_multiplier
    regression_percent = ((current_value - baseline_value) / baseline_value) * 100.0

    print(
        f"- {key}: baseline={baseline_value:.6f}, current={current_value:.6f}, "
        f"delta={regression_percent:+.2f}%"
    )

    if current_value > threshold_value:
        failures.append(
            f"{key} regressed by {regression_percent:.2f}% "
            f"(baseline {baseline_value:.6f}, current {current_value:.6f}, max {max_regression_percent:.2f}%)"
        )

if failures:
    print("\nPerformance regression check failed:")
    for failure in failures:
        print(f"  * {failure}")
    sys.exit(1)

print("\nPerformance regression check passed.")
PY
