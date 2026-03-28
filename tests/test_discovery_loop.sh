#!/usr/bin/env bash
# tests/test_discovery_loop.sh
# Unit tests for discovery_loop_should_continue() in lib/discovery.sh.
# Usage: bash tests/test_discovery_loop.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== discovery_loop_should_continue() tests ==="
echo ""

# Pre-declare globals expected by lib/discovery.sh and lib/common.sh
_consecutive_failure_count=0
_stale_cycle_count=0
_cleanup_pids=()
_cleanup_files=()
_interrupted=false

# Source common.sh first (provides get_cumulative_cost and other helpers)
log() { :; }
log_warn() { :; }
log_error() { :; }
log_success() { :; }
notify() { return 0; }
source "$PROJECT_DIR/lib/common.sh"

# Re-stub after sourcing common.sh
log() { :; }
log_warn() { :; }
log_error() { :; }
log_success() { :; }
notify() { return 0; }
run_hook() { return 0; }

# Source discovery.sh (and its dependency chain)
source "$PROJECT_DIR/lib/discovery.sh"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Test 1: All counters at zero, limits at defaults -> returns 0 (continue)
(
    _consecutive_failure_count=0
    _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_DISCOVERY_CYCLES=0
    FRONTIER_FILE="$TMPDIR_BASE/frontier1.json"
    echo '{"total_cycles":0}' > "$FRONTIER_FILE"
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "returns 0 when all counters below limits" "$result" "0"
)

# Test 2: _consecutive_failure_count at MAX_CONSECUTIVE_FAILURES -> returns 1 (stop)
(
    _consecutive_failure_count=3
    _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_DISCOVERY_CYCLES=0
    FRONTIER_FILE="$TMPDIR_BASE/frontier2.json"
    echo '{"total_cycles":1}' > "$FRONTIER_FILE"
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "stops when consecutive failures reach limit" "$result" "1"
)

# Test 3: _stale_cycle_count at MAX_STALE_CYCLES -> returns 1 (stop)
(
    _consecutive_failure_count=0
    _stale_cycle_count=5
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_DISCOVERY_CYCLES=0
    FRONTIER_FILE="$TMPDIR_BASE/frontier3.json"
    echo '{"total_cycles":1}' > "$FRONTIER_FILE"
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "stops when stale cycle count reaches limit" "$result" "1"
)

# Test 4: MAX_DISCOVERY_CYCLES set and total_cycles at limit -> returns 1 (stop)
(
    _consecutive_failure_count=0
    _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_DISCOVERY_CYCLES=10
    FRONTIER_FILE="$TMPDIR_BASE/frontier4.json"
    echo '{"total_cycles":10}' > "$FRONTIER_FILE"
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "stops when MAX_DISCOVERY_CYCLES reached" "$result" "1"
)

# Test 5: MAX_DISCOVERY_CYCLES=0 means unlimited - does not stop on cycle count
# shellcheck disable=SC2034
(
    _consecutive_failure_count=0
    _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_DISCOVERY_CYCLES=0
    FRONTIER_FILE="$TMPDIR_BASE/frontier5.json"
    echo '{"total_cycles":999}' > "$FRONTIER_FILE"
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "MAX_DISCOVERY_CYCLES=0 is unlimited (does not stop at high cycle count)" "$result" "0"
)

# Test 6: _consecutive_failure_count above limit -> returns 1
(
    _consecutive_failure_count=5
    _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_DISCOVERY_CYCLES=0
    FRONTIER_FILE="$TMPDIR_BASE/frontier6.json"
    echo '{"total_cycles":1}' > "$FRONTIER_FILE"
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "stops when consecutive failures exceed limit" "$result" "1"
)

# ── Budget guard tests ──────────────────────────────────────────────────────

# Helper: write a cycle-log fixture with given total cost
write_cycle_log() {
    local file="$1"
    local cost="${2:-0}"
    printf '{"cycles":[{"tokens":{"cost_usd":%s}}]}' "$cost" > "$file"
}

# Test B1: RALPH_BUDGET_LIMIT unset -> no budget stop
(
    _consecutive_failure_count=0; _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_DISCOVERY_CYCLES=0
    CYCLE_LOG_FILE="$TMPDIR_BASE/clDB1.json"
    FRONTIER_FILE="$TMPDIR_BASE/frDB1.json"
    echo '{"total_cycles":1}' > "$FRONTIER_FILE"
    write_cycle_log "$CYCLE_LOG_FILE" 999.99
    unset RALPH_BUDGET_LIMIT
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "RALPH_BUDGET_LIMIT unset -> continues" "$result" "0"
)

# Test B2: cost below limit -> continues
(
    _consecutive_failure_count=0; _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_DISCOVERY_CYCLES=0
    CYCLE_LOG_FILE="$TMPDIR_BASE/clDB2.json"
    FRONTIER_FILE="$TMPDIR_BASE/frDB2.json"
    echo '{"total_cycles":1}' > "$FRONTIER_FILE"
    write_cycle_log "$CYCLE_LOG_FILE" 10.00
    RALPH_BUDGET_LIMIT=50.00
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "cost below limit -> continues" "$result" "0"
)

# Test B3: cost at limit -> stops
(
    _consecutive_failure_count=0; _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_DISCOVERY_CYCLES=0
    CYCLE_LOG_FILE="$TMPDIR_BASE/clDB3.json"
    FRONTIER_FILE="$TMPDIR_BASE/frDB3.json"
    echo '{"total_cycles":1}' > "$FRONTIER_FILE"
    write_cycle_log "$CYCLE_LOG_FILE" 50.00
    RALPH_BUDGET_LIMIT=50.00
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "cost at limit -> stops" "$result" "1"
)

# Test B4: cost over limit -> stops
(
    _consecutive_failure_count=0; _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_DISCOVERY_CYCLES=0
    CYCLE_LOG_FILE="$TMPDIR_BASE/clDB4.json"
    FRONTIER_FILE="$TMPDIR_BASE/frDB4.json"
    echo '{"total_cycles":1}' > "$FRONTIER_FILE"
    write_cycle_log "$CYCLE_LOG_FILE" 75.50
    RALPH_BUDGET_LIMIT=50.00
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "cost over limit -> stops" "$result" "1"
)

# Test B5: empty cycle-log + limit set -> cost=0, continues
(
    _consecutive_failure_count=0; _stale_cycle_count=0
    MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_DISCOVERY_CYCLES=0
    CYCLE_LOG_FILE="$TMPDIR_BASE/clDB5.json"
    FRONTIER_FILE="$TMPDIR_BASE/frDB5.json"
    echo '{"total_cycles":1}' > "$FRONTIER_FILE"
    echo '{"cycles":[]}' > "$CYCLE_LOG_FILE"
    RALPH_BUDGET_LIMIT=50.00
    result=0
    discovery_loop_should_continue || result=$?
    assert_equals "empty cycle-log -> cost=0, continues" "$result" "0"
)

print_summary "discovery_loop_should_continue"
