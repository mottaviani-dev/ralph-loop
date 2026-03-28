#!/usr/bin/env bash
# tests/test_validate_env.sh
# Usage: bash tests/test_validate_env.sh
# Runs validate_env() tests by invoking run.sh with controlled env overrides.
# Expects run.sh to be at ../run.sh relative to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"
source "$SCRIPT_DIR/common.sh"

echo "=== validate_env() tests ==="
echo ""

# --- These tests require validate_env to be implemented ---
# They invoke run.sh --validate-only (added in Task 2) which runs
# check_dependencies + validate_env then exits 0 on success, 1 on failure.

echo "--- Numeric validation ---"
run_test "defaults pass (no overrides)"               0 \
    SKIP_CLAUDE_CHECK=1 -- --validate-only

run_test "WORK_AGENT_TIMEOUT=0 passes (disabled)"     0 \
    SKIP_CLAUDE_CHECK=1 WORK_AGENT_TIMEOUT=0 -- --validate-only

run_test "WORK_AGENT_TIMEOUT=300 passes"              0 \
    SKIP_CLAUDE_CHECK=1 WORK_AGENT_TIMEOUT=300 -- --validate-only

run_test "WORK_AGENT_TIMEOUT=abc fails"               1 \
    SKIP_CLAUDE_CHECK=1 WORK_AGENT_TIMEOUT=abc -- --validate-only

run_test "WORK_AGENT_TIMEOUT=-5 fails (below min 0)"  1 \
    SKIP_CLAUDE_CHECK=1 WORK_AGENT_TIMEOUT=-5 -- --validate-only

run_test "MAX_CONSECUTIVE_FAILURES=0 fails (min 1)"   1 \
    SKIP_CLAUDE_CHECK=1 MAX_CONSECUTIVE_FAILURES=0 -- --validate-only

run_test "MAX_CONSECUTIVE_FAILURES=abc fails"         1 \
    SKIP_CLAUDE_CHECK=1 MAX_CONSECUTIVE_FAILURES=abc -- --validate-only

run_test "MAX_STALE_CYCLES=1 passes"                  0 \
    SKIP_CLAUDE_CHECK=1 MAX_STALE_CYCLES=1 -- --validate-only

run_test "MAX_STALE_CYCLES=0 fails (min 1)"           1 \
    SKIP_CLAUDE_CHECK=1 MAX_STALE_CYCLES=0 -- --validate-only

run_test "MAX_WORK_CYCLES=0 passes (unlimited)"       0 \
    SKIP_CLAUDE_CHECK=1 MAX_WORK_CYCLES=0 -- --validate-only

run_test "MAX_WORK_CYCLES=10 passes"                  0 \
    SKIP_CLAUDE_CHECK=1 MAX_WORK_CYCLES=10 -- --validate-only

run_test "MAX_WORK_CYCLES=-1 fails (min 0)"           1 \
    SKIP_CLAUDE_CHECK=1 MAX_WORK_CYCLES=-1 -- --validate-only

run_test "MAX_EMPTY_TASK_CYCLES=1 passes"             0 \
    SKIP_CLAUDE_CHECK=1 MAX_EMPTY_TASK_CYCLES=1 -- --validate-only

run_test "MAX_EMPTY_TASK_CYCLES=0 fails (min 1)"      1 \
    SKIP_CLAUDE_CHECK=1 MAX_EMPTY_TASK_CYCLES=0 -- --validate-only

run_test "leading zeros (0900) pass"                  0 \
    SKIP_CLAUDE_CHECK=1 WORK_AGENT_TIMEOUT=0900 -- --validate-only

echo ""
echo "--- CLAUDE_MODEL validation ---"
run_test "CLAUDE_MODEL=opus passes silently"          0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=opus -- --validate-only

run_test "CLAUDE_MODEL=sonnet passes silently"        0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet -- --validate-only

run_test "CLAUDE_MODEL=haiku passes silently"         0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=haiku -- --validate-only

run_test "CLAUDE_MODEL=claude-opus-4-5 passes"       0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=claude-opus-4-5 -- --validate-only

run_test "CLAUDE_MODEL='' fails (empty)"              1 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL='' -- --validate-only

run_test "CLAUDE_MODEL with spaces fails"             1 \
    SKIP_CLAUDE_CHECK=1 'CLAUDE_MODEL=my model' -- --validate-only

run_test "CLAUDE_MODEL=gpt4 passes with warning"      0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=gpt4 -- --validate-only

echo ""
echo "--- DOCS_DIR validation ---"
run_test "DOCS_DIR=/nonexistent/path fails"             1 \
    SKIP_CLAUDE_CHECK=1 DOCS_DIR=/nonexistent/path -- --validate-only

_tmpdir=$(mktemp -d)
run_test "DOCS_DIR=valid directory passes"              0 \
    SKIP_CLAUDE_CHECK=1 "DOCS_DIR=$_tmpdir" -- --validate-only
rmdir "$_tmpdir"

echo ""
echo "--- Config logging ---"
config_output=$(env SKIP_CLAUDE_CHECK=1 bash "$RUN_SH" --validate-only 2>&1 || true)
assert_contains "config log shows model"    "$config_output" "Model:"
assert_contains "config log shows timeout"  "$config_output" "Agent timeout:"
assert_contains "config log shows cycles"   "$config_output" "Max work cycles:"

echo ""
echo "--- Multiple errors reported together ---"
multi_output=$(env SKIP_CLAUDE_CHECK=1 WORK_AGENT_TIMEOUT=abc MAX_CONSECUTIVE_FAILURES=0 bash "$RUN_SH" --validate-only 2>&1 || true)
assert_contains "multiple errors: first"   "$multi_output" "WORK_AGENT_TIMEOUT"
assert_contains "multiple errors: second"  "$multi_output" "MAX_CONSECUTIVE_FAILURES"

echo ""
echo "--- JOURNAL_KEEP_LINES validation ---"
run_test "JOURNAL_KEEP_LINES=abc fails (non-integer)"        1 \
    SKIP_CLAUDE_CHECK=1 JOURNAL_KEEP_LINES=abc -- --validate-only

run_test "JOURNAL_KEEP_LINES=0 fails (below min 1)"          1 \
    SKIP_CLAUDE_CHECK=1 JOURNAL_KEEP_LINES=0 -- --validate-only

run_test "JOURNAL_KEEP_LINES=500 fails (equal to max)"       1 \
    SKIP_CLAUDE_CHECK=1 JOURNAL_KEEP_LINES=500 -- --validate-only

run_test "JOURNAL_KEEP_LINES=600 fails (above max)"          1 \
    SKIP_CLAUDE_CHECK=1 JOURNAL_KEEP_LINES=600 -- --validate-only

run_test "JOURNAL_KEEP_LINES=499 passes (one below max)"     0 \
    SKIP_CLAUDE_CHECK=1 JOURNAL_KEEP_LINES=499 -- --validate-only

run_test "JOURNAL_KEEP_LINES=300 passes (default value)"     0 \
    SKIP_CLAUDE_CHECK=1 JOURNAL_KEEP_LINES=300 -- --validate-only

echo ""
echo "--- Notification config logging ---"
notify_output=$(env SKIP_CLAUDE_CHECK=1 \
    NOTIFY_WEBHOOK_URL="https://hooks.example.com/services/TOKEN" \
    bash "$RUN_SH" --validate-only 2>&1 || true)
assert_contains "validate_env logs webhook host (not token)" \
    "$notify_output" "hooks.example.com/..."
assert_contains "validate_env logs NOTIFY_ON" \
    "$notify_output" "Notify on:"

no_notify_output=$(env SKIP_CLAUDE_CHECK=1 \
    NOTIFY_WEBHOOK_URL="" \
    bash "$RUN_SH" --validate-only 2>&1 || true)
assert_contains "validate_env shows disabled when URL empty" \
    "$no_notify_output" "(disabled)"

echo ""
echo "--- CLAUDE_MODEL_FALLBACK validation ---"
run_test "CLAUDE_MODEL_FALLBACK=sonnet,haiku passes"                0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL_FALLBACK=sonnet,haiku -- --validate-only

run_test "CLAUDE_MODEL_FALLBACK='' passes (disabled)"              0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL_FALLBACK='' -- --validate-only

run_test "CLAUDE_MODEL_FALLBACK with empty token fails"            1 \
    SKIP_CLAUDE_CHECK=1 'CLAUDE_MODEL_FALLBACK=opus,,haiku' -- --validate-only

run_test "CLAUDE_MODEL_FALLBACK with unsafe chars fails"           1 \
    SKIP_CLAUDE_CHECK=1 'CLAUDE_MODEL_FALLBACK=opus;rm' -- --validate-only

run_test "CLAUDE_MODEL_FALLBACK with pipe char fails"              1 \
    SKIP_CLAUDE_CHECK=1 'CLAUDE_MODEL_FALLBACK=opus|cat' -- --validate-only

run_test "CLAUDE_MODEL_FALLBACK duplicate warns but passes"        0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=opus CLAUDE_MODEL_FALLBACK=opus,sonnet -- --validate-only

run_test "CLAUDE_MODEL_FALLBACK unrecognized warns but passes"     0 \
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL_FALLBACK=gpt4,sonnet -- --validate-only

echo ""
echo "--- Model fallback config logging ---"
fb_output=$(env SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL_FALLBACK=sonnet,haiku \
    bash "$RUN_SH" --validate-only 2>&1 || true)
assert_contains "config log shows fallback chain" "$fb_output" "sonnet,haiku"

fb_disabled_output=$(env SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL_FALLBACK="" \
    bash "$RUN_SH" --validate-only 2>&1 || true)
assert_contains "config log shows fallback disabled" "$fb_disabled_output" "(disabled)"

echo ""
echo "--- RALPH_BUDGET_LIMIT validation ---"
run_test "RALPH_BUDGET_LIMIT unset passes"                0 \
    SKIP_CLAUDE_CHECK=1 -- --validate-only

run_test "RALPH_BUDGET_LIMIT=50.00 passes"                0 \
    SKIP_CLAUDE_CHECK=1 RALPH_BUDGET_LIMIT=50.00 -- --validate-only

run_test "RALPH_BUDGET_LIMIT=0.01 passes"                 0 \
    SKIP_CLAUDE_CHECK=1 RALPH_BUDGET_LIMIT=0.01 -- --validate-only

run_test "RALPH_BUDGET_LIMIT=0 fails (not positive)"      1 \
    SKIP_CLAUDE_CHECK=1 RALPH_BUDGET_LIMIT=0 -- --validate-only

run_test "RALPH_BUDGET_LIMIT=-5 fails (negative)"         1 \
    SKIP_CLAUDE_CHECK=1 RALPH_BUDGET_LIMIT=-5 -- --validate-only

run_test "RALPH_BUDGET_LIMIT=abc fails (non-numeric)"     1 \
    SKIP_CLAUDE_CHECK=1 RALPH_BUDGET_LIMIT=abc -- --validate-only

run_test "RALPH_BUDGET_LIMIT with shell injection chars fails" 1 \
    SKIP_CLAUDE_CHECK=1 'RALPH_BUDGET_LIMIT=1;system("id")' -- --validate-only

run_test "RALPH_BUDGET_LIMIT with awk injection fails" 1 \
    SKIP_CLAUDE_CHECK=1 'RALPH_BUDGET_LIMIT=0+0; } BEGIN { system("id") }' -- --validate-only

run_test "RALPH_BUDGET_LIMIT='' (empty string) passes (treated as unset)" 0 \
    SKIP_CLAUDE_CHECK=1 RALPH_BUDGET_LIMIT='' -- --validate-only

# TRACK_TOKENS=false + RALPH_BUDGET_LIMIT set -> warns but does not fail
budget_warn_output=$(env SKIP_CLAUDE_CHECK=1 \
    TRACK_TOKENS=false RALPH_BUDGET_LIMIT=50.00 \
    bash "$RUN_SH" --validate-only 2>&1 || true)
assert_contains "warns when TRACK_TOKENS=false + RALPH_BUDGET_LIMIT set" \
    "$budget_warn_output" "TRACK_TOKENS"

# Config log shows budget limit when set
budget_log_output=$(env SKIP_CLAUDE_CHECK=1 \
    RALPH_BUDGET_LIMIT=25.00 \
    bash "$RUN_SH" --validate-only 2>&1 || true)
assert_contains "config log shows budget limit" \
    "$budget_log_output" "25.00"

print_summary "validate_env"
