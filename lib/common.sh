#!/bin/bash
# lib/common.sh — Colors, logging, dependency checks, JSON validation,
#                 environment validation, shared utilities.
#
# Dependencies: none (must be sourced first)
# Globals used: STATE_DIR, FRONTIER_FILE, CYCLE_LOG_FILE,
#               MAINTENANCE_STATE_FILE, TASKS_FILE, WORK_STATE_FILE,
#               CLAUDE_MODEL, WORK_AGENT_TIMEOUT, MAX_CONSECUTIVE_FAILURES,
#               MAX_STALE_CYCLES, MAX_WORK_CYCLES, MAX_EMPTY_TASK_CYCLES,
#               ENABLE_MCP, MCP_CONFIG_FILE, SKIP_PERMISSIONS,
#               CLAUDE_ARGS, _cleanup_pids, _last_git_hash,
#               _stale_cycle_count, DOCS_DIR,
#               LAST_AGENT_OUTPUT, LAST_AGENT_STATUS, LAST_AGENT_DURATION,
#               LAST_AGENT_COST, LAST_AGENT_INPUT_TOKENS,
#               LAST_AGENT_OUTPUT_TOKENS, LAST_AGENT_CACHE_READ,
#               LAST_AGENT_CACHE_CREATED,
#               NOTIFY_WEBHOOK_URL, NOTIFY_ON

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Portable ISO 8601 timestamp — works on both GNU and BSD (macOS) date.
# GNU `date -Iseconds` is not available on macOS; this uses POSIX format specifiers.
# Output example: 2024-01-15T14:30:00+0000 (offset without colon, valid ISO 8601).
iso_date() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

# _truncate_url — strips path and query from a URL for safe log output.
# Prevents tokens embedded in webhook URLs (e.g. Slack) from appearing in logs.
# Input:  https://hooks.slack.com/services/T.../B.../token
# Output: https://hooks.slack.com/...
_truncate_url() {
    # shellcheck disable=SC2001
    echo "$1" | sed 's|^\([a-z]*://[^/]*\).*|\1/...|'
}

# _notify_curl_warned — one-time guard to avoid repeated "curl not found" warnings.
_notify_curl_warned=false

# notify — POST a JSON event payload to NOTIFY_WEBHOOK_URL.
# Usage: notify EVENT_NAME CYCLE_NUM SUMMARY [MODE]
#   EVENT_NAME : complete | error | stalemate | cycle
#   CYCLE_NUM  : integer cycle number
#   SUMMARY    : human-readable description (safe for jq --arg)
#   MODE       : work | discovery (optional, defaults to "unknown")
#
# No-ops when NOTIFY_WEBHOOK_URL is empty.
# Respects NOTIFY_ON comma-separated filter (default: complete,error,stalemate).
# Never aborts the loop — all failures produce log_warn and return 0.
notify() {
    local event_name="$1"
    local cycle_num="${2:-0}"
    local summary="${3:-}"
    local mode="${4:-unknown}"

    # Guard 1: URL must be set
    [ -z "${NOTIFY_WEBHOOK_URL:-}" ] && return 0

    # Guard 2: Event filter — check if event_name appears in NOTIFY_ON
    local notify_on="${NOTIFY_ON:-complete,error,stalemate,budget}"
    local matched=false
    # Convert comma-separated list to newlines and grep for exact token match
    if echo "$notify_on" | tr ',' '\n' | grep -qFx "$event_name"; then
        matched=true
    fi
    [ "$matched" = "false" ] && return 0

    # Guard 3: curl must be in PATH
    if ! command -v curl > /dev/null 2>&1; then
        if [ "$_notify_curl_warned" = "false" ]; then
            log_warn "notify: curl not found in PATH — webhook notifications disabled"
            _notify_curl_warned=true
        fi
        return 0
    fi

    # Build JSON payload safely via jq (prevents shell injection in summary text)
    local payload
    payload=$(jq -cn \
        --arg event   "$event_name" \
        --argjson cycle "$cycle_num" \
        --arg summary "$summary" \
        --arg mode    "$mode" \
        --arg model   "${CLAUDE_MODEL:-unknown}" \
        --arg ts      "$(iso_date)" \
        '{event: $event, cycle: $cycle, summary: $summary, mode: $mode, model: $model, timestamp: $ts}')

    # POST — foreground with hard timeout caps; || true neutralises set -e
    local safe_url
    safe_url=$(_truncate_url "$NOTIFY_WEBHOOK_URL")
    local curl_output
    curl_output=$(curl --silent --show-error \
        --max-time 5 \
        --connect-timeout 3 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$NOTIFY_WEBHOOK_URL" 2>&1) || {
        log_warn "notify: webhook POST failed (${safe_url}): $curl_output"
    }

    return 0
}

# RL-011: exact-match PID deregistration — removes both PIDs in one pass and
# compacts accumulated empty-string slots from prior cycles.
# Modifies the global _cleanup_pids indexed array directly.
# Bash 3.2 safe: uses only [[, for, local, indexed array assignment, +=.
_deregister_cleanup_pids() {
    local _pid1="$1" _pid2="$2"
    local _new_pids=()
    local _p
    for _p in "${_cleanup_pids[@]}"; do
        [[ -n "$_p" && "$_p" != "$_pid1" && "$_p" != "$_pid2" ]] && _new_pids+=("$_p")
    done
    _cleanup_pids=("${_new_pids[@]+"${_new_pids[@]}"}")
}

# Portable timeout: runs a command with a deadline.
# Usage: run_with_timeout <seconds> <command> [args...]
# Returns: command exit code, or 124 on timeout.
# Works on macOS (no GNU timeout needed).
run_with_timeout() {
    local secs="$1"; shift

    if [ "$secs" -le 0 ] 2>/dev/null; then
        # Timeout disabled — run directly
        "$@"
        return $?
    fi

    # Run command in background, kill if it exceeds deadline
    "$@" &
    local cmd_pid=$!

    # Watchdog: sleep then kill (trap ensures sleep children are cleaned up on exit)
    (
        trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT
        sleep "$secs" &
        wait $!
        kill -TERM "$cmd_pid" 2>/dev/null
        sleep 10 &
        wait $!
        kill -KILL "$cmd_pid" 2>/dev/null
    ) &
    local watchdog_pid=$!

    # RL-018: register PIDs so the EXIT trap can kill them on interrupt
    _cleanup_pids+=("$cmd_pid" "$watchdog_pid")

    # Wait for the command to finish
    wait "$cmd_pid" 2>/dev/null
    local exit_code=$?

    # Clean up watchdog and its children
    pkill -P "$watchdog_pid" 2>/dev/null || true
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null

    # RL-011: exact-match deregistration — avoids substring corruption
    _deregister_cleanup_pids "$cmd_pid" "$watchdog_pid"

    # Distinguish timeout (killed by TERM=143, KILL=137) from normal failure
    if [ "$exit_code" -eq 143 ] || [ "$exit_code" -eq 137 ]; then
        return 124  # conventional "timed out" exit code
    fi
    return "$exit_code"
}

# acquire_run_lock — enforce single-instance execution per STATE_DIR.
# Uses atomic mkdir as the lock primitive (POSIX-portable, no flock needed).
# Creates $STATE_DIR/.ralph-loop.lock/ directory; writes PID inside it.
# Aborts with exit 1 if another live instance is detected.
# Registers lock directory in _cleanup_files[] so it is removed on EXIT/INT/TERM.
acquire_run_lock() {
    local lock_dir="$STATE_DIR/.ralph-loop.lock"
    local pid_file="$lock_dir/pid"
    mkdir -p "$STATE_DIR"

    # Remove any legacy plain PID file left by a pre-RL-030 installation.
    rm -f "$STATE_DIR/ralph-loop.pid" 2>/dev/null || true

    # Step 1: Attempt atomic lock acquisition.
    if mkdir "$lock_dir" 2>/dev/null; then
        echo "$$" > "$pid_file"
        _cleanup_files+=("$lock_dir")
        log "Lock acquired (PID $$, $lock_dir)"
        return 0
    fi

    # Step 2: mkdir failed — directory exists. Check if the holder is alive.
    local existing_pid
    existing_pid=$(cat "$pid_file" 2>/dev/null || echo "")

    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        log_error "Another ralph-loop instance is running (PID $existing_pid). Aborting."
        log_error "Lock dir: $lock_dir"
        log_error "If the process is gone, remove the directory manually and retry."
        exit 1
    fi

    # Step 3: Holder is dead — stale lock. Remove and retry once.
    log_warn "Stale lock found (PID ${existing_pid:-unknown} is not running). Reclaiming."
    rm -rf "$lock_dir"

    if mkdir "$lock_dir" 2>/dev/null; then
        echo "$$" > "$pid_file"
        _cleanup_files+=("$lock_dir")
        log "Lock acquired (PID $$, $lock_dir)"
        return 0
    fi

    # A third instance reclaimed the stale lock first — genuine contention.
    log_error "Failed to acquire lock after stale cleanup. Another instance may have started."
    exit 1
}

# Validate and repair JSON files
validate_json_files() {
    local had_errors=false
    local fix_script="$STATE_DIR/fix-json.py"
    if [ ! -f "$fix_script" ]; then
        fix_script="$SCRIPT_DIR/fix-json.py"
    fi
    if [ ! -f "$fix_script" ]; then
        log_warn "fix-json.py not found at $STATE_DIR or $SCRIPT_DIR — JSON repair disabled"
        return 0
    fi

    for json_file in "$FRONTIER_FILE" "$CYCLE_LOG_FILE" "$MAINTENANCE_STATE_FILE" "$TASKS_FILE" "$WORK_STATE_FILE"; do
        if [ ! -f "$json_file" ]; then
            continue
        fi

        if ! jq empty "$json_file" 2>/dev/null; then
            log_error "Invalid JSON detected in $(basename "$json_file"), attempting repair..."
            had_errors=true

            cp "$json_file" "$json_file.broken.$(date +%s)"

            if python3 "$fix_script" "$json_file" "$json_file.fixed" 2>/dev/null; then
                mv "$json_file.fixed" "$json_file"
                log_success "Repaired $(basename "$json_file") (escaped backslashes)"
            else
                rm -f "$json_file.fixed" 2>/dev/null
                log_error "Could not repair $(basename "$json_file") - manual fix required"
            fi
        fi
    done

    if [ "$had_errors" = true ]; then
        log_error "JSON validation completed with repairs"
    fi
}

# Check if jq is installed
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed. Install with: brew install jq"
        exit 1
    fi
    # Allow tests to skip the claude binary check (set SKIP_CLAUDE_CHECK=1)
    if [ "${SKIP_CLAUDE_CHECK:-0}" != "1" ] && ! command -v claude &> /dev/null; then
        log_error "claude CLI is required but not installed."
        exit 1
    fi
}

# Validate operator-configurable environment variables.
# Called after check_dependencies() in every action path that invokes Claude.
# Accumulates all errors before exiting so the operator sees every problem at once.
validate_env() {
    local errors=0

    # validate_integer VAR_NAME VALUE MIN
    # Increments $errors if VALUE is not an integer or is below MIN.
    validate_integer() {
        local name="$1" value="$2" min="$3"
        case "$value" in
            ''|*[!0-9-]*|'-')
                log_error "$name='$value' is not a valid integer (expected integer >= $min)"
                errors=$((errors + 1))
                return
                ;;
        esac
        if [ "$value" -lt "$min" ] 2>/dev/null; then
            log_error "$name=$value must be >= $min"
            errors=$((errors + 1))
        fi
    }

    # Numeric variables
    validate_integer "WORK_AGENT_TIMEOUT"       "$WORK_AGENT_TIMEOUT"       0
    validate_integer "MAX_CONSECUTIVE_FAILURES" "$MAX_CONSECUTIVE_FAILURES" 1
    validate_integer "MAX_STALE_CYCLES"         "$MAX_STALE_CYCLES"         1
    validate_integer "MAX_WORK_CYCLES"          "${MAX_WORK_CYCLES:-0}"     0
    validate_integer "MAX_EMPTY_TASK_CYCLES"    "$MAX_EMPTY_TASK_CYCLES"    1
    validate_integer "MAX_DISCOVERY_CYCLES"    "${MAX_DISCOVERY_CYCLES:-0}" 0
    validate_integer "JOURNAL_KEEP_LINES"       "$JOURNAL_KEEP_LINES"       1
    if [ "$JOURNAL_KEEP_LINES" -ge "$JOURNAL_MAX_LINES" ] 2>/dev/null; then
        log_error "JOURNAL_KEEP_LINES=$JOURNAL_KEEP_LINES must be < JOURNAL_MAX_LINES=$JOURNAL_MAX_LINES"
        errors=$((errors + 1))
    fi

    # CLAUDE_MODEL — hard-error on empty, whitespace, or shell-unsafe characters;
    # warn (but allow) on unrecognized short aliases so new model names work without script updates.
    # shellcheck disable=SC1003
    case "$CLAUDE_MODEL" in
        ''|*[[:space:]]*)
            log_error "CLAUDE_MODEL='$CLAUDE_MODEL' is empty or contains whitespace"
            errors=$((errors + 1))
            ;;
        *[';&|$`\\']*)
            log_error "CLAUDE_MODEL='$CLAUDE_MODEL' contains shell-unsafe characters"
            errors=$((errors + 1))
            ;;
        opus|sonnet|haiku|claude-opus-4-5|claude-sonnet-4-5|claude-haiku-3-5)
            # Known-good short aliases and identifiers — no output
            ;;
        *)
            log_warn "CLAUDE_MODEL='$CLAUDE_MODEL' is not a recognized alias (proceeding anyway)"
            ;;
    esac

    # DOCS_DIR — validate only when explicitly set by the user
    if [ -n "${DOCS_DIR+x}" ] && [ ! -d "$DOCS_DIR" ]; then
        log_error "DOCS_DIR='$DOCS_DIR' does not exist or is not a directory"
        errors=$((errors + 1))
    fi

    # RALPH_BUDGET_LIMIT — optional, must be a positive number when set
    if [ -n "${RALPH_BUDGET_LIMIT:-}" ]; then
        # Regex guard: only digits and optional decimal point — MUST come before awk
        # to prevent command injection via crafted values like "0; system(...)"
        if ! [[ "$RALPH_BUDGET_LIMIT" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            log_error "RALPH_BUDGET_LIMIT='$RALPH_BUDGET_LIMIT' is not a valid positive number"
            errors=$((errors + 1))
        elif ! awk "BEGIN { exit (${RALPH_BUDGET_LIMIT} > 0) ? 0 : 1 }"; then
            log_error "RALPH_BUDGET_LIMIT='$RALPH_BUDGET_LIMIT' is not a valid positive number"
            errors=$((errors + 1))
        fi
        if [ "${TRACK_TOKENS:-true}" = "false" ]; then
            log_warn "RALPH_BUDGET_LIMIT is set but TRACK_TOKENS=false — budget enforcement will be ineffective (no cost data)"
        fi
    fi

    if [ "$errors" -gt 0 ]; then
        log_error "Environment validation failed ($errors error(s)). Fix the above and retry."
        exit 1
    fi

    # Log effective configuration once at startup
    log "Configuration:"
    log "  Model:                  $CLAUDE_MODEL"
    log "  Agent timeout:          ${WORK_AGENT_TIMEOUT}s (0=disabled)"
    log "  Max work cycles:        ${MAX_WORK_CYCLES:-0} (0=unlimited)"
    log "  Max discovery cycles:   ${MAX_DISCOVERY_CYCLES:-0} (0=unlimited)"
    log "  Max consecutive fails:  $MAX_CONSECUTIVE_FAILURES"
    log "  Max stale cycles:       $MAX_STALE_CYCLES"
    log "  Max empty task cycles:  $MAX_EMPTY_TASK_CYCLES"
    log "  Journal keep lines:     $JOURNAL_KEEP_LINES (max=$JOURNAL_MAX_LINES)"
    if [ -n "${RALPH_BUDGET_LIMIT:-}" ]; then
        log "  Budget limit:           \$$RALPH_BUDGET_LIMIT"
    else
        log "  Budget limit:           (unlimited)"
    fi
    if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
        log "  Notify webhook:         $(_truncate_url "$NOTIFY_WEBHOOK_URL")"
        log "  Notify on:              ${NOTIFY_ON:-complete,error,stalemate,budget}"
    else
        log "  Notify webhook:         (disabled)"
    fi
}

# Build common claude CLI args (model, permissions, chrome, MCP)
# Populates the global CLAUDE_ARGS array — callers use "${CLAUDE_ARGS[@]}"
build_claude_args() {
    CLAUDE_ARGS=("-p" "--model" "$CLAUDE_MODEL")
    if [ "$SKIP_PERMISSIONS" = "true" ]; then
        CLAUDE_ARGS+=("--dangerously-skip-permissions")
    fi
    # Token/cost tracking: switch to JSON output format
    if [ "${TRACK_TOKENS:-true}" = "true" ]; then
        CLAUDE_ARGS+=("--output-format" "json")
    fi
    # MCP server integration (optional)
    if [ "$ENABLE_MCP" = "true" ] && [ -f "$MCP_CONFIG_FILE" ]; then
        CLAUDE_ARGS+=("--mcp-config" "$MCP_CONFIG_FILE")
    fi
}

# get_cumulative_cost — sums .tokens.cost_usd across all cycle-log entries.
# Outputs a decimal number to stdout. Returns "0" when file is missing,
# empty, or entries lack cost data. Safe under set -e.
get_cumulative_cost() {
    local cost
    cost=$(jq '[.cycles[]?.tokens?.cost_usd // 0] | add // 0' \
        "${CYCLE_LOG_FILE:-/dev/null}" 2>/dev/null) || cost=0
    # Sanitize: ensure the result is a valid number
    if ! awk "BEGIN { v = $cost + 0; exit (v == v) ? 0 : 1 }" 2>/dev/null; then
        cost=0
    fi
    echo "$cost"
}

# invoke_claude_agent PROMPT LABEL [TIMEOUT]
#
# Shared agent invocation used by all modes (work, discovery, maintenance, refine).
# Calls build_claude_args internally — callers should call build_claude_args before
# only if they need CLAUDE_ARGS for dry-run display; invoke_claude_agent always
# rebuilds them.
#
# IMPORTANT: Call directly (never in a subshell) so _cleanup_files+=() is visible
# to the EXIT trap. e.g.:
#   invoke_claude_agent "$prompt" "Work cycle"    # correct
#   out=$(invoke_claude_agent "$prompt" "Work")   # WRONG — breaks _cleanup_files
#
# Sets globals on return:
#   LAST_AGENT_OUTPUT         — agent text (extracted from JSON when TRACK_TOKENS=true)
#   LAST_AGENT_STATUS         — "success" | "timeout" | "failed"
#   LAST_AGENT_DURATION       — elapsed seconds (integer)
#   LAST_AGENT_COST           — cost in USD (empty string if unavailable)
#   LAST_AGENT_INPUT_TOKENS   — input token count (empty string if unavailable)
#   LAST_AGENT_OUTPUT_TOKENS  — output token count (empty string if unavailable)
#   LAST_AGENT_CACHE_READ     — cache read token count (empty string if unavailable)
#   LAST_AGENT_CACHE_CREATED  — cache creation token count (empty string if unavailable)
#
# Always returns 0; callers inspect LAST_AGENT_STATUS for error handling.
invoke_claude_agent() {
    local prompt="${1:?invoke_claude_agent requires a prompt argument}"
    local label="${2:-Agent}"
    local timeout="${3:-$WORK_AGENT_TIMEOUT}"

    build_claude_args

    local output_file
    output_file=$(mktemp)
    _cleanup_files+=("$output_file")

    local start_time
    start_time=$(date +%s)

    local exit_code=0
    if [ "$USE_AGENTS" = "true" ] && [ -f "$SUBAGENTS_FILE" ]; then
        run_with_timeout "$timeout" claude "${CLAUDE_ARGS[@]}" \
            --agents "$(cat "$SUBAGENTS_FILE")" "$prompt" > "$output_file" 2>&1 || exit_code=$?
    else
        run_with_timeout "$timeout" claude "${CLAUDE_ARGS[@]}" \
            "$prompt" > "$output_file" 2>&1 || exit_code=$?
    fi

    LAST_AGENT_STATUS="success"
    if [ "$exit_code" -eq 0 ]; then
        log_success "$label completed successfully"
    elif [ "$exit_code" -eq 124 ]; then
        log_error "$label TIMED OUT after ${timeout}s"
        LAST_AGENT_STATUS="timeout"
    else
        log_error "$label failed (exit=$exit_code)"
        LAST_AGENT_STATUS="failed"
    fi

    local raw_output
    raw_output=$(cat "$output_file")
    rm -f "$output_file"

    # Reset token globals
    LAST_AGENT_COST=""
    LAST_AGENT_INPUT_TOKENS=""
    LAST_AGENT_OUTPUT_TOKENS=""
    LAST_AGENT_CACHE_READ=""
    LAST_AGENT_CACHE_CREATED=""

    # When TRACK_TOKENS is enabled, claude outputs a JSON envelope with .result
    # containing the agent text and usage/cost metadata. Parse it here so callers
    # get clean text in LAST_AGENT_OUTPUT and token data in dedicated globals.
    if [ "${TRACK_TOKENS:-true}" = "true" ]; then
        local parsed_result
        parsed_result=$(jq -r '.result // empty' <<< "$raw_output" 2>/dev/null) || true
        if [ -n "$parsed_result" ]; then
            LAST_AGENT_COST=$(jq -r '.total_cost_usd // empty' <<< "$raw_output" 2>/dev/null) || true
            LAST_AGENT_INPUT_TOKENS=$(jq -r '.usage.input_tokens // empty' <<< "$raw_output" 2>/dev/null) || true
            LAST_AGENT_OUTPUT_TOKENS=$(jq -r '.usage.output_tokens // empty' <<< "$raw_output" 2>/dev/null) || true
            LAST_AGENT_CACHE_READ=$(jq -r '.usage.cache_read_input_tokens // empty' <<< "$raw_output" 2>/dev/null) || true
            LAST_AGENT_CACHE_CREATED=$(jq -r '.usage.cache_creation_input_tokens // empty' <<< "$raw_output" 2>/dev/null) || true
            LAST_AGENT_OUTPUT="$parsed_result"
        else
            # JSON parse failed or .result empty — fall back to raw output
            LAST_AGENT_OUTPUT="$raw_output"
        fi
    else
        LAST_AGENT_OUTPUT="$raw_output"
    fi

    local end_time
    end_time=$(date +%s)
    LAST_AGENT_DURATION=$((end_time - start_time))

    return 0
}

# Print a dry-run diagnostic report to stdout and save assembled prompt to a file.
# Called from run_work_cycle() and run_cycle() when DRY_RUN=true.
# Args: $1=mode ("work-once"|"once"), $2=prompt (assembled content), $3=output_file path
_print_dry_run_report() {
    local mode="$1"
    local prompt="$2"
    local output_file="$3"

    # Populate CLAUDE_ARGS so we can display what would be passed
    build_claude_args

    # Save the assembled prompt to the output file
    printf '%s\n' "$prompt" > "$output_file"

    # Print the diagnostic report
    local sep="════════════════════════════════════════"
    printf '\n%s\n' "$sep"
    printf 'DRY RUN — Assembled prompt preview\n'
    printf '%s\n\n' "$sep"
    printf 'Mode:              %s\n' "$mode"
    printf 'Model:             %s\n' "${CLAUDE_MODEL:-opus}"
    printf 'Timeout:           %ss\n' "${WORK_AGENT_TIMEOUT:-900}"

    if [ "${USE_AGENTS:-true}" = "true" ] && [ -f "${SUBAGENTS_FILE:-}" ]; then
        local agent_count
        agent_count=$(jq 'if type == "array" then length elif type == "object" then (.agents // [] | length) else 0 end' "${SUBAGENTS_FILE}" 2>/dev/null || echo "?")
        printf 'Subagents:         enabled (%s specialists)\n' "$agent_count"
    else
        printf 'Subagents:         disabled\n'
    fi

    printf 'Claude args:       %s\n' "${CLAUDE_ARGS[*]}"
    printf '\nState files read:\n'

    if [ "$mode" = "work-once" ]; then
        printf '  %s\n' "${WORK_PROMPT_FILE:-_state/work-prompt.md}          (template)"
        printf '  %s\n' "${WORK_STATE_FILE:-_state/work-state.json}          (cycle state)"
        printf '  %s\n' "${TASKS_FILE:-_state/tasks.json}                    (task registry)"
        if [ -f "${LAST_VALIDATION_FILE:-}" ]; then
            printf '  %s  (would be consumed — preserved in dry-run)\n' "${LAST_VALIDATION_FILE}"
        fi
        if [ -f "${DOCS_DIR:-$PWD}/LEARNINGS.md" ]; then
            printf '  %s/LEARNINGS.md                (compound learnings)\n' "${DOCS_DIR:-$PWD}"
        fi
    else
        printf '  %s\n' "${PROMPT_FILE:-_state/prompt.md}                    (discovery prompt)"
    fi

    if [ -f "${TASKS_FILE:-}" ]; then
        local val_cmds
        val_cmds=$(jq -r '.tasks[].validation_commands[]?' "${TASKS_FILE}" 2>/dev/null || true)
        if [ -n "$val_cmds" ]; then
            printf '\nValidation commands (would NOT execute):\n'
            while IFS= read -r cmd; do
                [ -n "$cmd" ] && printf '  %s\n' "$cmd"
            done <<< "$val_cmds"
        fi
    fi

    printf '\nPrompt saved to: %s\n' "$output_file"
    printf '%s\n' "$sep"
    printf '%s\n' "$prompt"
    printf '%s\n' "$sep"
    printf 'DRY RUN complete — claude was NOT invoked\n\n'
}

# Show aggregated cost summary from cycle-log.json.
# Usage: show_cost_summary
show_cost_summary() {
    if [ ! -f "$CYCLE_LOG_FILE" ]; then
        log_error "No cycle-log.json found at $CYCLE_LOG_FILE"
        return 1
    fi

    local total_cycles cycles_with_tokens
    total_cycles=$(jq '.cycles | length' "$CYCLE_LOG_FILE")
    cycles_with_tokens=$(jq '[.cycles[] | select(.tokens != null)] | length' "$CYCLE_LOG_FILE")

    echo ""
    echo "=== Ralph Loop Cost Summary ==="
    echo "Cycles with token data: $cycles_with_tokens / $total_cycles"
    echo ""

    if [ "$cycles_with_tokens" -eq 0 ]; then
        echo "  No token data recorded yet."
        echo ""
        echo "Total cost: \$0"
        return 0
    fi

    # Per-type aggregation
    printf "%-14s %10s %10s %12s %14s %12s\n" \
        "Type" "Input" "Output" "Cache Read" "Cache Create" "Cost (USD)"
    printf "%-14s %10s %10s %12s %14s %12s\n" \
        "──────────" "─────────" "─────────" "───────────" "────────────" "──────────"

    jq -r '
      .cycles
      | map(select(.tokens != null))
      | group_by(.type)
      | map({
          type: .[0].type,
          input: ([.[].tokens.input // 0] | add),
          output: ([.[].tokens.output // 0] | add),
          cache_read: ([.[].tokens.cache_read // 0] | add),
          cache_created: ([.[].tokens.cache_created // 0] | add),
          cost: ([.[].tokens.cost_usd // 0] | add)
        })
      | sort_by(.type)
      | .[]
      | [.type, .input, .output, .cache_read, .cache_created, .cost]
      | @tsv
    ' "$CYCLE_LOG_FILE" | while IFS=$'\t' read -r type input output cache_read cache_created cost; do
        printf "  %-12s %10s %10s %12s %14s %11s\n" \
            "$type" "$input" "$output" "$cache_read" "$cache_created" "\$$cost"
    done

    echo ""

    # Totals
    local total_input total_output total_cache_read total_cache_created total_cost
    total_input=$(jq '[.cycles[].tokens.input // 0] | add' "$CYCLE_LOG_FILE")
    total_output=$(jq '[.cycles[].tokens.output // 0] | add' "$CYCLE_LOG_FILE")
    total_cache_read=$(jq '[.cycles[].tokens.cache_read // 0] | add' "$CYCLE_LOG_FILE")
    total_cache_created=$(jq '[.cycles[].tokens.cache_created // 0] | add' "$CYCLE_LOG_FILE")
    total_cost=$(jq '[.cycles[].tokens.cost_usd // 0] | add' "$CYCLE_LOG_FILE")

    printf "  %-12s %10s %10s %12s %14s %11s\n" \
        "TOTAL" "$total_input" "$total_output" "$total_cache_read" "$total_cache_created" "\$$total_cost"
    echo ""

    # Average cost per cycle (with token data only)
    local avg_cost
    avg_cost=$(jq --arg n "$cycles_with_tokens" \
        '([.cycles[].tokens.cost_usd // 0] | add) / ($n | tonumber)' "$CYCLE_LOG_FILE")
    echo "Model: $CLAUDE_MODEL | Avg cost/cycle: \$$avg_cost"
    echo ""

    if [ -n "${RALPH_BUDGET_LIMIT:-}" ]; then
        # Safety: RALPH_BUDGET_LIMIT was regex-validated in validate_env() at startup;
        # re-check here defensively before awk interpolation to prevent injection.
        if [[ "$RALPH_BUDGET_LIMIT" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            local remaining
            remaining=$(awk "BEGIN { r = $RALPH_BUDGET_LIMIT - $total_cost; printf \"%.4f\", r }")
            echo "Budget limit:    \$$RALPH_BUDGET_LIMIT"
            echo "Remaining:       \$$remaining"
            echo ""
        fi
    fi
}

# apply_prompt_vars — resolve {{variable}} placeholders in a prompt string.
#
# Usage: apply_prompt_vars <prompt> <mode> <cycle_num>
#   prompt    : raw prompt text (positional arg $1)
#   mode      : current run mode — work|discovery|maintenance|refine (arg $2)
#   cycle_num : integer cycle counter for this run (arg $3)
#
# Substitution order (strict priority — later sources override earlier ones
# except built-ins, which are applied first and cannot be overridden):
#
#   1. Built-in variables (always resolved, protected from user override)
#   2. Config file variables ($DOCS_DIR/.ralph-loop.json -> "variables" key)
#   3. RALPH_VAR_* environment variables (highest user priority)
#
# Unresolved {{placeholders}} are left intact (no empty-string replacement).
# Safe against recursive expansion: each source is a single-pass substitution.
apply_prompt_vars() {
    local prompt="$1"
    local mode="${2:-unknown}"
    local cycle_num="${3:-0}"

    # -- 1. Built-in variables (applied first; reserved names block env/config override) --
    local reserved="state_dir docs_dir model mode cycle_num git_branch timestamp"

    # {{state_dir}} — hardcoded (matches existing behaviour exactly)
    prompt="${prompt//\{\{state_dir\}\}/_state}"

    # {{docs_dir}} — project root directory
    prompt="${prompt//\{\{docs_dir\}\}/${DOCS_DIR:-}}"

    # {{model}} — Claude model name with fallback
    prompt="${prompt//\{\{model\}\}/${CLAUDE_MODEL:-opus}}"

    # {{mode}} — run mode passed as argument
    prompt="${prompt//\{\{mode\}\}/$mode}"

    # {{cycle_num}} — cycle counter passed as argument
    prompt="${prompt//\{\{cycle_num\}\}/$cycle_num}"

    # {{git_branch}} — current git branch; "unknown" on failure (detached HEAD, no repo)
    local git_branch
    git_branch=$(git -C "${DOCS_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    prompt="${prompt//\{\{git_branch\}\}/$git_branch}"

    # {{timestamp}} — UTC ISO 8601 (POSIX format specifiers, macOS-safe)
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    prompt="${prompt//\{\{timestamp\}\}/$timestamp}"

    # -- Build set of RALPH_VAR_* names (needed to let env vars override config) --
    local env_var_names=" "
    local env_var
    while IFS= read -r env_var; do
        [ -z "$env_var" ] && continue
        env_var_names="$env_var_names${env_var#RALPH_VAR_} "
    done < <(compgen -v | grep '^RALPH_VAR_' || true)

    # -- 2. Config file variables ($DOCS_DIR/.ralph-loop.json) --
    local config_file="${DOCS_DIR:-}/.ralph-loop.json"
    if [ -f "$config_file" ]; then
        local config_vars
        # Parse "variables" object; errors are non-fatal — warn (to stderr) and skip
        if config_vars=$(jq -r '.variables // {} | to_entries[] | "\(.key)=\(.value)"' \
                         "$config_file" 2>/dev/null); then
            while IFS='=' read -r cfg_name cfg_value; do
                [ -z "$cfg_name" ] && continue
                # Skip reserved built-in names
                local is_reserved=false
                local r
                for r in $reserved; do
                    [ "$cfg_name" = "$r" ] && is_reserved=true && break
                done
                [ "$is_reserved" = "true" ] && continue
                # Skip names that have a RALPH_VAR_* counterpart (env wins)
                case "$env_var_names" in
                    *" $cfg_name "*) continue ;;
                esac
                prompt="${prompt//\{\{$cfg_name\}\}/$cfg_value}"
            done <<< "$config_vars"
        else
            log_warn "apply_prompt_vars: failed to parse $config_file — skipping config variables" >&2
        fi
    fi

    # -- 3. RALPH_VAR_* environment variables (highest user priority) --
    local env_name env_value
    while IFS= read -r env_var; do
        [ -z "$env_var" ] && continue
        env_name="${env_var#RALPH_VAR_}"
        # Skip reserved built-in names
        local is_reserved=false
        local r
        for r in $reserved; do
            [ "$env_name" = "$r" ] && is_reserved=true && break
        done
        [ "$is_reserved" = "true" ] && continue
        # Use indirect expansion to safely read the value
        env_value="${!env_var}"
        prompt="${prompt//\{\{$env_name\}\}/$env_value}"
    done < <(compgen -v | grep '^RALPH_VAR_' || true)

    printf '%s' "$prompt"
}

# Check for stalemate (no git changes across consecutive cycles)
check_stalemate() {
    local git_root
    git_root=$(cd "$DOCS_DIR" && git rev-parse --show-toplevel 2>/dev/null) || return 0

    local current_hash
    current_hash=$(cd "$git_root" && git diff HEAD --stat 2>/dev/null | shasum | cut -d' ' -f1)
    # Also include untracked files in the hash
    local untracked_hash
    untracked_hash=$(cd "$git_root" && git status --porcelain 2>/dev/null | shasum | cut -d' ' -f1)
    current_hash="${current_hash}-${untracked_hash}"

    if [ -n "$_last_git_hash" ] && [ "$current_hash" = "$_last_git_hash" ]; then
        _stale_cycle_count=$((_stale_cycle_count + 1))
        log_warn "Stalemate detected: no file changes for $_stale_cycle_count consecutive cycles"
        if [ "$_stale_cycle_count" -ge "$MAX_STALE_CYCLES" ]; then
            log_error "Aborting: $MAX_STALE_CYCLES consecutive cycles with no changes (stalemate)"
            return 1
        fi
    else
        _stale_cycle_count=0
    fi

    _last_git_hash="$current_hash"
    return 0
}
