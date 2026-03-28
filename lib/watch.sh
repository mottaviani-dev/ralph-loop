#!/bin/bash
# lib/watch.sh — Watch mode: readonly live-updating status dashboard.
#
# Dependencies: lib/common.sh (log_error, RED, GREEN, YELLOW, BLUE, MAGENTA, NC)
#               lib/work.sh   (print_task_summary)
# Globals used: STATE_DIR, WORK_STATE_FILE, TASKS_FILE, CYCLE_LOG_FILE,
#               WATCH_INTERVAL, GREEN, NC

# Clear the screen if stdout is a TTY; emit a plain separator otherwise.
# No dependency on tput or the clear binary.
_watch_clear() {
    if [ -t 1 ]; then
        printf '\033[2J\033[H'
    else
        printf '\n--- refresh ---\n'
    fi
}

# Check whether the ralph-loop process is alive.
# Reads $STATE_DIR/.ralph-loop.lock/pid (read-only — never acquires the lock).
# Outputs the PID string if alive, "not_running" otherwise.
# Always exits 0 (safe under set -e).
_watch_check_loop_alive() {
    local lock_dir="$STATE_DIR/.ralph-loop.lock"
    local pid_file="$lock_dir/pid"

    if [ ! -d "$lock_dir" ]; then
        echo "not_running"
        return
    fi

    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [ -z "$pid" ]; then
        echo "not_running"
        return
    fi

    if kill -0 "$pid" 2>/dev/null; then
        echo "$pid"
    else
        echo "not_running"
    fi
}

# Print an ASCII progress bar.
# Usage: _watch_progress_bar <completed> <total>
# Outputs nothing when total is 0.
_watch_progress_bar() {
    local completed=$1 total=$2 width=30
    [ "$total" -eq 0 ] && return
    local filled=$(( completed * width / total ))
    local bar="" i=0
    while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
    while [ $i -lt $width ];   do bar="${bar}░"; i=$(( i + 1 )); done
    printf "  Progress: [%s] %d/%d\n" "$bar" "$completed" "$total"
}

# Main watch loop. Reads state files and refreshes the terminal every
# $WATCH_INTERVAL seconds. Exits 0 when the loop process is no longer alive
# or when all tasks are complete. Never acquires the run lock.
run_watch_mode() {
    if [ ! -d "${STATE_DIR:-}" ]; then
        echo "Error: STATE_DIR not found (${STATE_DIR:-unset}). Run --setup first."
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required for --watch mode."
        exit 1
    fi

    printf "Ralph Loop — Watch Mode (refreshing every %ss — Ctrl+C to exit)\n\n" "$WATCH_INTERVAL"

    while true; do
        _watch_clear

        echo "┌──────────────────────────────────────────────────┐"
        printf "│  %-49s│\n" "Ralph Loop — Watch Mode"
        echo "└──────────────────────────────────────────────────┘"
        echo ""
        printf "  Updated: %s\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"

        # ── Loop status ────────────────────────────────────────
        local loop_pid
        loop_pid=$(_watch_check_loop_alive)
        if [ "$loop_pid" = "not_running" ]; then
            printf "  Status:  Not running\n\n"
        else
            printf "  Status:  Running (PID %s)\n\n" "$loop_pid"
        fi

        # ── Task progress ──────────────────────────────────────
        if [ -f "${WORK_STATE_FILE:-}" ]; then
            echo "=== Task Progress ==="
            print_task_summary

            local completed total
            completed=$(jq '[.tasks[] | select(.status == "completed")] | length' \
                "$TASKS_FILE" 2>/dev/null || echo 0)
            total=$(jq '.tasks | length' "$TASKS_FILE" 2>/dev/null || echo 0)
            _watch_progress_bar "$completed" "$total"
            echo ""

            echo "=== Last Action ==="
            local last_action last_outcome
            last_action=$(jq  -r '.last_action  // "none"' "$WORK_STATE_FILE" 2>/dev/null || echo "unknown")
            last_outcome=$(jq -r '.last_outcome // "none"' "$WORK_STATE_FILE" 2>/dev/null || echo "unknown")
            printf "  Action:  %s\n" "$last_action"
            printf "  Outcome: %s\n\n" "$last_outcome"
        fi

        # ── Recent cycles ──────────────────────────────────────
        if [ -f "${CYCLE_LOG_FILE:-}" ]; then
            echo "=== Recent Cycles ==="
            jq -r '.cycles[-3:] | reverse | .[] |
                "  Cycle \(.cycle // "?"): \(.duration_seconds // "?")s (\(.status // "unknown"))"' \
                "$CYCLE_LOG_FILE" 2>/dev/null || echo "  (no cycles yet)"

            local last_ts
            last_ts=$(jq -r '.cycles[-1].timestamp // empty' "$CYCLE_LOG_FILE" 2>/dev/null || echo "")
            if [ -n "$last_ts" ]; then
                local now last_epoch elapsed
                now=$(date +%s)
                # macOS: date -j -f; falls back to $now (0s ago) on parse failure
                last_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${last_ts%%.*}" +%s 2>/dev/null || echo "$now")
                elapsed=$(( now - last_epoch ))
                if [ "$elapsed" -lt 60 ]; then
                    printf "  Last cycle: %ds ago\n" "$elapsed"
                else
                    printf "  Last cycle: %dm ago\n" "$(( elapsed / 60 ))"
                fi
            fi
            echo ""
        fi

        printf "Refreshing every %ss — Ctrl+C to exit\n" "$WATCH_INTERVAL"

        # ── Exit conditions ────────────────────────────────────
        if [ "$loop_pid" = "not_running" ]; then
            local all_done
            all_done=$(jq -r '.all_tasks_complete // false' \
                "${WORK_STATE_FILE:-/dev/null}" 2>/dev/null || echo "false")
            if [ "$all_done" = "true" ]; then
                echo "Loop finished (all tasks complete)."
            else
                echo "Loop is not running."
            fi
            exit 0
        fi

        if [ ! -d "$STATE_DIR" ]; then
            echo "State directory removed. Exiting."
            exit 0
        fi

        sleep "$WATCH_INTERVAL"
    done
}
