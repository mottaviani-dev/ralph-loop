#!/bin/bash
# Test: acquire_run_lock() atomic mkdir-based locking (RL-028, RL-030)
# Usage: bash tests/test_locking.sh
# Exit 0 = all tests passed, Exit 1 = failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# We need logging functions and acquire_run_lock from lib/common.sh.
# To avoid sourcing run.sh (which has side effects), source lib/common.sh
# directly after defining the globals it expects.
# shellcheck disable=SC2034 # consumed by sourced lib/common.sh
SKIP_CLAUDE_CHECK=1
_cleanup_pids=()
_cleanup_files=()

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# -----------------------------------------------------------------------
# Test 1: Lock acquired — creates lock directory with PID file
# -----------------------------------------------------------------------
echo ""
echo "=== Test 1: Lock acquired — creates lock dir with current PID ==="

tmp_state=$(mktemp -d)
CLEANUP_DIRS+=("$tmp_state")
# shellcheck disable=SC2034 # consumed by acquire_run_lock
STATE_DIR="$tmp_state"
_cleanup_files=()

acquire_run_lock

lock_dir="$tmp_state/.ralph-loop.lock"
pid_file="$lock_dir/pid"
if [ -d "$lock_dir" ]; then
    pass "Lock directory created"
else
    fail "Lock directory NOT created"
fi

if [ -f "$pid_file" ]; then
    pass "PID file created inside lock directory"
else
    fail "PID file NOT created inside lock directory"
fi

stored_pid=$(cat "$pid_file" 2>/dev/null || echo "")
assert_equals "PID file contains current PID" "$stored_pid" "$$"

# Clean up lock so it doesn't interfere with later tests
rm -rf "$lock_dir"

# -----------------------------------------------------------------------
# Test 2: Lock blocks concurrent run — exits 1 with error message
# -----------------------------------------------------------------------
echo ""
echo "=== Test 2: Lock blocks concurrent run ==="

tmp_state2=$(mktemp -d)
CLEANUP_DIRS+=("$tmp_state2")

# Set up a lock directory with a known live PID (use $$ — our own process)
mkdir -p "$tmp_state2/.ralph-loop.lock"
echo "$$" > "$tmp_state2/.ralph-loop.lock/pid"

# Run acquire_run_lock in a subshell — it should exit 1
output=""
exit_code=0
output=$(STATE_DIR="$tmp_state2" _cleanup_files=() bash -c '
    source "'"$SCRIPT_DIR"'/../lib/common.sh"
    acquire_run_lock
' 2>&1) || exit_code=$?

assert_equals "Exit code is 1 when lock held by live PID" "$exit_code" "1"
assert_contains "Error message mentions running instance" "$output" "Another ralph-loop instance is running"
assert_contains "Error message includes PID" "$output" "PID $$"

# -----------------------------------------------------------------------
# Test 3: Stale lock cleared — dead PID lock is reclaimed with warning
# -----------------------------------------------------------------------
echo ""
echo "=== Test 3: Stale lock cleared — dead PID lock reclaimed ==="

tmp_state3=$(mktemp -d)
CLEANUP_DIRS+=("$tmp_state3")

# Use a PID that is (almost certainly) not running.
# PID 99999 is unlikely to be alive; verify with kill -0.
dead_pid=99999
while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
done

# Create a stale lock directory with the dead PID
mkdir -p "$tmp_state3/.ralph-loop.lock"
echo "$dead_pid" > "$tmp_state3/.ralph-loop.lock/pid"

output3=""
exit_code3=0
output3=$(STATE_DIR="$tmp_state3" _cleanup_files=() bash -c '
    source "'"$SCRIPT_DIR"'/../lib/common.sh"
    acquire_run_lock
' 2>&1) || exit_code3=$?

assert_equals "Exit code is 0 when lock is stale" "$exit_code3" "0"
assert_contains "Warning about stale lock" "$output3" "Stale lock found"

# Verify the lock directory was reclaimed with the subshell's PID
new_pid=$(cat "$tmp_state3/.ralph-loop.lock/pid" 2>/dev/null || echo "")
if [ "$new_pid" != "$dead_pid" ] && [ -n "$new_pid" ]; then
    pass "Lock reclaimed with new PID ($new_pid != $dead_pid)"
else
    fail "Lock NOT reclaimed (still $new_pid)"
fi

# -----------------------------------------------------------------------
# Test 4: Cleanup removes lock directory — _cleanup_files[] integration
# -----------------------------------------------------------------------
echo ""
echo "=== Test 4: Cleanup removes lock directory on exit ==="

tmp_state4=$(mktemp -d)
CLEANUP_DIRS+=("$tmp_state4")

# Run acquire_run_lock in a subshell that exits normally.
# The EXIT trap in run.sh calls _do_cleanup which iterates _cleanup_files[].
# We simulate this by sourcing the minimal trap + cleanup logic.
bash -c '
    set -e
    _cleanup_pids=()
    _cleanup_files=()
    _interrupted=false
    _do_cleanup() {
        set +e
        for f in "${_cleanup_files[@]}"; do
            [ -z "$f" ] && continue
            rm -rf "$f" 2>/dev/null || true
        done
    }
    trap "_do_cleanup" EXIT
    STATE_DIR="'"$tmp_state4"'"
    source "'"$SCRIPT_DIR"'/../lib/common.sh"
    acquire_run_lock
    # Subshell exits here — EXIT trap fires _do_cleanup
' 2>/dev/null

lock_dir4="$tmp_state4/.ralph-loop.lock"
if [ ! -d "$lock_dir4" ]; then
    pass "Lock directory removed after exit (cleanup works)"
else
    fail "Lock directory still exists after exit (cleanup did NOT fire)"
fi

# -----------------------------------------------------------------------
# Test 5: Concurrent start — exactly one winner
# -----------------------------------------------------------------------
echo ""
echo "=== Test 5: Concurrent start — exactly one acquires lock ==="

if [ "${TEST_SKIP_CONCURRENT:-false}" = "true" ]; then
    echo "  SKIP: TEST_SKIP_CONCURRENT=true"
else
    tmp_state5=$(mktemp -d)
    CLEANUP_DIRS+=("$tmp_state5")

    # Use a ready-file to synchronise both subshells
    ready_file="$tmp_state5/.ready"

    # Spawn two subshells that wait for the ready signal, then race to acquire
    (
        STATE_DIR="$tmp_state5" _cleanup_files=() bash -c '
            source "'"$SCRIPT_DIR"'/../lib/common.sh"
            # Signal ready
            touch "'"$ready_file"'.a"
            # Wait for both to be ready (up to 5s)
            for i in $(seq 1 50); do
                [ -f "'"$ready_file"'.b" ] && break
                sleep 0.1
            done
            acquire_run_lock
        ' 2>/dev/null
    ) &
    pid_a=$!

    (
        STATE_DIR="$tmp_state5" _cleanup_files=() bash -c '
            source "'"$SCRIPT_DIR"'/../lib/common.sh"
            # Signal ready
            touch "'"$ready_file"'.b"
            # Wait for both to be ready (up to 5s)
            for i in $(seq 1 50); do
                [ -f "'"$ready_file"'.a" ] && break
                sleep 0.1
            done
            acquire_run_lock
        ' 2>/dev/null
    ) &
    pid_b=$!

    exit_a=0; wait "$pid_a" || exit_a=$?
    exit_b=0; wait "$pid_b" || exit_b=$?

    # Exactly one should succeed (exit 0) and one should fail (exit 1)
    winner_count=0
    [ "$exit_a" -eq 0 ] && winner_count=$((winner_count + 1))
    [ "$exit_b" -eq 0 ] && winner_count=$((winner_count + 1))

    if [ "$winner_count" -eq 1 ]; then
        pass "Exactly one instance acquired the lock (exits: $exit_a, $exit_b)"
    elif [ "$winner_count" -eq 0 ]; then
        # Both failed — possible timing issue, don't hard-fail
        fail "Neither instance acquired the lock (exits: $exit_a, $exit_b)"
    else
        fail "Both instances acquired the lock — TOCTOU race! (exits: $exit_a, $exit_b)"
    fi

    # Clean up the lock directory
    rm -rf "$tmp_state5/.ralph-loop.lock" 2>/dev/null || true
fi

# -----------------------------------------------------------------------
# Test 5a: Signal cleanup (SIGINT) — PID file removed on SIGINT
# -----------------------------------------------------------------------
echo ""
echo "=== Test 5a: Signal cleanup — PID file removed on SIGINT ==="

tmp_state5a=$(mktemp -d)
CLEANUP_DIRS+=("$tmp_state5a")
lock_dir5a="$tmp_state5a/.ralph-loop.lock"
sentinel5a="$tmp_state5a/ready"

bash -c '
    set +e
    _cleanup_pids=()
    _cleanup_files=()
    _interrupted=false
    _do_cleanup() {
        set +e
        for f in "${_cleanup_files[@]}"; do
            [ -z "$f" ] && continue
            rm -rf "$f" 2>/dev/null || true
        done
    }
    trap "_interrupted=true; _do_cleanup; exit 130" INT
    trap "_interrupted=true; _do_cleanup; exit 143" TERM
    trap "_do_cleanup" EXIT
    STATE_DIR="'"$tmp_state5a"'"
    source "'"$SCRIPT_DIR"'/../lib/common.sh"
    acquire_run_lock
    touch "'"$sentinel5a"'"
    kill -INT $$
' &
child5a=$!

attempts=0
while [ ! -f "$sentinel5a" ] && [ "$attempts" -lt 50 ]; do
    sleep 0.1; attempts=$((attempts + 1))
done

wait "$child5a" || true

if [ ! -d "$lock_dir5a" ]; then
    pass "Lock directory removed on SIGINT"
else
    fail "Lock directory still exists after SIGINT (cleanup did NOT fire)"
fi

# -----------------------------------------------------------------------
# Test 5b: Signal cleanup (SIGTERM) — PID file removed on SIGTERM
# -----------------------------------------------------------------------
echo ""
echo "=== Test 5b: Signal cleanup — PID file removed on SIGTERM ==="

tmp_state5b=$(mktemp -d)
CLEANUP_DIRS+=("$tmp_state5b")
lock_dir5b="$tmp_state5b/.ralph-loop.lock"
sentinel5b="$tmp_state5b/ready"

bash -c '
    set +e
    _cleanup_pids=()
    _cleanup_files=()
    _interrupted=false
    _do_cleanup() {
        set +e
        for f in "${_cleanup_files[@]}"; do
            [ -z "$f" ] && continue
            rm -rf "$f" 2>/dev/null || true
        done
    }
    trap "_interrupted=true; _do_cleanup; exit 130" INT
    trap "_interrupted=true; _do_cleanup; exit 143" TERM
    trap "_do_cleanup" EXIT
    STATE_DIR="'"$tmp_state5b"'"
    source "'"$SCRIPT_DIR"'/../lib/common.sh"
    acquire_run_lock
    touch "'"$sentinel5b"'"
    kill -TERM $$
' &
child5b=$!

attempts=0
while [ ! -f "$sentinel5b" ] && [ "$attempts" -lt 50 ]; do
    sleep 0.1; attempts=$((attempts + 1))
done

wait "$child5b" || true

if [ ! -d "$lock_dir5b" ]; then
    pass "Lock directory removed on SIGTERM"
else
    fail "Lock directory still exists after SIGTERM (cleanup did NOT fire)"
fi

# -----------------------------------------------------------------------
# Test 6: Empty PID file — treated as stale (not a live lock)
# -----------------------------------------------------------------------
echo ""
echo "=== Test 6: Empty PID file treated as stale ==="

tmp_state6=$(mktemp -d)
CLEANUP_DIRS+=("$tmp_state6")

# Create lock directory with an empty PID file (simulates disk-full write or manual corruption)
mkdir -p "$tmp_state6/.ralph-loop.lock"
printf "" > "$tmp_state6/.ralph-loop.lock/pid"

exit_code6=0
output6=$(STATE_DIR="$tmp_state6" _cleanup_files=() bash -c '
    source "'"$SCRIPT_DIR"'/../lib/common.sh"
    acquire_run_lock
' 2>&1) || exit_code6=$?

assert_equals "Exit code 0 on empty PID file" "$exit_code6" "0"
assert_contains "Stale warning emitted for empty PID" "$output6" "Stale lock found"
assert_contains "Stale warning mentions unknown PID" "$output6" "unknown"

# PID file should be overwritten with a valid numeric PID
new_pid6=$(cat "$tmp_state6/.ralph-loop.lock/pid" 2>/dev/null || echo "")
if [ -n "$new_pid6" ] && [ "$new_pid6" -eq "$new_pid6" ] 2>/dev/null; then
    pass "PID file overwritten with valid numeric PID after empty file"
else
    fail "PID file not overwritten with valid PID (got: '$new_pid6')"
fi

# -----------------------------------------------------------------------
# Test 7: Non-numeric PID file content — treated as stale (not a live lock)
# -----------------------------------------------------------------------
echo ""
echo "=== Test 7: Non-numeric PID file content treated as stale ==="

tmp_state7=$(mktemp -d)
CLEANUP_DIRS+=("$tmp_state7")

# Create lock directory with garbage text in the PID file
mkdir -p "$tmp_state7/.ralph-loop.lock"
echo "not-a-pid" > "$tmp_state7/.ralph-loop.lock/pid"

exit_code7=0
output7=$(STATE_DIR="$tmp_state7" _cleanup_files=() bash -c '
    source "'"$SCRIPT_DIR"'/../lib/common.sh"
    acquire_run_lock
' 2>&1) || exit_code7=$?

assert_equals "Exit code 0 on garbage PID file" "$exit_code7" "0"
assert_contains "Stale warning emitted for garbage PID" "$output7" "Stale lock found"

# PID file should be overwritten with a valid numeric PID
new_pid7=$(cat "$tmp_state7/.ralph-loop.lock/pid" 2>/dev/null || echo "")
if [ -n "$new_pid7" ] && [ "$new_pid7" -eq "$new_pid7" ] 2>/dev/null; then
    pass "PID file overwritten with valid numeric PID after garbage content"
else
    fail "PID file not overwritten with valid PID (got: '$new_pid7')"
fi

# -----------------------------------------------------------------------
# Deferred: Concurrent acquisition race (TOCTOU)
# -----------------------------------------------------------------------
# Intentionally not tested: two processes racing to acquire the lock
# simultaneously. acquire_run_lock() has an inherent TOCTOU window between
# the `kill -0` check and the `echo $$ > pid_file` write. Testing this
# reliably is impractical because the race window is microseconds wide —
# any test would be non-deterministic and flaky. The risk is acknowledged
# and documented here for future contributors.

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
print_summary "locking"
