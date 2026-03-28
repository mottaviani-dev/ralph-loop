#!/bin/bash
# lib/maintenance.sh — Maintenance cycle: journal rotation, doc audits, state cleanup.
#
# Dependencies: lib/common.sh (log, log_success, log_error, log_warn,
#               build_claude_args, validate_json_files, run_with_timeout,
#               iso_date)
# Globals used: FRONTIER_FILE, JOURNAL_FILE, JOURNAL_MAX_LINES,
#               MAINTENANCE_CYCLE_INTERVAL, MAINTENANCE_PROMPT_FILE,
#               DOCS_DIR, CLAUDE_MODEL, USE_AGENTS, SUBAGENTS_FILE,
#               CLAUDE_ARGS, CYCLE_LOG_FILE, SKIP_COMMIT,
#               WORK_AGENT_TIMEOUT, _cleanup_files

# Check if maintenance cycle should run
# should_run_maintenance [state_file]
# state_file defaults to $FRONTIER_FILE (discovery mode).
# Pass $WORK_STATE_FILE to use work-mode cycle counter.
should_run_maintenance() {
    local state_file="${1:-$FRONTIER_FILE}"
    local cycle_num
    cycle_num=$(jq '.total_cycles' "$state_file" 2>/dev/null || echo "0")

    if [ $((cycle_num % MAINTENANCE_CYCLE_INTERVAL)) -eq 0 ] && [ "$cycle_num" -gt 0 ]; then
        echo "scheduled"
        return 0
    fi

    if [ -f "$JOURNAL_FILE" ]; then
        local journal_lines
        journal_lines=$(wc -l < "$JOURNAL_FILE" | tr -d ' ')
        if [ "$journal_lines" -gt "$JOURNAL_MAX_LINES" ]; then
            echo "journal_overflow"
            return 0
        fi
    fi

    return 1
}

# Run maintenance cycle
# run_maintenance_cycle <trigger_reason> [state_file]
# state_file defaults to $FRONTIER_FILE (discovery mode).
run_maintenance_cycle() {
    local trigger_reason="$1"
    local state_file="${2:-$FRONTIER_FILE}"

    log "═══════════════════════════════════════════════════════"
    log "MAINTENANCE CYCLE (trigger: $trigger_reason)"
    log "═══════════════════════════════════════════════════════"

    local prompt
    prompt=$(apply_prompt_vars "$(cat "$MAINTENANCE_PROMPT_FILE")" "maintenance" "0")

    cd "$DOCS_DIR"

    log "Running maintenance agent (model: $CLAUDE_MODEL, timeout: ${WORK_AGENT_TIMEOUT}s)..."

    invoke_claude_agent "$prompt" "Maintenance"
    local status="$LAST_AGENT_STATUS"
    local output="$LAST_AGENT_OUTPUT"
    local duration="$LAST_AGENT_DURATION"

    local cycle_num
    cycle_num=$(jq '.total_cycles' "$state_file" 2>/dev/null || echo "0")
    jq --arg num "$cycle_num" \
       --arg time "$(iso_date)" \
       --arg dur "$duration" \
       --arg status "$status" \
       --arg type "maintenance" \
       --arg trigger "$trigger_reason" \
       '.cycles += [{"cycle": ($num|tonumber), "timestamp": $time, "duration_seconds": ($dur|tonumber), "status": $status, "type": $type, "trigger": $trigger}]' \
       "$CYCLE_LOG_FILE" > "$CYCLE_LOG_FILE.tmp" && mv "$CYCLE_LOG_FILE.tmp" "$CYCLE_LOG_FILE"

    log "Maintenance completed in ${duration}s"

    cd "$DOCS_DIR"

    validate_json_files

    # Prune stale migration backups (older than 7 days)
    prune_migration_backups

    if [ "$SKIP_COMMIT" != "true" ]; then
        cd "$DOCS_DIR"
        local changes
        changes=$(git status --porcelain docs/ 2>/dev/null)
        if [ -n "$changes" ]; then
            git add docs/
            git commit -m "docs: maintenance cycle (${trigger_reason})"
            log_success "Committed maintenance changes"
        fi
        cd "$DOCS_DIR"
    fi
}
