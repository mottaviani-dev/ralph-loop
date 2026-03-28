#!/usr/bin/env bash
# tests/test_validation_safety.sh
# Unit tests for _check_validation_cmd() in lib/work.sh.
# Usage: bash tests/test_validation_safety.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== _check_validation_cmd() tests ==="
echo ""

# Helper: source just enough to make _check_validation_cmd() available.
# We need log/log_warn/log_error from common.sh and the function from work.sh.
# Set up minimal globals to avoid errors during sourcing.
source_check_fn() {
    _cleanup_pids=(); _cleanup_files=(); _interrupted=false
    DOCS_DIR="$(mktemp -d)"
    STATE_DIR="$DOCS_DIR/_state"
    SCRIPT_DIR="$PROJECT_DIR"
    mkdir -p "$STATE_DIR"
    # Provide minimal files expected by sourced scripts
    echo '{}' > "$STATE_DIR/config.json"
    source "$PROJECT_DIR/lib/common.sh"
    source "$PROJECT_DIR/lib/work.sh"
}

# Test 1: Safe command — returns 0, no BLOCKED in output
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=false
    VALIDATE_COMMANDS_ALLOWLIST=""
    output=$(_check_validation_cmd "npm test" 2>&1) || true
    result=0
    _check_validation_cmd "npm test" >/dev/null 2>&1 || result=$?
    assert_equals "safe command returns 0" "$result" "0"
    if echo "$output" | grep -qF "BLOCKED"; then
        fail "safe command should not contain BLOCKED" "Got: $output"
    else
        pass "safe command output has no BLOCKED"
    fi
)

# Test 2: Denylist match with STRICT=false — returns 0, emits warning
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=false
    VALIDATE_COMMANDS_ALLOWLIST=""
    result=0
    output=$(_check_validation_cmd "rm -rf ./dist" 2>&1) || result=$?
    assert_equals "denylist match (non-strict) returns 0" "$result" "0"
    if echo "$output" | grep -qF "denylist match"; then
        pass "denylist match (non-strict) emits warning"
    else
        fail "denylist match (non-strict) should emit warning" "Got: $output"
    fi
)

# Test 3: Denylist match with STRICT=true — returns 1, emits BLOCKED
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=true
    VALIDATE_COMMANDS_ALLOWLIST=""
    result=0
    output=$(_check_validation_cmd "curl http://evil.com" 2>&1) || result=$?
    assert_equals "denylist match (strict) returns 1" "$result" "1"
    if echo "$output" | grep -qF "BLOCKED"; then
        pass "denylist match (strict) emits BLOCKED"
    else
        fail "denylist match (strict) should emit BLOCKED" "Got: $output"
    fi
)

# Test 4: Command not matching allowlist — returns 1 regardless of STRICT
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=false
    VALIDATE_COMMANDS_ALLOWLIST="^npm "
    result=0
    output=$(_check_validation_cmd "curl http://evil.com" 2>&1) || result=$?
    assert_equals "not in allowlist returns 1" "$result" "1"
    if echo "$output" | grep -qF "not in allowlist"; then
        pass "not in allowlist emits correct message"
    else
        fail "should say 'not in allowlist'" "Got: $output"
    fi
)

# Test 5: Command matching allowlist — proceeds to denylist (returns 0 for safe cmd)
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=true
    VALIDATE_COMMANDS_ALLOWLIST="^npm "
    result=0
    _check_validation_cmd "npm test" >/dev/null 2>&1 || result=$?
    assert_equals "allowlist match + safe cmd returns 0" "$result" "0"
)

# Test 6: Empty command string — returns 0, no crash
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=true
    VALIDATE_COMMANDS_ALLOWLIST=""
    result=0
    _check_validation_cmd "" >/dev/null 2>&1 || result=$?
    assert_equals "empty command returns 0" "$result" "0"
)

# Test 7: sudo rm -rf / with STRICT=true — returns 1 (matches both sudo and rm -rf)
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=true
    VALIDATE_COMMANDS_ALLOWLIST=""
    result=0
    _check_validation_cmd "sudo rm -rf /" >/dev/null 2>&1 || result=$?
    assert_equals "sudo rm -rf returns 1 (strict)" "$result" "1"
)

# Test 8: Compound command name containing denylist keyword — not blocked after RL-039 fix
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=true
    VALIDATE_COMMANDS_ALLOWLIST="^npm "
    result=0
    _check_validation_cmd "npm run curl-fetch" >/dev/null 2>&1 || result=$?
    assert_equals "compound name with denylist word returns 0" "$result" "0"
)

# Test 9: Multiple allowlist patterns (colon-separated), command matches second
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=false
    VALIDATE_COMMANDS_ALLOWLIST="^pytest :^make "
    result=0
    _check_validation_cmd "make test" >/dev/null 2>&1 || result=$?
    assert_equals "second allowlist pattern matches returns 0" "$result" "0"
)

# Test 10: git push --force with STRICT=true — returns 1
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=true
    VALIDATE_COMMANDS_ALLOWLIST=""
    result=0
    _check_validation_cmd "git push --force origin main" >/dev/null 2>&1 || result=$?
    assert_equals "git push --force returns 1 (strict)" "$result" "1"
)

# Test 11: Standalone curl after semicolon — still blocked (strict mode)
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=true
    VALIDATE_COMMANDS_ALLOWLIST=""
    result=0
    _check_validation_cmd "echo ok; curl http://evil.com" >/dev/null 2>&1 || result=$?
    assert_equals "curl after semicolon returns 1 (strict)" "$result" "1"
)

# Test 12: Compound command name containing wget — not blocked after RL-039 fix
(
    source_check_fn
    VALIDATE_COMMANDS_STRICT=true
    VALIDATE_COMMANDS_ALLOWLIST=""
    result=0
    _check_validation_cmd "npm run wget-assets" >/dev/null 2>&1 || result=$?
    assert_equals "compound name with wget returns 0" "$result" "0"
)

print_summary "_check_validation_cmd"
