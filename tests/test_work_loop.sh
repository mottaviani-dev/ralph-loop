#!/usr/bin/env bash
# tests/test_work_loop.sh
# Unit tests for work_loop_should_continue() in lib/work.sh.
# Usage: bash tests/test_work_loop.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== work_loop_should_continue() tests ==="
echo ""

# Pre-declare globals expected by lib/work.sh and lib/common.sh
_consecutive_failure_count=0
_stale_cycle_count=0
_empty_task_cycle_count=0
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

# Stub run_preflight_validation to avoid invoking claude CLI.
# This must be declared BEFORE sourcing lib/work.sh.
run_preflight_validation() { return 0; }
notify() { return 0; }
run_hook() { return 0; }
log() { :; }
log_warn() { :; }
log_error() { :; }
log_success() { :; }

# Source work.sh (and its dependency chain)
source "$PROJECT_DIR/lib/work.sh"

# Helper: write a minimal WORK_STATE_FILE JSON fixture
write_state() {
    local file="$1"
    local all_complete="${2:-false}"
    local cycle="${3:-1}"
    printf '{"total_cycles":%s,"all_tasks_complete":%s,"last_action":"test","last_outcome":"ok"}' \
        "$cycle" "$all_complete" > "$file"
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Test 1: Normal case - all counters below limits -> returns 0 (continue)
(
    WORK_STATE_FILE="$TMPDIR_BASE/state1.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/val1.json"
    write_state "$WORK_STATE_FILE" false 1
    _consecutive_failure_count=0
    _stale_cycle_count=0
    _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "returns 0 when all counters below limits" "$result" "0"
)

# Test 2: MAX_WORK_CYCLES reached -> returns 1 (stop)
(
    WORK_STATE_FILE="$TMPDIR_BASE/state2.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/val2.json"
    write_state "$WORK_STATE_FILE" false 10
    _consecutive_failure_count=0
    _stale_cycle_count=0
    _empty_task_cycle_count=0
    MAX_WORK_CYCLES=10
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "stops when MAX_WORK_CYCLES reached" "$result" "1"
)

# Test 3: _consecutive_failure_count >= MAX_CONSECUTIVE_FAILURES -> returns 1
(
    WORK_STATE_FILE="$TMPDIR_BASE/state3.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/val3.json"
    write_state "$WORK_STATE_FILE" false 1
    _consecutive_failure_count=3
    _stale_cycle_count=0
    _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "stops when consecutive failures reach limit" "$result" "1"
)

# Test 4: _stale_cycle_count >= MAX_STALE_CYCLES -> returns 1
(
    WORK_STATE_FILE="$TMPDIR_BASE/state4.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/val4.json"
    write_state "$WORK_STATE_FILE" false 1
    _consecutive_failure_count=0
    _stale_cycle_count=5
    _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "stops when stale cycle count reaches limit" "$result" "1"
)

# Test 5: _empty_task_cycle_count >= MAX_EMPTY_TASK_CYCLES -> returns 1
(
    WORK_STATE_FILE="$TMPDIR_BASE/state5.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/val5.json"
    write_state "$WORK_STATE_FILE" false 1
    _consecutive_failure_count=0
    _stale_cycle_count=0
    _empty_task_cycle_count=3
    MAX_WORK_CYCLES=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "stops when empty task cycle count reaches limit" "$result" "1"
)

# Test 6: MAX_WORK_CYCLES=0 means unlimited - does not stop on cycle count alone
# shellcheck disable=SC2034 # variables consumed by sourced lib/work.sh
(
    WORK_STATE_FILE="$TMPDIR_BASE/state6.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/val6.json"
    write_state "$WORK_STATE_FILE" false 999
    _consecutive_failure_count=0
    _stale_cycle_count=0
    _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "MAX_WORK_CYCLES=0 is unlimited (does not stop at high cycle count)" "$result" "0"
)

# ── Budget guard tests ──────────────────────────────────────────────────────

# Helper: write a cycle-log fixture with given total cost
write_cycle_log() {
    local file="$1"
    local cost="${2:-0}"
    printf '{"cycles":[{"tokens":{"cost_usd":%s}}]}' "$cost" > "$file"
}

# Test B1: RALPH_BUDGET_LIMIT unset -> budget guard skipped, continues
(
    WORK_STATE_FILE="$TMPDIR_BASE/stateB1.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/valB1.json"
    CYCLE_LOG_FILE="$TMPDIR_BASE/clB1.json"
    write_state "$WORK_STATE_FILE" false 1
    write_cycle_log "$CYCLE_LOG_FILE" 999.99
    unset RALPH_BUDGET_LIMIT
    _consecutive_failure_count=0; _stale_cycle_count=0; _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0; MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "RALPH_BUDGET_LIMIT unset -> continues regardless of cost" "$result" "0"
)

# Test B2: cumulative cost below limit -> continues
(
    WORK_STATE_FILE="$TMPDIR_BASE/stateB2.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/valB2.json"
    CYCLE_LOG_FILE="$TMPDIR_BASE/clB2.json"
    write_state "$WORK_STATE_FILE" false 1
    write_cycle_log "$CYCLE_LOG_FILE" 10.00
    RALPH_BUDGET_LIMIT=50.00
    _consecutive_failure_count=0; _stale_cycle_count=0; _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0; MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "cost below limit -> continues" "$result" "0"
)

# Test B3: cumulative cost exactly at limit -> stops
(
    WORK_STATE_FILE="$TMPDIR_BASE/stateB3.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/valB3.json"
    CYCLE_LOG_FILE="$TMPDIR_BASE/clB3.json"
    write_state "$WORK_STATE_FILE" false 1
    write_cycle_log "$CYCLE_LOG_FILE" 50.00
    RALPH_BUDGET_LIMIT=50.00
    _consecutive_failure_count=0; _stale_cycle_count=0; _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0; MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "cost at limit (>=) -> stops" "$result" "1"
)

# Test B4: cumulative cost over limit -> stops
(
    WORK_STATE_FILE="$TMPDIR_BASE/stateB4.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/valB4.json"
    CYCLE_LOG_FILE="$TMPDIR_BASE/clB4.json"
    write_state "$WORK_STATE_FILE" false 1
    write_cycle_log "$CYCLE_LOG_FILE" 75.50
    RALPH_BUDGET_LIMIT=50.00
    _consecutive_failure_count=0; _stale_cycle_count=0; _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0; MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "cost over limit -> stops" "$result" "1"
)

# Test B5: empty cycle-log + RALPH_BUDGET_LIMIT set -> treats cost as 0, continues
(
    WORK_STATE_FILE="$TMPDIR_BASE/stateB5.json"
    LAST_VALIDATION_FILE="$TMPDIR_BASE/valB5.json"
    CYCLE_LOG_FILE="$TMPDIR_BASE/clB5.json"
    write_state "$WORK_STATE_FILE" false 1
    echo '{"cycles":[]}' > "$CYCLE_LOG_FILE"
    RALPH_BUDGET_LIMIT=50.00
    _consecutive_failure_count=0; _stale_cycle_count=0; _empty_task_cycle_count=0
    MAX_WORK_CYCLES=0; MAX_CONSECUTIVE_FAILURES=3; MAX_STALE_CYCLES=5; MAX_EMPTY_TASK_CYCLES=3
    result=0
    work_loop_should_continue || result=$?
    assert_equals "empty cycle-log -> cost=0, continues" "$result" "0"
)

print_summary "work_loop_should_continue"
