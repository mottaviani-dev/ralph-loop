#!/bin/bash
# Test: _do_cleanup() re-entrancy guard (RL-031)
# Verifies that _do_cleanup executes its body exactly once even when both
# signal traps and the EXIT trap fire on the same signal.
# Usage: bash tests/test_cleanup_guard.sh
# Exit 0 = all tests passed, Exit 1 = failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# -----------------------------------------------------------------------
# Helper: build a minimal script that defines the guard-protected
# _do_cleanup, registers traps, and writes a counter to a temp file.
# The counter file lets us observe subshell increments from the parent.
# -----------------------------------------------------------------------
build_cleanup_script() {
    local counter_file="$1"
    local action="${2:-}"  # optional: "kill-int", "kill-term", or empty (normal exit)
    cat <<SCRIPT
set -e
_cleanup_done=false
_cleanup_pids=()
_cleanup_files=()
_interrupted=false

_do_cleanup() {
    [ "\$_cleanup_done" = true ] && return
    _cleanup_done=true
    set +e
    # Increment counter file
    local c; c=\$(cat "$counter_file"); echo \$((c + 1)) > "$counter_file"
}

trap '_do_cleanup' EXIT
trap '_interrupted=true; _do_cleanup; exit 130' INT
trap '_interrupted=true; _do_cleanup; exit 143' TERM

SCRIPT

    case "$action" in
        kill-int)
            echo 'kill -INT "$$"'
            echo 'sleep 1  # should not reach here'
            ;;
        kill-term)
            echo 'kill -TERM "$$"'
            echo 'sleep 1  # should not reach here'
            ;;
        "")
            echo '# Normal exit — EXIT trap fires'
            echo 'exit 0'
            ;;
    esac
}

# -----------------------------------------------------------------------
# Test 1: SIGINT fires cleanup exactly once
# -----------------------------------------------------------------------
echo ""
echo "=== Test 1: SIGINT fires cleanup exactly once ==="

counter1=$(mktemp)
echo "0" > "$counter1"

exit_code1=0
bash -c "$(build_cleanup_script "$counter1" "kill-int")" 2>/dev/null || exit_code1=$?

count1=$(cat "$counter1")
assert_equals "Cleanup counter is 1 after SIGINT" "$count1" "1"
assert_equals "Exit code is 130 after SIGINT" "$exit_code1" "130"
rm -f "$counter1"

# -----------------------------------------------------------------------
# Test 2: SIGTERM fires cleanup exactly once
# -----------------------------------------------------------------------
echo ""
echo "=== Test 2: SIGTERM fires cleanup exactly once ==="

counter2=$(mktemp)
echo "0" > "$counter2"

exit_code2=0
bash -c "$(build_cleanup_script "$counter2" "kill-term")" 2>/dev/null || exit_code2=$?

count2=$(cat "$counter2")
assert_equals "Cleanup counter is 1 after SIGTERM" "$count2" "1"
assert_equals "Exit code is 143 after SIGTERM" "$exit_code2" "143"
rm -f "$counter2"

# -----------------------------------------------------------------------
# Test 3: Normal exit fires cleanup exactly once
# -----------------------------------------------------------------------
echo ""
echo "=== Test 3: Normal exit fires cleanup exactly once ==="

counter3=$(mktemp)
echo "0" > "$counter3"

exit_code3=0
bash -c "$(build_cleanup_script "$counter3" "")" 2>/dev/null || exit_code3=$?

count3=$(cat "$counter3")
assert_equals "Cleanup counter is 1 after normal exit" "$count3" "1"
assert_equals "Exit code is 0 after normal exit" "$exit_code3" "0"
rm -f "$counter3"

# -----------------------------------------------------------------------
# Test 4: Direct call after guard is set is a no-op
# -----------------------------------------------------------------------
echo ""
echo "=== Test 4: Direct call after guard is a no-op ==="

counter4=$(mktemp)
echo "0" > "$counter4"

exit_code4=0
bash -c "
set -e
_cleanup_done=false
_cleanup_pids=()
_cleanup_files=()
_interrupted=false

_do_cleanup() {
    [ \"\$_cleanup_done\" = true ] && return
    _cleanup_done=true
    set +e
    local c; c=\$(cat \"$counter4\"); echo \$((c + 1)) > \"$counter4\"
}

# No traps — we test the guard directly
_do_cleanup   # first call: should increment
_do_cleanup   # second call: guard blocks — no increment
" 2>/dev/null || exit_code4=$?

count4=$(cat "$counter4")
assert_equals "Cleanup counter is 1 after two direct calls" "$count4" "1"
assert_equals "Exit code is 0" "$exit_code4" "0"
rm -f "$counter4"

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
print_summary "cleanup-guard"
