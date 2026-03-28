#!/usr/bin/env bash
# tests/test_workspace.sh — Unit tests for lib/workspace.sh (RL-058)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== workspace orchestration tests ==="

# Stubs required by sourced libs
log()         { :; }
log_warn()    { :; }
log_error()   { echo "$*" >&2; }
log_success() { :; }

_cleanup_pids=()
_cleanup_files=()
_interrupted=false

# Source iso_date from common.sh by extracting just what we need
iso_date() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

SCRIPT_DIR="$PROJECT_DIR"
source "$PROJECT_DIR/lib/workspace.sh"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ──────────────────────────────────────────────────────
# Config parsing tests
# ──────────────────────────────────────────────────────

# Test 1: parse_workspace_config — missing file returns 1
(
    result=0
    parse_workspace_config "$TMPDIR_BASE/nonexistent.json" 2>/dev/null || result=$?
    assert_equals "returns 1 on missing config" "$result" "1"
)

# Test 2: parse_workspace_config — invalid JSON returns 1
(
    bad_json="$TMPDIR_BASE/bad.json"
    echo "not json at all" > "$bad_json"
    result=0
    parse_workspace_config "$bad_json" 2>/dev/null || result=$?
    assert_equals "returns 1 on invalid JSON" "$result" "1"
)

# Test 3: parse_workspace_config — no projects returns 1
(
    empty_proj="$TMPDIR_BASE/empty-projects.json"
    printf '{"projects": [], "scheduling": {"strategy": "round_robin", "max_total_cycles": 10}}' > "$empty_proj"
    result=0
    parse_workspace_config "$empty_proj" 2>/dev/null || result=$?
    assert_equals "returns 1 on empty projects array" "$result" "1"
)

# Test 4: parse_workspace_config — valid config sets _WS_CONFIG
(
    valid="$TMPDIR_BASE/valid.json"
    printf '{"projects":[{"name":"foo","path":"/tmp","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":5},"learnings":{"shared":true,"tag":"[cross-project]","max_inject_lines":30}}' > "$valid"
    _WS_CONFIG=""
    result=0
    parse_workspace_config "$valid" 2>/dev/null || result=$?
    assert_equals "returns 0 on valid config" "$result" "0"
    assert_not_empty "_WS_CONFIG is set" "$_WS_CONFIG"
)

# Test 5: validate_workspace_projects — nonexistent path returns 1
(
    bad_path="$TMPDIR_BASE/bad-path.json"
    printf '{"projects":[{"name":"ghost","path":"/nonexistent/path/xyz","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":5},"learnings":{"shared":true,"tag":"[cross-project]","max_inject_lines":30}}' > "$bad_path"
    _WS_CONFIG="$bad_path"
    result=0
    validate_workspace_projects 2>/dev/null || result=$?
    assert_equals "returns 1 on nonexistent project path" "$result" "1"
)

# ──────────────────────────────────────────────────────
# State init and locking tests
# ──────────────────────────────────────────────────────

# Test 6: init_workspace_state creates _workspace/ with state file
(
    ws_dir="$TMPDIR_BASE/ws_init_test/_workspace"
    _WS_DIR="$ws_dir"
    _WS_STATE_FILE="$ws_dir/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws_dir/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws_dir/workspace-cycle-log.json"
    init_workspace_state "2"
    assert_file_exists "workspace-state.json created" "$_WS_STATE_FILE"
    total=$(jq '.total_cycles' "$_WS_STATE_FILE")
    assert_equals "total_cycles initialized to 0" "$total" "0"
)

# Test 7: acquire_workspace_lock creates lock dir
(
    ws_dir="$TMPDIR_BASE/ws_lock_test/_workspace"
    mkdir -p "$ws_dir"
    _WS_DIR="$ws_dir"
    _cleanup_files=()
    acquire_workspace_lock
    assert_dir_exists "workspace lock dir created" "$ws_dir/.ralph-workspace.lock"
)

# ──────────────────────────────────────────────────────
# Scheduler tests
# ──────────────────────────────────────────────────────

# Test 8: select_next_project — round-robin across 3 projects
(
    cfg="$TMPDIR_BASE/rr.json"
    printf '{"projects":[{"name":"a","path":"/tmp","mode":"work"},{"name":"b","path":"/tmp","mode":"work"},{"name":"c","path":"/tmp","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":10},"learnings":{"shared":false,"tag":"[cross-project]","max_inject_lines":30}}' > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/rr_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_STATE_FILE="$ws/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws/workspace-cycle-log.json"
    init_workspace_state "3"
    p1=$(select_next_project)
    p2=$(select_next_project)
    p3=$(select_next_project)
    p4=$(select_next_project)
    assert_equals "first project is index 0 (name=a)" "$p1" "0"
    assert_equals "second project is index 1 (name=b)" "$p2" "1"
    assert_equals "third project is index 2 (name=c)" "$p3" "2"
    assert_equals "wraps back to index 0" "$p4" "0"
)

# Test 9: workspace_loop_should_continue — stops at max_total_cycles
(
    cfg="$TMPDIR_BASE/maxcycles.json"
    printf '{"projects":[{"name":"a","path":"/tmp","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":3},"learnings":{"shared":false,"tag":"[cross-project]","max_inject_lines":30}}' > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/max_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_STATE_FILE="$ws/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws/workspace-cycle-log.json"
    init_workspace_state "1"
    # Simulate 3 cycles already run
    jq '.total_cycles = 3' "$_WS_STATE_FILE" > "$_WS_STATE_FILE.tmp" && mv "$_WS_STATE_FILE.tmp" "$_WS_STATE_FILE"
    result=0
    workspace_loop_should_continue || result=$?
    assert_equals "stops when max_total_cycles reached" "$result" "1"
)

# Test 10: workspace_loop_should_continue — continues when under budget
(
    cfg="$TMPDIR_BASE/under_budget.json"
    printf '{"projects":[{"name":"a","path":"/tmp","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":5},"learnings":{"shared":false,"tag":"[cross-project]","max_inject_lines":30}}' > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/under_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_STATE_FILE="$ws/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws/workspace-cycle-log.json"
    init_workspace_state "1"
    result=0
    workspace_loop_should_continue || result=$?
    assert_equals "continues when under budget" "$result" "0"
)

# ──────────────────────────────────────────────────────
# run_project_cycle tests
# ──────────────────────────────────────────────────────

# Test 11: run_project_cycle — passes DOCS_DIR and CLAUDE_MODEL to subprocess
(
    stub_dir="$TMPDIR_BASE/stub_project"
    mkdir -p "$stub_dir/_state"
    stub_run="$TMPDIR_BASE/stub_run.sh"
    printf '#!/bin/bash\necho "DOCS_DIR=$DOCS_DIR CLAUDE_MODEL=$CLAUDE_MODEL"\nexit 0\n' > "$stub_run"
    chmod +x "$stub_run"

    cfg="$TMPDIR_BASE/rpc.json"
    printf '{"projects":[{"name":"stub","path":"%s","mode":"work","model":"sonnet","env":{},"skip_if_complete":true}],"scheduling":{"strategy":"round_robin","max_total_cycles":5},"learnings":{"shared":false,"tag":"[cross-project]","max_inject_lines":30}}' "$stub_dir" > "$cfg"
    _WS_CONFIG="$cfg"

    ws="$TMPDIR_BASE/rpc_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_STATE_FILE="$ws/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws/workspace-cycle-log.json"
    init_workspace_state "1"

    RALPH_RUN_SH="$stub_run"  # shellcheck disable=SC2034 — used by run_project_cycle()
    export RALPH_RUN_SH
    output=$(run_project_cycle "0" 2>&1)
    result=$?
    assert_equals "run_project_cycle exits 0 on success" "$result" "0"
    assert_contains "output contains DOCS_DIR" "$output" "DOCS_DIR=$stub_dir"
    assert_contains "output contains CLAUDE_MODEL=sonnet" "$output" "CLAUDE_MODEL=sonnet"
)

# ──────────────────────────────────────────────────────
# update_workspace_state tests
# ──────────────────────────────────────────────────────

# Test 12: update_workspace_state — increments total_cycles on success
(
    cfg="$TMPDIR_BASE/uws.json"
    printf '{"projects":[{"name":"alpha","path":"/tmp","mode":"work","skip_if_complete":true}],"scheduling":{"strategy":"round_robin","max_total_cycles":10},"learnings":{"shared":false,"tag":"[cross-project]","max_inject_lines":30}}' > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/uws_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_STATE_FILE="$ws/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws/workspace-cycle-log.json"
    init_workspace_state "1"
    MAX_CONSECUTIVE_FAILURES=3
    update_workspace_state "0" "0" "alpha"
    total=$(jq '.total_cycles' "$_WS_STATE_FILE")
    status=$(jq -r '.projects.alpha.status' "$_WS_STATE_FILE")
    assert_equals "total_cycles incremented to 1" "$total" "1"
    assert_equals "project status is active after success" "$status" "active"
)

# Test 13: update_workspace_state — stalls project after MAX_CONSECUTIVE_FAILURES
(
    cfg="$TMPDIR_BASE/uws2.json"
    printf '{"projects":[{"name":"beta","path":"/tmp","mode":"work","skip_if_complete":true}],"scheduling":{"strategy":"round_robin","max_total_cycles":10},"learnings":{"shared":false,"tag":"[cross-project]","max_inject_lines":30}}' > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/uws2_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_STATE_FILE="$ws/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws/workspace-cycle-log.json"
    init_workspace_state "1"
    MAX_CONSECUTIVE_FAILURES=3
    update_workspace_state "0" "1" "beta"
    update_workspace_state "0" "1" "beta"
    update_workspace_state "0" "1" "beta"
    status=$(jq -r '.projects.beta.status' "$_WS_STATE_FILE")
    assert_equals "project stalled after 3 consecutive failures" "$status" "stalled"
)

# ──────────────────────────────────────────────────────
# Cross-project learnings tests
# ──────────────────────────────────────────────────────

# Test 14: harvest_learnings_from_project — extracts [cross-project] tagged lines
(
    proj_dir="$TMPDIR_BASE/harvest_proj"
    mkdir -p "$proj_dir"
    cat > "$proj_dir/LEARNINGS.md" <<'EOF'
- Normal learning about this project
- [cross-project] Shared pattern: always use jq for JSON
- Another internal note
- [cross-project] Convention: use snake_case for bash variables
EOF

    cfg="$TMPDIR_BASE/harvest.json"
    printf '{"projects":[{"name":"harvtest","path":"%s","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":5},"learnings":{"shared":true,"tag":"[cross-project]","max_inject_lines":30}}' "$proj_dir" > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/harvest_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    touch "$_WS_LEARNINGS_FILE"

    harvest_learnings_from_project "0" "harvtest"

    count=$(grep -c "\[cross-project\]" "$_WS_LEARNINGS_FILE" 2>/dev/null || echo "0")
    assert_equals "harvested 2 cross-project entries" "$count" "2"
)

# Test 15: harvest_learnings_from_project — deduplicates on re-harvest
(
    proj_dir="$TMPDIR_BASE/dedup_proj"
    mkdir -p "$proj_dir"
    echo "- [cross-project] Shared pattern: always use jq for JSON" > "$proj_dir/LEARNINGS.md"

    cfg="$TMPDIR_BASE/dedup.json"
    printf '{"projects":[{"name":"deduptest","path":"%s","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":5},"learnings":{"shared":true,"tag":"[cross-project]","max_inject_lines":30}}' "$proj_dir" > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/dedup_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    touch "$_WS_LEARNINGS_FILE"

    harvest_learnings_from_project "0" "deduptest"
    harvest_learnings_from_project "0" "deduptest"

    count=$(grep -c "\[cross-project\]" "$_WS_LEARNINGS_FILE" 2>/dev/null || echo "0")
    assert_equals "deduplication: only 1 entry after 2 harvests" "$count" "1"
)

# Test 16: sync_learnings_to_project — injects workspace learnings into project LEARNINGS.md
(
    proj_dir="$TMPDIR_BASE/sync_proj"
    mkdir -p "$proj_dir"
    touch "$proj_dir/LEARNINGS.md"

    cfg="$TMPDIR_BASE/sync.json"
    printf '{"projects":[{"name":"synctest","path":"%s","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":5},"learnings":{"shared":true,"tag":"[cross-project]","max_inject_lines":30}}' "$proj_dir" > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/sync_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    {
        echo "- [cross-project] Use portable sed -i on macOS"
        echo "- [cross-project] Prefer small focused files"
    } > "$_WS_LEARNINGS_FILE"

    sync_learnings_to_project "0" "synctest"

    count=$(grep -c "\[workspace-injected\]" "$proj_dir/LEARNINGS.md" 2>/dev/null || echo "0")
    assert_equals "sync injected workspace-injected marker entries" "$count" "2"
)

# ──────────────────────────────────────────────────────
# Summary and status tests
# ──────────────────────────────────────────────────────

# Test 17: show_workspace_status — outputs per-project status
(
    cfg="$TMPDIR_BASE/status.json"
    printf '{"projects":[{"name":"p1","path":"/tmp","mode":"work"},{"name":"p2","path":"/tmp","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":10},"learnings":{"shared":false,"tag":"[cross-project]","max_inject_lines":30}}' > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/status_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_STATE_FILE="$ws/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws/workspace-cycle-log.json"
    init_workspace_state "2"
    MAX_CONSECUTIVE_FAILURES=3
    update_workspace_state "0" "0" "p1"
    update_workspace_state "1" "1" "p2"

    output=$(show_workspace_status 2>&1)
    assert_contains "status shows project p1" "$output" "p1"
    assert_contains "status shows project p2" "$output" "p2"
    assert_contains "status shows total cycles" "$output" "total"
)

# Test 18: workspace_loop_should_continue — stops when all projects stalled
(
    cfg="$TMPDIR_BASE/all_stalled.json"
    printf '{"projects":[{"name":"x","path":"/tmp","mode":"work"}],"scheduling":{"strategy":"round_robin","max_total_cycles":100},"learnings":{"shared":false,"tag":"[cross-project]","max_inject_lines":30}}' > "$cfg"
    _WS_CONFIG="$cfg"
    ws="$TMPDIR_BASE/stalled_ws"
    mkdir -p "$ws"
    _WS_DIR="$ws"
    _WS_STATE_FILE="$ws/workspace-state.json"
    _WS_LEARNINGS_FILE="$ws/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$ws/workspace-cycle-log.json"
    init_workspace_state "1"
    # Register project as stalled
    jq '.projects.x = {"status": "stalled", "cycles": 3, "consecutive_failures": 3, "stale_cycles": 0}' \
        "$_WS_STATE_FILE" > "$_WS_STATE_FILE.tmp" && mv "$_WS_STATE_FILE.tmp" "$_WS_STATE_FILE"
    result=0
    workspace_loop_should_continue || result=$?
    assert_equals "stops when all projects stalled" "$result" "1"
)

print_summary "workspace"
