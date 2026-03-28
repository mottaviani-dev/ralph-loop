#!/bin/bash
# lib/setup.sh — Auto-detection, project setup, first-run wizard, frontier init.
#
# Dependencies: lib/common.sh (log, log_success, log_error, log_warn)
#               lib/work.sh (init_work_state)
# Globals used: DOCS_DIR, SCRIPT_DIR, STATE_DIR, CONFIG_FILE, FRONTIER_FILE,
#               CYCLE_LOG_FILE, JOURNAL_FILE, JOURNAL_SUMMARY_FILE,
#               MAINTENANCE_STATE_FILE, WORK_STATE_FILE, SUBAGENTS_FILE

# Auto-detect subproject modules inside the project directory
auto_detect_modules() {
    local workspace_dir="$DOCS_DIR"
    local modules_json="{}"
    local count=0

    for dir in "$workspace_dir"/*/; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")

        # Skip: non-code directories, hidden dirs, underscore-prefixed dirs
        case "$name" in
            docs|ralph-loop|node_modules|public|tests|.*|_*) continue ;;
        esac

        # Detect project type by markers (no .git requirement — submodules live in-tree)
        local ptype=""
        if [ -f "$dir/composer.json" ]; then
            ptype="backend"
        elif [ -f "$dir/angular.json" ]; then
            ptype="frontend"
        elif [ -f "$dir/nuxt.config.js" ] || [ -f "$dir/nuxt.config.ts" ]; then
            ptype="frontend"
        elif [ -f "$dir/package.json" ]; then
            ptype="frontend"
        elif [ -d "$dir/.git" ]; then
            # Reference repos (e.g. apple.theme.cms) without root markers
            ptype="reference"
        elif find "$dir" -maxdepth 1 \( -name '*.ts' -o -name '*.vue' -o -name '*.php' \) -print -quit 2>/dev/null | grep -q .; then
            # Directories with code files but no package manager
            ptype="module"
        else
            continue
        fi

        modules_json=$(echo "$modules_json" | jq \
            --arg name "$name" \
            --arg path "./$name" \
            --arg type "$ptype" \
            '. + {($name): {"path": $path, "type": $type, "integrates_with": []}}')
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        return 1
    fi

    # Write detected modules to state directory (never mutate source-controlled config/)
    mkdir -p "$STATE_DIR"
    local config_template="$SCRIPT_DIR/config/modules.json"
    local config_target="$STATE_DIR/config.json"
    if [ -f "$config_template" ]; then
        jq --argjson mods "$modules_json" '.modules = $mods' "$config_template" \
            > "$config_target.tmp" && mv "$config_target.tmp" "$config_target"
    else
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
            "cross_service_dir": "docs/_cross-service",
            "cycle_sleep_seconds": 10
        }' > "$config_target"
    fi

    echo "$count"
}

# Auto-generate subagents.json from modules.json
auto_detect_subagents() {
    local modules_file="$STATE_DIR/config.json"
    local subagents_file="$STATE_DIR/subagents.json"
    local subagents="{}"

    while IFS= read -r name; do
        local ptype
        ptype=$(jq -r --arg n "$name" '.modules[$n].type' "$modules_file")
        local path
        path=$(jq -r --arg n "$name" '.modules[$n].path' "$modules_file")

        local type_label
        case "$ptype" in
            backend)   type_label="Backend" ;;
            frontend)  type_label="Frontend" ;;
            reference) type_label="Reference" ;;
            module)    type_label="Module" ;;
            *)         type_label="General" ;;
        esac

        local prompt="You are a specialist for the $name service. Working directory: $path"
        if [ -f "$DOCS_DIR/$name/CLAUDE.md" ]; then
            prompt="$prompt. Read CLAUDE.md in the project root for full context."
        fi

        subagents=$(echo "$subagents" | jq \
            --arg name "$name" \
            --arg desc "$type_label developer for $name" \
            --arg prompt "$prompt" \
            '. + {($name): {"description": $desc, "prompt": $prompt, "tools": ["Read","Write","Edit","Glob","Grep","Bash"], "model": "inherit"}}')
    done < <(jq -r '.modules | keys[]' "$modules_file")

    echo "$subagents" > "$subagents_file"
}

# Print detected projects table
print_detected_projects() {
    local modules_file="$STATE_DIR/config.json"
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
                    log_success "Generated _state/config.json ($detected modules)"
                    log_success "Generated _state/subagents.json"
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

    # Migrate any pre-existing state files before setup recreates them
    migrate_all

    # Copy config template (skip if auto-detection already populated state)
    if [ -f "$STATE_DIR/config.json" ] && jq -e '.modules | length > 0' "$STATE_DIR/config.json" >/dev/null 2>&1; then
        echo "  _state/config.json already populated by auto-detection (skipping template copy)"
    else
        if [ -f "$SCRIPT_DIR/config/modules.json" ]; then
            cp "$SCRIPT_DIR/config/modules.json" "$STATE_DIR/config.json"
            echo "  Created _state/config.json from template"
        fi
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

    # Copy subagents (skip if auto-detection already populated state)
    if [ -f "$STATE_DIR/subagents.json" ] && jq -e 'keys | length > 0' "$STATE_DIR/subagents.json" >/dev/null 2>&1; then
        echo "  _state/subagents.json already populated by auto-detection (skipping template copy)"
    else
        if [ -f "$SCRIPT_DIR/config/subagents.json" ]; then
            cp "$SCRIPT_DIR/config/subagents.json" "$STATE_DIR/subagents.json"
            echo "  Created _state/subagents.json"
        fi
    fi

    # Copy fix-json utility
    if [ -f "$SCRIPT_DIR/fix-json.py" ]; then
        cp "$SCRIPT_DIR/fix-json.py" "$STATE_DIR/fix-json.py"
        echo "  Created _state/fix-json.py"
    fi

    # Copy work mode prompt
    if [ -f "$SCRIPT_DIR/prompts/work.md" ]; then
        cp "$SCRIPT_DIR/prompts/work.md" "$STATE_DIR/work-prompt.md"
        echo "  Created _state/work-prompt.md"
    fi

    # Copy refine mode prompt
    if [ -f "$SCRIPT_DIR/prompts/refine.md" ]; then
        cp "$SCRIPT_DIR/prompts/refine.md" "$STATE_DIR/refine-prompt.md"
        echo "  Created _state/refine-prompt.md"
    fi

    # Copy tasks template
    if [ -f "$SCRIPT_DIR/config/tasks.json" ]; then
        cp "$SCRIPT_DIR/config/tasks.json" "$STATE_DIR/tasks.json"
        echo "  Created _state/tasks.json"
    fi

    # Copy style guide
    if [ -f "$SCRIPT_DIR/config/style-guide.md" ]; then
        cp "$SCRIPT_DIR/config/style-guide.md" "$STATE_DIR/style-guide.md"
        echo "  Created _state/style-guide.md"
    fi

    # Create empty state files
    # Delegate to init_work_state for canonical schema (single source of truth)
    rm -f "$STATE_DIR/work-state.json"
    init_work_state
    echo "  Created _state/work-state.json (canonical schema)"
    echo '{"schema_version":1,"mode":"breadth","current_focus":null,"queue":[],"discovered_concepts":[],"cross_service_patterns":[],"last_cycle":null,"total_cycles":0}' > "$STATE_DIR/frontier.json"
    echo '{"cycles":[]}' > "$CYCLE_LOG_FILE"
    echo '{"schema_version":1,"last_rotation_cycle":0,"audit_progress":{}}' > "$STATE_DIR/maintenance-state.json"
    touch "$STATE_DIR/journal.md"
    touch "$STATE_DIR/journal-summary.md"

    echo ""
    echo "Setup complete. Now configure ralph-loop/config/modules.json with your modules."
    echo "Then run: $0 --once"
}

# Initialize frontier if empty
init_frontier() {
    local queue_length
    queue_length=$(jq '.queue | length' "$FRONTIER_FILE")
    local total_cycles
    total_cycles=$(jq '.total_cycles' "$FRONTIER_FILE")

    if [ "$queue_length" -eq 0 ] && [ "$total_cycles" -eq 0 ]; then
        log "Initializing frontier with all modules (breadth-first)..."

        jq --slurpfile config "$CONFIG_FILE" '.queue = [$config[0].modules | keys[]]' \
            "$FRONTIER_FILE" > "$FRONTIER_FILE.tmp" && mv "$FRONTIER_FILE.tmp" "$FRONTIER_FILE"
    fi
}
