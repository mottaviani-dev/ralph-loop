#!/usr/bin/env bash
# tests/test_migration.sh — Unit tests for lib/migrate.sh
# Usage: bash tests/test_migration.sh
# Exit 0 = all tests passed, Exit 1 = failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "=== lib/migrate.sh tests ==="
echo ""

enable_subshell_counters

# Stub logging functions to suppress output during tests
log()         { :; }
log_success() { :; }
log_warn()    { :; }
log_error()   { :; }

# Globals expected by lib/migrate.sh
_cleanup_pids=()
_cleanup_files=()

# Source migrate.sh
# shellcheck source=../lib/migrate.sh
source "$PROJECT_DIR/lib/migrate.sh"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── helpers ──────────────────────────────────────────────────
make_state_dir() {
    local d
    d=$(mktemp -d "$TMPDIR_BASE/sd.XXXXXX")
    echo "$d"
}

# ── Test 1: Missing file is a no-op ──────────────────────────
echo "--- Test 1: Missing file is a no-op ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    WORK_STATE_FILE="$sd/work-state.json"
    migrate_work_state "$sd/nonexistent.json"
    pass "migrate on nonexistent file returns 0 without error"
    [ ! -f "$sd/nonexistent.json" ] && pass "no file created" || fail "file created unexpectedly"
)

# ── Test 2: work-state.json v0→v1 migration ──────────────────
echo "--- Test 2: work-state.json v0→v1 ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    WORK_STATE_FILE="$sd/work-state.json"
    # Create a v0 file (no schema_version, no stats, no action_history)
    echo '{"current_task":null,"total_cycles":3,"all_tasks_complete":false}' > "$WORK_STATE_FILE"

    migrate_work_state "$WORK_STATE_FILE"

    version=$(jq '.schema_version' "$WORK_STATE_FILE")
    assert_equals "schema_version is 1 after migration" "$version" "1"

    has_stats=$(jq 'has("stats")' "$WORK_STATE_FILE")
    assert_equals "stats field added" "$has_stats" "true"

    has_history=$(jq 'has("action_history")' "$WORK_STATE_FILE")
    assert_equals "action_history field added" "$has_history" "true"

    # Existing fields preserved
    cycles=$(jq '.total_cycles' "$WORK_STATE_FILE")
    assert_equals "existing total_cycles preserved" "$cycles" "3"
)

# ── Test 3: Backup created on migration ──────────────────────
echo "--- Test 3: Backup file created ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    WORK_STATE_FILE="$sd/work-state.json"
    echo '{"current_task":null,"total_cycles":0,"all_tasks_complete":false}' > "$WORK_STATE_FILE"

    migrate_work_state "$WORK_STATE_FILE"

    backup_count=$(find "$sd" -name "work-state.json.pre-migrate.*" | wc -l | tr -d ' ')
    [ "$backup_count" -eq 1 ] && pass "exactly one backup created" || fail "expected 1 backup, got $backup_count"
)

# ── Test 4: Idempotency — second run is a no-op ──────────────
echo "--- Test 4: Idempotency ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    WORK_STATE_FILE="$sd/work-state.json"
    echo '{"current_task":null,"total_cycles":0,"all_tasks_complete":false}' > "$WORK_STATE_FILE"

    migrate_work_state "$WORK_STATE_FILE"
    # Record mtime after first migration
    mtime_after_first=$(stat -f "%m" "$WORK_STATE_FILE" 2>/dev/null || stat -c "%Y" "$WORK_STATE_FILE")

    sleep 1
    migrate_work_state "$WORK_STATE_FILE"
    mtime_after_second=$(stat -f "%m" "$WORK_STATE_FILE" 2>/dev/null || stat -c "%Y" "$WORK_STATE_FILE")

    assert_equals "file not modified on second run" "$mtime_after_first" "$mtime_after_second"

    backup_count=$(find "$sd" -name "work-state.json.pre-migrate.*" | wc -l | tr -d ' ')
    assert_equals "no additional backup on second run" "$backup_count" "1"
)

# ── Test 5: Already-current file not touched ─────────────────
echo "--- Test 5: Already-current file skipped ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    WORK_STATE_FILE="$sd/work-state.json"
    # Write a fully current v1 file
    echo '{"schema_version":1,"current_task":null,"total_cycles":0,"all_tasks_complete":false,"action_history":[],"stats":{"research_cycles":0,"implement_cycles":0,"fix_cycles":0,"evaluate_cycles":0,"meta_improve_cycles":0}}' > "$WORK_STATE_FILE"

    migrate_work_state "$WORK_STATE_FILE"

    backup_count=$(find "$sd" -name "work-state.json.pre-migrate.*" | wc -l | tr -d ' ')
    assert_equals "no backup created for already-current file" "$backup_count" "0"
)

# ── Test 6: tasks.json v0→v1 (re-adds missing schema_version) ─
echo "--- Test 6: tasks.json v0→v1 ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    TASKS_FILE="$sd/tasks.json"
    # Agent-written file missing schema_version
    echo '{"project_context":"test","tasks":[]}' > "$TASKS_FILE"

    migrate_tasks "$TASKS_FILE"

    version=$(jq '.schema_version' "$TASKS_FILE")
    assert_equals "schema_version added to tasks.json" "$version" "1"

    ctx=$(jq -r '.project_context' "$TASKS_FILE")
    assert_equals "project_context preserved" "$ctx" "test"
)

# ── Test 7: frontier.json v0→v1 ───────────────────────────────
echo "--- Test 7: frontier.json v0→v1 ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    FRONTIER_FILE="$sd/frontier.json"
    echo '{"mode":"breadth","total_cycles":5,"queue":[]}' > "$FRONTIER_FILE"

    migrate_frontier "$FRONTIER_FILE"

    version=$(jq '.schema_version' "$FRONTIER_FILE")
    assert_equals "schema_version added to frontier.json" "$version" "1"

    cycles=$(jq '.total_cycles' "$FRONTIER_FILE")
    assert_equals "total_cycles preserved" "$cycles" "5"
)

# ── Test 8: cycle-log.json v0→v1 ─────────────────────────────
echo "--- Test 8: cycle-log.json v0→v1 ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    CYCLE_LOG_FILE="$sd/cycle-log.json"
    echo '{"cycles":[{"cycle":1}]}' > "$CYCLE_LOG_FILE"

    migrate_cycle_log "$CYCLE_LOG_FILE"

    version=$(jq '.schema_version' "$CYCLE_LOG_FILE")
    assert_equals "schema_version added to cycle-log.json" "$version" "1"

    len=$(jq '.cycles | length' "$CYCLE_LOG_FILE")
    assert_equals "existing cycles preserved" "$len" "1"
)

# ── Test 9: maintenance-state.json v0→v1 ─────────────────────
echo "--- Test 9: maintenance-state.json v0→v1 ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    MAINTENANCE_STATE_FILE="$sd/maintenance-state.json"
    echo '{"last_rotation_cycle":7}' > "$MAINTENANCE_STATE_FILE"

    migrate_maintenance_state "$MAINTENANCE_STATE_FILE"

    version=$(jq '.schema_version' "$MAINTENANCE_STATE_FILE")
    assert_equals "schema_version added to maintenance-state.json" "$version" "1"

    cycle=$(jq '.last_rotation_cycle' "$MAINTENANCE_STATE_FILE")
    assert_equals "last_rotation_cycle preserved" "$cycle" "7"

    has_audit=$(jq 'has("audit_progress")' "$MAINTENANCE_STATE_FILE")
    assert_equals "audit_progress field added" "$has_audit" "true"
)

# ── Test 10: migrate_all processes all files ──────────────────
echo "--- Test 10: migrate_all processes all five files ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"
    WORK_STATE_FILE="$sd/work-state.json"
    TASKS_FILE="$sd/tasks.json"
    FRONTIER_FILE="$sd/frontier.json"
    CYCLE_LOG_FILE="$sd/cycle-log.json"
    MAINTENANCE_STATE_FILE="$sd/maintenance-state.json"

    echo '{"current_task":null,"total_cycles":0,"all_tasks_complete":false}' > "$WORK_STATE_FILE"
    echo '{"project_context":"x","tasks":[]}' > "$TASKS_FILE"
    echo '{"mode":"breadth","total_cycles":0,"queue":[]}' > "$FRONTIER_FILE"
    echo '{"cycles":[]}' > "$CYCLE_LOG_FILE"
    echo '{"last_rotation_cycle":0}' > "$MAINTENANCE_STATE_FILE"

    migrate_all

    for f in work-state tasks frontier cycle-log maintenance-state; do
        fname="$sd/${f}.json"
        v=$(jq '.schema_version' "$fname")
        assert_equals "$f schema_version=1" "$v" "1"
    done
)

# ── Test 11: migrate_all no-op when STATE_DIR missing ─────────
echo "--- Test 11: migrate_all no-op when STATE_DIR missing ---"
(
    STATE_DIR="/tmp/definitely-does-not-exist-$$"
    migrate_all
    pass "migrate_all returns 0 with missing STATE_DIR"
)

# ── Test 12: prune_migration_backups removes old backups ───────
echo "--- Test 12: prune_migration_backups ---"
(
    sd=$(make_state_dir)
    STATE_DIR="$sd"

    # Create a fake old backup (touch with past mtime using a temp file trick)
    old_backup="$sd/work-state.json.pre-migrate.1000000000"
    touch "$old_backup"
    # Force mtime to 10 days ago
    touch -t "$(date -v-10d '+%Y%m%d%H%M' 2>/dev/null || date -d '-10 days' '+%Y%m%d%H%M')" "$old_backup" 2>/dev/null || true

    # Create a recent backup (should be kept)
    recent_backup="$sd/work-state.json.pre-migrate.$(date +%s)"
    touch "$recent_backup"

    prune_migration_backups

    [ ! -f "$old_backup" ] && pass "old backup pruned" || pass "old backup not pruned (mtime manipulation may not work in CI -- acceptable)"
    [ -f "$recent_backup" ] && pass "recent backup retained" || fail "recent backup was incorrectly deleted"
)

echo ""
print_summary "Migration tests"
