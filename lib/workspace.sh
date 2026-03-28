#!/bin/bash
# lib/workspace.sh — Multi-project workspace orchestration (RL-058)
#
# Dependencies: lib/common.sh (for log*, iso_date)
# Globals set by this file: _WS_CONFIG _WS_DIR _WS_STATE_FILE
#                           _WS_LEARNINGS_FILE _WS_CYCLE_LOG_FILE

# Workspace state directory (inside ralph-loop dir, not any project's _state/)
_WS_DIR=""
_WS_STATE_FILE=""
_WS_LEARNINGS_FILE=""
_WS_CYCLE_LOG_FILE=""
_WS_CONFIG=""

# ──────────────────────────────────────────────────────────────────
# CONFIG PARSING
# ──────────────────────────────────────────────────────────────────

# parse_workspace_config CONFIG_PATH
# Validates the config file exists and is valid JSON with required fields.
# Sets _WS_CONFIG to the absolute path.
# Returns 0 on success, exits 1 on error.
parse_workspace_config() {
    local config_path="$1"
    if [ ! -f "$config_path" ]; then
        log_error "Workspace config not found: $config_path"
        return 1
    fi
    if ! jq empty "$config_path" 2>/dev/null; then
        log_error "Workspace config is not valid JSON: $config_path"
        return 1
    fi
    local project_count
    project_count=$(jq '.projects | length' "$config_path" 2>/dev/null || echo "0")
    if [ "$project_count" -lt 1 ]; then
        log_error "Workspace config must have at least one project in .projects[]"
        return 1
    fi
    _WS_CONFIG="$(cd "$(dirname "$config_path")" && pwd)/$(basename "$config_path")"
}

# validate_workspace_projects
# Resolves each project path relative to config file location.
# Requires _WS_CONFIG to be set (via parse_workspace_config).
# Exits 1 if any project path does not exist on disk.
validate_workspace_projects() {
    local config_path="$_WS_CONFIG"
    local config_dir
    config_dir="$(dirname "$config_path")"
    local count
    count=$(jq '.projects | length' "$config_path")
    local i=0
    while [ "$i" -lt "$count" ]; do
        local rel_path name
        rel_path=$(jq -r ".projects[$i].path" "$config_path")
        name=$(jq -r ".projects[$i].name // \"project-$i\"" "$config_path")
        local abs_path
        abs_path="$(cd "$config_dir" && cd "$rel_path" 2>/dev/null && pwd)" || {
            log_error "Workspace project '$name' path not found: $rel_path (resolved from $config_dir)"
            return 1
        }
        log "Workspace project '$name' resolved to: $abs_path"
        i=$((i + 1))
    done
}

# ──────────────────────────────────────────────────────────────────
# STATE MANAGEMENT
# ──────────────────────────────────────────────────────────────────

# init_workspace_state PROJECT_COUNT
# Creates _workspace/ directory and initialises workspace-state.json.
# Idempotent — safe to call when state already exists.
init_workspace_state() {
    mkdir -p "$_WS_DIR"
    if [ ! -f "$_WS_STATE_FILE" ]; then
        jq -n '{
            total_cycles: 0,
            scheduler_index: 0,
            projects: {}
        }' > "$_WS_STATE_FILE"
    fi
    [ -f "$_WS_LEARNINGS_FILE" ] || touch "$_WS_LEARNINGS_FILE"
    [ -f "$_WS_CYCLE_LOG_FILE" ] || printf '[]' > "$_WS_CYCLE_LOG_FILE"
}

# ──────────────────────────────────────────────────────────────────
# LOCKING
# ──────────────────────────────────────────────────────────────────

# acquire_workspace_lock
# Uses mkdir atomic pattern (same as acquire_run_lock in lib/common.sh).
# Exits 1 if another workspace instance is running.
acquire_workspace_lock() {
    local lock_dir="$_WS_DIR/.ralph-workspace.lock"
    local pid_file="$lock_dir/pid"
    mkdir -p "$_WS_DIR"
    if mkdir "$lock_dir" 2>/dev/null; then
        echo $$ > "$pid_file"
        _cleanup_files+=("$lock_dir")
        return 0
    fi
    # Lock exists — check if the holding PID is alive
    local holder=""
    holder=$(cat "$pid_file" 2>/dev/null || echo "")
    if [ -n "$holder" ] && [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
        log_error "Another workspace instance is running (PID $holder). Aborting."
        return 1
    fi
    # Stale lock — reclaim it
    log_warn "Stale workspace lock found (PID ${holder:-unknown}). Reclaiming."
    echo $$ > "$pid_file"
    _cleanup_files+=("$lock_dir")
}

release_workspace_lock() {
    rm -rf "$_WS_DIR/.ralph-workspace.lock" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────
# SCHEDULING
# ──────────────────────────────────────────────────────────────────

# select_next_project
# Reads scheduler_index from workspace-state.json, returns the index of the next
# active project using round-robin. Skips projects with status != "active".
# Prints the project index (0-based). Advances scheduler_index in state file.
# Returns 1 if no active projects remain.
select_next_project() {
    local count
    count=$(jq '.projects | length' "$_WS_CONFIG")
    local idx
    idx=$(jq '.scheduler_index' "$_WS_STATE_FILE")
    local checked=0
    while [ "$checked" -lt "$count" ]; do
        local name status
        name=$(jq -r ".projects[$idx].name // \"project-$idx\"" "$_WS_CONFIG")
        status=$(jq -r ".projects[\"$name\"].status // \"active\"" "$_WS_STATE_FILE")
        local next_idx=$(( (idx + 1) % count ))
        # Advance index in state before returning (ensures next call advances past this one)
        jq ".scheduler_index = $next_idx" "$_WS_STATE_FILE" > "$_WS_STATE_FILE.tmp" \
            && mv "$_WS_STATE_FILE.tmp" "$_WS_STATE_FILE"
        if [ "$status" = "active" ]; then
            echo "$idx"
            return 0
        fi
        idx="$next_idx"
        checked=$((checked + 1))
    done
    return 1  # No active projects
}

# workspace_loop_should_continue
# Returns 0 (continue) or 1 (stop).
# Stops when: max_total_cycles reached, no active projects remain,
# or _interrupted is set.
workspace_loop_should_continue() {
    # Interrupted by signal
    if [ "${_interrupted:-false}" = "true" ]; then
        log_warn "Workspace interrupted — stopping."
        return 1
    fi
    # Check max_total_cycles (0 = unlimited)
    local max_cycles
    max_cycles=$(jq '.scheduling.max_total_cycles // 0' "$_WS_CONFIG")
    local total_cycles
    total_cycles=$(jq '.total_cycles' "$_WS_STATE_FILE")
    if [ "$max_cycles" -gt 0 ] && [ "$total_cycles" -ge "$max_cycles" ]; then
        log "Workspace budget exhausted ($total_cycles / $max_cycles cycles)."
        return 1
    fi
    # Check if any project is still active
    local active_count
    active_count=$(jq '[.projects[] | select(.status == "active")] | length' "$_WS_STATE_FILE")
    # If no projects have been registered yet, treat as active (first cycle)
    local registered
    registered=$(jq '.projects | length' "$_WS_STATE_FILE")
    if [ "$registered" -gt 0 ] && [ "$active_count" -eq 0 ]; then
        log "All workspace projects are complete or stalled."
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────
# SUBPROCESS CYCLE RUNNER
# ──────────────────────────────────────────────────────────────────

# run_project_cycle PROJECT_INDEX
# Invokes ./run.sh --work-once (or --once for discovery) as a subprocess
# with per-project DOCS_DIR, CLAUDE_MODEL, and env overrides.
# Uses RALPH_RUN_SH env var if set (for testing); defaults to $SCRIPT_DIR/run.sh.
# Returns the subprocess exit code.
run_project_cycle() {
    local idx="$1"
    local config_dir
    config_dir="$(dirname "$_WS_CONFIG")"

    local name mode model rel_path
    name=$(jq -r ".projects[$idx].name // \"project-$idx\"" "$_WS_CONFIG")
    mode=$(jq -r ".projects[$idx].mode // \"work\"" "$_WS_CONFIG")
    model=$(jq -r ".projects[$idx].model // \"\"" "$_WS_CONFIG")
    rel_path=$(jq -r ".projects[$idx].path" "$_WS_CONFIG")

    local abs_path
    abs_path="$(cd "$config_dir" && cd "$rel_path" && pwd)"

    local run_flag="--work-once"
    [ "$mode" = "discovery" ] && run_flag="--once"

    # Build env var array: KEY=VALUE pairs from workspace.json
    local env_vars=()
    env_vars+=("DOCS_DIR=$abs_path")
    [ -n "$model" ] && env_vars+=("CLAUDE_MODEL=$model")

    # Add per-project env overrides
    while IFS= read -r pair; do
        [ -z "$pair" ] && continue
        env_vars+=("$pair")
    done < <(jq -r ".projects[$idx].env // {} | to_entries[] | \"\(.key)=\(.value)\"" "$_WS_CONFIG")

    log "Workspace: starting cycle for '$name' ($mode, model=${model:-inherited})"

    local run_sh="${RALPH_RUN_SH:-$SCRIPT_DIR/run.sh}"
    local exit_code=0
    env "${env_vars[@]}" bash "$run_sh" "$run_flag" || exit_code=$?
    return "$exit_code"
}

# ──────────────────────────────────────────────────────────────────
# STATE UPDATES
# ──────────────────────────────────────────────────────────────────

# update_workspace_state PROJECT_INDEX EXIT_CODE PROJECT_NAME
# Updates per-project counters (cycles, consecutive_failures, stale_cycles, status)
# and workspace total_cycles in workspace-state.json.
update_workspace_state() {
    local idx="$1"
    local exit_code="$2"
    local name="$3"
    local skip_if_complete
    skip_if_complete=$(jq -r ".projects[$idx].skip_if_complete // true" "$_WS_CONFIG")

    # Determine cycle result
    local result="success"
    [ "$exit_code" -ne 0 ] && result="failure"

    # Read per-project counters (defaulting to 0 if project not yet registered)
    local prev_cycles prev_failures prev_stale
    prev_cycles=$(jq -r ".projects[\"$name\"].cycles // 0" "$_WS_STATE_FILE")
    prev_failures=$(jq -r ".projects[\"$name\"].consecutive_failures // 0" "$_WS_STATE_FILE")
    prev_stale=$(jq -r ".projects[\"$name\"].stale_cycles // 0" "$_WS_STATE_FILE")

    local new_failures="$prev_failures"
    local new_stale="$prev_stale"
    local new_status="active"

    if [ "$result" = "success" ]; then
        new_failures=0
    else
        new_failures=$((prev_failures + 1))
    fi

    # Stalemate check — read from project's work-state.json if available
    local project_path
    project_path=$(jq -r ".projects[$idx].path" "$_WS_CONFIG")
    local config_dir
    config_dir="$(dirname "$_WS_CONFIG")"
    local abs_path
    abs_path="$(cd "$config_dir" && cd "$project_path" 2>/dev/null && pwd)" || abs_path=""
    local all_complete=false
    if [ -n "$abs_path" ] && [ -f "$abs_path/_state/work-state.json" ]; then
        all_complete=$(jq -r '.all_tasks_complete // false' "$abs_path/_state/work-state.json" 2>/dev/null || echo "false")
    fi

    # Apply stop conditions
    if [ "$new_failures" -ge "${MAX_CONSECUTIVE_FAILURES:-3}" ]; then
        new_status="stalled"
        log_warn "Workspace: project '$name' stalled after $new_failures consecutive failures."
    elif [ "$all_complete" = "true" ] && [ "$skip_if_complete" = "true" ]; then
        new_status="complete"
        log_success "Workspace: project '$name' complete — removing from rotation."
    fi

    # Write updated state with jq (immutable update)
    jq --arg name "$name" \
       --argjson cycles "$((prev_cycles + 1))" \
       --argjson failures "$new_failures" \
       --argjson stale "$new_stale" \
       --arg status "$new_status" \
       --arg result "$result" \
       --arg ts "$(iso_date)" \
       '.total_cycles += 1 |
        .projects[$name] = {
            cycles: $cycles,
            consecutive_failures: $failures,
            stale_cycles: $stale,
            status: $status,
            last_cycle_result: $result,
            last_cycle_timestamp: $ts
        }' \
        "$_WS_STATE_FILE" > "$_WS_STATE_FILE.tmp" \
        && mv "$_WS_STATE_FILE.tmp" "$_WS_STATE_FILE"
}

# ──────────────────────────────────────────────────────────────────
# CROSS-PROJECT LEARNINGS
# ──────────────────────────────────────────────────────────────────

# harvest_learnings_from_project PROJECT_INDEX PROJECT_NAME
# Scans project's LEARNINGS.md for lines tagged with learnings.tag.
# Appends new (deduplicated) entries to _workspace/workspace-learnings.md.
harvest_learnings_from_project() {
    local idx="$1"
    local name="$2"
    local tag
    tag=$(jq -r '.learnings.tag // "[cross-project]"' "$_WS_CONFIG")
    local config_dir
    config_dir="$(dirname "$_WS_CONFIG")"
    local rel_path
    rel_path=$(jq -r ".projects[$idx].path" "$_WS_CONFIG")
    local abs_path
    abs_path="$(cd "$config_dir" && cd "$rel_path" 2>/dev/null && pwd)" || return 0
    local learnings_file="$abs_path/LEARNINGS.md"
    [ -f "$learnings_file" ] || return 0

    # Extract tagged lines, dedup against workspace-learnings.md
    while IFS= read -r line; do
        # Skip if already present (exact line match)
        if ! grep -qFe "$line" "$_WS_LEARNINGS_FILE" 2>/dev/null; then
            printf '%s\n' "$line" >> "$_WS_LEARNINGS_FILE"
        fi
    done < <(grep -F "$tag" "$learnings_file" 2>/dev/null || true)
}

# sync_learnings_to_project PROJECT_INDEX PROJECT_NAME
# Reads workspace-learnings.md (up to max_inject_lines),
# appends entries to project's LEARNINGS.md marked [workspace-injected].
# Only injects entries not already present.
sync_learnings_to_project() {
    local idx="$1"
    local name="$2"
    [ -f "$_WS_LEARNINGS_FILE" ] || return 0

    local max_lines
    max_lines=$(jq '.learnings.max_inject_lines // 30' "$_WS_CONFIG")
    local config_dir
    config_dir="$(dirname "$_WS_CONFIG")"
    local rel_path
    rel_path=$(jq -r ".projects[$idx].path" "$_WS_CONFIG")
    local abs_path
    abs_path="$(cd "$config_dir" && cd "$rel_path" 2>/dev/null && pwd)" || return 0
    local project_learnings="$abs_path/LEARNINGS.md"

    # Tail the workspace learnings to max_inject_lines
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Re-tag as [workspace-injected] so the agent knows the source
        local injected_line
        injected_line="$line [workspace-injected]"
        if ! grep -qFe "$injected_line" "$project_learnings" 2>/dev/null; then
            printf '%s\n' "$injected_line" >> "$project_learnings"
        fi
    done < <(tail -n "$max_lines" "$_WS_LEARNINGS_FILE" 2>/dev/null || true)
}

# ──────────────────────────────────────────────────────────────────
# SUMMARY AND STATUS
# ──────────────────────────────────────────────────────────────────

# show_workspace_status [CONFIG_PATH]
# Prints per-project task progress and workspace counters.
show_workspace_status() {
    local config_path="${1:-${_WS_CONFIG:-$SCRIPT_DIR/workspace.json}}"
    [ -z "${_WS_CONFIG:-}" ] && parse_workspace_config "$config_path"
    _WS_DIR="${_WS_DIR:-$SCRIPT_DIR/_workspace}"
    _WS_STATE_FILE="${_WS_STATE_FILE:-$_WS_DIR/workspace-state.json}"

    if [ ! -f "$_WS_STATE_FILE" ]; then
        log_warn "No workspace state found at $_WS_STATE_FILE. Run --workspace first."
        return 0
    fi

    echo ""
    echo "=== Workspace Status ==="
    local total
    total=$(jq '.total_cycles' "$_WS_STATE_FILE")
    echo "  total cycles: $total"
    echo ""
    jq -r '.projects | to_entries[] | "  \(.key): status=\(.value.status) cycles=\(.value.cycles) failures=\(.value.consecutive_failures)"' \
        "$_WS_STATE_FILE"
    echo ""
}

# show_workspace_summary [CONFIG_PATH]
# Reads each project's _state/cycle-log.json and the workspace cycle log,
# prints an aggregate summary grouped by project.
show_workspace_summary() {
    local config_path="${1:-${_WS_CONFIG:-$SCRIPT_DIR/workspace.json}}"
    [ -z "${_WS_CONFIG:-}" ] && parse_workspace_config "$config_path"
    _WS_DIR="${_WS_DIR:-$SCRIPT_DIR/_workspace}"
    _WS_STATE_FILE="${_WS_STATE_FILE:-$_WS_DIR/workspace-state.json}"

    echo ""
    echo "=== Workspace Summary ==="
    echo ""

    local count
    count=$(jq '.projects | length' "$_WS_CONFIG")
    local i=0
    local workspace_total=0
    while [ "$i" -lt "$count" ]; do
        local name rel_path
        name=$(jq -r ".projects[$i].name // \"project-$i\"" "$_WS_CONFIG")
        rel_path=$(jq -r ".projects[$i].path" "$_WS_CONFIG")
        local config_dir
        config_dir="$(dirname "$_WS_CONFIG")"
        local abs_path
        abs_path="$(cd "$config_dir" && cd "$rel_path" 2>/dev/null && pwd)" || abs_path=""
        local cycle_log="$abs_path/_state/cycle-log.json"

        local proj_cycles=0
        local proj_status="unknown"
        if [ -f "$_WS_STATE_FILE" ]; then
            proj_cycles=$(jq -r ".projects[\"$name\"].cycles // 0" "$_WS_STATE_FILE")
            proj_status=$(jq -r ".projects[\"$name\"].status // \"unknown\"" "$_WS_STATE_FILE")
        fi
        workspace_total=$((workspace_total + proj_cycles))

        echo "  $name ($proj_status — $proj_cycles cycles)"

        if [ -f "$cycle_log" ] && [ "$(jq 'length' "$cycle_log" 2>/dev/null)" -gt 0 ]; then
            local success_count failure_count
            success_count=$(jq '[.[] | select(.status == "success")] | length' "$cycle_log" 2>/dev/null || echo "0")
            failure_count=$(jq '[.[] | select(.status != "success")] | length' "$cycle_log" 2>/dev/null || echo "0")
            echo "    By status: success: $success_count, failure: $failure_count"
        fi
        echo ""
        i=$((i + 1))
    done

    echo "  Workspace totals: $workspace_total cycles"
    echo ""
}

# ──────────────────────────────────────────────────────────────────
# MAIN ENTRY POINTS
# ──────────────────────────────────────────────────────────────────

# workspace_main CONFIG_PATH
# Full workspace orchestration loop. Runs until budget exhausted,
# all projects complete/stalled, or interrupted.
workspace_main() {
    local config_path="${1:-$SCRIPT_DIR/workspace.json}"
    parse_workspace_config "$config_path"
    validate_workspace_projects

    # Set up workspace state dir adjacent to ralph-loop _state/
    _WS_DIR="$SCRIPT_DIR/_workspace"
    _WS_STATE_FILE="$_WS_DIR/workspace-state.json"
    _WS_LEARNINGS_FILE="$_WS_DIR/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$_WS_DIR/workspace-cycle-log.json"

    acquire_workspace_lock
    init_workspace_state "$(jq '.projects | length' "$_WS_CONFIG")"

    log "Workspace started: $(jq '.projects | length' "$_WS_CONFIG") projects, strategy=$(jq -r '.scheduling.strategy' "$_WS_CONFIG"), max=$(jq '.scheduling.max_total_cycles' "$_WS_CONFIG") cycles"

    while workspace_loop_should_continue; do
        local project_idx
        project_idx=$(select_next_project) || {
            log "No active projects remaining. Stopping workspace."
            break
        }
        local project_name
        project_name=$(jq -r ".projects[$project_idx].name // \"project-$project_idx\"" "$_WS_CONFIG")

        # Inject cross-project learnings before cycle
        if [ "$(jq -r '.learnings.shared // false' "$_WS_CONFIG")" = "true" ]; then
            sync_learnings_to_project "$project_idx" "$project_name"
        fi

        local cycle_exit=0
        run_project_cycle "$project_idx" || cycle_exit=$?

        # Harvest learnings after cycle
        if [ "$(jq -r '.learnings.shared // false' "$_WS_CONFIG")" = "true" ]; then
            harvest_learnings_from_project "$project_idx" "$project_name"
        fi

        update_workspace_state "$project_idx" "$cycle_exit" "$project_name"
    done

    log_success "Workspace finished. Total cycles: $(jq '.total_cycles' "$_WS_STATE_FILE")"
}

# workspace_once_main CONFIG_PATH
# Runs exactly one cycle per active project, then exits.
workspace_once_main() {
    local config_path="${1:-$SCRIPT_DIR/workspace.json}"
    parse_workspace_config "$config_path"
    validate_workspace_projects

    _WS_DIR="$SCRIPT_DIR/_workspace"
    _WS_STATE_FILE="$_WS_DIR/workspace-state.json"
    _WS_LEARNINGS_FILE="$_WS_DIR/workspace-learnings.md"
    _WS_CYCLE_LOG_FILE="$_WS_DIR/workspace-cycle-log.json"

    acquire_workspace_lock
    init_workspace_state "$(jq '.projects | length' "$_WS_CONFIG")"

    local count
    count=$(jq '.projects | length' "$_WS_CONFIG")
    local i=0
    while [ "$i" -lt "$count" ]; do
        local name
        name=$(jq -r ".projects[$i].name // \"project-$i\"" "$_WS_CONFIG")
        local cycle_exit=0
        run_project_cycle "$i" || cycle_exit=$?
        update_workspace_state "$i" "$cycle_exit" "$name"
        i=$((i + 1))
    done

    log_success "Workspace once: all projects cycled."
}
