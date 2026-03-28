#!/bin/bash
# lib/refine.sh — Documentation refinement: dual-purpose format conversion.
#
# Dependencies: lib/common.sh (log, log_success, log_error, log_warn,
#               build_claude_args, validate_json_files, run_with_timeout,
#               check_dependencies, validate_env, iso_date)
# Globals used: CONFIG_FILE, DOCS_DIR, REFINE_PROMPT_FILE,
#               CLAUDE_MODEL, CLAUDE_ARGS, CYCLE_LOG_FILE,
#               SKIP_COMMIT, WORK_AGENT_TIMEOUT, _cleanup_files,
#               USE_AGENTS, SUBAGENTS_FILE

# Run refinement on a single service
run_refine_service() {
    local service="$1"
    local service_dir="$DOCS_DIR/$service"

    if [ ! -d "$service_dir" ]; then
        log_error "Service directory not found: $service_dir"
        return 1
    fi

    local file_count
    file_count=$(find "$service_dir" -name '*.md' \
        -not -name 'README.md' \
        -not -name '_*.md' \
        -type f | wc -l | tr -d ' ')

    if [ "$file_count" -eq 0 ]; then
        log_error "No eligible files in $service — skipping"
        return 0
    fi

    log "───────────────────────────────────────"
    log "Refining $service ($file_count files)"
    log "───────────────────────────────────────"

    local prompt
    prompt=$(apply_prompt_vars \
        "$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$REFINE_PROMPT_FILE")" \
        "refine" "0")
    prompt="$prompt

## Target

Process the service: **$service**
Service docs folder: docs/$service/
Style guide: docs/_state/style-guide.md
Reference: docs/.claude/skills/refine-docs/reference.md"

    cd "$DOCS_DIR"

    log "Running refine agent for $service (model: $CLAUDE_MODEL, timeout: ${WORK_AGENT_TIMEOUT}s)..."

    invoke_claude_agent "$prompt" "Refinement of $service"
    local status="$LAST_AGENT_STATUS"
    local output="$LAST_AGENT_OUTPUT"
    local duration="$LAST_AGENT_DURATION"

    jq --arg time "$(iso_date)" \
       --arg dur "$duration" \
       --arg status "$status" \
       --arg svc "$service" \
       '.cycles += [{"timestamp": $time, "duration_seconds": ($dur|tonumber), "status": $status, "type": "refinement", "service": $svc}]' \
       "$CYCLE_LOG_FILE" > "$CYCLE_LOG_FILE.tmp" && mv "$CYCLE_LOG_FILE.tmp" "$CYCLE_LOG_FILE"

    log "Refined $service in ${duration}s (status: $status)"

    cd "$DOCS_DIR"

    validate_json_files

    return 0
}

# Run refinement loop across services
run_refine() {
    local target="${1:-all}"

    log "╔═══════════════════════════════════════════════════════╗"
    log "║       DOCUMENTATION REFINEMENT                        ║"
    log "║       Dual-Purpose Format Conversion                  ║"
    log "╚═══════════════════════════════════════════════════════╝"

    check_dependencies
    validate_env

    # Populate SERVICES_ORDER at call time (moved from source time — RL-012)
    SERVICES_ORDER=()
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE — run --setup first"
        return 1
    fi
    while IFS= read -r svc; do
        SERVICES_ORDER+=("$svc")
    done < <(jq -r '.modules | keys[]' "$CONFIG_FILE" 2>/dev/null)

    if [ "$target" = "all" ]; then
        local total_start
        total_start=$(date +%s)
        local succeeded=0
        local failed=0

        for service in "${SERVICES_ORDER[@]}"; do
            if run_refine_service "$service"; then
                succeeded=$((succeeded + 1))
            else
                failed=$((failed + 1))
            fi

            if [ "$SKIP_COMMIT" != "true" ]; then
                cd "$DOCS_DIR"
                local changes
                changes=$(git status --porcelain docs/ 2>/dev/null)
                if [ -n "$changes" ]; then
                    git add docs/
                    git commit -m "docs: refine $service (dual-purpose format)"
                    log_success "Committed refinement: $service"
                fi
                cd "$DOCS_DIR"
            fi
        done

        local total_end
        total_end=$(date +%s)
        local total_duration
        total_duration=$((total_end - total_start))

        echo ""
        log "═══════════════════════════════════════════════════════"
        log_success "Refinement complete: $succeeded succeeded, $failed failed (${total_duration}s total)"
        log "═══════════════════════════════════════════════════════"
    else
        run_refine_service "$target"

        if [ "$SKIP_COMMIT" != "true" ]; then
            cd "$DOCS_DIR"
            local changes
            changes=$(git status --porcelain docs/ 2>/dev/null)
            if [ -n "$changes" ]; then
                git add docs/
                git commit -m "docs: refine $target (dual-purpose format)"
                log_success "Committed refinement: $target"
            fi
            cd "$DOCS_DIR"
        fi
    fi
}
