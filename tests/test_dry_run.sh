#!/usr/bin/env bash
# tests/test_dry_run.sh
# Tests for --dry-run flag behavior.
# Usage: bash tests/test_dry_run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== Dry-run flag tests ==="
echo ""

# Helper: set up a minimal DOCS_DIR with the structure needed for --work-once
_setup_work_tmpdir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local state="$tmpdir/_state"
    mkdir -p "$state" "$tmpdir/config" "$tmpdir/prompts" "$tmpdir/lib"

    # Minimal prompts/work.md with placeholder
    printf 'Hello {{state_dir}} world\n' > "$tmpdir/prompts/work.md"

    # Minimal config templates
    printf '{"schema_version":1,"project_context":"test","tasks":[]}' > "$tmpdir/config/tasks.json"
    printf '{}' > "$tmpdir/config/modules.json"
    printf '{}' > "$tmpdir/config/subagents.json"

    echo "$tmpdir"
}

# --work-once --dry-run: exits 0
(
    tmpdir=$(_setup_work_tmpdir)
    exit_code=0
    DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet \
        bash "$RUN_SH" --work-once --dry-run >/dev/null 2>&1 || exit_code=$?
    assert_equals "--work-once --dry-run exits 0" "$exit_code" "0"
    rm -rf "$tmpdir"
)

# --work-once --dry-run: writes _state/dry-run-prompt.md
(
    tmpdir=$(_setup_work_tmpdir)
    DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet \
        bash "$RUN_SH" --work-once --dry-run >/dev/null 2>&1 || true
    if [ -f "$tmpdir/_state/dry-run-prompt.md" ]; then
        pass "--work-once --dry-run writes _state/dry-run-prompt.md"
    else
        fail "--work-once --dry-run writes _state/dry-run-prompt.md" "file not found"
    fi
    rm -rf "$tmpdir"
)

# --work-once --dry-run: LAST_VALIDATION_FILE is preserved (not deleted)
(
    tmpdir=$(_setup_work_tmpdir)
    state="$tmpdir/_state"
    # Pre-seed a validation results file
    printf '{"_summary":"ok"}' > "$state/last-validation-results.json"
    DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet \
        bash "$RUN_SH" --work-once --dry-run >/dev/null 2>&1 || true
    if [ -f "$state/last-validation-results.json" ]; then
        pass "--work-once --dry-run preserves last-validation-results.json"
    else
        fail "--work-once --dry-run preserves last-validation-results.json" "file was deleted"
    fi
    rm -rf "$tmpdir"
)

# --work-once --dry-run: output contains DRY RUN header
(
    tmpdir=$(_setup_work_tmpdir)
    output=""
    output=$(DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet \
        bash "$RUN_SH" --work-once --dry-run 2>&1) || true
    assert_contains "--work-once --dry-run output contains DRY RUN header" "$output" "DRY RUN"
    rm -rf "$tmpdir"
)

# --work-once --dry-run: output contains 'claude was NOT invoked'
(
    tmpdir=$(_setup_work_tmpdir)
    output=""
    output=$(DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet \
        bash "$RUN_SH" --work-once --dry-run 2>&1) || true
    assert_contains "--work-once --dry-run output confirms claude not invoked" "$output" "claude was NOT invoked"
    rm -rf "$tmpdir"
)

# DRY_RUN=true env var: equivalent to --dry-run flag
(
    tmpdir=$(_setup_work_tmpdir)
    exit_code=0
    DRY_RUN=true DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet \
        bash "$RUN_SH" --work-once >/dev/null 2>&1 || exit_code=$?
    assert_equals "DRY_RUN=true env var exits 0" "$exit_code" "0"
    rm -rf "$tmpdir"
)

# --work-once --dry-run: prompt has {{state_dir}} replaced
(
    tmpdir=$(_setup_work_tmpdir)
    DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet \
        bash "$RUN_SH" --work-once --dry-run >/dev/null 2>&1 || true
    if [ -f "$tmpdir/_state/dry-run-prompt.md" ]; then
        content=$(cat "$tmpdir/_state/dry-run-prompt.md")
        if echo "$content" | grep -qF '_state'; then
            pass "--work-once --dry-run prompt has {{state_dir}} replaced"
        else
            fail "--work-once --dry-run prompt has {{state_dir}} replaced" "placeholder not substituted"
        fi
    else
        fail "--work-once --dry-run prompt has {{state_dir}} replaced" "dry-run-prompt.md not found"
    fi
    rm -rf "$tmpdir"
)

# --once --dry-run: exits 0 and writes dry-run output
(
    tmpdir=$(mktemp -d)
    state="$tmpdir/_state"
    mkdir -p "$state" "$tmpdir/config" "$tmpdir/prompts"
    # Minimal discovery prompt
    printf 'Discovery prompt content\n' > "$state/prompt.md"
    printf '{}' > "$tmpdir/config/modules.json"
    printf '{}' > "$tmpdir/config/subagents.json"
    # check_first_run needs config.json with at least one module
    printf '{"modules":{"test":{"path":"."}},"docs_root":".","cycle_sleep_seconds":10}' > "$state/config.json"
    # init_frontier needs frontier.json
    printf '{"mode":"breadth","current_focus":null,"queue":[],"discovered_concepts":[],"cross_service_patterns":[],"last_cycle":null,"total_cycles":0}' > "$state/frontier.json"
    printf '{"cycles":[]}' > "$state/cycle-log.json"
    touch "$state/journal.md"

    exit_code=0
    output=""
    output=$(DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet \
        bash "$RUN_SH" --once --dry-run 2>&1) || exit_code=$?
    assert_equals "--once --dry-run exits 0" "$exit_code" "0"
    assert_contains "--once --dry-run output contains DRY RUN header" "$output" "DRY RUN"
    rm -rf "$tmpdir"
)

print_summary "dry_run"
