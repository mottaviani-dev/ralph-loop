#!/usr/bin/env bash
# tests/test_summary.sh — Unit tests for show_summary() in lib/stats.sh
# Seeds a temp _state/cycle-log.json with known fixture data and asserts output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== show_summary() tests ==="
echo ""

# Shared fixture: 4 cycles — 2 work/success, 1 discovery/success, 1 work/timeout
FIXTURE='{
  "cycles": [
    {"cycle":1,"timestamp":"2024-01-01T00:00:00Z","duration_seconds":60,"status":"success","type":"work","action":"implement"},
    {"cycle":2,"timestamp":"2024-01-01T00:01:00Z","duration_seconds":120,"status":"success","type":"work","action":"test"},
    {"cycle":3,"timestamp":"2024-01-01T00:02:00Z","duration_seconds":90,"status":"success","type":"discovery"},
    {"cycle":4,"timestamp":"2024-01-01T00:03:00Z","duration_seconds":300,"status":"timeout","type":"work","action":"refactor"}
  ]
}'

# Helper: run show_summary against a given cycle-log content
run_summary() {
    local log_content="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    local state_dir="$tmpdir/_state"
    mkdir -p "$state_dir"
    echo "$log_content" > "$state_dir/cycle-log.json"

    # Source lib/stats.sh with CYCLE_LOG_FILE pointing at the temp file
    (
        CYCLE_LOG_FILE="$state_dir/cycle-log.json"
        # shellcheck source=lib/stats.sh
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary
    )
    local exit_code=$?
    rm -rf "$tmpdir"
    return $exit_code
}

# Test: missing cycle-log.json prints "No cycle data" and exits 0
(
    tmpdir=$(mktemp -d)
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary
    )
    exit_code=0
    (
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary >/dev/null 2>&1
    ) || exit_code=$?
    assert_equals "missing file exits 0" "$exit_code" "0"
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    ) || true
    assert_contains "missing file prints no-data message" "$output" "No cycle data"
    rm -rf "$tmpdir"
)

# Test: empty cycles array prints "No cycles recorded" and exits 0
(
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/_state"
    echo '{"cycles":[]}' > "$tmpdir/_state/cycle-log.json"
    exit_code=0
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    ) || exit_code=$?
    assert_equals "empty cycles exits 0" "$exit_code" "0"
    assert_contains "empty cycles prints no-cycles message" "$output" "No cycles"
    rm -rf "$tmpdir"
)

# Test: fixture data — total cycle count
(
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/_state"
    echo "$FIXTURE" > "$tmpdir/_state/cycle-log.json"
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    )
    assert_contains "total cycles shows 4" "$output" "4"
    rm -rf "$tmpdir"
)

# Test: fixture data — type breakdown shows work and discovery
(
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/_state"
    echo "$FIXTURE" > "$tmpdir/_state/cycle-log.json"
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    )
    assert_contains "by-type output contains 'work'" "$output" "work"
    assert_contains "by-type output contains 'discovery'" "$output" "discovery"
    rm -rf "$tmpdir"
)

# Test: fixture data — status breakdown shows success and timeout
(
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/_state"
    echo "$FIXTURE" > "$tmpdir/_state/cycle-log.json"
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    )
    assert_contains "by-status output contains 'success'" "$output" "success"
    assert_contains "by-status output contains 'timeout'" "$output" "timeout"
    rm -rf "$tmpdir"
)

# Test: fixture data — total duration is sum of all durations (60+120+90+300=570)
(
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/_state"
    echo "$FIXTURE" > "$tmpdir/_state/cycle-log.json"
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    )
    assert_contains "total duration shows 570" "$output" "570"
    rm -rf "$tmpdir"
)

# Test: fixture data — min duration is 60, max is 300
(
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/_state"
    echo "$FIXTURE" > "$tmpdir/_state/cycle-log.json"
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    )
    assert_contains "min duration shows 60" "$output" "60"
    assert_contains "max duration shows 300" "$output" "300"
    rm -rf "$tmpdir"
)

# Test: refinement cycle without 'cycle' field is counted correctly
(
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/_state"
    echo '{"cycles":[
      {"timestamp":"2024-01-01T00:00:00Z","duration_seconds":45,"status":"success","type":"refinement","service":"api"}
    ]}' > "$tmpdir/_state/cycle-log.json"
    exit_code=0
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    ) || exit_code=$?
    assert_equals "refinement cycle (no 'cycle' field) exits 0" "$exit_code" "0"
    assert_contains "refinement type shown" "$output" "refinement"
    rm -rf "$tmpdir"
)

# Test: banner/header is present in output
(
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/_state"
    echo "$FIXTURE" > "$tmpdir/_state/cycle-log.json"
    output=$(
        CYCLE_LOG_FILE="$tmpdir/_state/cycle-log.json"
        source "$SCRIPT_DIR/../lib/stats.sh"
        show_summary 2>&1
    )
    assert_contains "summary banner is present" "$output" "Summary"
    rm -rf "$tmpdir"
)

print_summary "summary"
