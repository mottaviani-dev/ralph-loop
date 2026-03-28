#!/usr/bin/env bash
# tests/test_ensure_learnings_file.sh
# Unit tests for ensure_learnings_file() in lib/work.sh.
# Usage: bash tests/test_ensure_learnings_file.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== ensure_learnings_file() tests ==="
echo ""

# Stub logging and other dependencies before sourcing lib/work.sh
log() { :; }
log_warn() { :; }
log_error() { :; }
log_success() { :; }

# Pre-declare globals expected by lib/work.sh and lib/common.sh
_cleanup_pids=()
_cleanup_files=()
_interrupted=false
_consecutive_failure_count=0
_stale_cycle_count=0
_empty_task_cycle_count=0

# Source work.sh (and its dependency chain)
source "$PROJECT_DIR/lib/work.sh"

# Helper: create a temp state dir with the required variables set
setup_state_dir() {
    local dir
    dir=$(mktemp -d)
    # Create a fake journal so the guard passes
    touch "$dir/journal.md"
    echo "$dir"
}

# Test 1: Creates LEARNINGS.md with header when file is absent
(
    STATE=$(setup_state_dir)
    trap 'rm -rf "$STATE"' EXIT
    # shellcheck disable=SC2034
    DOCS_DIR="$STATE"
    # shellcheck disable=SC2034
    JOURNAL_FILE="$STATE/journal.md"
    ensure_learnings_file
    assert_equals "creates LEARNINGS.md when absent" "$(test -f "$STATE/LEARNINGS.md" && echo yes || echo no)" "yes"
)

# Test 2: Does not overwrite an existing LEARNINGS.md
(
    STATE=$(setup_state_dir)
    trap 'rm -rf "$STATE"' EXIT
    # shellcheck disable=SC2034
    DOCS_DIR="$STATE"
    # shellcheck disable=SC2034
    JOURNAL_FILE="$STATE/journal.md"
    echo "existing content" > "$STATE/LEARNINGS.md"
    ensure_learnings_file
    assert_equals "does not overwrite existing LEARNINGS.md" "$(cat "$STATE/LEARNINGS.md")" "existing content"
)

# Test 3: Returns 0 and does nothing when journal is absent
(
    STATE=$(mktemp -d)
    trap 'rm -rf "$STATE"' EXIT
    # shellcheck disable=SC2034
    DOCS_DIR="$STATE"
    # shellcheck disable=SC2034
    JOURNAL_FILE="$STATE/journal.md"   # does NOT exist
    result=0
    ensure_learnings_file || result=$?
    assert_equals "returns 0 when journal is absent" "$result" "0"
    assert_equals "does not create LEARNINGS.md when journal absent" "$(test -f "$STATE/LEARNINGS.md" && echo yes || echo no)" "no"
)

print_summary "ensure_learnings_file"
