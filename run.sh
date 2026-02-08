#!/bin/bash

# Ralph Loop Runner
# Runs continuous discovery cycles for codebase documentation

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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
REFINE_PROMPT_FILE="${REFINE_PROMPT_FILE:-$DOCS_DIR/.claude/skills/refine-docs/SKILL.md}"

# Enable specialist subagents for delegation (set to false to disable)
USE_AGENTS="${USE_AGENTS:-true}"

# How often to run maintenance cycles (every N cycles)
MAINTENANCE_CYCLE_INTERVAL=5

# Journal rotation threshold (lines)
JOURNAL_MAX_LINES=500

# Configuration (can override via environment)
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"  # sonnet for speed, opus for depth
SKIP_PERMISSIONS="${SKIP_PERMISSIONS:-true}"  # set to false for interactive mode
SKIP_COMMIT="${SKIP_COMMIT:-false}"  # set to true to skip commit step
COMMIT_MSG_PREFIX="${COMMIT_MSG_PREFIX:-docs: discovery cycle}"  # commit message prefix
DISCOVERY_ONLY="${DISCOVERY_ONLY:-false}"  # skip maintenance cycles

# Token limits (increase from defaults for larger context)
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-64000}"
export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-31999}"

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

# Validate and repair JSON files
validate_json_files() {
    local had_errors=false
    local fix_script="$STATE_DIR/fix-json.py"

    for json_file in "$FRONTIER_FILE" "$CYCLE_LOG_FILE" "$MAINTENANCE_STATE_FILE"; do
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
    if ! command -v claude &> /dev/null; then
        log_error "claude CLI is required but not installed."
        exit 1
    fi
}

# Auto-detect sibling projects and generate modules.json
auto_detect_modules() {
    local workspace_dir="$DOCS_DIR/.."
    local docs_basename
    docs_basename=$(basename "$DOCS_DIR")
    local modules_json="{}"
    local count=0

    for dir in "$workspace_dir"/*/; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")

        # Skip: self, hidden dirs, underscore-prefixed dirs
        case "$name" in
            "$docs_basename"|.*|_*) continue ;;
        esac

        # Must have .git/ to be a recognized project
        [ -d "$dir/.git" ] || continue

        # Detect project type
        local ptype=""
        if [ -f "$dir/composer.json" ]; then
            ptype="backend"
        elif [ -f "$dir/angular.json" ]; then
            ptype="frontend"
        elif [ -f "$dir/nuxt.config.js" ] || [ -f "$dir/nuxt.config.ts" ]; then
            ptype="frontend"
        elif [ -f "$dir/package.json" ]; then
            ptype="frontend"
        else
            continue
        fi

        modules_json=$(echo "$modules_json" | jq \
            --arg name "$name" \
            --arg path "../$name" \
            --arg type "$ptype" \
            '. + {($name): {"path": $path, "type": $type, "integrates_with": []}}')
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        return 1
    fi

    # Merge into modules.json template (preserve taxonomy and other fields)
    local config_template="$SCRIPT_DIR/config/modules.json"
    if [ -f "$config_template" ]; then
        jq --argjson mods "$modules_json" '.modules = $mods' "$config_template" \
            > "$config_template.tmp" && mv "$config_template.tmp" "$config_template"
    else
        mkdir -p "$SCRIPT_DIR/config"
        jq -n --argjson mods "$modules_json" '{
            "taxonomy": {
                "authentication": "Authentication & Security",
                "features": "Product Features",
                "integrations": "Integrations",
                "data-reporting": "Data & Reporting",
                "infrastructure": "Infrastructure",
                "development-standards": "Development Standards"
            },
            "modules": $mods,
            "docs_root": ".",
            "cross_service_dir": "cross-service",
            "cycle_sleep_seconds": 10
        }' > "$config_template"
    fi

    echo "$count"
}

# Auto-generate subagents.json from modules.json
auto_detect_subagents() {
    local modules_file="$SCRIPT_DIR/config/modules.json"
    local subagents_file="$SCRIPT_DIR/config/subagents.json"
    local workspace_dir="$DOCS_DIR/.."
    local subagents="{}"

    local module_names
    module_names=$(jq -r '.modules | keys[]' "$modules_file")

    for name in $module_names; do
        local ptype
        ptype=$(jq -r --arg n "$name" '.modules[$n].type' "$modules_file")
        local path
        path=$(jq -r --arg n "$name" '.modules[$n].path' "$modules_file")

        local type_label
        case "$ptype" in
            backend)  type_label="Backend" ;;
            frontend) type_label="Frontend" ;;
            *)        type_label="General" ;;
        esac

        local prompt="You are a specialist for the $name service. Working directory: $path"
        if [ -f "$workspace_dir/$name/CLAUDE.md" ]; then
            prompt="$prompt. Read CLAUDE.md in the project root for full context."
        fi

        subagents=$(echo "$subagents" | jq \
            --arg name "$name" \
            --arg desc "$type_label developer for $name" \
            --arg prompt "$prompt" \
            '. + {($name): {"description": $desc, "prompt": $prompt, "tools": ["Read","Write","Edit","Glob","Grep","Bash"], "model": "inherit"}}')
    done

    echo "$subagents" > "$subagents_file"
}

# Print detected projects table
print_detected_projects() {
    local modules_file="$SCRIPT_DIR/config/modules.json"
    jq -r '.modules | to_entries[] | "  \(.key)\t\(.value.type)\t\(.value.path)"' "$modules_file" | \
        column -t -s $'\t'
}

# Show manual setup instructions
print_manual_setup() {
    cat <<'SETUP_GUIDE'
Before starting discovery, prepare these files:

1. MODULE REGISTRY  (ralph-loop/config/modules.json)
   Define the services/repos to explore:
   {
     "modules": {
       "my-api":      { "path": "../my-api",      "type": "backend",  "integrates_with": ["my-frontend"] },
       "my-frontend": { "path": "../my-frontend",  "type": "frontend", "integrates_with": ["my-api"] }
     },
     "docs_root": ".",
     "cycle_sleep_seconds": 10
   }

2. SPECIALIST AGENTS  (ralph-loop/config/subagents.json)
   Define a domain expert for each module:
   {
     "my-api": {
       "description": "Backend API developer for my-api",
       "prompt": "You are a specialist for the my-api service. ...",
       "tools": ["Read", "Write", "Edit", "Glob", "Grep", "Bash"],
       "model": "inherit"
     }
   }

3. PROJECT CONTEXT  (CLAUDE.md in your docs root)
   High-level project overview: what it does, architecture, conventions.

4. INITIAL STATE  (run with --setup flag)
   Creates _state/ with empty frontier, journals, and cycle log.

Then run:  ralph-loop/run.sh --once
SETUP_GUIDE
}

# Check if this is first run (no configured modules)
check_first_run() {
    local config_file="$STATE_DIR/config.json"
    if [ ! -f "$config_file" ] || ! jq -e '.modules | length > 0' "$config_file" >/dev/null 2>&1; then
        echo ""
        echo "┌──────────────────────────────────────────────────┐"
        echo "│  Ralph Loop — First Run Setup                    │"
        echo "└──────────────────────────────────────────────────┘"
        echo ""

        # Try to detect projects
        local detected
        detected=$(auto_detect_modules 2>/dev/null) || detected=0

        if [ "$detected" -gt 0 ]; then
            echo "No modules configured. Detected $detected projects in ../:"
            echo ""
            print_detected_projects
            echo ""
            echo "  [a] Auto-configure from detected projects and run setup"
            echo "  [m] Show manual setup instructions and exit"
            echo ""
            read -r -p "  Choose [a/m]: " choice </dev/tty
            case "$choice" in
                a|A)
                    log "Auto-configuring from detected projects..."
                    auto_detect_subagents
                    log_success "Generated config/modules.json ($detected modules)"
                    log_success "Generated config/subagents.json"
                    run_setup
                    echo ""
                    log_success "Auto-setup complete. Continuing to discovery..."
                    echo ""
                    return 0
                    ;;
                *)
                    echo ""
                    print_manual_setup
                    exit 0
                    ;;
            esac
        else
            echo "No sibling projects detected in ../."
            echo ""
            print_manual_setup
            exit 0
        fi
    fi
}

# Initialize _state/ directory with empty state files
run_setup() {
    echo "Setting up _state/ directory..."
    mkdir -p "$STATE_DIR"

    # Copy config template
    if [ -f "$SCRIPT_DIR/config/modules.json" ]; then
        cp "$SCRIPT_DIR/config/modules.json" "$STATE_DIR/config.json"
        echo "  Created _state/config.json from template"
    fi

    # Copy prompts
    if [ -f "$SCRIPT_DIR/prompts/discovery.md" ]; then
        cp "$SCRIPT_DIR/prompts/discovery.md" "$STATE_DIR/prompt.md"
        echo "  Created _state/prompt.md"
    fi
    if [ -f "$SCRIPT_DIR/prompts/maintenance.md" ]; then
        cp "$SCRIPT_DIR/prompts/maintenance.md" "$STATE_DIR/maintenance-prompt.md"
        echo "  Created _state/maintenance-prompt.md"
    fi

    # Copy subagents
    if [ -f "$SCRIPT_DIR/config/subagents.json" ]; then
        cp "$SCRIPT_DIR/config/subagents.json" "$STATE_DIR/subagents.json"
        echo "  Created _state/subagents.json"
    fi

    # Copy fix-json utility
    if [ -f "$SCRIPT_DIR/fix-json.py" ]; then
        cp "$SCRIPT_DIR/fix-json.py" "$STATE_DIR/fix-json.py"
        echo "  Created _state/fix-json.py"
    fi

    # Copy style guide
    if [ -f "$SCRIPT_DIR/config/style-guide.md" ]; then
        cp "$SCRIPT_DIR/config/style-guide.md" "$STATE_DIR/style-guide.md"
        echo "  Created _state/style-guide.md"
    fi

    # Create empty state files
    echo '{"mode":"breadth","current_focus":null,"queue":[],"discovered_concepts":[],"cross_service_patterns":[],"last_cycle":null,"total_cycles":0}' > "$STATE_DIR/frontier.json"
    echo '{"cycles":[]}' > "$STATE_DIR/cycle-log.json"
    echo '{"last_rotation_cycle":0,"audit_progress":{}}' > "$STATE_DIR/maintenance-state.json"
    touch "$STATE_DIR/journal.md"
    touch "$STATE_DIR/journal-summary.md"

    echo ""
    echo "Setup complete. Now configure ralph-loop/config/modules.json with your modules."
    echo "Then run: $0 --once"
}

# Initialize frontier if empty
init_frontier() {
    local queue_length=$(jq '.queue | length' "$FRONTIER_FILE")
    local total_cycles=$(jq '.total_cycles' "$FRONTIER_FILE")

    if [ "$queue_length" -eq 0 ] && [ "$total_cycles" -eq 0 ]; then
        log "Initializing frontier with all modules (breadth-first)..."

        jq --slurpfile config "$CONFIG_FILE" '.queue = [$config[0].modules | keys[]]' \
            "$FRONTIER_FILE" > "$FRONTIER_FILE.tmp" && mv "$FRONTIER_FILE.tmp" "$FRONTIER_FILE"
    fi
}

# Check if maintenance cycle should run
should_run_maintenance() {
    local cycle_num=$(jq '.total_cycles' "$FRONTIER_FILE")

    if [ $((cycle_num % MAINTENANCE_CYCLE_INTERVAL)) -eq 0 ] && [ "$cycle_num" -gt 0 ]; then
        echo "scheduled"
        return 0
    fi

    if [ -f "$JOURNAL_FILE" ]; then
        local journal_lines=$(wc -l < "$JOURNAL_FILE" | tr -d ' ')
        if [ "$journal_lines" -gt "$JOURNAL_MAX_LINES" ]; then
            echo "journal_overflow"
            return 0
        fi
    fi

    return 1
}

# Run maintenance cycle
run_maintenance_cycle() {
    local trigger_reason="$1"

    log "═══════════════════════════════════════════════════════"
    log "MAINTENANCE CYCLE (trigger: $trigger_reason)"
    log "═══════════════════════════════════════════════════════"

    local start_time=$(date +%s)
    local prompt=$(cat "$MAINTENANCE_PROMPT_FILE")

    cd "$DOCS_DIR/.."

    log "Running maintenance agent (model: $CLAUDE_MODEL)..."

    local claude_args="-p --model $CLAUDE_MODEL"
    if [ "$SKIP_PERMISSIONS" = "true" ]; then
        claude_args="$claude_args --dangerously-skip-permissions"
    fi

    local output
    local status="success"
    if [ "$USE_AGENTS" = "true" ] && [ -f "$SUBAGENTS_FILE" ]; then
        if output=$(claude $claude_args --agents "$(cat "$SUBAGENTS_FILE")" "$prompt" 2>&1); then
            log_success "Maintenance completed successfully"
        else
            log_error "Maintenance failed"
            status="failed"
        fi
    else
        if output=$(claude $claude_args "$prompt" 2>&1); then
            log_success "Maintenance completed successfully"
        else
            log_error "Maintenance failed"
            status="failed"
        fi
    fi

    echo "$output"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    local cycle_num=$(jq '.total_cycles' "$FRONTIER_FILE")
    jq --arg num "$cycle_num" \
       --arg time "$(date -Iseconds)" \
       --arg dur "$duration" \
       --arg status "$status" \
       --arg type "maintenance" \
       --arg trigger "$trigger_reason" \
       '.cycles += [{"cycle": ($num|tonumber), "timestamp": $time, "duration_seconds": ($dur|tonumber), "status": $status, "type": $type, "trigger": $trigger}]' \
       "$CYCLE_LOG_FILE" > "$CYCLE_LOG_FILE.tmp" && mv "$CYCLE_LOG_FILE.tmp" "$CYCLE_LOG_FILE"

    log "Maintenance completed in ${duration}s"

    cd "$DOCS_DIR"

    validate_json_files

    if [ "$SKIP_COMMIT" != "true" ]; then
        cd "$DOCS_DIR/.."
        local changes=$(git status --porcelain docs/ 2>/dev/null)
        if [ -n "$changes" ]; then
            git add docs/
            git commit -m "docs: maintenance cycle (${trigger_reason})"
            log_success "Committed maintenance changes"
        fi
        cd "$DOCS_DIR"
    fi
}

# Run one discovery cycle
run_cycle() {
    local cycle_num=$(jq '.total_cycles' "$FRONTIER_FILE")
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

    local start_time=$(date +%s)

    local prompt=$(cat "$PROMPT_FILE")

    cd "$DOCS_DIR/.."

    log "Running Claude discovery agent (model: $CLAUDE_MODEL)..."

    local claude_args="-p --model $CLAUDE_MODEL"
    if [ "$SKIP_PERMISSIONS" = "true" ]; then
        claude_args="$claude_args --dangerously-skip-permissions"
    fi

    local output
    local status="success"
    if [ "$USE_AGENTS" = "true" ] && [ -f "$SUBAGENTS_FILE" ]; then
        if output=$(claude $claude_args --agents "$(cat "$SUBAGENTS_FILE")" "$prompt" 2>&1); then
            log_success "Cycle completed successfully"
        else
            log_error "Cycle failed with error"
            status="failed"
        fi
    else
        if output=$(claude $claude_args "$prompt" 2>&1); then
            log_success "Cycle completed successfully"
        else
            log_error "Cycle failed with error"
            status="failed"
        fi
    fi

    echo "$output"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

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

    jq ".total_cycles = $cycle_num | .last_cycle = \"$(date -Iseconds)\"" \
        "$FRONTIER_FILE" > "$FRONTIER_FILE.tmp" && mv "$FRONTIER_FILE.tmp" "$FRONTIER_FILE"

    jq --arg num "$cycle_num" \
       --arg time "$(date -Iseconds)" \
       --arg dur "$duration" \
       --arg status "$status" \
       --arg type "discovery" \
       '.cycles += [{"cycle": ($num|tonumber), "timestamp": $time, "duration_seconds": ($dur|tonumber), "status": $status, "type": $type}]' \
       "$CYCLE_LOG_FILE" > "$CYCLE_LOG_FILE.tmp" && mv "$CYCLE_LOG_FILE.tmp" "$CYCLE_LOG_FILE"

    log "Cycle #$cycle_num completed in ${duration}s"

    cd "$DOCS_DIR"

    validate_json_files

    commit_changes "$cycle_num"
}

# Commit changes after cycle
commit_changes() {
    local cycle_num="$1"

    if [ "$SKIP_COMMIT" = "true" ]; then
        return
    fi

    cd "$DOCS_DIR/.."

    local changes=$(git status --porcelain docs/ 2>/dev/null)

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

# ────────────────────────────────────────────────────────
# DOCUMENTATION REFINEMENT FUNCTIONS
# ────────────────────────────────────────────────────────

SERVICES_ORDER=$(jq -r '.modules | keys | join(" ")' "$CONFIG_FILE" 2>/dev/null || echo "")

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

    local start_time=$(date +%s)

    local prompt
    prompt=$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$REFINE_PROMPT_FILE")
    prompt="$prompt

## Target

Process the service: **$service**
Service docs folder: docs/$service/
Style guide: docs/_state/style-guide.md
Reference: docs/.claude/skills/refine-docs/reference.md"

    cd "$DOCS_DIR/.."

    local claude_args="-p --model $CLAUDE_MODEL"
    if [ "$SKIP_PERMISSIONS" = "true" ]; then
        claude_args="$claude_args --dangerously-skip-permissions"
    fi

    local output
    local status="success"
    if output=$(claude $claude_args "$prompt" 2>&1); then
        log_success "Refinement of $service completed"
    else
        log_error "Refinement of $service failed"
        status="failed"
    fi

    echo "$output"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    jq --arg time "$(date -Iseconds)" \
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

    if [ "$target" = "all" ]; then
        local total_start=$(date +%s)
        local succeeded=0
        local failed=0

        for service in $SERVICES_ORDER; do
            if run_refine_service "$service"; then
                succeeded=$((succeeded + 1))
            else
                failed=$((failed + 1))
            fi

            if [ "$SKIP_COMMIT" != "true" ]; then
                cd "$DOCS_DIR/.."
                local changes=$(git status --porcelain docs/ 2>/dev/null)
                if [ -n "$changes" ]; then
                    git add docs/
                    git commit -m "docs: refine $service (dual-purpose format)"
                    log_success "Committed refinement: $service"
                fi
                cd "$DOCS_DIR"
            fi
        done

        local total_end=$(date +%s)
        local total_duration=$((total_end - total_start))

        echo ""
        log "═══════════════════════════════════════════════════════"
        log_success "Refinement complete: $succeeded succeeded, $failed failed (${total_duration}s total)"
        log "═══════════════════════════════════════════════════════"
    else
        run_refine_service "$target"

        if [ "$SKIP_COMMIT" != "true" ]; then
            cd "$DOCS_DIR/.."
            local changes=$(git status --porcelain docs/ 2>/dev/null)
            if [ -n "$changes" ]; then
                git add docs/
                git commit -m "docs: refine $target (dual-purpose format)"
                log_success "Committed refinement: $target"
            fi
            cd "$DOCS_DIR"
        fi
    fi
}

# Main loop
main() {
    log "╔═══════════════════════════════════════════════════════╗"
    log "║       RALPH LOOP — Discovery Runner                    ║"
    log "╚═══════════════════════════════════════════════════════╝"

    check_dependencies
    check_first_run

    validate_json_files

    local sleep_seconds=$(jq -r '.cycle_sleep_seconds // 10' "$CONFIG_FILE")

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

    while true; do
        run_cycle || log_error "Cycle failed, continuing..."

        log "Sleeping for ${sleep_seconds}s before next cycle..."
        echo ""
        sleep "$sleep_seconds"
    done
}

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
        --status)
            ACTION="status"
            ;;
        --commit)
            ACTION="commit"
            ;;
        --reset)
            ACTION="reset"
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
        check_first_run
        validate_json_files
        init_frontier
        run_cycle
        ;;
    maintenance)
        check_dependencies
        validate_json_files
        run_maintenance_cycle "manual"
        ;;
    setup)
        run_setup
        exit 0
        ;;
    auto-setup)
        check_dependencies
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
    refine)
        run_refine "$REFINE_TARGET"
        exit 0
        ;;
    status)
        echo "=== Frontier ==="
        jq '{total_cycles, last_cycle, queue_length: (.queue | length), concepts: (.discovered_concepts | length), patterns: (.cross_service_patterns | length)}' "$FRONTIER_FILE"
        echo ""
        echo "=== Journal Stats ==="
        echo "journal.md: $(wc -l < "$JOURNAL_FILE" 2>/dev/null | tr -d ' ' || echo '0') lines"
        echo "journal-summary.md: $(wc -l < "$JOURNAL_SUMMARY_FILE" 2>/dev/null | tr -d ' ' || echo '0') lines"
        echo ""
        echo "=== Maintenance State ==="
        jq '{files_audited: (.cross_service_audit.files_audited | length), files_split: (.cross_service_audit.files_split | length), files_correct: (.cross_service_audit.files_correct | length), current_target: .cross_service_audit.current_target}' "$MAINTENANCE_STATE_FILE"
        echo ""
        echo "=== Cross-Service Files Remaining ==="
        audited=$(jq -r '.cross_service_audit.files_audited[]' "$MAINTENANCE_STATE_FILE" 2>/dev/null | sort)
        all_files=$(ls docs/_cross-service/*.md 2>/dev/null | xargs -n1 basename | sort)
        echo "$all_files" | while read -r f; do
            echo "$audited" | grep -qxF "$f" || echo "$f"
        done | head -10
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
        jq '.cycles | .[-5:]' "$CYCLE_LOG_FILE"
        ;;
    commit)
        cd "$DOCS_DIR/.."
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
        ;;
    reset)
        log_error "Resetting state..."
        echo '{"mode":"breadth","current_focus":null,"queue":[],"discovered_concepts":[],"cross_service_patterns":[],"last_cycle":null,"total_cycles":0}' > "$FRONTIER_FILE"
        echo '{"cycles":[]}' > "$CYCLE_LOG_FILE"
        log_success "State reset complete"
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
        echo "  --setup            Initialize _state/ directory with empty state files"
        echo "  --auto-setup       Detect sibling projects, generate configs, and run setup"
        echo "  --refine           Refine all service docs (add digests, compress, cross-ref)"
        echo "  --refine=SERVICE   Refine a specific service (e.g., --refine=my-api)"
        echo "  --commit           Commit pending docs changes"
        echo "  --status           Show current state"
        echo "  --reset            Reset all state files"
        echo "  --help             Show this help"
        echo ""
        echo "Cycle types:"
        echo "  - Discovery: Explores code, documents concepts"
        echo "  - Maintenance: Rotates journals, audits docs, cleans state (every ${MAINTENANCE_CYCLE_INTERVAL} cycles)"
        echo ""
        echo "Maintenance runs automatically when:"
        echo "  - Every ${MAINTENANCE_CYCLE_INTERVAL} cycles"
        echo "  - journal.md exceeds ${JOURNAL_MAX_LINES} lines"
        echo ""
        echo "Environment variables:"
        echo "  CLAUDE_MODEL                    Model to use (default: opus)"
        echo "  SKIP_PERMISSIONS                Skip permission prompts (default: true)"
        echo "  SKIP_COMMIT                     Skip auto-commit (default: false)"
        echo "  COMMIT_MSG_PREFIX               Commit message prefix (default: 'docs: discovery cycle')"
        echo "  USE_AGENTS                      Enable specialist subagents (default: true)"
        echo "  DISCOVERY_ONLY                  Skip maintenance (default: false)"
        echo "  CLAUDE_CODE_MAX_OUTPUT_TOKENS   Max output tokens (default: 64000, max: 64000)"
        echo "  MAX_THINKING_TOKENS             Extended thinking budget (default: 31999)"
        echo ""
        echo "Examples:"
        echo "  $0                              # Run continuous loop (all cycle types)"
        echo "  $0 --once                       # Run single cycle"
        echo "  $0 --discovery-only             # Continuous loop, discovery only"
        echo "  $0 --discovery-once             # Single discovery cycle, no extras"
        echo "  $0 --refine                     # Refine all services"
        echo "  $0 --refine=my-api              # Refine one service"
        echo "  $0 --maintenance                # Force cleanup cycle"
        echo "  CLAUDE_MODEL=opus $0            # Use opus for deeper analysis"
        echo "  SKIP_COMMIT=true $0             # Don't commit changes"
        echo "  USE_AGENTS=false $0             # Disable specialist delegation"
        ;;
    run)
        main
        ;;
esac
