#!/usr/bin/env bash
# tests/test_log_format.sh — Tests for LOG_FORMAT and LOG_FILE env vars.
# Tests log() / log_success() / log_error() / log_warn() output in json/text modes,
# file capture behavior, and validate_env() checks for LOG_FORMAT.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "=== test_log_format.sh ==="
enable_subshell_counters

# ── Text mode (default) ──────────────────────────────────────────────────────

( # T1: log() default (text) contains bracketed timestamp and message
    output=$(LOG_FORMAT=text LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'hello world'
    " 2>&1)
    assert_contains "log() text: contains timestamp brackets" "$output" "["
    assert_contains "log() text: contains message" "$output" "hello world"
)

( # T2: log_error() text contains message
    output=$(LOG_FORMAT=text LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log_error 'something failed'
    " 2>&1)
    assert_contains "log_error() text: contains message" "$output" "something failed"
)

( # T3: log_warn() text contains message
    output=$(LOG_FORMAT=text LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log_warn 'heads up'
    " 2>&1)
    assert_contains "log_warn() text: contains message" "$output" "heads up"
)

( # T4: log_success() text contains message
    output=$(LOG_FORMAT=text LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log_success 'all good'
    " 2>&1)
    assert_contains "log_success() text: contains message" "$output" "all good"
)

# ── JSON mode ────────────────────────────────────────────────────────────────

( # T5: log() json produces valid JSON
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'hello json'
    " 2>&1)
    echo "$output" | jq empty 2>/dev/null \
        && pass "log() json: output is valid JSON" \
        || fail "log() json: output is not valid JSON" "$output"
)

( # T6: log() json has level=info
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'check level'
    " 2>&1)
    level=$(echo "$output" | jq -r '.level' 2>/dev/null)
    assert_equals "log() json: level is info" "$level" "info"
)

( # T7: log_error() json has level=error
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log_error 'bad thing'
    " 2>&1)
    level=$(echo "$output" | jq -r '.level' 2>/dev/null)
    assert_equals "log_error() json: level is error" "$level" "error"
)

( # T8: log_warn() json has level=warn
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log_warn 'be careful'
    " 2>&1)
    level=$(echo "$output" | jq -r '.level' 2>/dev/null)
    assert_equals "log_warn() json: level is warn" "$level" "warn"
)

( # T9: log_success() json has level=info (not "success")
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log_success 'done'
    " 2>&1)
    level=$(echo "$output" | jq -r '.level' 2>/dev/null)
    assert_equals "log_success() json: level is info" "$level" "info"
)

( # T10: JSON msg field matches input message
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'my test message'
    " 2>&1)
    msg=$(echo "$output" | jq -r '.msg' 2>/dev/null)
    assert_equals "log() json: msg field matches input" "$msg" "my test message"
)

( # T11: JSON ts field is non-empty
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'ts check'
    " 2>&1)
    ts=$(echo "$output" | jq -r '.ts' 2>/dev/null)
    [ -n "$ts" ] && [ "$ts" != "null" ] \
        && pass "log() json: ts field is non-empty" \
        || fail "log() json: ts field is empty or null" "$ts"
)

( # T12: JSON mode handles embedded double-quotes in message
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c '
        source '"'$ROOT_DIR/lib/common.sh'"'
        log "she said \"hello\""
    ' 2>&1)
    echo "$output" | jq empty 2>/dev/null \
        && pass "log() json: embedded quotes produce valid JSON" \
        || fail "log() json: embedded quotes broke JSON" "$output"
)

( # T13: JSON mode handles backslashes in message
    output=$(LOG_FORMAT=json LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'path: /foo\\\\bar'
    " 2>&1)
    echo "$output" | jq empty 2>/dev/null \
        && pass "log() json: backslashes produce valid JSON" \
        || fail "log() json: backslashes broke JSON" "$output"
)

# ── LOG_FILE file capture ────────────────────────────────────────────────────

( # T14: LOG_FILE text mode: file receives log line without ANSI codes
    tmpfile=$(mktemp)
    LOG_FORMAT=text LOG_FILE="$tmpfile" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'file capture test'
    " 2>&1
    file_content=$(cat "$tmpfile")
    assert_contains "LOG_FILE text: file receives message" "$file_content" "file capture test"
    # Must not contain ESC character (ANSI prefix) — check via cat -v which renders ESC as ^[
    if printf '%s' "$file_content" | cat -v | grep -qF '^['; then
        fail "LOG_FILE text: file contains ANSI escape codes" "$file_content"
    else
        pass "LOG_FILE text: file has no ANSI escape codes"
    fi
    rm -f "$tmpfile"
)

( # T15: LOG_FILE json mode: file receives valid JSON line
    tmpfile=$(mktemp)
    LOG_FORMAT=json LOG_FILE="$tmpfile" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'json file test'
    " 2>&1
    file_content=$(cat "$tmpfile")
    echo "$file_content" | jq empty 2>/dev/null \
        && pass "LOG_FILE json: file contains valid JSON" \
        || fail "LOG_FILE json: file JSON is invalid" "$file_content"
    rm -f "$tmpfile"
)

( # T16: LOG_FILE appends multiple lines
    tmpfile=$(mktemp)
    LOG_FORMAT=json LOG_FILE="$tmpfile" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'line one'
        log 'line two'
    " 2>&1
    line_count=$(wc -l < "$tmpfile" | tr -d ' ')
    assert_equals "LOG_FILE: appends multiple lines" "$line_count" "2"
    rm -f "$tmpfile"
)

( # T17: LOG_FILE missing: stdout still works (no crash)
    output=$(LOG_FORMAT=text LOG_FILE="" bash -c "
        source '$ROOT_DIR/lib/common.sh'
        log 'no file set'
    " 2>&1)
    assert_contains "no LOG_FILE: stdout output present" "$output" "no file set"
)

# ── validate_env LOG_FORMAT validation ──────────────────────────────────────

( # T18: invalid LOG_FORMAT triggers error exit
    RUN_SH="$ROOT_DIR/run.sh"
    output=$(LOG_FORMAT=yaml SKIP_CLAUDE_CHECK=1 \
        bash "$RUN_SH" --validate-only 2>&1) || true
    assert_contains "validate_env: invalid LOG_FORMAT triggers error" \
        "$output" "LOG_FORMAT"
)

( # T19: LOG_FORMAT=json passes validate_env (no error about LOG_FORMAT)
    RUN_SH="$ROOT_DIR/run.sh"
    output=$(LOG_FORMAT=json SKIP_CLAUDE_CHECK=1 \
        bash "$RUN_SH" --validate-only 2>&1) || true
    if echo "$output" | grep -q "LOG_FORMAT.*invalid\|invalid.*LOG_FORMAT"; then
        fail "validate_env: LOG_FORMAT=json should not produce error" "$output"
    else
        pass "validate_env: LOG_FORMAT=json accepted"
    fi
)

print_summary "test_log_format"
