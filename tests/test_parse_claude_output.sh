#!/usr/bin/env bash
# tests/test_parse_claude_output.sh
# Unit tests for parse_claude_output() in lib/common.sh.
# Usage: bash tests/test_parse_claude_output.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== parse_claude_output() tests ==="
echo ""

# Source lib/common.sh with required globals
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Test 1: Valid JSON envelope → globals populated correctly ──
(
    tmpdir=$(mktemp -d)
    # Minimal env stubs for lib/common.sh
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
    SCRIPT_DIR="$PROJECT_DIR"
    SKIP_CLAUDE_CHECK=1
    TRACK_TOKENS=true
    _cleanup_pids=()
    _stale_cycle_count=0
    _last_git_hash=""

    source "$PROJECT_DIR/lib/common.sh"

    # Create a valid JSON envelope
    cat > "$tmpdir/output.json" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"duration_ms":2184,"num_turns":1,"result":"Hello from the agent","stop_reason":"end_turn","total_cost_usd":0.0734225,"usage":{"input_tokens":2,"cache_creation_input_tokens":11694,"cache_read_input_tokens":0,"output_tokens":13,"server_tool_use":{"web_search_requests":0}}}
EOF

    parse_claude_output "$tmpdir/output.json"

    assert_equals "valid JSON: _PARSED_RESULT" "$_PARSED_RESULT" "Hello from the agent"
    assert_equals "valid JSON: _PARSED_COST" "$_PARSED_COST" "0.0734225"
    assert_equals "valid JSON: _PARSED_INPUT" "$_PARSED_INPUT" "2"
    assert_equals "valid JSON: _PARSED_OUTPUT" "$_PARSED_OUTPUT" "13"
    assert_equals "valid JSON: _PARSED_CACHE_READ" "$_PARSED_CACHE_READ" "0"
    assert_equals "valid JSON: _PARSED_CACHE_CREATED" "$_PARSED_CACHE_CREATED" "11694"

    rm -rf "$tmpdir"
)

# ── Test 2: Malformed JSON → raw fallback, token globals empty ──
(
    tmpdir=$(mktemp -d)
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
    SCRIPT_DIR="$PROJECT_DIR"
    SKIP_CLAUDE_CHECK=1
    TRACK_TOKENS=true
    _cleanup_pids=()
    _stale_cycle_count=0
    _last_git_hash=""

    source "$PROJECT_DIR/lib/common.sh"

    echo "This is plain text, not JSON" > "$tmpdir/output.txt"

    parse_claude_output "$tmpdir/output.txt"

    assert_equals "malformed JSON: _PARSED_RESULT is raw" "$_PARSED_RESULT" "This is plain text, not JSON"
    assert_equals "malformed JSON: _PARSED_COST is empty" "$_PARSED_COST" ""
    assert_equals "malformed JSON: _PARSED_INPUT is empty" "$_PARSED_INPUT" ""
    assert_equals "malformed JSON: _PARSED_OUTPUT is empty" "$_PARSED_OUTPUT" ""

    rm -rf "$tmpdir"
)

# ── Test 3: TRACK_TOKENS=false → raw pass-through, token globals empty ──
(
    tmpdir=$(mktemp -d)
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
    SCRIPT_DIR="$PROJECT_DIR"
    SKIP_CLAUDE_CHECK=1
    TRACK_TOKENS=false
    _cleanup_pids=()
    _stale_cycle_count=0
    _last_git_hash=""

    source "$PROJECT_DIR/lib/common.sh"

    # Even with valid JSON, should not parse when tracking is off
    cat > "$tmpdir/output.json" <<'EOF'
{"type":"result","result":"Agent text","total_cost_usd":0.05,"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF

    parse_claude_output "$tmpdir/output.json"

    # Result should be the raw JSON string (not extracted .result)
    raw=$(cat "$tmpdir/output.json")
    assert_equals "TRACK_TOKENS=false: _PARSED_RESULT is raw" "$_PARSED_RESULT" "$raw"
    assert_equals "TRACK_TOKENS=false: _PARSED_COST is empty" "$_PARSED_COST" ""
    assert_equals "TRACK_TOKENS=false: _PARSED_INPUT is empty" "$_PARSED_INPUT" ""

    rm -rf "$tmpdir"
)

# ── Test 4: Empty .result field → raw fallback with warning ──
(
    tmpdir=$(mktemp -d)
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
    SCRIPT_DIR="$PROJECT_DIR"
    SKIP_CLAUDE_CHECK=1
    TRACK_TOKENS=true
    _cleanup_pids=()
    _stale_cycle_count=0
    _last_git_hash=""

    source "$PROJECT_DIR/lib/common.sh"

    # JSON envelope with null result
    echo '{"type":"result","result":null,"total_cost_usd":0.01}' > "$tmpdir/output.json"

    # Call directly so globals propagate; redirect stdout to capture warning
    parse_claude_output "$tmpdir/output.json" > "$tmpdir/parse_log.txt" 2>&1 || true

    # Should fall back to raw
    raw=$(cat "$tmpdir/output.json")
    assert_equals "null .result: _PARSED_RESULT is raw" "$_PARSED_RESULT" "$raw"
    assert_equals "null .result: _PARSED_COST is empty" "$_PARSED_COST" ""
    parse_log=$(cat "$tmpdir/parse_log.txt")
    assert_contains "null .result: warning logged" "$parse_log" "empty or missing"

    rm -rf "$tmpdir"
)

# ── Test 5: JSON with multiline .result → extracted correctly ──
(
    tmpdir=$(mktemp -d)
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
    SCRIPT_DIR="$PROJECT_DIR"
    SKIP_CLAUDE_CHECK=1
    TRACK_TOKENS=true
    _cleanup_pids=()
    _stale_cycle_count=0
    _last_git_hash=""

    source "$PROJECT_DIR/lib/common.sh"

    # JSON with newlines in result (escaped)
    printf '{"result":"line1\\nline2\\nline3","total_cost_usd":0.02,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":1,"cache_creation_input_tokens":2}}\n' > "$tmpdir/output.json"

    parse_claude_output "$tmpdir/output.json"

    # jq -r converts \n to actual newlines
    expected=$(printf 'line1\nline2\nline3')
    assert_equals "multiline result: _PARSED_RESULT extracted" "$_PARSED_RESULT" "$expected"
    assert_equals "multiline result: _PARSED_COST" "$_PARSED_COST" "0.02"

    rm -rf "$tmpdir"
)

print_summary "parse_claude_output"
