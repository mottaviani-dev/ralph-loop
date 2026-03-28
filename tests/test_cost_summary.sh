#!/usr/bin/env bash
# tests/test_cost_summary.sh
# Unit tests for show_cost_summary() in lib/common.sh.
# Usage: bash tests/test_cost_summary.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== show_cost_summary() tests ==="
echo ""

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Helper to source lib/common.sh with minimal globals
setup_env() {
    local tmpdir="$1"
    STATE_DIR="$tmpdir"
    FRONTIER_FILE="$tmpdir/frontier.json"
    CYCLE_LOG_FILE="$tmpdir/cycle-log.json"
    MAINTENANCE_STATE_FILE="$tmpdir/maintenance-state.json"
    TASKS_FILE="$tmpdir/tasks.json"
    WORK_STATE_FILE="$tmpdir/work-state.json"
    CLAUDE_MODEL="opus"
    WORK_AGENT_TIMEOUT=900
    MAX_CONSECUTIVE_FAILURES=3
    MAX_STALE_CYCLES=5
    MAX_WORK_CYCLES=0
    MAX_EMPTY_TASK_CYCLES=3
    MAX_DISCOVERY_CYCLES=0
    JOURNAL_KEEP_LINES=300
    JOURNAL_MAX_LINES=500
    ENABLE_MCP=false
    MCP_CONFIG_FILE=""
    SKIP_PERMISSIONS=true
    DOCS_DIR="$tmpdir"
    # shellcheck disable=SC2034
    SCRIPT_DIR="$PROJECT_DIR"
    SKIP_CLAUDE_CHECK=1
    TRACK_TOKENS=true
    _cleanup_pids=()
    _stale_cycle_count=0
    _last_git_hash=""
}

# ── Test 1: All entries have tokens → correct totals ──
(
    tmpdir=$(mktemp -d)
    setup_env "$tmpdir"
    source "$PROJECT_DIR/lib/common.sh"

    cat > "$CYCLE_LOG_FILE" <<'EOF'
{"cycles":[
  {"cycle":1,"type":"work","status":"success","tokens":{"input":1000,"output":500,"cache_read":200,"cache_created":100,"cost_usd":0.05}},
  {"cycle":2,"type":"work","status":"success","tokens":{"input":2000,"output":1000,"cache_read":400,"cache_created":200,"cost_usd":0.10}},
  {"cycle":3,"type":"discovery","status":"success","tokens":{"input":500,"output":250,"cache_read":100,"cache_created":50,"cost_usd":0.025}}
]}
EOF

    output=$(show_cost_summary 2>&1)
    exit_code=0

    assert_contains "all tokens: shows 3/3" "$output" "3 / 3"
    assert_contains "all tokens: shows work type" "$output" "work"
    assert_contains "all tokens: shows discovery type" "$output" "discovery"
    assert_contains "all tokens: shows total cost" "$output" "0.175"

    rm -rf "$tmpdir"
)

# ── Test 2: Mixed log (some with tokens, some without) ──
(
    tmpdir=$(mktemp -d)
    setup_env "$tmpdir"
    source "$PROJECT_DIR/lib/common.sh"

    cat > "$CYCLE_LOG_FILE" <<'EOF'
{"cycles":[
  {"cycle":1,"type":"work","status":"success","tokens":{"input":1000,"output":500,"cache_read":200,"cache_created":100,"cost_usd":0.05}},
  {"cycle":2,"type":"work","status":"failed"},
  {"cycle":3,"type":"discovery","status":"success","tokens":{"input":500,"output":250,"cache_read":100,"cache_created":50,"cost_usd":0.025}}
]}
EOF

    output=$(show_cost_summary 2>&1)

    assert_contains "mixed: shows 2/3" "$output" "2 / 3"
    assert_contains "mixed: shows total cost" "$output" "0.075"

    rm -rf "$tmpdir"
)

# ── Test 3: Missing cycle-log.json → error, non-zero exit ──
(
    tmpdir=$(mktemp -d)
    setup_env "$tmpdir"
    source "$PROJECT_DIR/lib/common.sh"

    # Remove cycle-log.json
    rm -f "$CYCLE_LOG_FILE"

    exit_code=0
    output=$(show_cost_summary 2>&1) || exit_code=$?

    assert_equals "missing log: non-zero exit" "$exit_code" "1"
    assert_contains "missing log: error message" "$output" "No cycle-log.json"

    rm -rf "$tmpdir"
)

# ── Test 4: Empty cycles array → zero totals, no crash ──
(
    tmpdir=$(mktemp -d)
    setup_env "$tmpdir"
    source "$PROJECT_DIR/lib/common.sh"

    echo '{"cycles":[]}' > "$CYCLE_LOG_FILE"

    exit_code=0
    output=$(show_cost_summary 2>&1) || exit_code=$?

    assert_equals "empty cycles: exits 0" "$exit_code" "0"
    assert_contains "empty cycles: shows 0/0" "$output" "0 / 0"
    assert_contains "empty cycles: no token data message" "$output" "No token data"

    rm -rf "$tmpdir"
)

# ── Test 5: Legacy entries (no tokens field) → clean read ──
(
    tmpdir=$(mktemp -d)
    setup_env "$tmpdir"
    source "$PROJECT_DIR/lib/common.sh"

    cat > "$CYCLE_LOG_FILE" <<'EOF'
{"cycles":[
  {"cycle":1,"type":"work","status":"success","duration_seconds":120},
  {"cycle":2,"type":"discovery","status":"success","duration_seconds":90}
]}
EOF

    exit_code=0
    output=$(show_cost_summary 2>&1) || exit_code=$?

    assert_equals "legacy entries: exits 0" "$exit_code" "0"
    assert_contains "legacy entries: shows 0/2" "$output" "0 / 2"
    assert_contains "legacy entries: no token data message" "$output" "No token data"

    rm -rf "$tmpdir"
)

print_summary "show_cost_summary"
