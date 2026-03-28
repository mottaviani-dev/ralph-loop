#!/bin/bash
# Test: _do_cleanup() SIGTERM→SIGKILL escalation, verbose logging, and timeout (RL-046)
# Exercises the new escalation and logging features in lib/cleanup.sh.
# Usage: bash tests/test_cleanup_escalation.sh
# Exit 0 = all tests passed, Exit 1 = failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Stub log_warn (defined in lib/common.sh, not sourced here)
log_warn() { echo "WARN: $*" >&2; }

source "$SCRIPT_DIR/../lib/cleanup.sh"
source "$SCRIPT_DIR/common.sh"

STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

# Helper: reset cleanup state between tests
reset_cleanup_state() {
    _cleanup_done=false
    _cleanup_pids=()
    _cleanup_files=()
    _interrupted=false
    RALPH_VERBOSE_CLEANUP=false
}

# -----------------------------------------------------------------------
# Test 1: SIGKILL escalation kills SIGTERM-ignoring process
# -----------------------------------------------------------------------
echo ""
echo "=== Test 1: SIGKILL escalation kills SIGTERM-ignoring process ==="

reset_cleanup_state
bash -c 'trap "" TERM; sleep 300' &
pid=$!

# Verify process is alive
kill -0 "$pid" 2>/dev/null
assert_equals "SIGTERM-ignoring process is alive before cleanup" "$?" "0"

_cleanup_pids+=("$pid")
_do_cleanup

# Wait briefly for background subshell to complete
sleep 1

if kill -0 "$pid" 2>/dev/null; then
    # Give it a bit more time (escalation takes ~2s)
    sleep 3
fi

if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    fail "SIGTERM-ignoring process was killed by escalation" "Process $pid is still alive"
else
    pass "SIGTERM-ignoring process was killed by escalation"
fi

# -----------------------------------------------------------------------
# Test 2: Verbose logging on — SIGTERM message appears
# -----------------------------------------------------------------------
echo ""
echo "=== Test 2: Verbose logging on — SIGTERM message appears ==="

reset_cleanup_state
RALPH_VERBOSE_CLEANUP=true
sleep 300 &
pid=$!

_cleanup_pids+=("$pid")
stderr_output=$(_do_cleanup 2>&1 1>/dev/null)

if echo "$stderr_output" | grep -qF "CLEANUP: sent SIGTERM to PID"; then
    pass "Verbose SIGTERM message appears on stderr"
else
    fail "Verbose SIGTERM message appears on stderr" "Got: $stderr_output"
fi

# -----------------------------------------------------------------------
# Test 3: Verbose logging off — no CLEANUP output
# -----------------------------------------------------------------------
echo ""
echo "=== Test 3: Verbose logging off — no CLEANUP output ==="

reset_cleanup_state
RALPH_VERBOSE_CLEANUP=false
sleep 300 &
pid=$!

_cleanup_pids+=("$pid")
stderr_output=$(_do_cleanup 2>&1 1>/dev/null)

if echo "$stderr_output" | grep -qF "CLEANUP:"; then
    fail "No CLEANUP messages when verbose is off" "Got: $stderr_output"
else
    pass "No CLEANUP messages when verbose is off"
fi

# -----------------------------------------------------------------------
# Test 4: Verbose file removal logging
# -----------------------------------------------------------------------
echo ""
echo "=== Test 4: Verbose file removal logging ==="

reset_cleanup_state
RALPH_VERBOSE_CLEANUP=true
tmpfile=$(mktemp)
_cleanup_files+=("$tmpfile")

stderr_output=$(_do_cleanup 2>&1 1>/dev/null)

if echo "$stderr_output" | grep -qF "CLEANUP: removed"; then
    pass "Verbose file removal message appears on stderr"
else
    fail "Verbose file removal message appears on stderr" "Got: $stderr_output"
fi

if [ -f "$tmpfile" ]; then
    fail "File was actually removed" "File still exists: $tmpfile"
else
    pass "File was actually removed"
fi

# -----------------------------------------------------------------------
# Test 5: Cleanup completes within timeout
# -----------------------------------------------------------------------
echo ""
echo "=== Test 5: Cleanup completes within timeout ==="

reset_cleanup_state
bash -c 'trap "" TERM; sleep 300' &
pid=$!

_cleanup_pids+=("$pid")

# Also register a file to verify file cleanup runs after timeout
tmpfile2=$(mktemp)
_cleanup_files+=("$tmpfile2")

start_time=$(date +%s)
_do_cleanup
end_time=$(date +%s)
elapsed=$((end_time - start_time))

if [ "$elapsed" -le 12 ]; then
    pass "Cleanup completed within 12 seconds (took ${elapsed}s)"
else
    fail "Cleanup completed within 12 seconds" "Took ${elapsed}s"
fi

if [ ! -f "$tmpfile2" ]; then
    pass "File cleanup ran after PID cleanup timeout"
else
    fail "File cleanup ran after PID cleanup timeout" "File still exists: $tmpfile2"
fi

# Kill the stubborn process in case it's still around
kill -9 "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
print_summary "cleanup-escalation"
