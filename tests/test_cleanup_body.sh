#!/bin/bash
# Test: _do_cleanup() body — PID killing, file removal, tmp-glob cleanup (RL-034)
# Exercises the real cleanup actions, not just the re-entrancy guard.
# Usage: bash tests/test_cleanup_body.sh
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
# Test 1: PID cleanup kills background process
# -----------------------------------------------------------------------
echo ""
echo "=== Test 1: PID cleanup kills background process ==="

reset_cleanup_state
sleep 300 &
pid=$!

# Verify process is alive
kill -0 "$pid" 2>/dev/null
assert_equals "Background process is alive before cleanup" "$?" "0"

_cleanup_pids+=("$pid")
_do_cleanup

if kill -0 "$pid" 2>/dev/null; then
    fail "Process was killed by cleanup" "Process $pid is still alive"
else
    pass "Process was killed by cleanup"
fi

# -----------------------------------------------------------------------
# Test 2: File cleanup removes registered files
# -----------------------------------------------------------------------
echo ""
echo "=== Test 2: File cleanup removes registered files ==="

reset_cleanup_state
tmpfile1=$(mktemp)
tmpfile2=$(mktemp)
_cleanup_files+=("$tmpfile1" "$tmpfile2")
_do_cleanup

if [ ! -f "$tmpfile1" ] && [ ! -f "$tmpfile2" ]; then
    pass "Both registered files were removed"
else
    fail "Both registered files were removed" "File(s) still exist"
fi

# -----------------------------------------------------------------------
# Test 3: Tmp-glob cleanup removes *.tmp in STATE_DIR
# -----------------------------------------------------------------------
echo ""
echo "=== Test 3: Tmp-glob cleanup removes *.tmp in STATE_DIR ==="

reset_cleanup_state
touch "$STATE_DIR/a.tmp" "$STATE_DIR/b.tmp"
_do_cleanup

tmp_count=$(find "$STATE_DIR" -name '*.tmp' | wc -l | tr -d ' ')
assert_equals "No .tmp files remain in STATE_DIR" "$tmp_count" "0"

# -----------------------------------------------------------------------
# Test 4: Empty arrays produce no errors
# -----------------------------------------------------------------------
echo ""
echo "=== Test 4: Empty arrays produce no errors ==="

reset_cleanup_state
# _cleanup_pids and _cleanup_files are already empty from reset
# STATE_DIR has no .tmp files (cleaned in test 3)
exit_code=0
_do_cleanup || exit_code=$?
assert_equals "Exit code is 0 with empty arrays" "$exit_code" "0"

# -----------------------------------------------------------------------
# Test 5: File path with spaces is removed correctly
# -----------------------------------------------------------------------
echo ""
echo "=== Test 5: File path with spaces is removed correctly ==="

reset_cleanup_state
tmpfile_space=$(mktemp "/tmp/cleanup test XXXXXX")
_cleanup_files+=("$tmpfile_space")
_do_cleanup

if [ ! -f "$tmpfile_space" ]; then
    pass "File with spaces in path was removed"
else
    fail "File with spaces in path was removed" "File still exists: $tmpfile_space"
fi

# -----------------------------------------------------------------------
# Test 6: Already-dead PID in array causes no error
# -----------------------------------------------------------------------
echo ""
echo "=== Test 6: Already-dead PID in array causes no error ==="

reset_cleanup_state
sleep 0.01 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true

_cleanup_pids+=("$dead_pid")
exit_code=0
_do_cleanup || exit_code=$?
assert_equals "Exit code is 0 with already-dead PID" "$exit_code" "0"

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
print_summary "cleanup-body"
