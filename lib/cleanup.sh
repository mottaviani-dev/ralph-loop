#!/bin/bash
# Cleanup globals and _do_cleanup function.
# Sourced by run.sh and tests/test_cleanup_body.sh.
_cleanup_pids=()
_cleanup_files=()
_interrupted=false
_cleanup_done=false

# Verbose cleanup logging (opt-in). When true, logs each PID signalled and
# each file removed during cleanup. Default: false.
RALPH_VERBOSE_CLEANUP="${RALPH_VERBOSE_CLEANUP:-false}"

_do_cleanup() {
    [ "$_cleanup_done" = true ] && return
    _cleanup_done=true
    set +e  # prevent cleanup failures from cascading under set -e

    if [ "$_interrupted" = true ]; then
        log_warn "Interrupted — cleaning up..."
    fi

    # ── PID cleanup: SIGTERM → 2s wait → SIGKILL (timeout-guarded) ──
    # Wrapped in a background subshell with a 10s watchdog so a stuck
    # process cannot block cleanup indefinitely.
    local _kill_subshell_pid _watchdog_pid

    (
        # Phase 1: SIGTERM all live tracked PIDs
        local _alive_pids=()
        for p in ${_cleanup_pids[@]+"${_cleanup_pids[@]}"}; do
            [ -z "$p" ] && continue
            if kill -0 "$p" 2>/dev/null; then
                kill "$p" 2>/dev/null || true
                pkill -P "$p" 2>/dev/null || true
                _alive_pids+=("$p")
                if [ "${RALPH_VERBOSE_CLEANUP:-false}" = "true" ]; then
                    log_warn "CLEANUP: sent SIGTERM to PID $p"
                fi
            fi
        done

        # Phase 2: wait, then SIGKILL survivors
        if [ ${#_alive_pids[@]} -gt 0 ]; then
            sleep 2
            for p in "${_alive_pids[@]}"; do
                if kill -0 "$p" 2>/dev/null; then
                    kill -9 "$p" 2>/dev/null || true
                    pkill -9 -P "$p" 2>/dev/null || true
                    if [ "${RALPH_VERBOSE_CLEANUP:-false}" = "true" ]; then
                        log_warn "CLEANUP: PID $p ignored SIGTERM, sent SIGKILL"
                    fi
                fi
            done
        fi
    ) &
    _kill_subshell_pid=$!

    # Watchdog: kill the PID-cleanup subshell after 10s if it hasn't finished
    ( sleep 10; kill "$_kill_subshell_pid" 2>/dev/null ) &
    _watchdog_pid=$!

    # Wait for the PID-cleanup subshell (or watchdog to kill it)
    wait "$_kill_subshell_pid" 2>/dev/null
    # Cancel the watchdog if cleanup finished in time
    kill "$_watchdog_pid" 2>/dev/null || true
    wait "$_watchdog_pid" 2>/dev/null

    if [ "${RALPH_VERBOSE_CLEANUP:-false}" = "true" ]; then
        log_warn "CLEANUP: PID cleanup phase complete"
    fi

    # ── File cleanup (always runs, even after timeout) ──
    for f in ${_cleanup_files[@]+"${_cleanup_files[@]}"}; do
        [ -z "$f" ] && continue
        rm -rf "$f" 2>/dev/null || true
        if [ "${RALPH_VERBOSE_CLEANUP:-false}" = "true" ]; then
            log_warn "CLEANUP: removed $f"
        fi
    done

    # ── Tmp-glob cleanup ──
    rm -f "$STATE_DIR"/*.tmp 2>/dev/null || true
}
