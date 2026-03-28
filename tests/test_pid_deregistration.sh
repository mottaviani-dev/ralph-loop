#!/usr/bin/env bash
# tests/test_pid_deregistration.sh
# Unit tests for _deregister_cleanup_pids() in lib/common.sh.
# Usage: bash tests/test_pid_deregistration.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# _cleanup_pids must exist before sourcing (declared globally in run.sh at runtime)
_cleanup_pids=()
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/common.sh"

# Assert _cleanup_pids matches expected values exactly.
# Usage: check_pids "description" expected_element...
# Pass zero expected elements to assert an empty array.
check_pids() {
    local description="$1"; shift
    local expected=("$@")
    local expected_len="${#expected[@]}"
    local actual_len="${#_cleanup_pids[@]}"

    local ok=true
    if [[ "$actual_len" -ne "$expected_len" ]]; then
        ok=false
    else
        local i
        for i in "${!expected[@]}"; do
            if [[ "${_cleanup_pids[$i]}" != "${expected[$i]}" ]]; then
                ok=false
                break
            fi
        done
    fi

    if [[ "$ok" == true ]]; then
        echo "  PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $description"
        echo "        Expected (len=$expected_len): [${expected[*]+"${expected[*]}"}]"
        echo "        Got      (len=$actual_len): [${_cleanup_pids[*]+"${_cleanup_pids[*]}"}]"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== _deregister_cleanup_pids() tests ==="
echo ""

echo "--- Normal deregistration ---"
_cleanup_pids=(100 200)
_deregister_cleanup_pids 100 200
check_pids "both PIDs removed, array empty"
# Expected: empty array

echo ""
echo "--- Prefix-collision safety ---"
_cleanup_pids=(12 123 456)
_deregister_cleanup_pids 12 99
check_pids "12 removed; 123 and 456 intact" "123" "456"
# With substring substitution: 123 → "3" (corrupted). Exact match must leave it untouched.

echo ""
echo "--- Empty-string compaction ---"
_cleanup_pids=("" "" 100 101)
_deregister_cleanup_pids 100 101
check_pids "both PIDs removed and empty slots compacted"
# With substring substitution: leaves ("" ""); exact match + compaction yields empty array.

print_summary "pid_deregistration"
