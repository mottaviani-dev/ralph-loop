#!/usr/bin/env bash
# tests/test_arg_parsing.sh
# Smoke tests for run.sh argument parsing.
# Usage: bash tests/test_arg_parsing.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_SH="$SCRIPT_DIR/../run.sh"
source "$SCRIPT_DIR/common.sh"
enable_subshell_counters

echo "=== Argument parsing smoke tests ==="
echo ""

# --help: exits 0 and prints Usage
(
    output=$(SKIP_CLAUDE_CHECK=1 bash "$RUN_SH" --help 2>&1) || true
    exit_code=0
    SKIP_CLAUDE_CHECK=1 bash "$RUN_SH" --help >/dev/null 2>&1 || exit_code=$?
    assert_equals "--help exits 0" "$exit_code" "0"
    assert_contains "--help prints Usage" "$output" "Usage"
)

# Unknown flag: exits 1
(
    exit_code=0
    output=$(SKIP_CLAUDE_CHECK=1 bash "$RUN_SH" --not-a-real-flag 2>&1) || exit_code=$?
    assert_equals "unknown flag exits 1" "$exit_code" "1"
    assert_contains "unknown flag prints error message" "$output" "--not-a-real-flag"
)

# --validate-only: exits 0 with valid env
(
    exit_code=0
    SKIP_CLAUDE_CHECK=1 CLAUDE_MODEL=sonnet bash "$RUN_SH" --validate-only >/dev/null 2>&1 || exit_code=$?
    assert_equals "--validate-only exits 0 with valid env" "$exit_code" "0"
)

# --validate-only with bad env var: exits 1
(
    exit_code=0
    SKIP_CLAUDE_CHECK=1 WORK_AGENT_TIMEOUT=abc bash "$RUN_SH" --validate-only >/dev/null 2>&1 || exit_code=$?
    assert_equals "--validate-only exits 1 with invalid WORK_AGENT_TIMEOUT" "$exit_code" "1"
)

# --status: exits 0 and produces output (smoke test for flag wiring)
(
    exit_code=0
    output=$(SKIP_CLAUDE_CHECK=1 bash "$RUN_SH" --status 2>&1) || exit_code=$?
    assert_equals "--status exits 0" "$exit_code" "0"
    # Should contain at least one of the status section headers
    assert_contains "--status prints status output" "$output" "==="
)

# --reset: clears all state files (discovery + work + maintenance + journals + ephemeral)
(
    # Set up a temporary DOCS_DIR with _state/ seeded with stale data
    tmpdir=$(mktemp -d)
    state="$tmpdir/_state"
    mkdir -p "$state"

    # Seed discovery state
    echo '{"mode":"breadth","current_focus":"stale","queue":["a"],"discovered_concepts":[],"cross_service_patterns":[],"last_cycle":null,"total_cycles":42}' > "$state/frontier.json"
    echo '{"cycles":[{"type":"discovery"}]}' > "$state/cycle-log.json"

    # Seed work state with stale cycle count
    echo '{"current_task":"old-task","total_cycles":99,"last_cycle":null,"last_action":null,"last_outcome":null,"all_tasks_complete":false,"action_history":[],"stats":{}}' > "$state/work-state.json"

    # Seed tasks.json with stale data
    echo '{"schema_version":1,"project_context":"stale","tasks":[{"id":"old","status":"done"}]}' > "$state/tasks.json"

    # Seed maintenance state
    echo '{"cross_service_audit":{"files_audited":["x"]}}' > "$state/maintenance-state.json"

    # Seed journals with content
    echo "old journal line" > "$state/journal.md"
    echo "old summary line" > "$state/journal-summary.md"

    # Seed ephemeral outputs
    echo '{"result":"stale"}' > "$state/last-validation-results.json"
    echo "stale findings" > "$state/eval-findings.md"

    # Create config/ dir with tasks.json template for re-seeding
    mkdir -p "$tmpdir/config"
    echo '{"schema_version":1,"project_context":"fresh","tasks":[]}' > "$tmpdir/config/tasks.json"

    # Also need prompts/work.md for init_work_state
    mkdir -p "$tmpdir/prompts"
    echo "placeholder work prompt" > "$tmpdir/prompts/work.md"

    # Also need lib/ and the main script — run from the repo's run.sh with DOCS_DIR override
    exit_code=0
    output=$(DOCS_DIR="$tmpdir" SKIP_CLAUDE_CHECK=1 bash "$RUN_SH" --reset 2>&1) || exit_code=$?
    assert_equals "--reset exits 0" "$exit_code" "0"

    # Discovery state reset
    discovery_cycles=$(jq '.total_cycles' "$state/frontier.json" 2>/dev/null)
    assert_equals "--reset zeroes discovery total_cycles" "$discovery_cycles" "0"

    # Work state reset
    work_cycles=$(jq '.total_cycles' "$state/work-state.json" 2>/dev/null)
    assert_equals "--reset zeroes work total_cycles" "$work_cycles" "0"

    # Journal emptied
    journal_lines=$(wc -l < "$state/journal.md" 2>/dev/null | tr -d ' ')
    assert_equals "--reset empties journal.md" "$journal_lines" "0"

    # Journal summary emptied
    summary_lines=$(wc -l < "$state/journal-summary.md" 2>/dev/null | tr -d ' ')
    assert_equals "--reset empties journal-summary.md" "$summary_lines" "0"

    # Tasks.json re-seeded from config (should have "fresh" context, not "stale")
    tasks_ctx=$(jq -r '.project_context' "$state/tasks.json" 2>/dev/null)
    assert_equals "--reset re-seeds tasks.json from config" "$tasks_ctx" "fresh"

    # Ephemeral outputs removed
    if [ ! -f "$state/last-validation-results.json" ]; then pass "--reset removes last-validation-results.json"; else fail "--reset removes last-validation-results.json" "file still exists"; fi
    if [ ! -f "$state/eval-findings.md" ]; then pass "--reset removes eval-findings.md"; else fail "--reset removes eval-findings.md" "file still exists"; fi

    rm -rf "$tmpdir"
)

# --watch with missing STATE_DIR: exits 1 with informative error
(
    exit_code=0
    tmpdir=$(mktemp -d)
    output=$(SKIP_CLAUDE_CHECK=1 DOCS_DIR="$tmpdir" bash "$RUN_SH" --watch 2>&1) || exit_code=$?
    assert_equals "--watch exits 1 when STATE_DIR absent" "$exit_code" "1"
    assert_contains "--watch reports missing state dir" "$output" "STATE_DIR not found"
    rm -rf "$tmpdir"
)

# --dry-run: recognized flag (does not error as unknown)
(
    exit_code=0
    output=$(SKIP_CLAUDE_CHECK=1 bash "$RUN_SH" --help 2>&1) || exit_code=$?
    assert_contains "--help shows --dry-run flag" "$output" "--dry-run"
)

# --help: shows DRY_RUN env var
(
    output=$(SKIP_CLAUDE_CHECK=1 bash "$RUN_SH" --help 2>&1) || true
    assert_contains "--help shows DRY_RUN env var" "$output" "DRY_RUN"
)

print_summary "arg_parsing"
