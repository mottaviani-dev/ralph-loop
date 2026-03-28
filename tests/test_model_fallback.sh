#!/usr/bin/env bash
# tests/test_model_fallback.sh — Unit tests for invoke_claude_with_fallback()
# Uses a fake_claude stub script to simulate per-model pass/fail behavior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "=== invoke_claude_with_fallback() tests ==="
echo ""

enable_subshell_counters

# ── Stub setup ──────────────────────────────────────────────────────────────
STUB_DIR=$(mktemp -d)
CALL_LOG="$STUB_DIR/call_log"
touch "$CALL_LOG"
export STUB_DIR CALL_LOG

# fake_claude: records model arg and exits based on FAKE_CLAUDE_EXITS mapping.
# FAKE_CLAUDE_EXITS is a comma-separated list of model=exit_code pairs.
# Example: FAKE_CLAUDE_EXITS="opus=1,sonnet=0" → opus exits 1, sonnet exits 0.
cat > "$STUB_DIR/claude" << 'STUB'
#!/usr/bin/env bash
# Extract model from args: look for --model <value>
model="unknown"
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--model" ]]; then
        model="$2"
        shift 2
    else
        shift
    fi
done
echo "$model" >> "$CALL_LOG"
# Determine exit code from FAKE_CLAUDE_EXITS
IFS=',' read -ra pairs <<< "${FAKE_CLAUDE_EXITS:-}"
for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    if [[ "$key" == "$model" ]]; then
        exit "$val"
    fi
done
# Default: success
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Helper: reset call log between tests
reset_log() { : > "$CALL_LOG"; }

# Helper: source lib/common.sh and call invoke_claude_with_fallback
# Usage: run_fallback_test <expected_exit> <expected_model> <env_overrides...>
run_fallback() {
    local output_file="$STUB_DIR/output"
    : > "$output_file"
    env PATH="$STUB_DIR:$PATH" \
        CLAUDE_MODEL="${CLAUDE_MODEL:-opus}" \
        CLAUDE_MODEL_FALLBACK="${CLAUDE_MODEL_FALLBACK:-}" \
        FAKE_CLAUDE_EXITS="${FAKE_CLAUDE_EXITS:-}" \
        CALL_LOG="$CALL_LOG" \
        SKIP_PERMISSIONS="${SKIP_PERMISSIONS:-true}" \
        ENABLE_MCP="false" \
        SKIP_CLAUDE_CHECK=1 \
        bash -c "
            source '$SCRIPT_DIR/../lib/common.sh'
            # Stub run_with_timeout to just run the command (no actual timeout)
            run_with_timeout() { shift; \"\$@\"; return \$?; }
            _last_used_model='$CLAUDE_MODEL'
            invoke_claude_with_fallback 900 '$output_file' '-p' 'test prompt'
            echo \"EXIT=\$?\"
            echo \"MODEL=\$_last_used_model\"
        " 2>/dev/null
}

# ── Tests ───────────────────────────────────────────────────────────────────

echo "--- No-op when CLAUDE_MODEL_FALLBACK is unset ---"

(
    reset_log
    result=$(CLAUDE_MODEL="opus" CLAUDE_MODEL_FALLBACK="" FAKE_CLAUDE_EXITS="opus=0" run_fallback)
    exit_code=$(echo "$result" | grep "^EXIT=" | cut -d= -f2)
    used_model=$(echo "$result" | grep "^MODEL=" | cut -d= -f2)
    call_count=$(wc -l < "$CALL_LOG" | tr -d ' ')

    assert_equals "no-op: exit code is 0" "$exit_code" "0"
    assert_equals "no-op: model is primary" "$used_model" "opus"
    assert_equals "no-op: claude called once" "$call_count" "1"
)

echo "--- Primary success skips fallback ---"

(
    reset_log
    result=$(CLAUDE_MODEL="opus" CLAUDE_MODEL_FALLBACK="sonnet,haiku" FAKE_CLAUDE_EXITS="opus=0,sonnet=0,haiku=0" run_fallback)
    exit_code=$(echo "$result" | grep "^EXIT=" | cut -d= -f2)
    used_model=$(echo "$result" | grep "^MODEL=" | cut -d= -f2)
    call_count=$(wc -l < "$CALL_LOG" | tr -d ' ')

    assert_equals "primary success: exit code is 0" "$exit_code" "0"
    assert_equals "primary success: model is primary" "$used_model" "opus"
    assert_equals "primary success: claude called once" "$call_count" "1"
)

echo "--- Timeout bypasses fallback (exit 124) ---"

(
    reset_log
    # We need to simulate exit code 124 from run_with_timeout
    output_file="$STUB_DIR/output_timeout"
    : > "$output_file"
    result=$(env PATH="$STUB_DIR:$PATH" \
        CLAUDE_MODEL="opus" \
        CLAUDE_MODEL_FALLBACK="sonnet,haiku" \
        FAKE_CLAUDE_EXITS="opus=1,sonnet=0,haiku=0" \
        CALL_LOG="$CALL_LOG" \
        SKIP_PERMISSIONS="true" \
        ENABLE_MCP="false" \
        SKIP_CLAUDE_CHECK=1 \
        bash -c "
            source '$SCRIPT_DIR/../lib/common.sh'
            # Stub run_with_timeout to return 124 (timeout) always
            run_with_timeout() { shift; return 124; }
            _last_used_model='opus'
            invoke_claude_with_fallback 900 '$output_file' '-p' 'test prompt'
            echo \"EXIT=\$?\"
            echo \"MODEL=\$_last_used_model\"
        " 2>/dev/null)
    exit_code=$(echo "$result" | grep "^EXIT=" | cut -d= -f2)
    used_model=$(echo "$result" | grep "^MODEL=" | cut -d= -f2)

    assert_equals "timeout: exit code is 124" "$exit_code" "124"
    assert_equals "timeout: model is primary (no fallback tried)" "$used_model" "opus"
)

echo "--- Fallback used on primary failure ---"

(
    reset_log
    result=$(CLAUDE_MODEL="opus" CLAUDE_MODEL_FALLBACK="sonnet,haiku" FAKE_CLAUDE_EXITS="opus=1,sonnet=0,haiku=0" run_fallback)
    exit_code=$(echo "$result" | grep "^EXIT=" | cut -d= -f2)
    used_model=$(echo "$result" | grep "^MODEL=" | cut -d= -f2)
    call_count=$(wc -l < "$CALL_LOG" | tr -d ' ')
    first_call=$(sed -n '1p' "$CALL_LOG")
    second_call=$(sed -n '2p' "$CALL_LOG")

    assert_equals "fallback: exit code is 0" "$exit_code" "0"
    assert_equals "fallback: model is sonnet" "$used_model" "sonnet"
    assert_equals "fallback: claude called twice" "$call_count" "2"
    assert_equals "fallback: first call was opus" "$first_call" "opus"
    assert_equals "fallback: second call was sonnet" "$second_call" "sonnet"
)

echo "--- All models fail ---"

(
    reset_log
    result=$(CLAUDE_MODEL="opus" CLAUDE_MODEL_FALLBACK="sonnet,haiku" FAKE_CLAUDE_EXITS="opus=1,sonnet=1,haiku=1" run_fallback)
    exit_code=$(echo "$result" | grep "^EXIT=" | cut -d= -f2)
    used_model=$(echo "$result" | grep "^MODEL=" | cut -d= -f2)
    call_count=$(wc -l < "$CALL_LOG" | tr -d ' ')

    assert_equals "all fail: exit code is 1" "$exit_code" "1"
    assert_equals "all fail: model is last tried (haiku)" "$used_model" "haiku"
    assert_equals "all fail: claude called 3 times" "$call_count" "3"
)

echo "--- Model logged correctly after fallback success ---"

(
    reset_log
    # Primary and first fallback fail, second fallback succeeds
    result=$(CLAUDE_MODEL="opus" CLAUDE_MODEL_FALLBACK="sonnet,haiku" FAKE_CLAUDE_EXITS="opus=1,sonnet=1,haiku=0" run_fallback)
    exit_code=$(echo "$result" | grep "^EXIT=" | cut -d= -f2)
    used_model=$(echo "$result" | grep "^MODEL=" | cut -d= -f2)
    call_count=$(wc -l < "$CALL_LOG" | tr -d ' ')

    assert_equals "deep fallback: exit code is 0" "$exit_code" "0"
    assert_equals "deep fallback: model is haiku" "$used_model" "haiku"
    assert_equals "deep fallback: claude called 3 times" "$call_count" "3"
)

# Cleanup
rm -rf "$STUB_DIR"

print_summary "invoke_claude_with_fallback"
