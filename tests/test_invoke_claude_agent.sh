#!/usr/bin/env bash
# tests/test_invoke_claude_agent.sh
# Unit tests for invoke_claude_agent() in lib/common.sh.
# Usage: bash tests/test_invoke_claude_agent.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== invoke_claude_agent tests ==="
echo ""

# Helper: set up minimal globals, source common.sh, then override stubs.
# Must be called at the start of each subshell test.
_setup() {
    USE_AGENTS="false"
    SUBAGENTS_FILE=""
    WORK_AGENT_TIMEOUT=60
    CLAUDE_MODEL="sonnet"
    SKIP_PERMISSIONS="false"
    ENABLE_MCP="false"
    MCP_CONFIG_FILE=""
    CLAUDE_ARGS=()
    _cleanup_files=()
    _cleanup_pids=()
    SKIP_CLAUDE_CHECK=1
    # Source common.sh to get invoke_claude_agent
    source "$PROJECT_DIR/lib/common.sh"
    # Override logging to silence output
    log() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warn() { :; }
}

# ── Test 1: run_with_timeout returns 0 → LAST_AGENT_STATUS="success" ────────
(
    _setup
    run_with_timeout() {
        local _t="$1"; shift
        echo "agent output for success"
        return 0
    }

    invoke_claude_agent "test prompt" "Test label" >/dev/null
    assert_equals "status is success on exit 0" "$LAST_AGENT_STATUS" "success"
)

# ── Test 2: run_with_timeout returns 124 → LAST_AGENT_STATUS="timeout" ──────
(
    _setup
    run_with_timeout() {
        local _t="$1"; shift
        echo "timed out output"
        return 124
    }

    invoke_claude_agent "test prompt" "Test label" >/dev/null
    assert_equals "status is timeout on exit 124" "$LAST_AGENT_STATUS" "timeout"
)

# ── Test 3: run_with_timeout returns 1 → LAST_AGENT_STATUS="failed" ─────────
(
    _setup
    run_with_timeout() {
        local _t="$1"; shift
        echo "error output"
        return 1
    }

    invoke_claude_agent "test prompt" "Test label" >/dev/null
    assert_equals "status is failed on exit 1" "$LAST_AGENT_STATUS" "failed"
)

# ── Test 4: LAST_AGENT_OUTPUT contains expected content ──────────────────────
(
    _setup
    run_with_timeout() {
        local _t="$1"; shift
        echo "expected agent output 42"
        return 0
    }

    invoke_claude_agent "test prompt" "Test label" >/dev/null
    assert_contains "LAST_AGENT_OUTPUT has expected content" "$LAST_AGENT_OUTPUT" "expected agent output 42"
)

# ── Test 5: USE_AGENTS=true + valid SUBAGENTS_FILE → --agents flag passed ────
(
    _setup
    TMPDIR_TEST=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_TEST"' EXIT

    echo '{"specialist":{}}' > "$TMPDIR_TEST/subagents.json"
    USE_AGENTS="true"
    SUBAGENTS_FILE="$TMPDIR_TEST/subagents.json"

    _captured_args=""
    run_with_timeout() {
        local _t="$1"; shift
        _captured_args="$*"
        echo "agents output"
        return 0
    }

    invoke_claude_agent "test prompt" "Test label" >/dev/null
    assert_contains "--agents flag is passed when USE_AGENTS=true" "$_captured_args" "--agents"
)

# ── Test 6: USE_AGENTS=false → no --agents flag ─────────────────────────────
(
    _setup

    _captured_args=""
    run_with_timeout() {
        local _t="$1"; shift
        _captured_args="$*"
        echo "no agents output"
        return 0
    }

    invoke_claude_agent "test prompt" "Test label" >/dev/null
    if echo "$_captured_args" | grep -qF -- "--agents"; then
        fail "--agents flag is NOT passed when USE_AGENTS=false" "Found --agents in: $_captured_args"
    else
        pass "--agents flag is NOT passed when USE_AGENTS=false"
    fi
)

# ── Test 7: Custom timeout overrides WORK_AGENT_TIMEOUT ─────────────────────
(
    _setup
    WORK_AGENT_TIMEOUT=999

    _captured_timeout=""
    run_with_timeout() {
        _captured_timeout="$1"; shift
        echo "custom timeout output"
        return 0
    }

    invoke_claude_agent "test prompt" "Test label" 42 >/dev/null
    assert_equals "custom timeout overrides WORK_AGENT_TIMEOUT" "$_captured_timeout" "42"
)

# ── Test 8: Missing prompt argument → non-zero exit ─────────────────────────
(
    _setup
    run_with_timeout() { :; }

    # ${1:?...} exits the shell, so we must run in a sub-subshell to capture
    local_exit=0
    ( invoke_claude_agent ) 2>/dev/null || local_exit=$?
    assert_equals "missing prompt argument returns non-zero" "$local_exit" "1"
)

# ── Test 9: LAST_AGENT_DURATION is set to a non-negative integer ──────────────
(
    _setup
    run_with_timeout() {
        local _t="$1"; shift
        echo "duration test output"
        return 0
    }

    invoke_claude_agent "test prompt" "Test label" >/dev/null
    if [ "$LAST_AGENT_DURATION" -ge 0 ] 2>/dev/null; then
        pass "LAST_AGENT_DURATION is a non-negative integer ($LAST_AGENT_DURATION)"
    else
        fail "LAST_AGENT_DURATION should be a non-negative integer" "Got: ${LAST_AGENT_DURATION:-unset}"
    fi
)

print_summary "invoke_claude_agent"
