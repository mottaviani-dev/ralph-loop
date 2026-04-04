#!/bin/bash
# lib/work.sh — Work mode: task-driven implementation cycles.
#
# Dependencies: lib/common.sh (log, log_success, log_error, log_warn,
#               run_with_timeout, build_claude_args, validate_json_files,
#               check_stalemate, check_dependencies, validate_env,
#               iso_date)
# Globals used: STATE_DIR, SCRIPT_DIR, DOCS_DIR, CONFIG_FILE,
#               WORK_STATE_FILE, TASKS_FILE, LAST_VALIDATION_FILE,
#               WORK_PROMPT_FILE, SUBAGENTS_FILE, CYCLE_LOG_FILE,
#               JOURNAL_FILE, CLAUDE_MODEL, USE_AGENTS, CLAUDE_ARGS,
#               WORK_AGENT_TIMEOUT, SKIP_COMMIT, WORK_COMMIT_MSG_PREFIX,
#               WORK_GIT_EXCLUDE_DEFAULTS, MAX_WORK_CYCLES,
#               MAX_CONSECUTIVE_FAILURES, MAX_STALE_CYCLES,
#               MAX_EMPTY_TASK_CYCLES,
#               NOTIFY_WEBHOOK_URL, NOTIFY_ON,
#               _cleanup_files, _consecutive_failure_count,
#               _stale_cycle_count, _empty_task_cycle_count,
#               RED, GREEN, YELLOW, BLUE, MAGENTA, NC

# Check a validation command for dangerous patterns before execution.
# Returns 0 (proceed) or 1 (blocked — caller must skip execution).
# Three layers: (1) audit log, (2) allowlist filter, (3) denylist check.
_check_validation_cmd() {
    local cmd="$1"

    # Layer 1: Audit log — always emit
    log_warn "VALIDATION EXEC: $cmd"

    # Empty command — nothing to check
    [ -z "$cmd" ] && return 0

    # Layer 2: Allowlist (only when VALIDATE_COMMANDS_ALLOWLIST is set)
    if [ -n "${VALIDATE_COMMANDS_ALLOWLIST:-}" ]; then
        local allowed=false
        local IFS_SAVE="$IFS"
        IFS=':'
        for pattern in $VALIDATE_COMMANDS_ALLOWLIST; do
            IFS="$IFS_SAVE"
            [ -z "$pattern" ] && continue
            if echo "$cmd" | grep -qE "$pattern"; then
                allowed=true
                break
            fi
        done
        IFS="$IFS_SAVE"
        if [ "$allowed" = false ]; then
            log_error "VALIDATION BLOCKED (not in allowlist): $cmd"
            return 1
        fi
    fi

    # Layer 3: Denylist — dangerous pattern detection
    local denylist_pattern
    denylist_pattern='rm[[:space:]]+-[rRf]'
    denylist_pattern="$denylist_pattern"'|\bcurl\b'
    denylist_pattern="$denylist_pattern"'|\bwget\b'
    denylist_pattern="$denylist_pattern"'|\bnc[[:space:]]'
    denylist_pattern="$denylist_pattern"'|\bnetcat\b'
    denylist_pattern="$denylist_pattern"'|\beval[[:space:]]'
    denylist_pattern="$denylist_pattern"'|\bbase64\b.*\|'
    denylist_pattern="$denylist_pattern"'|/dev/tcp'
    denylist_pattern="$denylist_pattern"'|>[[:space:]]*.*\.env'
    denylist_pattern="$denylist_pattern"'|\bdd[[:space:]]+if='
    denylist_pattern="$denylist_pattern"'|\bchmod[[:space:]]+777'
    denylist_pattern="$denylist_pattern"'|\bssh[[:space:]]'
    denylist_pattern="$denylist_pattern"'|\bscp[[:space:]]'
    denylist_pattern="$denylist_pattern"'|git[[:space:]]+push[[:space:]]+(-f|--force)'
    denylist_pattern="$denylist_pattern"'|\bsudo[[:space:]]'

    if echo "$cmd" | grep -qE "$denylist_pattern"; then
        if [ "${VALIDATE_COMMANDS_STRICT:-false}" = "true" ]; then
            log_error "VALIDATION BLOCKED (denylist): $cmd"
            return 1
        else
            log_warn "VALIDATION WARNING (denylist match, executing anyway): $cmd"
            return 0
        fi
    fi

    return 0
}

# Initialize work state files if missing (fully self-contained, no --setup required)
init_work_state() {
    # Ensure _state/ directory exists
    mkdir -p "$STATE_DIR"

    # Migrate pre-existing state files before reading them
    migrate_all

    # Work-specific state files
    if [ ! -f "$WORK_STATE_FILE" ]; then
        echo '{"schema_version":1,"current_task":null,"total_cycles":0,"last_cycle":null,"last_action":null,"last_outcome":null,"all_tasks_complete":false,"action_history":[],"stats":{"research_cycles":0,"implement_cycles":0,"fix_cycles":0,"evaluate_cycles":0,"meta_improve_cycles":0}}' > "$WORK_STATE_FILE"
        log "Created work-state.json"
    fi
    if [ ! -f "$TASKS_FILE" ]; then
        if [ -f "$SCRIPT_DIR/config/tasks.json" ]; then
            cp "$SCRIPT_DIR/config/tasks.json" "$TASKS_FILE"
        else
            echo '{"schema_version":1,"project_context":"Search workspace for requirements files","tasks":[]}' > "$TASKS_FILE"
        fi
        log "Created tasks.json"
    fi
    # Always refresh prompt from template (picks up edits)
    if [ -f "$SCRIPT_DIR/prompts/work.md" ]; then
        cp "$SCRIPT_DIR/prompts/work.md" "$WORK_PROMPT_FILE"
    else
        log_error "Work prompt not found at $SCRIPT_DIR/prompts/work.md"
        exit 1
    fi

    # Always refresh subagents from config (picks up tool/prompt changes)
    if [ -f "$SCRIPT_DIR/config/subagents.json" ]; then
        cp "$SCRIPT_DIR/config/subagents.json" "$SUBAGENTS_FILE"
    fi

    # Shared files that work mode also needs
    if [ ! -f "$CYCLE_LOG_FILE" ]; then
        echo '{"schema_version":1,"cycles":[]}' > "$CYCLE_LOG_FILE"
        log "Created cycle-log.json"
    fi
    if [ ! -f "$JOURNAL_FILE" ]; then
        touch "$JOURNAL_FILE"
        log "Created journal.md"
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        # Minimal config — work mode doesn't need module discovery
        echo '{"modules":{},"docs_root":".","cycle_sleep_seconds":10}' > "$CONFIG_FILE"
        log "Created minimal config.json"
    fi

    # Copy fix-json utility if available
    if [ ! -f "$STATE_DIR/fix-json.py" ] && [ -f "$SCRIPT_DIR/fix-json.py" ]; then
        cp "$SCRIPT_DIR/fix-json.py" "$STATE_DIR/fix-json.py"
    fi

    # Copy maintenance prompt so work mode can trigger maintenance cycles (RL-023)
    if [ ! -f "$MAINTENANCE_PROMPT_FILE" ] && [ -f "$SCRIPT_DIR/prompts/maintenance.md" ]; then
        cp "$SCRIPT_DIR/prompts/maintenance.md" "$MAINTENANCE_PROMPT_FILE"
        log "Copied maintenance prompt for work mode"
    fi
}

# Print task progress summary
print_task_summary() {
    if [ ! -f "$TASKS_FILE" ]; then
        echo "  No tasks.json found"
        return
    fi

    local total pending in_progress completed failed blocked
    total=$(jq '.tasks | length' "$TASKS_FILE")
    pending=$(jq '[.tasks[] | select(.status == "pending")] | length' "$TASKS_FILE")
    in_progress=$(jq '[.tasks[] | select(.status == "in_progress")] | length' "$TASKS_FILE")
    completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$TASKS_FILE")
    failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$TASKS_FILE")
    blocked=$(jq '[.tasks[] | select(.status == "blocked")] | length' "$TASKS_FILE")

    echo -e "  Tasks: ${GREEN}${completed}${NC} done | ${YELLOW}${in_progress}${NC} active | ${BLUE}${pending}${NC} pending | ${RED}${failed}${NC} failed | ${MAGENTA}${blocked}${NC} blocked | ${total} total"

    local current_task
    current_task=$(jq -r '.current_task // "none"' "$WORK_STATE_FILE" 2>/dev/null)
    if [ "$current_task" != "none" ] && [ "$current_task" != "null" ]; then
        local task_title
        task_title=$(jq -r --arg id "$current_task" '.tasks[] | select(.id == $id) | .title // "unknown"' "$TASKS_FILE")
        echo -e "  Current: ${YELLOW}${current_task}${NC} — ${task_title}"
    fi

    local cycle_count
    cycle_count=$(jq '.total_cycles' "$WORK_STATE_FILE" 2>/dev/null || echo "0")
    echo "  Cycles: $cycle_count"
}

# Run pre-flight validation baseline (once at startup)
run_preflight_validation() {
    log "Running pre-flight validation baseline..."

    # Collect validation commands from all tasks
    local all_commands
    all_commands=$(jq -r '.tasks[].validation_commands[]?' "$TASKS_FILE" 2>/dev/null | sort -u)

    if [ -z "$all_commands" ]; then
        # Fallback: try common validation commands from CLAUDE.md patterns
        log "No task validation commands found, skipping pre-flight"
        return 0
    fi

    local results="{}"
    local pass_count=0
    local fail_count=0

    while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        log "  Baseline: $cmd"

        # Safety check: audit, allowlist, denylist
        if ! _check_validation_cmd "$cmd"; then
            results=$(echo "$results" | jq \
                --arg cmd "$cmd" \
                '. + {($cmd): {"exit_code": 1, "output": "BLOCKED by validation safety check"}}')
            fail_count=$((fail_count + 1))
            continue
        fi

        local exit_code=0
        local cmd_output
        local raw_output
        cd "$DOCS_DIR"
        raw_output=$(run_with_timeout 120 bash -c "$cmd" 2>&1) || exit_code=$?
        cmd_output=$(echo "$raw_output" | tail -30)

        results=$(echo "$results" | jq \
            --arg cmd "$cmd" \
            --arg code "$exit_code" \
            --arg out "$cmd_output" \
            '. + {($cmd): {"exit_code": ($code|tonumber), "output": $out}}')

        if [ "$exit_code" -eq 0 ]; then
            log_success "  PASS: $cmd"
            pass_count=$((pass_count + 1))
        else
            log_warn "  FAIL (exit $exit_code): $cmd"
            fail_count=$((fail_count + 1))
        fi
    done <<< "$all_commands"

    # Write baseline results — injected into the first cycle
    local summary="${pass_count} passed, ${fail_count} failed"
    results=$(echo "$results" | jq --arg s "$summary" '. + {"_summary": $s}')
    echo "$results" | jq '.' > "$LAST_VALIDATION_FILE"
    log "Pre-flight baseline: $summary (written to last-validation-results.json)"
}

# Run post-cycle external validation
run_post_work_validation() {
    local current_task
    current_task=$(jq -r '.current_task // empty' "$WORK_STATE_FILE" 2>/dev/null)

    if [ -z "$current_task" ]; then
        return 0
    fi

    local has_commands
    has_commands=$(jq -r --arg id "$current_task" '.tasks[] | select(.id == $id) | .validation_commands | length' "$TASKS_FILE" 2>/dev/null)

    if [ -z "$has_commands" ] || [ "$has_commands" = "0" ]; then
        return 0
    fi

    log "Running external validation for task: $current_task"

    local results="{}"
    local commands
    commands=$(jq -r --arg id "$current_task" '.tasks[] | select(.id == $id) | .validation_commands[]' "$TASKS_FILE")

    local pass_count=0
    local fail_count=0

    while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        log "  Validating: $cmd"

        # Safety check: audit, allowlist, denylist
        if ! _check_validation_cmd "$cmd"; then
            results=$(echo "$results" | jq \
                --arg cmd "$cmd" \
                '. + {($cmd): {"exit_code": 1, "output": "BLOCKED by validation safety check"}}')
            fail_count=$((fail_count + 1))
            continue
        fi

        local exit_code=0
        local cmd_output
        local raw_output
        cd "$DOCS_DIR"
        # Capture exit code before truncating output (pipeline would mask it)
        raw_output=$(run_with_timeout 120 bash -c "$cmd" 2>&1) || exit_code=$?
        cmd_output=$(echo "$raw_output" | tail -30)

        results=$(echo "$results" | jq \
            --arg cmd "$cmd" \
            --arg code "$exit_code" \
            --arg out "$cmd_output" \
            '. + {($cmd): {"exit_code": ($code|tonumber), "output": $out}}')

        if [ "$exit_code" -eq 0 ]; then
            log_success "  PASS: $cmd"
            pass_count=$((pass_count + 1))
        else
            log_error "  FAIL (exit $exit_code): $cmd"
            fail_count=$((fail_count + 1))
        fi
    done <<< "$commands"

    # Add summary for quick parsing by agent
    local summary="${pass_count} passed, ${fail_count} failed"
    results=$(echo "$results" | jq --arg s "$summary" '. + {"_summary": $s}')

    echo "$results" | jq '.' > "$LAST_VALIDATION_FILE"
    log "Validation: $summary (written to last-validation-results.json)"
}

# build_git_exclude_pathspecs
# Populates GIT_EXCLUDE_PATHSPECS with :(exclude) pathspecs derived from
# WORK_GIT_EXCLUDE_DEFAULTS and RALPH_GIT_EXCLUDE. Call once per commit cycle.
build_git_exclude_pathspecs() {
    GIT_EXCLUDE_PATHSPECS=()
    for _pat in "${WORK_GIT_EXCLUDE_DEFAULTS[@]}"; do
        GIT_EXCLUDE_PATHSPECS+=(":(exclude)$_pat")
    done
    if [ -n "${RALPH_GIT_EXCLUDE:-}" ]; then
        for _pat in $RALPH_GIT_EXCLUDE; do
            GIT_EXCLUDE_PATHSPECS+=(":(exclude)$_pat")
        done
    fi
}

# Commit work changes (single commit per cycle)
# Validates before committing — if validation fails, changes stay uncommitted
# so the next cycle can fix them (set VALIDATE_BEFORE_COMMIT=false to skip)
commit_work_changes() {
    local cycle_num="$1"

    if [ "$SKIP_COMMIT" = "true" ]; then
        return
    fi

    # Find git root (may differ from DOCS_DIR)
    local git_root
    git_root=$(cd "$DOCS_DIR" && git rev-parse --show-toplevel 2>/dev/null) || return 0
    cd "$git_root"

    # Build exclusion pathspecs once; reused by git status, git add, and
    # the untracked-file warning check below.
    build_git_exclude_pathspecs

    # Scope the change-detection check to the same set we would stage,
    # so we don't attempt an empty commit when only excluded files changed.
    local all_changes
    all_changes=$(git status --porcelain -- "${GIT_EXCLUDE_PATHSPECS[@]}" 2>/dev/null)
    if [ -n "$all_changes" ]; then
        # Validate before committing (default: true)
        if [ "${VALIDATE_BEFORE_COMMIT:-true}" = "true" ] && [ -f "$LAST_VALIDATION_FILE" ]; then
            local fail_count
            fail_count=$(jq '[to_entries[] | select(.key != "_summary") | select(.value.exit_code != 0)] | length' "$LAST_VALIDATION_FILE" 2>/dev/null || echo "0")
            if [ "$fail_count" -gt 0 ]; then
                log_warn "Skipping commit: validation has $fail_count failures. Changes preserved for next cycle to fix."
                cd "$DOCS_DIR"
                return 0
            fi
        fi

        # Get current task name for a descriptive commit message
        local task_id
        task_id=$(jq -r '.current_task // empty' "$WORK_STATE_FILE" 2>/dev/null)
        local action
        action=$(jq -r '.last_action // "work"' "$WORK_STATE_FILE" 2>/dev/null)

        local commit_msg="$WORK_COMMIT_MSG_PREFIX $cycle_num"
        if [ -n "$task_id" ]; then
            commit_msg="$commit_msg [$action] $task_id"
        else
            commit_msg="$commit_msg [$action]"
        fi

        # || true: git add exits 1 when an excluded path is gitignored
        # (e.g. _state/ in .gitignore), but files are still staged correctly.
        git add -A -- "${GIT_EXCLUDE_PATHSPECS[@]}" || true

        # Audit log: show what was staged
        local _staged_count
        _staged_count=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
        log "Staging $_staged_count file(s) for commit"
        if [ "${RALPH_VERBOSE_COMMIT:-false}" = "true" ]; then
            git diff --cached --name-only 2>/dev/null | while IFS= read -r _f; do
                log "  staged: $_f"
            done
        fi

        # Warn if untracked non-excluded files remain (possible data loss)
        local _remaining
        _remaining=$(git ls-files --others --exclude-standard -- "${GIT_EXCLUDE_PATHSPECS[@]}" 2>/dev/null)
        if [ -n "$_remaining" ]; then
            log_warn "Untracked files not staged (add to RALPH_GIT_EXCLUDE if unintentional):"
            echo "$_remaining" | head -10 | while IFS= read -r _f; do
                log_warn "  unstaged: $_f"
            done
        fi

        git commit -m "$commit_msg"
        log_success "Committed: $commit_msg"
    fi

    cd "$DOCS_DIR"
}

# Ensure LEARNINGS.md exists with a standard header so the agent can append patterns.
# Content is written by the agent directly during work cycles (see prompts/work.md).
# This function only creates the skeleton file if absent (idempotent safety net).
ensure_learnings_file() {
    local learnings_file="$DOCS_DIR/LEARNINGS.md"

    # Guard: if journal doesn't exist, state isn't initialized — skip
    if [ ! -f "$JOURNAL_FILE" ]; then
        return 0
    fi

    # Create LEARNINGS.md with header if it doesn't exist yet
    if [ ! -f "$learnings_file" ]; then
        cat > "$learnings_file" <<'LEARNINGS_HEADER'
# Learnings

Accumulated patterns, gotchas, and conventions discovered by the ralph-loop agent.
This file is read at the start of every cycle so future iterations benefit from past discoveries.

Content is managed by the agent during work cycles. Manual edits are preserved.

---

LEARNINGS_HEADER
        log "Created LEARNINGS.md"
    fi
}

# Run one work cycle
run_work_cycle() {
    local cycle_num
    cycle_num=$(jq '.total_cycles' "$WORK_STATE_FILE" 2>/dev/null || echo "0")
    cycle_num=$((cycle_num + 1))

    # Periodic maintenance cycle trigger — mirrors run_cycle() in lib/discovery.sh (RL-023)
    if [ -f "$MAINTENANCE_PROMPT_FILE" ]; then
        local maintenance_trigger
        if maintenance_trigger=$(should_run_maintenance "$WORK_STATE_FILE"); then
            run_maintenance_cycle "$maintenance_trigger" "$WORK_STATE_FILE" \
                || log_error "Maintenance cycle failed, continuing..."
        fi
    fi

    log "═══════════════════════════════════════════════════════"
    log "Starting work cycle #$cycle_num"
    log "═══════════════════════════════════════════════════════"
    print_task_summary
    echo ""

    # Build prompt — resolve all {{variable}} placeholders
    local prompt
    prompt=$(apply_prompt_vars "$(cat "$WORK_PROMPT_FILE")" "work" "${cycle_num:-0}")

    if [ -f "$LAST_VALIDATION_FILE" ]; then
        local validation_content
        validation_content=$(cat "$LAST_VALIDATION_FILE")
        prompt="$prompt

────────────────────────────────────────
PREVIOUS CYCLE VALIDATION RESULTS
────────────────────────────────────────
The runner executed validation commands after the last cycle. Results:

\`\`\`json
$validation_content
\`\`\`

Use these results to decide your action (fix if failed, continue if passed)."
        # Clean up after injection (skip in dry-run to preserve non-destructive guarantee)
        if [ "${DRY_RUN:-false}" != "true" ]; then
            rm -f "$LAST_VALIDATION_FILE"
        fi
    fi

    # Inject compound learning context — recent learnings from previous cycles
    local learnings_file="$DOCS_DIR/LEARNINGS.md"
    if [ -f "$learnings_file" ]; then
        local learnings_lines
        learnings_lines=$(wc -l < "$learnings_file" | tr -d ' ')
        if [ "$learnings_lines" -gt 5 ]; then
            # Inject last 50 lines of LEARNINGS.md (most recent patterns)
            local recent_learnings
            recent_learnings=$(tail -50 "$learnings_file")
            prompt="$prompt

────────────────────────────────────────
ACCUMULATED LEARNINGS (from previous cycles)
────────────────────────────────────────
These patterns were discovered by previous cycles. Use them to avoid repeating mistakes:

$recent_learnings

After THIS cycle, if you discovered a new reusable pattern, append it to LEARNINGS.md.
If you discovered a pattern is WRONG, remove or correct it in LEARNINGS.md."
        fi
    fi

    # ── DRY-RUN EXIT POINT ──────────────────────────────────────────────────
    # All prompt assembly is complete. In dry-run mode: print report and return.
    # Journal, state-update, and commit steps are intentionally skipped — dry-run
    # must not mutate cycle state.
    if [ "${DRY_RUN:-false}" = "true" ]; then
        local dry_run_output_file="${DOCS_DIR}/_state/dry-run-prompt.md"
        _print_dry_run_report "work-once" "$prompt" "$dry_run_output_file"
        return 0
    fi
    # ── END DRY-RUN ─────────────────────────────────────────────────────────

    cd "$DOCS_DIR"

    log "Running work agent (model: $CLAUDE_MODEL, timeout: ${WORK_AGENT_TIMEOUT}s)..."

    invoke_claude_agent "$prompt" "Work cycle #$cycle_num"
    local output="$LAST_AGENT_OUTPUT"
    local status="$LAST_AGENT_STATUS"
    local duration="$LAST_AGENT_DURATION"
    echo "$output"

    # Append to journal
    {
        echo ""
        echo "---"
        echo ""
        echo "## Work Cycle $cycle_num — $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "**Duration**: ${duration}s | **Status**: $status | **Model**: $CLAUDE_MODEL"
        echo ""
        echo "$output"
    } >> "$JOURNAL_FILE"

    log "Saved cycle output to journal.md"

    # Rotate journal if it exceeds JOURNAL_MAX_LINES (RL-023)
    if [ -f "$JOURNAL_FILE" ]; then
        local journal_lines
        journal_lines=$(wc -l < "$JOURNAL_FILE" | tr -d ' ')
        if [ "$journal_lines" -gt "$JOURNAL_MAX_LINES" ]; then
            log_warn "journal.md exceeds $JOURNAL_MAX_LINES lines ($journal_lines) — rotating"
            local tmp
            tmp=$(mktemp)
            echo "<!-- Journal rotated $(iso_date) — kept last $JOURNAL_KEEP_LINES of $journal_lines lines -->" > "$tmp"
            tail -n "$JOURNAL_KEEP_LINES" "$JOURNAL_FILE" >> "$tmp" && mv "$tmp" "$JOURNAL_FILE"
            log "journal.md rotated: kept last $JOURNAL_KEEP_LINES lines"
        fi
    fi

    # Log to cycle-log.json (with optional token data from invoke_claude_agent)
    local action_type
    action_type=$(jq -r '.last_action // "unknown"' "$WORK_STATE_FILE" 2>/dev/null)

    jq --arg num "$cycle_num" \
       --arg time "$(iso_date)" \
       --arg dur "$duration" \
       --arg status "$status" \
       --arg type "work" \
       --arg action "$action_type" \
       --arg cost "${LAST_AGENT_COST:-}" \
       --arg input_t "${LAST_AGENT_INPUT_TOKENS:-}" \
       --arg out_t "${LAST_AGENT_OUTPUT_TOKENS:-}" \
       --arg cr "${LAST_AGENT_CACHE_READ:-}" \
       --arg cc "${LAST_AGENT_CACHE_CREATED:-}" \
       '.cycles += [{"cycle": ($num|tonumber), "timestamp": $time, "duration_seconds": ($dur|tonumber), "status": $status, "type": $type, "action": $action} + (if $cost != "" then {"tokens": {"input": ($input_t|tonumber), "output": ($out_t|tonumber), "cache_read": ($cr|tonumber), "cache_created": ($cc|tonumber), "cost_usd": ($cost|tonumber)}} else {} end)]' \
       "$CYCLE_LOG_FILE" > "$CYCLE_LOG_FILE.tmp" && mv "$CYCLE_LOG_FILE.tmp" "$CYCLE_LOG_FILE"

    log "Work cycle #$cycle_num completed in ${duration}s"
    notify "cycle" "$cycle_num" "Work cycle #$cycle_num completed in ${duration}s" "work"

    cd "$DOCS_DIR"

    validate_json_files

    # Empty-task detection: count consecutive cycles with 0 tasks
    local task_count
    task_count=$(jq '.tasks | length' "$TASKS_FILE" 2>/dev/null || echo 0)
    if [ "$task_count" -eq 0 ]; then
        _empty_task_cycle_count=$((_empty_task_cycle_count + 1))
        log_warn "No tasks in tasks.json ($_empty_task_cycle_count/$MAX_EMPTY_TASK_CYCLES consecutive empty-task cycles)"
    else
        _empty_task_cycle_count=0
    fi

    # Run post-cycle external validation
    run_post_work_validation

    # Stalemate detection
    if ! check_stalemate; then
        return 1
    fi

    # Compound learning — ensure LEARNINGS.md exists for the agent to update
    ensure_learnings_file

    # Commit changes
    commit_work_changes "$cycle_num"
}

# Show work status summary
show_work_status() {
    echo ""
    echo "┌──────────────────────────────────────────────────┐"
    echo "│  Ralph Loop — Work Status                        │"
    echo "└──────────────────────────────────────────────────┘"
    echo ""

    if [ ! -f "$WORK_STATE_FILE" ] || [ ! -f "$TASKS_FILE" ]; then
        echo "Work mode not initialized. Run: $0 --setup"
        return
    fi

    echo "=== Task Progress ==="
    print_task_summary
    echo ""

    echo "=== Action Stats ==="
    jq '.stats' "$WORK_STATE_FILE"
    echo ""

    echo "=== Blocked Tasks ==="
    local blocked
    blocked=$(jq -r '.tasks[] | select(.status == "blocked") | "  \(.id): \(.title)"' "$TASKS_FILE" 2>/dev/null)
    if [ -n "$blocked" ]; then
        echo "$blocked"
    else
        echo "  (none)"
    fi
    echo ""

    echo "=== Failed Tasks ==="
    local failed
    failed=$(jq -r '.tasks[] | select(.status == "failed") | "  \(.id): \(.title) (\(.attempts | length) attempts)"' "$TASKS_FILE" 2>/dev/null)
    if [ -n "$failed" ]; then
        echo "$failed"
    else
        echo "  (none)"
    fi
    echo ""

    echo "=== Last 5 Cycles ==="
    jq '.cycles | [.[] | select(.type == "work")] | .[-5:]' "$CYCLE_LOG_FILE" 2>/dev/null || echo "  (no cycles yet)"
}

# Check if work loop should continue
work_loop_should_continue() {
    # AUTONOMOUS MODEL: Agent decides what to work on and when tasks are done.
    # Runner enforces safety limits and detects completion signal.
    #
    # Return 0 = continue looping
    # Return 1 = stop looping

    # Check if agent signaled all tasks complete
    if [ -f "$WORK_STATE_FILE" ]; then
        local all_complete
        all_complete=$(jq -r '.all_tasks_complete // false' "$WORK_STATE_FILE" 2>/dev/null)
        if [ "$all_complete" = "true" ]; then
            log_success "Agent signaled ALL_TASKS_COMPLETE. Running final validation (all tasks)..."
            run_preflight_validation
            local validation_ok=true
            if [ -f "$LAST_VALIDATION_FILE" ]; then
                local fail_count
                fail_count=$(jq '[to_entries[] | select(.key != "_summary") | select(.value.exit_code != 0)] | length' "$LAST_VALIDATION_FILE" 2>/dev/null || echo "0")
                if [ "$fail_count" -gt 0 ]; then
                    log_warn "Final validation has $fail_count failures — continuing loop for fixes"
                    # Reset the flag so agent can fix and re-signal
                    jq '.all_tasks_complete = false' "$WORK_STATE_FILE" > "$WORK_STATE_FILE.tmp" && mv "$WORK_STATE_FILE.tmp" "$WORK_STATE_FILE"
                    validation_ok=false
                fi
            fi
            if [ "$validation_ok" = "true" ]; then
                log_success "All tasks complete and validation passed. Work loop finished."
                notify "complete" "$(jq '.total_cycles // 0' "$WORK_STATE_FILE" 2>/dev/null || echo 0)" \
                    "All tasks complete and validation passed." "work"
                return 1
            fi
        fi
    fi

    # Get current cycle number
    local current_cycle=0
    if [ -f "$WORK_STATE_FILE" ]; then
        current_cycle=$(jq '.total_cycles // 0' "$WORK_STATE_FILE" 2>/dev/null || echo "0")
    fi

    # Max cycles from environment (0 = unlimited)
    local max_cycles="${MAX_WORK_CYCLES:-0}"

    if [ "$max_cycles" -gt 0 ] && [ "$current_cycle" -ge "$max_cycles" ]; then
        log_warn "Max cycles ($max_cycles) reached. Work loop finished."
        return 1
    fi

    # Guard: cumulative spend exceeds budget limit
    # Safety: $cumulative_cost comes from get_cumulative_cost() (jq-sanitized numeric output).
    # $RALPH_BUDGET_LIMIT was regex-validated in validate_env() at startup (digits/dot only).
    if [ -n "${RALPH_BUDGET_LIMIT:-}" ]; then
        local cumulative_cost
        cumulative_cost=$(get_cumulative_cost)
        if awk "BEGIN { exit ($cumulative_cost >= $RALPH_BUDGET_LIMIT) ? 0 : 1 }"; then
            log_warn "Budget limit reached: \$${cumulative_cost} >= \$${RALPH_BUDGET_LIMIT}. Stopping loop."
            notify "budget" "${current_cycle:-0}" \
                "Budget limit reached: \$${cumulative_cost} >= \$${RALPH_BUDGET_LIMIT}" "work"
            return 1
        fi
    fi

    # Guard: abort after too many consecutive failures/timeouts
    if [ "$_consecutive_failure_count" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        log_error "Aborting: $MAX_CONSECUTIVE_FAILURES consecutive cycle failures/timeouts. Check agent configuration."
        notify "error" "$_consecutive_failure_count" \
            "Aborting: $MAX_CONSECUTIVE_FAILURES consecutive cycle failures/timeouts." "work"
        return 1
    fi

    # Guard: abort on stalemate (no changes for too many cycles)
    if [ "$_stale_cycle_count" -ge "$MAX_STALE_CYCLES" ]; then
        log_error "Aborting: $MAX_STALE_CYCLES consecutive cycles with no file changes (stalemate)."
        notify "stalemate" "$_stale_cycle_count" \
            "Aborting: $MAX_STALE_CYCLES consecutive stale cycles (no file changes)." "work"
        return 1
    fi

    # Guard: abort after too many consecutive cycles with no tasks
    if [ "$_empty_task_cycle_count" -ge "$MAX_EMPTY_TASK_CYCLES" ]; then
        log_error "Aborting: $MAX_EMPTY_TASK_CYCLES consecutive cycles with 0 tasks in tasks.json. Seed tasks or check agent configuration."
        return 1
    fi

    # Otherwise, always continue — agent decides when to stop
    return 0
}
