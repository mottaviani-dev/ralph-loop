#!/usr/bin/env bash
# tests/test_config_file.sh — tests for lib/config.sh load_project_config()
# Usage: bash tests/test_config_file.sh
# Exit 0 = all tests passed, Exit 1 = failure
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/../lib/config.sh"

# --- Test 1: no config file present — all vars stay unset ---
echo "=== no config file present ==="
DOCS_DIR="$(mktemp -d)"
unset CLAUDE_MODEL WORK_AGENT_TIMEOUT SKIP_COMMIT
load_project_config
if [[ -z "${CLAUDE_MODEL+x}" ]]; then pass "CLAUDE_MODEL unset"; else fail "CLAUDE_MODEL unset" "was set to '$CLAUDE_MODEL'"; fi
if [[ -z "${WORK_AGENT_TIMEOUT+x}" ]]; then pass "WORK_AGENT_TIMEOUT unset"; else fail "WORK_AGENT_TIMEOUT unset" "was set"; fi
if [[ -z "${SKIP_COMMIT+x}" ]]; then pass "SKIP_COMMIT unset"; else fail "SKIP_COMMIT unset" "was set"; fi
rm -rf "$DOCS_DIR"

# --- Test 2: valid config file — values are applied ---
echo ""
echo "=== valid config file ==="
DOCS_DIR="$(mktemp -d)"
cat > "$DOCS_DIR/.ralph-loop.json" <<'JSON'
{
  "model": "sonnet",
  "timeout": 300,
  "skip_commit": "true",
  "max_work_cycles": 50,
  "validate_before_commit": "true",
  "use_agents": "false",
  "notify": { "webhook_url": "https://example.com/hook", "on": ["complete", "error"] },
  "git_exclude": ["vendor/", "*.lock"]
}
JSON
unset CLAUDE_MODEL WORK_AGENT_TIMEOUT SKIP_COMMIT MAX_WORK_CYCLES VALIDATE_BEFORE_COMMIT USE_AGENTS NOTIFY_WEBHOOK_URL NOTIFY_ON RALPH_GIT_EXCLUDE
load_project_config 2>/dev/null
if [[ "$CLAUDE_MODEL" == "sonnet" ]]; then pass "model=sonnet"; else fail "model=sonnet" "got '$CLAUDE_MODEL'"; fi
if [[ "$WORK_AGENT_TIMEOUT" == "300" ]]; then pass "timeout=300"; else fail "timeout=300" "got '$WORK_AGENT_TIMEOUT'"; fi
if [[ "$SKIP_COMMIT" == "true" ]]; then pass "skip_commit=true"; else fail "skip_commit=true" "got '$SKIP_COMMIT'"; fi
if [[ "$MAX_WORK_CYCLES" == "50" ]]; then pass "max_work_cycles=50"; else fail "max_work_cycles=50" "got '$MAX_WORK_CYCLES'"; fi
if [[ "$USE_AGENTS" == "false" ]]; then pass "use_agents=false"; else fail "use_agents=false" "got '$USE_AGENTS'"; fi
if [[ "$NOTIFY_WEBHOOK_URL" == "https://example.com/hook" ]]; then pass "notify.webhook_url set"; else fail "notify.webhook_url set" "got '$NOTIFY_WEBHOOK_URL'"; fi
if [[ "$NOTIFY_ON" == "complete,error" ]]; then pass "notify.on array joined"; else fail "notify.on array joined" "got '$NOTIFY_ON'"; fi
if [[ "$RALPH_GIT_EXCLUDE" == "vendor/ *.lock " ]]; then pass "git_exclude space-delimited"; else fail "git_exclude space-delimited" "got '$RALPH_GIT_EXCLUDE'"; fi
rm -rf "$DOCS_DIR"

# --- Test 3: env var override — config value is ignored ---
echo ""
echo "=== env var overrides config ==="
DOCS_DIR="$(mktemp -d)"
cat > "$DOCS_DIR/.ralph-loop.json" <<'JSON'
{ "model": "sonnet", "timeout": 300 }
JSON
export CLAUDE_MODEL="opus"
unset WORK_AGENT_TIMEOUT
load_project_config 2>/dev/null
if [[ "$CLAUDE_MODEL" == "opus" ]]; then pass "env CLAUDE_MODEL=opus wins"; else fail "env CLAUDE_MODEL=opus wins" "got '$CLAUDE_MODEL'"; fi
if [[ "$WORK_AGENT_TIMEOUT" == "300" ]]; then pass "WORK_AGENT_TIMEOUT from config"; else fail "WORK_AGENT_TIMEOUT from config" "got '$WORK_AGENT_TIMEOUT'"; fi
unset CLAUDE_MODEL
rm -rf "$DOCS_DIR"

# --- Test 4: explicit empty env var is preserved ---
echo ""
echo "=== explicit empty env var preserved ==="
DOCS_DIR="$(mktemp -d)"
cat > "$DOCS_DIR/.ralph-loop.json" <<'JSON'
{ "model": "sonnet" }
JSON
export CLAUDE_MODEL=""
load_project_config 2>/dev/null
if [[ "${CLAUDE_MODEL+x}" == "x" && -z "$CLAUDE_MODEL" ]]; then pass "explicit empty CLAUDE_MODEL preserved"; else fail "explicit empty CLAUDE_MODEL preserved" "was overwritten"; fi
unset CLAUDE_MODEL
rm -rf "$DOCS_DIR"

# --- Test 5: malformed JSON — exits with non-zero status ---
echo ""
echo "=== malformed JSON exits with error ==="
DOCS_DIR="$(mktemp -d)"
printf '{not valid json' > "$DOCS_DIR/.ralph-loop.json"
set +e
(load_project_config 2>/dev/null)
exit_code=$?
set -e
if [[ $exit_code -ne 0 ]]; then pass "malformed JSON exits non-zero"; else fail "malformed JSON exits non-zero" "exit code was $exit_code"; fi
rm -rf "$DOCS_DIR"

# --- Test 6: unknown keys emit warning ---
echo ""
echo "=== unknown keys emit warning ==="
DOCS_DIR="$(mktemp -d)"
cat > "$DOCS_DIR/.ralph-loop.json" <<'JSON'
{ "model": "sonnet", "unsupported_key": "value" }
JSON
unset CLAUDE_MODEL
stderr_output="$(load_project_config 2>&1 >/dev/null)"
if [[ "$stderr_output" == *"unknown key"* ]]; then pass "unknown key warning emitted"; else fail "unknown key warning emitted" "stderr: '$stderr_output'"; fi
rm -rf "$DOCS_DIR"

# --- Test 7: sensitive field (webhook_url) emits warning ---
echo ""
echo "=== webhook_url warning ==="
DOCS_DIR="$(mktemp -d)"
cat > "$DOCS_DIR/.ralph-loop.json" <<'JSON'
{ "notify": { "webhook_url": "https://secret.example.com" } }
JSON
unset NOTIFY_WEBHOOK_URL
stderr_output="$(load_project_config 2>&1 >/dev/null)"
if [[ "$stderr_output" == *"webhook_url"* ]]; then pass "webhook_url sensitivity warning"; else fail "webhook_url sensitivity warning" "stderr: '$stderr_output'"; fi
rm -rf "$DOCS_DIR"

# --- Test 8: notify.on as plain string passed through ---
echo ""
echo "=== notify.on as string ==="
DOCS_DIR="$(mktemp -d)"
cat > "$DOCS_DIR/.ralph-loop.json" <<'JSON'
{ "notify": { "on": "complete,error,stalemate" } }
JSON
unset NOTIFY_ON
load_project_config 2>/dev/null
if [[ "$NOTIFY_ON" == "complete,error,stalemate" ]]; then pass "notify.on string passthrough"; else fail "notify.on string passthrough" "got '$NOTIFY_ON'"; fi
rm -rf "$DOCS_DIR"

# --- Test 9: boolean values (true/false) stored as strings ---
echo ""
echo "=== boolean coercion ==="
DOCS_DIR="$(mktemp -d)"
cat > "$DOCS_DIR/.ralph-loop.json" <<'JSON'
{ "skip_commit": true, "validate_before_commit": false }
JSON
unset SKIP_COMMIT VALIDATE_BEFORE_COMMIT
load_project_config 2>/dev/null
if [[ "$SKIP_COMMIT" == "true" ]]; then pass "true stored as string 'true'"; else fail "true stored as string 'true'" "got '$SKIP_COMMIT'"; fi
if [[ "$VALIDATE_BEFORE_COMMIT" == "false" ]]; then pass "false stored as string 'false'"; else fail "false stored as string 'false'" "got '$VALIDATE_BEFORE_COMMIT'"; fi
rm -rf "$DOCS_DIR"

# --- Test 10: missing jq — warning emitted, config skipped ---
echo ""
echo "=== missing jq — graceful skip ==="
DOCS_DIR="$(mktemp -d)"
cat > "$DOCS_DIR/.ralph-loop.json" <<'JSON'
{ "model": "sonnet" }
JSON
unset CLAUDE_MODEL
# Temporarily shadow jq with a non-existent command
PATH_BACKUP="$PATH"
export PATH="/no-such-dir"
stderr_output="$(load_project_config 2>&1)"
export PATH="$PATH_BACKUP"
if [[ "$stderr_output" == *"jq is not installed"* ]]; then pass "missing jq warning emitted"; else fail "missing jq warning emitted" "stderr: '$stderr_output'"; fi
if [[ -z "${CLAUDE_MODEL+x}" ]]; then pass "CLAUDE_MODEL still unset"; else fail "CLAUDE_MODEL still unset" "was set to '$CLAUDE_MODEL'"; fi
rm -rf "$DOCS_DIR"

# --- Summary ---
print_summary "config_file"
