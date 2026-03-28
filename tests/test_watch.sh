#!/usr/bin/env bash
# tests/test_watch.sh
# Unit tests for lib/watch.sh helper functions.
# Usage: bash tests/test_watch.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== lib/watch.sh unit tests ==="
echo ""

# Stub logging functions required by sourced libs
log()         { :; }
log_warn()    { :; }
log_error()   { :; }
log_success() { :; }

# Pre-declare globals expected by lib/common.sh and lib/work.sh
_cleanup_pids=()
_cleanup_files=()
_interrupted=false
RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" NC=""

# Source only the file under test (watch.sh has no hard deps at source time)
# shellcheck source=../lib/watch.sh
source "$PROJECT_DIR/lib/watch.sh"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# _watch_check_loop_alive() — lock directory absent
# ---------------------------------------------------------------------------
(
    STATE_DIR="$TMPDIR_BASE/state_nolock"
    mkdir -p "$STATE_DIR"
    # No .ralph-loop.lock dir created
    result=$(_watch_check_loop_alive)
    assert_equals "_watch_check_loop_alive: no lock dir → not_running" "$result" "not_running"
)

# ---------------------------------------------------------------------------
# _watch_check_loop_alive() — stale lock (dead PID)
# ---------------------------------------------------------------------------
(
    STATE_DIR="$TMPDIR_BASE/state_stale"
    mkdir -p "$STATE_DIR/.ralph-loop.lock"
    # Use a PID that definitely does not exist
    echo "999999999" > "$STATE_DIR/.ralph-loop.lock/pid"
    result=$(_watch_check_loop_alive)
    assert_equals "_watch_check_loop_alive: dead PID → not_running" "$result" "not_running"
)

# ---------------------------------------------------------------------------
# _watch_check_loop_alive() — live lock (self PID)
# ---------------------------------------------------------------------------
(
    STATE_DIR="$TMPDIR_BASE/state_live"
    mkdir -p "$STATE_DIR/.ralph-loop.lock"
    echo "$$" > "$STATE_DIR/.ralph-loop.lock/pid"
    result=$(_watch_check_loop_alive)
    assert_equals "_watch_check_loop_alive: live PID → own PID" "$result" "$$"
)

# ---------------------------------------------------------------------------
# _watch_clear() — non-TTY output (stdout is not a terminal in tests)
# ---------------------------------------------------------------------------
(
    output=$(_watch_clear 2>&1)
    assert_contains "_watch_clear: non-TTY emits separator" "$output" "--- refresh ---"
)

# ---------------------------------------------------------------------------
# _watch_progress_bar() — output format
# ---------------------------------------------------------------------------

# 0/0: no output (guard condition)
(
    output=$(_watch_progress_bar 0 0 2>&1)
    assert_equals "_watch_progress_bar: 0/0 emits nothing" "$output" ""
)

# 3/6: half filled — should contain block and shade characters
(
    output=$(_watch_progress_bar 3 6)
    assert_contains "_watch_progress_bar: 3/6 contains fill blocks" "$output" "█"
    assert_contains "_watch_progress_bar: 3/6 contains shade blocks" "$output" "░"
    assert_contains "_watch_progress_bar: 3/6 shows count" "$output" "3/6"
)

# 6/6: fully filled — no shade characters
(
    output=$(_watch_progress_bar 6 6)
    assert_contains "_watch_progress_bar: 6/6 shows count" "$output" "6/6"
    # Bar should be entirely filled — no shade blocks
    if echo "$output" | grep -qF "░"; then
        fail "_watch_progress_bar: 6/6 should have no shade blocks"
    else
        pass "_watch_progress_bar: 6/6 has no shade blocks"
    fi
)

print_summary "watch"
