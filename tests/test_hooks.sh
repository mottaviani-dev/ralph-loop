#!/usr/bin/env bash
# tests/test_hooks.sh — Unit tests for run_hook() in lib/hooks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "=== run_hook() tests ==="
echo ""

enable_subshell_counters

# Shared stub dir for recording hook invocations
STUB_DIR=$(mktemp -d)
HOOK_LOG="$STUB_DIR/hook_calls.log"
touch "$HOOK_LOG"
export HOOK_LOG STUB_DIR

# Helper: source both libs in a fresh bash subshell and call run_hook with given env
call_run_hook() {
    # Usage: env KEY=VAL ... call_run_hook HOOK_NAME [EXTRA_KV...]
    local hook_name="$1"; shift
    env DOCS_DIR="${DOCS_DIR:-$(pwd)}" \
        RALPH_CYCLE_NUM="${RALPH_CYCLE_NUM:-0}" \
        RALPH_MODE="${RALPH_MODE:-work}" \
        RALPH_STATUS="${RALPH_STATUS:-}" \
        RALPH_HOOK_TIMEOUT="${RALPH_HOOK_TIMEOUT:-60}" \
        RALPH_HOOK_PRE_COMMIT_STRICT="${RALPH_HOOK_PRE_COMMIT_STRICT:-false}" \
        bash -c "
            _cleanup_pids=()
            _cleanup_files=()
            source '$SCRIPT_DIR/../lib/common.sh'
            source '$SCRIPT_DIR/../lib/hooks.sh'
            run_hook '$hook_name' $(printf "'%s' " "$@")
        "
}

reset_log() { : > "$HOOK_LOG"; }

echo "--- No-op when RALPH_HOOK_PRE_CYCLE is unset ---"

(
    reset_log
    exit_code=0
    call_run_hook "PRE_CYCLE" || exit_code=$?
    assert_equals "unset hook: returns 0" "$exit_code" "0"
)

echo "--- Hook executes when RALPH_HOOK_PRE_CYCLE is set ---"

(
    reset_log
    MARKER_FILE="$STUB_DIR/executed.marker"
    RALPH_HOOK_PRE_CYCLE="touch '$MARKER_FILE'" \
        call_run_hook "PRE_CYCLE"
    assert_file_exists "hook: marker file created" "$MARKER_FILE"
)

echo "--- Context vars injected into hook subprocess ---"

(
    reset_log
    OUTPUT_FILE="$STUB_DIR/ctx_output.txt"
    RALPH_HOOK_PRE_CYCLE="echo \"\$RALPH_CYCLE_NUM:\$RALPH_MODE\" > '$OUTPUT_FILE'" \
    RALPH_CYCLE_NUM="42" \
    RALPH_MODE="discovery" \
        call_run_hook "PRE_CYCLE"
    content=$(cat "$OUTPUT_FILE" 2>/dev/null || echo "")
    assert_contains "context: cycle num injected" "$content" "42"
    assert_contains "context: mode injected" "$content" "discovery"
)

echo "--- Non-strict hook failure is swallowed ---"

(
    reset_log
    exit_code=0
    RALPH_HOOK_POST_CYCLE="exit 1" \
        call_run_hook "POST_CYCLE" || exit_code=$?
    assert_equals "non-strict fail: returns 0" "$exit_code" "0"
)

echo "--- PRE_COMMIT strict mode propagates non-zero exit ---"

(
    reset_log
    exit_code=0
    RALPH_HOOK_PRE_COMMIT="exit 1" \
    RALPH_HOOK_PRE_COMMIT_STRICT="true" \
        call_run_hook "PRE_COMMIT" || exit_code=$?
    assert_equals "strict pre-commit fail: returns 1" "$exit_code" "1"
)

echo "--- PRE_COMMIT non-strict (default) swallows failure ---"

(
    reset_log
    exit_code=0
    RALPH_HOOK_PRE_COMMIT="exit 1" \
    RALPH_HOOK_PRE_COMMIT_STRICT="false" \
        call_run_hook "PRE_COMMIT" || exit_code=$?
    assert_equals "non-strict pre-commit fail: returns 0" "$exit_code" "0"
)

echo "--- Hook timeout treated as failure (non-strict) ---"

(
    reset_log
    exit_code=0
    start=$(date +%s)
    RALPH_HOOK_PRE_CYCLE="sleep 30" \
    RALPH_HOOK_TIMEOUT="1" \
        call_run_hook "PRE_CYCLE" || exit_code=$?
    end=$(date +%s)
    elapsed=$((end - start))
    assert_equals "timeout: returns 0 (non-strict)" "$exit_code" "0"
    # Should complete in well under 30s (timeout was 1s)
    [ "$elapsed" -lt 10 ] || { echo "FAIL: timeout took ${elapsed}s (expected <10s)"; exit 1; }
    echo "  timeout elapsed: ${elapsed}s (pass)"
)

echo "--- Extra KEY=VAL args injected into hook subprocess ---"

(
    reset_log
    OUTPUT_FILE="$STUB_DIR/extra_env_output.txt"
    RALPH_HOOK_POST_CYCLE="echo \"\$RALPH_EXIT_CODE\" > '$OUTPUT_FILE'" \
        call_run_hook "POST_CYCLE" "RALPH_EXIT_CODE=42"
    content=$(cat "$OUTPUT_FILE" 2>/dev/null || echo "")
    assert_contains "extra env: RALPH_EXIT_CODE injected" "$content" "42"
)

# Cleanup
rm -rf "$STUB_DIR"

print_summary "run_hook"
