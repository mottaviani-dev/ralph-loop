#!/bin/bash
# lib/discovery.sh — Discovery cycle: run Claude agent, journal, commit.
#
# Dependencies: lib/common.sh (log, log_success, log_error, log_warn,
#               run_with_timeout, build_claude_args, validate_json_files,
#               check_stalemate, iso_date)
#               lib/maintenance.sh (should_run_maintenance, run_maintenance_cycle)
#               lib/setup.sh (check_first_run, init_frontier)
# Globals used: FRONTIER_FILE, PROMPT_FILE, DOCS_DIR, CLAUDE_MODEL,
#               USE_AGENTS, SUBAGENTS_FILE, CLAUDE_ARGS, CYCLE_LOG_FILE,
#               JOURNAL_FILE, SKIP_COMMIT, COMMIT_MSG_PREFIX,
#               WORK_AGENT_TIMEOUT, DISCOVERY_ONLY, CONFIG_FILE,
#               MAINTENANCE_CYCLE_INTERVAL, JOURNAL_MAX_LINES,
#               NOTIFY_WEBHOOK_URL, NOTIFY_ON,
#               _cleanup_files

# Run one discovery cycle
run_cycle() {
    local cycle_num
    cycle_num=$(jq '.total_cycles' "$FRONTIER_FILE")
    cycle_num=$((cycle_num + 1))

    # Check if this should be a maintenance cycle
    if [ "$DISCOVERY_ONLY" != "true" ]; then
        local maintenance_trigger
        if maintenance_trigger=$(should_run_maintenance); then
            run_maintenance_cycle "$maintenance_trigger" || log_error "Maintenance cycle failed, continuing..."
        fi
    fi

    log "═══════════════════════════════════════════════════════"
    log "Starting discovery cycle #$cycle_num"
    log "═══════════════════════════════════════════════════════"

    local prompt
    prompt=$(apply_prompt_vars "$(cat "$PROMPT_FILE")" "discovery" "${cycle_num:-0}")

    # ── DRY-RUN EXIT POINT ──────────────────────────────────────────────────
    if [ "${DRY_RUN:-false}" = "true" ]; then
        local dry_run_output_file="${DOCS_DIR}/_state/dry-run-prompt.md"
        _print_dry_run_report "once" "$prompt" "$dry_run_output_file"
        return 0
    fi
    # ── END DRY-RUN ─────────────────────────────────────────────────────────

    cd "$DOCS_DIR"

    log "Running Claude discovery agent (model: $CLAUDE_MODEL, timeout: ${WORK_AGENT_TIMEOUT}s)..."

    invoke_claude_agent "$prompt" "Discovery cycle #$cycle_num"
    local output="$LAST_AGENT_OUTPUT"
    local status="$LAST_AGENT_STATUS"
    local duration="$LAST_AGENT_DURATION"
    echo "$output"

    {
        echo ""
        echo "---"
        echo ""
        echo "## Cycle $cycle_num — $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "**Duration**: ${duration}s | **Status**: $status | **Model**: $CLAUDE_MODEL"
        echo ""
        echo "$output"
    } >> "$JOURNAL_FILE"

    log "Saved cycle output to journal.md"

    jq --arg num "$cycle_num" --arg ts "$(iso_date)" \
        '.total_cycles = ($num|tonumber) | .last_cycle = $ts' \
        "$FRONTIER_FILE" > "$FRONTIER_FILE.tmp" && mv "$FRONTIER_FILE.tmp" "$FRONTIER_FILE"

    jq --arg num "$cycle_num" \
       --arg time "$(iso_date)" \
       --arg dur "$duration" \
       --arg status "$status" \
       --arg type "discovery" \
       --arg cost "${LAST_AGENT_COST:-}" \
       --arg input_t "${LAST_AGENT_INPUT_TOKENS:-}" \
       --arg out_t "${LAST_AGENT_OUTPUT_TOKENS:-}" \
       --arg cr "${LAST_AGENT_CACHE_READ:-}" \
       --arg cc "${LAST_AGENT_CACHE_CREATED:-}" \
       '.cycles += [{"cycle": ($num|tonumber), "timestamp": $time, "duration_seconds": ($dur|tonumber), "status": $status, "type": $type} + (if $cost != "" then {"tokens": {"input": ($input_t|tonumber), "output": ($out_t|tonumber), "cache_read": ($cr|tonumber), "cache_created": ($cc|tonumber), "cost_usd": ($cost|tonumber)}} else {} end)]' \
       "$CYCLE_LOG_FILE" > "$CYCLE_LOG_FILE.tmp" && mv "$CYCLE_LOG_FILE.tmp" "$CYCLE_LOG_FILE"

    log "Cycle #$cycle_num completed in ${duration}s"
    notify "cycle" "$cycle_num" "Discovery cycle #$cycle_num completed in ${duration}s" "discovery"

    cd "$DOCS_DIR"

    validate_json_files

    # Stalemate detection for discovery mode
    if ! check_stalemate; then
        return 1
    fi

    commit_changes "$cycle_num"
}

# Commit changes after cycle
commit_changes() {
    local cycle_num="$1"

    if [ "$SKIP_COMMIT" = "true" ]; then
        return
    fi

    cd "$DOCS_DIR"

    local changes
    changes=$(git status --porcelain docs/ 2>/dev/null)

    if [ -z "$changes" ]; then
        log "No changes to commit."
        cd "$DOCS_DIR"
        return
    fi

    echo ""
    log "Committing changes..."
    git status --short docs/
    echo ""

    local commit_msg="$COMMIT_MSG_PREFIX $cycle_num"
    git add docs/
    git commit -m "$commit_msg"
    log_success "Committed: $commit_msg"

    cd "$DOCS_DIR"
}

# Check if discovery loop should continue (mirrors work_loop_should_continue)
discovery_loop_should_continue() {
    # Guard: consecutive failures
    if [ "$_consecutive_failure_count" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        log_error "Aborting: $MAX_CONSECUTIVE_FAILURES consecutive discovery cycle failures."
        notify "error" "$_consecutive_failure_count" \
            "Aborting: $MAX_CONSECUTIVE_FAILURES consecutive discovery cycle failures." "discovery"
        return 1
    fi

    # Guard: stalemate
    if [ "$_stale_cycle_count" -ge "$MAX_STALE_CYCLES" ]; then
        log_error "Aborting: $MAX_STALE_CYCLES consecutive cycles with no changes (stalemate)."
        notify "stalemate" "$_stale_cycle_count" \
            "Aborting: $MAX_STALE_CYCLES consecutive discovery stale cycles." "discovery"
        return 1
    fi

    # Guard: max discovery cycles (0 = unlimited)
    if [ "${MAX_DISCOVERY_CYCLES:-0}" -gt 0 ]; then
        local current_cycle=0
        if [ -f "$FRONTIER_FILE" ]; then
            current_cycle=$(jq '.total_cycles // 0' "$FRONTIER_FILE" 2>/dev/null || echo "0")
        fi
        if [ "$current_cycle" -ge "$MAX_DISCOVERY_CYCLES" ]; then
            log_warn "Max discovery cycles ($MAX_DISCOVERY_CYCLES) reached. Stopping."
            return 1
        fi
    fi

    # Guard: cumulative spend exceeds budget limit
    # Safety: $cumulative_cost comes from get_cumulative_cost() (jq-sanitized numeric output).
    # $RALPH_BUDGET_LIMIT was regex-validated in validate_env() at startup (digits/dot only).
    if [ -n "${RALPH_BUDGET_LIMIT:-}" ]; then
        local cumulative_cost
        cumulative_cost=$(get_cumulative_cost)
        if awk "BEGIN { exit ($cumulative_cost >= $RALPH_BUDGET_LIMIT) ? 0 : 1 }"; then
            log_warn "Budget limit reached: \$${cumulative_cost} >= \$${RALPH_BUDGET_LIMIT}. Stopping loop."
            notify "budget" "0" \
                "Budget limit reached: \$${cumulative_cost} >= \$${RALPH_BUDGET_LIMIT}" "discovery"
            return 1
        fi
    fi

    return 0
}

# Main loop
main() {
    log "╔═══════════════════════════════════════════════════════╗"
    log "║       RALPH LOOP — Discovery Runner                    ║"
    log "╚═══════════════════════════════════════════════════════╝"

    check_dependencies
    validate_env
    check_first_run

    validate_json_files

    local sleep_seconds
    sleep_seconds=$(jq -r '.cycle_sleep_seconds // 10' "$CONFIG_FILE")

    log "Sleep between cycles: ${sleep_seconds}s"
    if [ "$DISCOVERY_ONLY" = "true" ]; then
        log "Mode: discovery only (maintenance skipped)"
    else
        log "Mode: full (discovery + maintenance)"
    fi
    log "Maintenance every: ${MAINTENANCE_CYCLE_INTERVAL} cycles"
    log "Journal rotation at: ${JOURNAL_MAX_LINES} lines"
    if [ "$USE_AGENTS" = "true" ] && [ -f "$SUBAGENTS_FILE" ]; then
        log "Subagents: $(jq 'keys | length' "$SUBAGENTS_FILE") specialists loaded"
    else
        log "Subagents: disabled"
    fi
    log "Press Ctrl+C to stop"
    echo ""

    init_frontier

    while discovery_loop_should_continue; do
        if run_cycle; then
            _consecutive_failure_count=0
        else
            _consecutive_failure_count=$((_consecutive_failure_count + 1))
            log_error "Discovery cycle failed (consecutive: $_consecutive_failure_count/$MAX_CONSECUTIVE_FAILURES)"
        fi
        log "Sleeping for ${sleep_seconds}s before next cycle..."
        echo ""
        sleep "$sleep_seconds"
    done
    log_success "Discovery loop finished."
}
