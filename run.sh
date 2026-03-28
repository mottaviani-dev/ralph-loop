#!/bin/bash
# shellcheck shell=bash

# Ralph Loop Runner
# Runs continuous discovery cycles for codebase documentation

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCS_DIR="${DOCS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE_DIR="$DOCS_DIR/_state"
CONFIG_FILE="$STATE_DIR/config.json"
FRONTIER_FILE="$STATE_DIR/frontier.json"
CYCLE_LOG_FILE="$STATE_DIR/cycle-log.json"
JOURNAL_FILE="$STATE_DIR/journal.md"
JOURNAL_SUMMARY_FILE="$STATE_DIR/journal-summary.md"
PROMPT_FILE="$STATE_DIR/prompt.md"
MAINTENANCE_PROMPT_FILE="$STATE_DIR/maintenance-prompt.md"
MAINTENANCE_STATE_FILE="$STATE_DIR/maintenance-state.json"
SUBAGENTS_FILE="$STATE_DIR/subagents.json"
WORK_PROMPT_FILE="$STATE_DIR/work-prompt.md"
WORK_STATE_FILE="$STATE_DIR/work-state.json"
TASKS_FILE="$STATE_DIR/tasks.json"
LAST_VALIDATION_FILE="$STATE_DIR/last-validation-results.json"
REFINE_PROMPT_FILE="${REFINE_PROMPT_FILE:-$STATE_DIR/refine-prompt.md}"
WORK_COMMIT_MSG_PREFIX="${WORK_COMMIT_MSG_PREFIX:-feat: work cycle}"

# Files/directories excluded from work mode commits (git pathspec patterns).
# These protect against accidentally committing secrets, operational state,
# OS artifacts, and agent worktrees. Users can extend this list via
# RALPH_GIT_EXCLUDE (space-separated pathspec patterns, e.g. "my-secrets/ *.vault").
WORK_GIT_EXCLUDE_DEFAULTS=(
    '_state/'
    '.symphony-workspaces/'
    '.env'
    '.env.*'
    '*.broken.*'
    '.DS_Store'
    'Thumbs.db'
    '*.secret'
    '*.key'
    '*.pem'
    '__pycache__/'
)

# Enable specialist subagents for delegation (set to false to disable)
USE_AGENTS="${USE_AGENTS:-true}"

# How often to run maintenance cycles (every N cycles)
MAINTENANCE_CYCLE_INTERVAL=10

# Journal rotation threshold (lines)
JOURNAL_MAX_LINES=500

# Lines to retain after journal rotation (must be < JOURNAL_MAX_LINES)
JOURNAL_KEEP_LINES="${JOURNAL_KEEP_LINES:-300}"

# Configuration (can override via environment)
CLAUDE_MODEL="${CLAUDE_MODEL-opus}"  # sonnet for speed, opus for depth (use - not :- so explicit empty is caught by validate_env)
SKIP_PERMISSIONS="${SKIP_PERMISSIONS:-true}"  # set to false for interactive mode
SKIP_COMMIT="${SKIP_COMMIT:-false}"  # set to true to skip commit step
COMMIT_MSG_PREFIX="${COMMIT_MSG_PREFIX:-docs: discovery cycle}"  # commit message prefix
DISCOVERY_ONLY="${DISCOVERY_ONLY:-false}"  # skip maintenance cycles

# MCP integration (optional — provide config/mcp-servers.json to enable)
ENABLE_MCP="${ENABLE_MCP:-false}"
MCP_CONFIG_FILE="$SCRIPT_DIR/config/mcp-servers.json"

# CLAUDE_ARGS is a Bash array — do NOT convert to a string.
# Array expansion ("${CLAUDE_ARGS[@]}") preserves spaces in values (e.g., paths with spaces).
# Populated by build_claude_args() before every claude invocation. See RL-022.
CLAUDE_ARGS=()

# Timeout for claude CLI invocations (seconds). 0 = no timeout.
# Default 15 minutes — long enough for deep work, short enough to catch hangs.
WORK_AGENT_TIMEOUT="${WORK_AGENT_TIMEOUT:-900}"

# Max consecutive cycles with 0 total tasks before aborting (prevents infinite plan loops)
MAX_EMPTY_TASK_CYCLES="${MAX_EMPTY_TASK_CYCLES:-3}"

# Token/cost tracking (requires claude CLI with --output-format json support)
TRACK_TOKENS="${TRACK_TOKENS:-true}"

# Validation command safety controls
VALIDATE_COMMANDS_STRICT="${VALIDATE_COMMANDS_STRICT:-false}"
VALIDATE_COMMANDS_ALLOWLIST="${VALIDATE_COMMANDS_ALLOWLIST:-}"

# Verbose cleanup logging (opt-in, see lib/cleanup.sh)
RALPH_VERBOSE_CLEANUP="${RALPH_VERBOSE_CLEANUP:-false}"

# Budget limit: stop loop after cumulative spend reaches this amount (USD).
# Unset (default) = unlimited. Requires TRACK_TOKENS=true (RL-045).
RALPH_BUDGET_LIMIT="${RALPH_BUDGET_LIMIT:-}"

# Webhook notifications (optional)
NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}"
NOTIFY_ON="${NOTIFY_ON:-complete,error,stalemate,budget}"

# Max consecutive failed cycles before aborting
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"

# Stalemate detection: abort after N consecutive cycles with zero git changes
MAX_STALE_CYCLES="${MAX_STALE_CYCLES:-5}"

# Max discovery cycles (0 = unlimited)
MAX_DISCOVERY_CYCLES="${MAX_DISCOVERY_CYCLES:-0}"

# Internal counters (do not override)
_empty_task_cycle_count=0
_consecutive_failure_count=0
_stale_cycle_count=0
_last_git_hash=""

# ── Signal handler for graceful shutdown (RL-018) ──
# shellcheck source=lib/cleanup.sh
source "$SCRIPT_DIR/lib/cleanup.sh"

trap '_do_cleanup' EXIT
trap '_interrupted=true; _do_cleanup; exit 130' INT
trap '_interrupted=true; _do_cleanup; exit 143' TERM

# Token limits (increase from defaults for larger context)
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-64000}"
export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-31999}"

# ── Source library modules ──
# Order matters: common first (defines log*), then setup, maintenance,
# discovery (calls maintenance), work, refine.
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$SCRIPT_DIR/lib/maintenance.sh"
source "$SCRIPT_DIR/lib/discovery.sh"
source "$SCRIPT_DIR/lib/work.sh"
source "$SCRIPT_DIR/lib/refine.sh"
source "$SCRIPT_DIR/lib/stats.sh"
# shellcheck source=lib/migrate.sh
source "$SCRIPT_DIR/lib/migrate.sh"

# ────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ────────────────────────────────────────────────────────

ACTION=""
REFINE_TARGET=""

for arg in "$@"; do
    case "$arg" in
        --once)
            ACTION="once"
            ;;
        --discovery-only)
            DISCOVERY_ONLY=true
            ;;
        --discovery-once)
            DISCOVERY_ONLY=true
            ACTION="once"
            ;;
        --maintenance)
            ACTION="maintenance"
            ;;
        --setup)
            ACTION="setup"
            ;;
        --auto-setup)
            ACTION="auto-setup"
            ;;
        --refine)
            ACTION="refine"
            REFINE_TARGET="all"
            ;;
        --refine=*)
            ACTION="refine"
            REFINE_TARGET="${arg#--refine=}"
            ;;
        --work)
            ACTION="work"
            ;;
        --work-once)
            ACTION="work-once"
            ;;
        --work-status)
            ACTION="work-status"
            ;;
        --cost)
            ACTION="cost"
            ;;
        --status)
            ACTION="status"
            ;;
        --summary)
            ACTION="summary"
            ;;
        --commit)
            ACTION="commit"
            ;;
        --reset)
            ACTION="reset"
            ;;
        --migrate)
            ACTION="migrate"
            ;;
        --validate-only)
            ACTION="validate-only"
            ;;
        --help|-h)
            ACTION="help"
            ;;
        *)
            log_error "Unknown option: $arg"
            echo "Run $0 --help for usage."
            exit 1
            ;;
    esac
done

# Execute based on parsed flags
case "${ACTION:-run}" in
    once)
        check_dependencies
        validate_env
        acquire_run_lock
        check_first_run
        validate_json_files
        init_frontier
        run_cycle
        ;;
    maintenance)
        check_dependencies
        validate_env
        acquire_run_lock
        validate_json_files
        run_maintenance_cycle "manual"
        ;;
    setup)
        run_setup
        exit 0
        ;;
    auto-setup)
        check_dependencies
        validate_env
        echo ""
        echo "┌──────────────────────────────────────────────────┐"
        echo "│  Ralph Loop — Auto Setup                         │"
        echo "└──────────────────────────────────────────────────┘"
        echo ""
        detected=$(auto_detect_modules 2>/dev/null) || detected=0
        if [ "$detected" -gt 0 ]; then
            log_success "Detected $detected projects:"
            echo ""
            print_detected_projects
            echo ""
            auto_detect_subagents
            log_success "Generated config/modules.json ($detected modules)"
            log_success "Generated config/subagents.json"
            run_setup
            echo ""
            log_success "Auto-setup complete. Run: $0 --once"
        else
            log_error "No sibling projects detected in ../. Cannot auto-configure."
            exit 1
        fi
        exit 0
        ;;
    work)
        check_dependencies
        validate_env
        acquire_run_lock
        init_work_state
        validate_json_files

        log "╔═══════════════════════════════════════════════════════╗"
        log "║       RALPH LOOP — Work Mode (Continuous)              ║"
        log "╚═══════════════════════════════════════════════════════╝"

        sleep_seconds=$(jq -r '.cycle_sleep_seconds // 10' "$CONFIG_FILE" 2>/dev/null || echo "10")

        log "Model: $CLAUDE_MODEL"
        log "Timeout: ${WORK_AGENT_TIMEOUT}s per cycle"
        log "Max cycles: ${MAX_WORK_CYCLES:-unlimited}"
        log "Validate before commit: ${VALIDATE_BEFORE_COMMIT:-true}"
        if [ "$USE_AGENTS" = "true" ] && [ -f "$SUBAGENTS_FILE" ]; then
            log "Subagents: $(jq 'keys | length' "$SUBAGENTS_FILE") specialists loaded"
        fi
        echo ""

        # Run pre-flight validation to give the first cycle a baseline
        run_preflight_validation
        echo ""

        log "Press Ctrl+C to stop"
        echo ""

        while work_loop_should_continue; do
            if run_work_cycle; then
                _consecutive_failure_count=0
            else
                _consecutive_failure_count=$((_consecutive_failure_count + 1))
                log_error "Work cycle failed (consecutive failures: $_consecutive_failure_count/$MAX_CONSECUTIVE_FAILURES)"
            fi
            log "Sleeping for ${sleep_seconds}s before next cycle..."
            echo ""
            sleep "$sleep_seconds"
        done

        log_success "All tasks completed or blocked. Work loop finished."
        show_work_status
        ;;
    work-once)
        check_dependencies
        validate_env
        acquire_run_lock
        init_work_state
        validate_json_files
        # Pre-flight gives the agent a baseline on first run
        if [ ! -f "$LAST_VALIDATION_FILE" ]; then
            run_preflight_validation
        fi
        run_work_cycle
        ;;
    work-status)
        show_work_status
        ;;
    cost)
        show_cost_summary
        ;;
    summary)
        show_summary
        ;;
    refine)
        run_refine "$REFINE_TARGET"
        exit 0
        ;;
    validate-only)
        check_dependencies
        validate_env
        exit 0
        ;;
    status)
        if [ ! -d "$STATE_DIR" ] || [ ! -f "$FRONTIER_FILE" ]; then
            echo "=== Discovery Status ==="
            echo "State not initialized. Run: $0 --setup"
            exit 0
        fi
        echo "=== Frontier ==="
        jq '{total_cycles, last_cycle, queue_length: (.queue | length), concepts: (.discovered_concepts | length), patterns: (.cross_service_patterns | length)}' "$FRONTIER_FILE"
        echo ""
        echo "=== Journal Stats ==="
        echo "journal.md: $(wc -l < "$JOURNAL_FILE" 2>/dev/null | tr -d ' ' || echo '0') lines"
        echo "journal-summary.md: $(wc -l < "$JOURNAL_SUMMARY_FILE" 2>/dev/null | tr -d ' ' || echo '0') lines"
        echo ""
        echo "=== Maintenance State ==="
        if [ -f "$MAINTENANCE_STATE_FILE" ]; then
            jq '{files_audited: (.cross_service_audit.files_audited | length), files_split: (.cross_service_audit.files_split | length), files_correct: (.cross_service_audit.files_correct | length), current_target: .cross_service_audit.current_target}' "$MAINTENANCE_STATE_FILE"
            echo ""
            echo "=== Cross-Service Files Remaining ==="
            audited=$(jq -r '.cross_service_audit.files_audited[]' "$MAINTENANCE_STATE_FILE" 2>/dev/null | sort)
            all_files=$(find docs/_cross-service -maxdepth 1 -name '*.md' -exec basename {} \; 2>/dev/null | sort)
            echo "$all_files" | while read -r f; do
                echo "$audited" | grep -qxF "$f" || echo "$f"
            done | head -10
        else
            echo "Not initialized"
        fi
        echo ""
        echo "=== Agents ==="
        if [ "$USE_AGENTS" = "true" ] && [ -f "$SUBAGENTS_FILE" ]; then
            echo "Subagents: $(jq 'keys | length' "$SUBAGENTS_FILE") specialists loaded"
            jq -r 'keys[]' "$SUBAGENTS_FILE" | sed 's/^/  - /'
        else
            echo "Subagents: disabled"
        fi
        echo ""
        echo "=== Last 5 Cycles ==="
        if [ -f "$CYCLE_LOG_FILE" ]; then
            jq '.cycles | .[-5:]' "$CYCLE_LOG_FILE"
        else
            echo "No cycle history"
        fi
        ;;
    commit)
        # Honour SKIP_COMMIT flag (was previously ignored for --commit)
        if [ "$SKIP_COMMIT" = "true" ]; then
            log "SKIP_COMMIT=true — skipping commit."
            exit 0
        fi

        # Detect the last active mode from cycle-log
        last_type="discovery"
        if [ -f "$CYCLE_LOG_FILE" ]; then
            last_type=$(jq -r '.cycles[-1].type // "discovery"' "$CYCLE_LOG_FILE" 2>/dev/null || echo "discovery")
        fi

        # Secondary signal: any uncommitted changes outside docs/
        git_root=$(cd "$DOCS_DIR" && git rev-parse --show-toplevel 2>/dev/null) || git_root="$DOCS_DIR"
        outside_docs=$(cd "$git_root" && git status --porcelain -- . ':(exclude)docs/' 2>/dev/null | head -1)

        if [ "$last_type" = "work" ] || [ -n "$outside_docs" ]; then
            # Work-mode path: reuse commit_work_changes() with validation bypassed
            # (--commit is a manual action; the user is explicitly requesting a commit)
            log "Detected work-mode changes — committing all staged/unstaged files..."
            cycle_num=$(jq '.total_cycles // 0' "$WORK_STATE_FILE" 2>/dev/null || echo "0")
            VALIDATE_BEFORE_COMMIT=false commit_work_changes "$cycle_num"
        else
            # Discovery-mode path: original docs/-scoped behaviour (unchanged)
            cd "$DOCS_DIR"
            changes=$(git status --porcelain docs/ 2>/dev/null)
            if [ -z "$changes" ]; then
                log "No pending docs changes to commit."
            else
                cycle_num=$(jq '.total_cycles' "$FRONTIER_FILE")
                git status --short docs/
                git add docs/
                git commit -m "$COMMIT_MSG_PREFIX $cycle_num"
                log_success "Committed: $COMMIT_MSG_PREFIX $cycle_num"
            fi
        fi
        ;;
    reset)
        log "Resetting all state..."

        # --- Discovery state ---
        echo '{"mode":"breadth","current_focus":null,"queue":[],"discovered_concepts":[],"cross_service_patterns":[],"last_cycle":null,"total_cycles":0}' > "$FRONTIER_FILE"
        echo '{"cycles":[]}' > "$CYCLE_LOG_FILE"
        log "Reset discovery state (frontier.json, cycle-log.json)"

        # --- Work state ---
        rm -f "$WORK_STATE_FILE"
        rm -f "$TASKS_FILE"
        init_work_state
        log "Reset work state (work-state.json, tasks.json)"

        # --- Maintenance state ---
        rm -f "$MAINTENANCE_STATE_FILE"
        log "Reset maintenance state"

        # --- Journals (truncate, don't delete — agents expect the files to exist) ---
        : > "$JOURNAL_FILE"
        : > "$JOURNAL_SUMMARY_FILE"
        log "Truncated journals (journal.md, journal-summary.md)"

        # --- Ephemeral outputs ---
        rm -f "$LAST_VALIDATION_FILE"
        rm -f "$STATE_DIR/eval-findings.md"
        log "Removed ephemeral outputs"

        log_success "Full state reset complete"
        ;;
    migrate)
        acquire_run_lock
        migrate_all
        log_success "Migration complete"
        exit 0
        ;;
    help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (none)             Run continuous discovery loop (all cycle types)"
        echo "  --once             Run single cycle and exit (may include maintenance)"
        echo "  --discovery-only   Skip maintenance cycles (combinable)"
        echo "  --discovery-once   Run single discovery cycle only and exit"
        echo "  --maintenance      Force maintenance cycle (cleanup/consolidation)"
        echo "  --work             Run continuous work loop until all tasks done/blocked"
        echo "  --work-once        Run single work cycle and exit"
        echo "  --work-status      Show task progress summary"
        echo "  --cost             Show aggregated token usage and cost from cycle-log.json"
        echo "  --setup            Initialize _state/ directory with empty state files"
        echo "  --auto-setup       Detect sibling projects, generate configs, and run setup"
        echo "  --refine           Refine all service docs (add digests, compress, cross-ref)"
        echo "  --refine=SERVICE   Refine a specific service (e.g., --refine=my-api)"
        echo "  --commit           Commit pending changes (auto-detects work vs discovery mode)"
        echo "  --status           Show current state"
        echo "  --summary          Show aggregate cycle statistics"
        echo "  --reset            Reset all state files"
        echo "  --migrate          Migrate _state/ files to current schema versions"
        echo "  --validate-only    Validate env vars and exit (used by test suite)"
        echo "  --help             Show this help"
        echo ""
        echo "Cycle types:"
        echo "  - Discovery: Explores code, documents concepts"
        echo "  - Work: Self-directed implementation (plan → research → implement → fix)"
        echo "  - Maintenance: Rotates journals, audits docs, cleans state (every ${MAINTENANCE_CYCLE_INTERVAL} cycles)"
        echo ""
        echo "Maintenance runs automatically when:"
        echo "  - Every ${MAINTENANCE_CYCLE_INTERVAL} cycles"
        echo "  - journal.md exceeds ${JOURNAL_MAX_LINES} lines"
        echo ""
        echo "Environment variables:"
        echo "  DOCS_DIR                        Target project root (default: parent of run.sh)"
        echo "  CLAUDE_MODEL                    Model to use (default: opus)"
        echo "  SKIP_PERMISSIONS                Skip permission prompts (default: true)"
        echo "  SKIP_COMMIT                     Skip auto-commit (default: false)"
        echo "  COMMIT_MSG_PREFIX               Commit message prefix (default: 'docs: discovery cycle')"
        echo "  USE_AGENTS                      Enable specialist subagents (default: true)"
        echo "  DISCOVERY_ONLY                  Skip maintenance (default: false)"
        echo "  WORK_COMMIT_MSG_PREFIX          Work mode commit prefix (default: 'feat: work cycle')"
        echo "  MAX_WORK_CYCLES                 Max work cycles, 0=unlimited (default: 0)"
        echo "  MAX_DISCOVERY_CYCLES            Max discovery cycles, 0=unlimited (default: 0)"
        echo "  VALIDATE_BEFORE_COMMIT          Run validation before committing (default: true)"
        echo "  JOURNAL_KEEP_LINES              Lines kept after journal rotation (default: 300)"
        echo "  VALIDATE_COMMANDS_STRICT        Block denylist-matched commands (default: false, warn only)"
        echo "  VALIDATE_COMMANDS_ALLOWLIST     Colon-separated ERE patterns; only matching commands run"
        echo "  RALPH_VAR_*                      User-defined prompt variables (RALPH_VAR_foo=bar → {{foo}})"
        echo "  RALPH_VERBOSE_CLEANUP            Log each PID killed and file removed during cleanup (default: false)"
        echo "  RALPH_BUDGET_LIMIT              Stop loop after cumulative spend reaches this USD amount (default: unset, unlimited)"
        echo "  NOTIFY_WEBHOOK_URL              HTTP endpoint for event webhooks (default: unset, disabled)"
        echo "  NOTIFY_ON                       Comma-separated filter: complete,error,stalemate,budget,cycle (default: complete,error,stalemate,budget)"
        echo "  TRACK_TOKENS                    Enable per-cycle token/cost capture (default: true)"
        echo "  CLAUDE_CODE_MAX_OUTPUT_TOKENS   Max output tokens (default: 64000, max: 64000)"
        echo "  MAX_THINKING_TOKENS             Extended thinking budget (default: 31999)"
        echo ""
        echo "Examples:"
        echo "  $0                              # Run continuous loop (all cycle types)"
        echo "  $0 --once                       # Run single cycle"
        echo "  $0 --discovery-only             # Continuous loop, discovery only"
        echo "  $0 --discovery-once             # Single discovery cycle, no extras"
        echo "  $0 --work                       # Continuous work until all tasks done"
        echo "  $0 --work-once                  # Single work cycle and exit"
        echo "  $0 --work-status                # Show task progress"
        echo "  $0 --summary                    # Show cycle statistics"
        echo "  $0 --refine                     # Refine all services"
        echo "  $0 --refine=my-api              # Refine one service"
        echo "  $0 --maintenance                # Force cleanup cycle"
        echo "  CLAUDE_MODEL=opus $0            # Use opus for deeper analysis"
        echo "  $0 --migrate                    # Migrate state files after upgrade"
        echo "  SKIP_COMMIT=true $0             # Don't commit changes"
        echo "  USE_AGENTS=false $0             # Disable specialist delegation"
        echo ""
        echo "Prompt template variables:"
        echo "  Built-in: {{state_dir}}, {{docs_dir}}, {{model}}, {{mode}}, {{cycle_num}}, {{git_branch}}, {{timestamp}}"
        echo "  Environment: RALPH_VAR_foo=bar resolves {{foo}} in all prompt templates"
        echo "  Config file: \$DOCS_DIR/.ralph-loop.json \"variables\" key (env vars take precedence)"
        ;;
    run)
        acquire_run_lock
        main
        ;;
esac
