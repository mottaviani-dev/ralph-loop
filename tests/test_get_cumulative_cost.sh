#!/usr/bin/env bash
# tests/test_get_cumulative_cost.sh
# Unit tests for get_cumulative_cost() in lib/common.sh.
# Usage: bash tests/test_get_cumulative_cost.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== get_cumulative_cost() tests ==="
echo ""

# Stub logging and other globals to avoid side effects
log() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
notify() { return 0; }
run_hook() { return 0; }
_cleanup_pids=(); _cleanup_files=(); _interrupted=false
_consecutive_failure_count=0; _stale_cycle_count=0; _empty_task_cycle_count=0

source "$PROJECT_DIR/lib/common.sh"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Test 1: empty cycles array -> returns 0
(
    CYCLE_LOG_FILE="$TMPDIR_BASE/cl1.json"
    echo '{"cycles":[]}' > "$CYCLE_LOG_FILE"
    result=$(get_cumulative_cost)
    assert_equals "empty cycles returns 0" "$result" "0"
)

# Test 2: single cycle with cost -> returns that cost
(
    CYCLE_LOG_FILE="$TMPDIR_BASE/cl2.json"
    printf '{"cycles":[{"tokens":{"cost_usd":0.42}}]}' > "$CYCLE_LOG_FILE"
    result=$(get_cumulative_cost)
    assert_equals "single cycle cost" "$result" "0.42"
)

# Test 3: multiple cycles summed correctly
(
    CYCLE_LOG_FILE="$TMPDIR_BASE/cl3.json"
    printf '{"cycles":[{"tokens":{"cost_usd":1.00}},{"tokens":{"cost_usd":2.50}}]}' > "$CYCLE_LOG_FILE"
    result=$(get_cumulative_cost)
    assert_equals "multi-cycle sum" "$result" "3.5"
)

# Test 4: cycles with null cost treated as 0
(
    CYCLE_LOG_FILE="$TMPDIR_BASE/cl4.json"
    printf '{"cycles":[{"tokens":{}},{"tokens":{"cost_usd":1.00}}]}' > "$CYCLE_LOG_FILE"
    result=$(get_cumulative_cost)
    # jq preserves decimal formatting: 0 + 1.00 = 1 (may output as 1 or 1.00)
    # Use awk to compare numerically
    if awk "BEGIN { exit ($result == 1) ? 0 : 1 }"; then
        pass "null cost_usd treated as 0"
    else
        fail "null cost_usd treated as 0" "Expected 1, got '$result'"
    fi
)

# Test 5: missing/nonexistent cycle-log -> returns 0
(
    CYCLE_LOG_FILE="$TMPDIR_BASE/nonexistent.json"
    result=$(get_cumulative_cost)
    assert_equals "missing file returns 0" "$result" "0"
)

# Test 6: cycles without tokens key -> returns 0
(
    CYCLE_LOG_FILE="$TMPDIR_BASE/cl6.json"
    printf '{"cycles":[{"status":"success"},{"status":"failed"}]}' > "$CYCLE_LOG_FILE"
    result=$(get_cumulative_cost)
    assert_equals "cycles without tokens key returns 0" "$result" "0"
)

print_summary "get_cumulative_cost"
