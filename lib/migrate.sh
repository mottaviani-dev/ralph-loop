#!/bin/bash
# lib/migrate.sh — Schema version tracking and incremental migration for _state/ files.
#
# Each state file has its own independent schema_version integer.
# Files missing the field are treated as version 0.
# Migration functions are idempotent: re-running on an already-current file is a no-op.
#
# Dependencies: lib/common.sh (log, log_warn, log_error)
# Globals used: STATE_DIR, WORK_STATE_FILE, TASKS_FILE, FRONTIER_FILE,
#               CYCLE_LOG_FILE, MAINTENANCE_STATE_FILE

# ── Expected (current) schema versions ──
# Increment the relevant constant when you change a file's schema.
EXPECTED_WORK_STATE_VERSION=2
EXPECTED_TASKS_VERSION=1
EXPECTED_FRONTIER_VERSION=1
EXPECTED_CYCLE_LOG_VERSION=1
EXPECTED_MAINTENANCE_STATE_VERSION=1

# _migrate_file <file> <expected_version> <migration_callback_fn>
# - No-op if file does not exist.
# - No-op if file is already at or above expected_version.
# - Creates <file>.pre-migrate.<timestamp> backup before first mutation.
# - Calls <migration_callback_fn> <file> <current_version> for each version step.
_migrate_file() {
    local file="$1"
    local expected="$2"
    local callback="$3"

    [ -f "$file" ] || return 0

    local current
    current=$(jq '.schema_version // 0' "$file")

    [ "$current" -ge "$expected" ] && return 0

    # Backup before first mutation
    local backup
    backup="${file}.pre-migrate.$(date +%s)"
    cp "$file" "$backup"
    log "Migrating $(basename "$file") v${current} → v${expected} (backup: $(basename "$backup"))"

    # Apply incremental steps
    local step=$current
    while [ "$step" -lt "$expected" ]; do
        "$callback" "$file" "$step"
        step=$((step + 1))
    done

    log_success "$(basename "$file") migrated to v${expected}"
}

# ── work-state.json ──
_migrate_work_state_step() {
    local file="$1"
    local from_version="$2"
    if [ "$from_version" -eq 0 ]; then
        # v0→v1: add schema_version, action_history, stats if missing
        jq '
          . + {
            "schema_version": 1,
            "action_history": (.action_history // []),
            "stats": (.stats // {
              "research_cycles": 0,
              "implement_cycles": 0,
              "fix_cycles": 0,
              "evaluate_cycles": 0,
              "meta_improve_cycles": 0
            })
          }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
    if [ "$from_version" -eq 1 ]; then
        # v1→v2: add phase pipeline fields
        jq '
          . + {
            "schema_version": 2,
            "current_phase": (.current_phase // ""),
            "judge_mode": (.judge_mode // "pre"),
            "pipeline_mode": (.pipeline_mode // "full"),
            "phase_task_id": (.phase_task_id // ""),
            "phase_task_title": (.phase_task_title // ""),
            "pre_reject_count": (.pre_reject_count // 0),
            "post_reject_count": (.post_reject_count // 0),
            "last_reject_phase": (.last_reject_phase // ""),
            "last_reject_reason": (.last_reject_reason // ""),
            "last_implementation_commit": (.last_implementation_commit // "")
          }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

migrate_work_state() {
    local file="${1:-$WORK_STATE_FILE}"
    _migrate_file "$file" "$EXPECTED_WORK_STATE_VERSION" _migrate_work_state_step
}

# ── tasks.json ──
_migrate_tasks_step() {
    local file="$1"
    local from_version="$2"
    if [ "$from_version" -eq 0 ]; then
        # v0→v1: ensure schema_version field exists (was already 1 in most files,
        # but some agent-written copies may have dropped it)
        jq '. + {"schema_version": 1}' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

migrate_tasks() {
    local file="${1:-$TASKS_FILE}"
    _migrate_file "$file" "$EXPECTED_TASKS_VERSION" _migrate_tasks_step
}

# ── frontier.json ──
_migrate_frontier_step() {
    local file="$1"
    local from_version="$2"
    if [ "$from_version" -eq 0 ]; then
        # v0→v1: add schema_version field
        jq '. + {"schema_version": 1}' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

migrate_frontier() {
    local file="${1:-$FRONTIER_FILE}"
    _migrate_file "$file" "$EXPECTED_FRONTIER_VERSION" _migrate_frontier_step
}

# ── cycle-log.json ──
_migrate_cycle_log_step() {
    local file="$1"
    local from_version="$2"
    if [ "$from_version" -eq 0 ]; then
        jq '. + {"schema_version": 1}' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

migrate_cycle_log() {
    local file="${1:-$CYCLE_LOG_FILE}"
    _migrate_file "$file" "$EXPECTED_CYCLE_LOG_VERSION" _migrate_cycle_log_step
}

# ── maintenance-state.json ──
_migrate_maintenance_state_step() {
    local file="$1"
    local from_version="$2"
    if [ "$from_version" -eq 0 ]; then
        # v0→v1: add schema_version, ensure last_rotation_cycle and audit_progress exist
        jq '
          . + {
            "schema_version": 1,
            "last_rotation_cycle": (.last_rotation_cycle // 0),
            "audit_progress": (.audit_progress // {})
          }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

migrate_maintenance_state() {
    local file="${1:-$MAINTENANCE_STATE_FILE}"
    _migrate_file "$file" "$EXPECTED_MAINTENANCE_STATE_VERSION" _migrate_maintenance_state_step
}

# migrate_all — run all per-file migrations in dependency order.
# No-op if STATE_DIR does not exist.
migrate_all() {
    [ -d "${STATE_DIR:-}" ] || return 0

    migrate_work_state
    migrate_tasks
    migrate_frontier
    migrate_cycle_log
    migrate_maintenance_state
}

# prune_migration_backups — delete backup files older than 7 days.
# Called during maintenance cycles to prevent _state/ accumulation.
# macOS-compatible: find -mtime +7 counts 24-hour periods.
prune_migration_backups() {
    [ -d "${STATE_DIR:-}" ] || return 0
    find "$STATE_DIR" -name "*.pre-migrate.*" -mtime +7 -delete 2>/dev/null || true
    log "Pruned migration backups older than 7 days"
}
