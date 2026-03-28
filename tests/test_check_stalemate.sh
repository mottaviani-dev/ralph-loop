#!/usr/bin/env bash
# tests/test_check_stalemate.sh
# Unit tests for check_stalemate() in lib/common.sh.
# Usage: bash tests/test_check_stalemate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== check_stalemate() tests ==="
echo ""

# Setup: temp git repo with initial commit
setup_git_repo() {
    local dir
    dir=$(mktemp -d)
    git init -q "$dir"
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    echo "initial" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "init"
    echo "$dir"
}

# Each test case runs in a subshell to isolate globals.

# Test 1: Counter increments on consecutive stale calls
(
    REPO=$(setup_git_repo)
    trap 'rm -rf "$REPO"' EXIT
    cd "$REPO"
    _cleanup_pids=(); _cleanup_files=(); _interrupted=false
    DOCS_DIR="$REPO"
    _stale_cycle_count=0; _last_git_hash=""
    source "$PROJECT_DIR/lib/common.sh"
    MAX_STALE_CYCLES=5
    check_stalemate || true  # call 1 - hash set, count stays 0
    check_stalemate || true  # call 2 - same hash, count becomes 1
    assert_equals "stale counter increments to 1 after second stale call" "$_stale_cycle_count" "1"
)

# Test 2: Counter resets to 0 after a real file change
(
    REPO=$(setup_git_repo)
    trap 'rm -rf "$REPO"' EXIT
    cd "$REPO"
    _cleanup_pids=(); _cleanup_files=(); _interrupted=false
    DOCS_DIR="$REPO"
    _stale_cycle_count=0; _last_git_hash=""
    source "$PROJECT_DIR/lib/common.sh"
    MAX_STALE_CYCLES=5
    check_stalemate || true  # establishes baseline
    check_stalemate || true  # stale: count=1
    # Make a real change
    echo "changed" >> "$REPO/README.md"
    git -C "$REPO" add README.md
    check_stalemate || true  # change detected: count resets
    assert_equals "stale counter resets after real change" "$_stale_cycle_count" "0"
)

# Test 3: Returns 1 (abort signal) after MAX_STALE_CYCLES consecutive stale calls
(
    REPO=$(setup_git_repo)
    trap 'rm -rf "$REPO"' EXIT
    cd "$REPO"
    _cleanup_pids=(); _cleanup_files=(); _interrupted=false
    DOCS_DIR="$REPO"
    _stale_cycle_count=0; _last_git_hash=""
    source "$PROJECT_DIR/lib/common.sh"
    MAX_STALE_CYCLES=3
    check_stalemate || true   # baseline (count=0)
    check_stalemate || true   # count=1
    check_stalemate || true   # count=2
    result=0
    check_stalemate || result=$?  # count=3 >= MAX_STALE_CYCLES=3 -> returns 1
    assert_equals "returns 1 when stale count reaches MAX_STALE_CYCLES" "$result" "1"
)

# Test 4: Does NOT abort before threshold is reached
(
    REPO=$(setup_git_repo)
    trap 'rm -rf "$REPO"' EXIT
    cd "$REPO"
    _cleanup_pids=(); _cleanup_files=(); _interrupted=false
    DOCS_DIR="$REPO"
    _stale_cycle_count=0; _last_git_hash=""
    source "$PROJECT_DIR/lib/common.sh"
    MAX_STALE_CYCLES=3
    check_stalemate || true   # baseline
    check_stalemate || true   # count=1
    result=0
    check_stalemate || result=$?  # count=2 < 3 -> still returns 0
    assert_equals "does not abort before threshold" "$result" "0"
)

# Test 5: Counter resets after stale streak -> change -> stale again starts fresh
# shellcheck disable=SC2034 # DOCS_DIR and MAX_STALE_CYCLES consumed by sourced lib/common.sh
(
    REPO=$(setup_git_repo)
    trap 'rm -rf "$REPO"' EXIT
    cd "$REPO"
    _cleanup_pids=(); _cleanup_files=(); _interrupted=false
    DOCS_DIR="$REPO"
    _stale_cycle_count=0; _last_git_hash=""
    source "$PROJECT_DIR/lib/common.sh"
    MAX_STALE_CYCLES=5
    check_stalemate || true  # baseline
    check_stalemate || true  # count=1
    echo "change" >> "$REPO/README.md"; git -C "$REPO" add README.md
    check_stalemate || true  # reset: count=0
    check_stalemate || true  # count=1 again (fresh streak)
    assert_equals "counter restarts fresh after reset" "$_stale_cycle_count" "1"
)

print_summary "check_stalemate"
