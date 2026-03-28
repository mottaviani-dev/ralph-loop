#!/usr/bin/env bash
# tests/test_validation_exit_codes.sh
# Regression test: validation pipeline correctly captures non-zero exit codes.
# Without the fix, all exit codes are 0 (masked by tail -30 in the pipeline).
# Usage: bash tests/test_validation_exit_codes.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== validation exit code capture tests ==="
echo ""

# ── Unit: capture pattern ────────────────────────────────────────────────────

# Test 1: failing command exit code is captured (not masked by tail)
(
    exit_code=0
    raw_output=$(bash -c "echo 'some output'; exit 42" 2>&1) || exit_code=$?
    cmd_output=$(echo "$raw_output" | tail -30)
    assert_equals "failing command exit code is captured" "$exit_code" "42"
    assert_contains "output is preserved after tail" "$cmd_output" "some output"
)

# Test 2: passing command records exit code 0
(
    exit_code=0
    raw_output=$(bash -c "echo 'all good'; exit 0" 2>&1) || exit_code=$?
    cmd_output=$(echo "$raw_output" | tail -30)
    assert_equals "passing command exit code is 0" "$exit_code" "0"
    assert_contains "passing output is preserved" "$cmd_output" "all good"
)

# Test 3: tail -30 truncates output correctly (only last 30 lines kept)
(
    exit_code=0
    raw_output=$(bash -c "for i in \$(seq 1 50); do echo \"line \$i\"; done; exit 1" 2>&1) || exit_code=$?
    cmd_output=$(echo "$raw_output" | tail -30)
    line_count=$(echo "$cmd_output" | wc -l | tr -d ' ')
    assert_equals "output is truncated to last 30 lines" "$line_count" "30"
    assert_equals "exit code is still captured despite truncation" "$exit_code" "1"
)

# ── Integration: run_post_work_validation writes correct exit_code ────────────

# Test 4: run_post_work_validation writes non-zero exit_code to JSON
(
    TMPDIR_TEST=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_TEST"' EXIT

    # Minimal globals required by lib/work.sh and lib/common.sh
    STATE_DIR="$TMPDIR_TEST/_state"
    DOCS_DIR="$TMPDIR_TEST"
    WORK_STATE_FILE="$TMPDIR_TEST/_state/work-state.json"
    TASKS_FILE="$TMPDIR_TEST/_state/tasks.json"
    LAST_VALIDATION_FILE="$TMPDIR_TEST/_state/last-validation-results.json"
    SCRIPT_DIR="$PROJECT_DIR"
    CLAUDE_MODEL="sonnet"
    USE_AGENTS="false"
    WORK_AGENT_TIMEOUT=900
    SKIP_COMMIT="true"
    WORK_COMMIT_MSG_PREFIX="work:"
    WORK_GIT_EXCLUDE_DEFAULTS=()
    JOURNAL_FILE="$TMPDIR_TEST/_state/journal.md"
    CYCLE_LOG_FILE="$TMPDIR_TEST/_state/cycle-log.json"
    WORK_PROMPT_FILE="$TMPDIR_TEST/_state/work-prompt.md"
    SUBAGENTS_FILE=""
    MAINTENANCE_PROMPT_FILE=""
    CONFIG_FILE="$TMPDIR_TEST/_state/config.json"
    JOURNAL_MAX_LINES=500
    JOURNAL_KEEP_LINES=300
    MAX_WORK_CYCLES=0
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_EMPTY_TASK_CYCLES=3
    _consecutive_failure_count=0
    _stale_cycle_count=0
    _empty_task_cycle_count=0
    _cleanup_files=()
    _cleanup_pids=()
    _interrupted=false
    RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" NC=""

    mkdir -p "$STATE_DIR"

    # Stub logging functions
    log() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warn() { :; }

    # Stub run_with_timeout to just run the command (no timeout wrapper needed)
    run_with_timeout() {
        local _timeout="$1"; shift
        "$@"
    }

    # work-state.json with current_task pointing to task-001
    printf '{"current_task":"task-001","total_cycles":1,"all_tasks_complete":false,"last_action":"implement","last_outcome":"ok"}' \
        > "$WORK_STATE_FILE"

    # tasks.json with a failing validation command for task-001
    printf '{"schema_version":1,"tasks":[{"id":"task-001","title":"Test task","status":"in_progress","validation_commands":["exit 7"]}]}' \
        > "$TASKS_FILE"

    # Source lib/work.sh (defines run_post_work_validation)
    source "$PROJECT_DIR/lib/work.sh" || { echo "FATAL: could not source lib/work.sh" >&2; exit 1; }

    # Run post-work validation — this writes last-validation-results.json
    run_post_work_validation

    # Parse the written file and check exit_code field
    if [ ! -f "$LAST_VALIDATION_FILE" ]; then
        fail "run_post_work_validation: last-validation-results.json was written" \
             "File does not exist at $LAST_VALIDATION_FILE"
    else
        pass "run_post_work_validation: last-validation-results.json was written"

        recorded_exit=$(jq '[to_entries[] | select(.key != "_summary") | .value.exit_code] | first' \
            "$LAST_VALIDATION_FILE" 2>/dev/null || echo "-1")
        assert_equals "exit_code in JSON is non-zero (7)" "$recorded_exit" "7"

        summary=$(jq -r '._summary' "$LAST_VALIDATION_FILE" 2>/dev/null || echo "")
        assert_contains "summary reports failure" "$summary" "failed"
    fi
)

print_summary "validation exit code capture"
