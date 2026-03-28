#!/usr/bin/env bash
# tests/test_prompt_vars.sh
# Unit tests for apply_prompt_vars() in lib/common.sh.
# Usage: bash tests/test_prompt_vars.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== apply_prompt_vars tests ==="
echo ""

# Helper: minimal globals + source common.sh
_setup() {
    export DOCS_DIR="/tmp/test-docs-$$"
    mkdir -p "$DOCS_DIR"
    # Init a git repo with a commit so {{git_branch}} works
    git -C "$DOCS_DIR" init -q -b test-branch 2>/dev/null || {
        git -C "$DOCS_DIR" init -q 2>/dev/null
        git -C "$DOCS_DIR" checkout -b test-branch 2>/dev/null || true
    }
    git -C "$DOCS_DIR" config user.email "test@test.com"
    git -C "$DOCS_DIR" config user.name "Test"
    touch "$DOCS_DIR/.gitkeep"
    git -C "$DOCS_DIR" add . && git -C "$DOCS_DIR" commit -q -m "init" 2>/dev/null || true

    CLAUDE_MODEL="sonnet"
    SKIP_CLAUDE_CHECK=1
    SKIP_PERMISSIONS="false"
    ENABLE_MCP="false"
    MCP_CONFIG_FILE=""
    WORK_AGENT_TIMEOUT=60
    USE_AGENTS="false"
    SUBAGENTS_FILE=""
    CLAUDE_ARGS=()
    _cleanup_files=()
    _cleanup_pids=()
    STATE_DIR="$DOCS_DIR/_state"
    mkdir -p "$STATE_DIR"

    source "$PROJECT_DIR/lib/common.sh"
    # Silence logging
    log() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warn() { :; }
}

_teardown() {
    rm -rf "/tmp/test-docs-$$"
}

# ── Test 1: {{state_dir}} is resolved ──────────────────────────────────────
(
    _setup
    result=$(apply_prompt_vars "path={{state_dir}}/file" "work" "1")
    assert_equals "{{state_dir}} resolved to _state" "$result" "path=_state/file"
    _teardown
)

# ── Test 2: {{docs_dir}} is resolved ───────────────────────────────────────
(
    _setup
    result=$(apply_prompt_vars "root={{docs_dir}}" "work" "1")
    assert_equals "{{docs_dir}} resolved to DOCS_DIR" "$result" "root=$DOCS_DIR"
    _teardown
)

# ── Test 3: {{model}} is resolved ──────────────────────────────────────────
(
    _setup
    result=$(apply_prompt_vars "model={{model}}" "work" "1")
    assert_equals "{{model}} resolved to sonnet" "$result" "model=sonnet"
    _teardown
)

# ── Test 4: {{mode}} is resolved ───────────────────────────────────────────
(
    _setup
    result=$(apply_prompt_vars "mode={{mode}}" "discovery" "5")
    assert_equals "{{mode}} resolved to discovery" "$result" "mode=discovery"
    _teardown
)

# ── Test 5: {{cycle_num}} is resolved ──────────────────────────────────────
(
    _setup
    result=$(apply_prompt_vars "cycle={{cycle_num}}" "work" "42")
    assert_equals "{{cycle_num}} resolved to 42" "$result" "cycle=42"
    _teardown
)

# ── Test 6: {{git_branch}} is resolved ─────────────────────────────────────
(
    _setup
    result=$(apply_prompt_vars "branch={{git_branch}}" "work" "1")
    assert_equals "{{git_branch}} resolved to test-branch" "$result" "branch=test-branch"
    _teardown
)

# ── Test 7: {{timestamp}} is resolved (format check) ──────────────────────
(
    _setup
    result=$(apply_prompt_vars "ts={{timestamp}}" "work" "1")
    # Should match ISO 8601 UTC pattern: ts=YYYY-MM-DDTHH:MM:SSZ
    if echo "$result" | grep -qE '^ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
        pass "{{timestamp}} resolved to ISO 8601 UTC"
    else
        fail "{{timestamp}} format mismatch" "Got: $result"
    fi
    _teardown
)

# ── Test 8: RALPH_VAR_* env vars are resolved ─────────────────────────────
(
    _setup
    export RALPH_VAR_project="acme-api"
    result=$(apply_prompt_vars "project={{project}}" "work" "1")
    assert_equals "RALPH_VAR_project resolved" "$result" "project=acme-api"
    unset RALPH_VAR_project
    _teardown
)

# ── Test 9: Config file variables are resolved ─────────────────────────────
(
    _setup
    cat > "$DOCS_DIR/.ralph-loop.json" <<'EOF'
{
    "variables": {
        "env": "staging",
        "app_name": "test-app"
    }
}
EOF
    result=$(apply_prompt_vars "env={{env}} app={{app_name}}" "work" "1")
    assert_equals "Config file variables resolved" "$result" "env=staging app=test-app"
    _teardown
)

# ── Test 10: RALPH_VAR_* overrides config file ─────────────────────────────
(
    _setup
    cat > "$DOCS_DIR/.ralph-loop.json" <<'EOF'
{
    "variables": {
        "env": "staging"
    }
}
EOF
    export RALPH_VAR_env="production"
    result=$(apply_prompt_vars "env={{env}}" "work" "1")
    assert_equals "Env var overrides config file" "$result" "env=production"
    unset RALPH_VAR_env
    _teardown
)

# ── Test 11: Reserved names cannot be overridden by RALPH_VAR_* ────────────
(
    _setup
    export RALPH_VAR_state_dir="/evil/path"
    result=$(apply_prompt_vars "dir={{state_dir}}" "work" "1")
    assert_equals "Reserved state_dir not overridden by env" "$result" "dir=_state"
    unset RALPH_VAR_state_dir
    _teardown
)

# ── Test 12: Reserved names cannot be overridden by config file ────────────
(
    _setup
    cat > "$DOCS_DIR/.ralph-loop.json" <<'EOF'
{
    "variables": {
        "state_dir": "/evil/path",
        "model": "evil-model"
    }
}
EOF
    result=$(apply_prompt_vars "dir={{state_dir}} model={{model}}" "work" "1")
    assert_equals "Reserved names not overridden by config" "$result" "dir=_state model=sonnet"
    _teardown
)

# ── Test 13: Unresolved placeholders are left intact ───────────────────────
(
    _setup
    result=$(apply_prompt_vars "hello={{unknown_var}}" "work" "1")
    assert_equals "Unknown placeholder left intact" "$result" "hello={{unknown_var}}"
    _teardown
)

# ── Test 14: Multiple variables in one prompt ──────────────────────────────
(
    _setup
    export RALPH_VAR_foo="bar"
    export RALPH_VAR_baz="qux"
    result=$(apply_prompt_vars "{{foo}}-{{baz}}-{{state_dir}}" "work" "1")
    assert_equals "Multiple variables resolved" "$result" "bar-qux-_state"
    unset RALPH_VAR_foo RALPH_VAR_baz
    _teardown
)

# ── Test 15: Empty prompt returns empty ────────────────────────────────────
(
    _setup
    result=$(apply_prompt_vars "" "work" "1")
    assert_equals "Empty prompt returns empty" "$result" ""
    _teardown
)

# ── Test 16: Malformed config file is handled gracefully ───────────────────
(
    _setup
    echo "NOT JSON" > "$DOCS_DIR/.ralph-loop.json"
    # Should not crash — malformed config is skipped
    result=$(apply_prompt_vars "val={{state_dir}}" "work" "1" 2>/dev/null)
    assert_equals "Malformed config skipped gracefully" "$result" "val=_state"
    _teardown
)

# ── Test 17: Config file without variables key works ───────────────────────
(
    _setup
    echo '{"other_key": "value"}' > "$DOCS_DIR/.ralph-loop.json"
    result=$(apply_prompt_vars "val={{state_dir}}" "work" "1")
    assert_equals "Config without variables key works" "$result" "val=_state"
    _teardown
)

# ── Test 18: No recursive expansion ───────────────────────────────────────
(
    _setup
    export RALPH_VAR_a='{{state_dir}}'
    result=$(apply_prompt_vars "val={{a}}" "work" "1")
    # Should be literal {{state_dir}}, not _state (no recursive expansion)
    assert_equals "No recursive expansion" "$result" 'val={{state_dir}}'
    unset RALPH_VAR_a
    _teardown
)

# ── Test 19: No config file is fine ───────────────────────────────────────
(
    _setup
    rm -f "$DOCS_DIR/.ralph-loop.json"
    result=$(apply_prompt_vars "val={{state_dir}}" "work" "1")
    assert_equals "Missing config file is fine" "$result" "val=_state"
    _teardown
)

print_summary "apply_prompt_vars"
