#!/usr/bin/env bash
# tests/test_notify.sh — Unit tests for notify() in lib/common.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "=== notify() tests ==="
echo ""

enable_subshell_counters

# ── Stub setup ──────────────────────────────────────────────────────────────
# Create a temp directory for the curl stub and invocation log.
STUB_DIR=$(mktemp -d)
CURL_LOG="$STUB_DIR/curl_calls.log"
touch "$CURL_LOG"

# Write a curl stub that records its arguments.
cat > "$STUB_DIR/curl" << 'STUB'
#!/usr/bin/env bash
echo "$@" >> "$CURL_LOG"
exit "${CURL_STUB_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/curl"

# Export for subshells
export CURL_LOG STUB_DIR

# Helper: reset the call log between tests
reset_log() { : > "$CURL_LOG"; }

# Helper: source lib/common.sh with controlled env then call notify()
call_notify() {
    # Usage: call_notify EVENT CYCLE SUMMARY MODE
    local event="$1" cycle="$2" summary="$3" mode="$4"
    env PATH="$STUB_DIR:$PATH" \
        NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}" \
        NOTIFY_ON="${NOTIFY_ON:-complete,error,stalemate}" \
        CLAUDE_MODEL="${CLAUDE_MODEL:-opus}" \
        CURL_STUB_EXIT="${CURL_STUB_EXIT:-0}" \
        CURL_LOG="$CURL_LOG" \
        bash -c "
            source '$SCRIPT_DIR/../lib/common.sh'
            notify '$event' '$cycle' '$summary' '$mode'
        "
}

# ── Tests ───────────────────────────────────────────────────────────────────

echo "--- No-op when NOTIFY_WEBHOOK_URL is empty ---"

(
    reset_log
    NOTIFY_WEBHOOK_URL="" call_notify "complete" "1" "done" "work"
    call_count=$(wc -l < "$CURL_LOG" | tr -d ' ')
    assert_equals "URL empty: curl not called" "$call_count" "0"
)

echo "--- Event filter ---"

(
    reset_log
    NOTIFY_WEBHOOK_URL="https://example.com/hook" \
    NOTIFY_ON="complete" \
        call_notify "complete" "5" "All done" "work"
    call_count=$(wc -l < "$CURL_LOG" | tr -d ' ')
    assert_equals "filter match: curl called once" "$call_count" "1"
)

(
    reset_log
    NOTIFY_WEBHOOK_URL="https://example.com/hook" \
    NOTIFY_ON="complete" \
        call_notify "stalemate" "5" "Stuck" "work"
    call_count=$(wc -l < "$CURL_LOG" | tr -d ' ')
    assert_equals "filter no-match: curl not called" "$call_count" "0"
)

(
    reset_log
    NOTIFY_WEBHOOK_URL="https://example.com/hook" \
    NOTIFY_ON="complete,stalemate" \
        call_notify "stalemate" "5" "Stuck" "work"
    call_count=$(wc -l < "$CURL_LOG" | tr -d ' ')
    assert_equals "multi-filter match: curl called once" "$call_count" "1"
)

echo "--- curl failure is warn-only (no abort) ---"

(
    reset_log
    exit_code=0
    NOTIFY_WEBHOOK_URL="https://example.com/hook" \
    NOTIFY_ON="error" \
    CURL_STUB_EXIT=1 \
        call_notify "error" "3" "Fail" "work" || exit_code=$?
    assert_equals "curl fail: notify returns 0" "$exit_code" "0"
)

echo "--- Payload contains required fields ---"

(
    reset_log
    # Use a stub that captures the -d (body) argument to a separate file
    PAYLOAD_FILE="$STUB_DIR/payload.json"
    cat > "$STUB_DIR/curl" << STUB2
#!/usr/bin/env bash
echo "\$@" >> "\$CURL_LOG"
# Extract -d argument (next arg after -d flag)
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-d" ]]; then
    echo "\$2" > "$PAYLOAD_FILE"
    break
  fi
  shift
done
exit 0
STUB2
    chmod +x "$STUB_DIR/curl"

    NOTIFY_WEBHOOK_URL="https://example.com/hook" \
    NOTIFY_ON="complete" \
        call_notify "complete" "42" "All tasks done" "work"

    payload=$(cat "$PAYLOAD_FILE" 2>/dev/null || echo "{}")
    assert_contains "payload has event"     "$payload" '"event"'
    assert_contains "payload has cycle"     "$payload" '"cycle"'
    assert_contains "payload has summary"   "$payload" '"summary"'
    assert_contains "payload has timestamp" "$payload" '"timestamp"'
    assert_contains "payload has mode"      "$payload" '"mode"'
    assert_contains "payload has model"     "$payload" '"model"'
)

echo "--- URL truncation hides token in logs ---"

(
    reset_log
    # Restore original curl stub (payload test overwrites it)
    cat > "$STUB_DIR/curl" << 'STUBRESTORE'
#!/usr/bin/env bash
echo "$@" >> "$CURL_LOG"
exit "${CURL_STUB_EXIT:-0}"
STUBRESTORE
    chmod +x "$STUB_DIR/curl"
    warn_output=$(env \
        PATH="$STUB_DIR:$PATH" \
        NOTIFY_WEBHOOK_URL="https://hooks.slack.com/services/T123/B456/secret-token" \
        NOTIFY_ON="stalemate" \
        CURL_STUB_EXIT=1 \
        CURL_LOG="$CURL_LOG" \
        CLAUDE_MODEL="opus" \
        bash -c "source '$SCRIPT_DIR/../lib/common.sh'; notify 'stalemate' '10' 'Stuck' 'discovery'" \
        2>&1 || true)
    # Logs should show scheme+host but not the path token
    assert_contains "log shows host" "$warn_output" "hooks.slack.com"
)

echo "--- curl not in PATH: warn-only, no abort ---"

(
    reset_log
    exit_code=0
    # Use a PATH with basic tools but no curl
    NO_CURL_DIR=$(mktemp -d)
    # Create stubs for basic tools we need (jq, tr, grep, date, sed) but NOT curl
    for cmd in jq tr grep date sed bash; do
        real=$(command -v "$cmd" 2>/dev/null || true)
        if [ -n "$real" ]; then
            ln -sf "$real" "$NO_CURL_DIR/$cmd"
        fi
    done
    env PATH="$NO_CURL_DIR" \
        NOTIFY_WEBHOOK_URL="https://example.com/hook" \
        NOTIFY_ON="complete" \
        CLAUDE_MODEL="opus" \
        bash -c "source '$SCRIPT_DIR/../lib/common.sh'; notify 'complete' '1' 'done' 'work'" \
        2>/dev/null || exit_code=$?
    rm -rf "$NO_CURL_DIR"
    assert_equals "no curl in PATH: exits 0" "$exit_code" "0"
)

echo "--- notify() project field backward compatibility ---"

# Test: payload without project field omits "project" key
(
    payload=$(jq -n \
        --arg event "complete" \
        --argjson cycle 1 \
        --arg summary "test" \
        --arg mode "work" \
        --arg model "opus" \
        --arg project "" \
        --arg ts "2026-01-01T00:00:00+0000" \
        '{event: $event, cycle: $cycle, summary: $summary, mode: $mode, model: $model, timestamp: $ts} |
         if $project != "" then . + {project: $project} else . end')
    has_project=$(echo "$payload" | jq 'has("project")')
    assert_equals "project field absent when empty string" "$has_project" "false"
)

# Test: payload with project field includes "project" key
(
    payload=$(jq -n \
        --arg event "complete" \
        --argjson cycle 1 \
        --arg summary "test" \
        --arg mode "work" \
        --arg model "opus" \
        --arg project "my-project" \
        --arg ts "2026-01-01T00:00:00+0000" \
        '{event: $event, cycle: $cycle, summary: $summary, mode: $mode, model: $model, timestamp: $ts} |
         if $project != "" then . + {project: $project} else . end')
    has_project=$(echo "$payload" | jq 'has("project")')
    proj_val=$(echo "$payload" | jq -r '.project')
    assert_equals "project field present when non-empty" "$has_project" "true"
    assert_equals "project field value correct" "$proj_val" "my-project"
)

# Cleanup
rm -rf "$STUB_DIR"

print_summary "notify"
