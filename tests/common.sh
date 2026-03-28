#!/usr/bin/env bash
# tests/common.sh — Shared bash test harness for ralph-loop.
# Source this file from any bash test script.
# Pattern: run each test case in a subshell ( ... ) to isolate global state.

export LOG_FORMAT=text  # ensure text format for all test assertions
export LOG_FILE=""       # ensure no file capture during tests

PASS=0
FAIL=0

# File-based counters for subshell-safe test tracking.
# When tests run in ( ) subshells, shell variable increments are lost.
# Call enable_subshell_counters before any subshell tests.
_COUNTER_DIR=""

enable_subshell_counters() {
    _COUNTER_DIR=$(mktemp -d)
    echo "0" > "$_COUNTER_DIR/pass"
    echo "0" > "$_COUNTER_DIR/fail"
}

pass() {
    echo "  PASS: $1"
    if [ -n "$_COUNTER_DIR" ]; then
        local c; c=$(cat "$_COUNTER_DIR/pass"); echo $((c + 1)) > "$_COUNTER_DIR/pass"
    else
        PASS=$((PASS + 1))
    fi
}

fail() {
    echo "  FAIL: $1"; echo "        ${2:-}"
    if [ -n "$_COUNTER_DIR" ]; then
        local c; c=$(cat "$_COUNTER_DIR/fail"); echo $((c + 1)) > "$_COUNTER_DIR/fail"
    else
        FAIL=$((FAIL + 1))
    fi
}

# run_test "description" expected_exit [ENV=val ...] -- [script args]
# Invokes bash "$RUN_SH" (caller must export RUN_SH) with the given env overrides.
run_test() {
    local description="$1"
    local expected_exit="$2"
    shift 2
    local env_vars=()
    local run_args=()
    local past_separator=false
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            past_separator=true
        elif [ "$past_separator" = true ]; then
            run_args+=("$arg")
        else
            env_vars+=("$arg")
        fi
    done
    local actual_exit=0
    local output
    output=$(env "${env_vars[@]}" bash "$RUN_SH" "${run_args[@]}" 2>&1) || actual_exit=$?
    if [ "$actual_exit" -eq "$expected_exit" ]; then
        pass "$description"
    else
        fail "$description" "Expected exit $expected_exit, got $actual_exit. Output: $(echo "$output" | head -3)"
    fi
}

# assert_contains "description" "$output" "substring"
assert_contains() {
    local description="$1"
    local output="$2"
    local substring="$3"
    if echo "$output" | grep -qF -- "$substring"; then
        pass "$description"
    else
        fail "$description" "Substring not found: '$substring'"
    fi
}

# assert_equals "description" actual expected
assert_equals() {
    local description="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description" "Expected '$expected', got '$actual'"
    fi
}

# assert_file_exists "description" filepath
assert_file_exists() {
    local description="$1"
    local filepath="$2"
    if [ -f "$filepath" ]; then
        pass "$description"
    else
        fail "$description" "File not found: '$filepath'"
    fi
}

# assert_exit_code "description" expected_exit cmd [args...]
assert_exit_code() {
    local description="$1"
    local expected="$2"
    shift 2
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    assert_equals "$description" "$actual" "$expected"
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        pass "$label"
    else
        fail "$label — file not found: $path"
    fi
}

assert_dir_exists() {
    local label="$1" path="$2"
    if [ -d "$path" ]; then
        pass "$label"
    else
        fail "$label — directory not found: $path"
    fi
}

assert_not_empty() {
    local label="$1" value="$2"
    if [ -n "$value" ]; then
        pass "$label"
    else
        fail "$label — expected non-empty value"
    fi
}

# print_summary: print totals and exit non-zero if any failures.
# Call at end of every test file.
print_summary() {
    local suite="${1:-Tests}"
    local p="$PASS" f="$FAIL"
    if [ -n "$_COUNTER_DIR" ]; then
        p=$(cat "$_COUNTER_DIR/pass")
        f=$(cat "$_COUNTER_DIR/fail")
        rm -rf "$_COUNTER_DIR"
    fi
    echo ""
    echo "=== $suite: $p passed, $f failed ==="
    [ "$f" -eq 0 ]
}
