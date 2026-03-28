#!/usr/bin/env bash
# lib/hooks.sh — Lifecycle hook execution for ralph-loop.
#
# Provides run_hook() — a single entry point for all lifecycle hooks.
# Sourced by run.sh after lib/common.sh (needs log, log_warn, run_with_timeout)
# and before lib/discovery.sh and lib/work.sh (which call run_hook).
#
# Operator configuration (env vars, see run.sh for defaults):
#   RALPH_HOOK_PRE_CYCLE   — before each agent invocation
#   RALPH_HOOK_POST_CYCLE  — after agent exits
#   RALPH_HOOK_PRE_COMMIT  — before git commit (can abort when strict mode is on)
#   RALPH_HOOK_POST_COMMIT — after successful commit
#   RALPH_HOOK_ON_COMPLETE — when all work tasks complete
#   RALPH_HOOK_ON_ERROR    — on consecutive-failure abort
#   RALPH_HOOK_TIMEOUT     — seconds before hook is killed (default: 60)
#   RALPH_HOOK_PRE_COMMIT_STRICT — if "true", non-zero pre-commit hook aborts commit
#
# Context env vars injected into every hook subprocess:
#   RALPH_CYCLE_NUM  — current cycle number (set by caller)
#   RALPH_MODE       — "work" or "discovery" (set by caller)
#   RALPH_STATUS     — "success", "failed", or "timeout" (post-cycle hooks)
#   RALPH_EXIT_CODE  — raw agent exit code (post-cycle hooks, passed as extra arg)
#   RALPH_COMMIT_MSG — commit message (post-commit hooks, passed as extra arg)

# run_hook HOOK_NAME [KEY=VALUE...]
#
# Executes the shell command in RALPH_HOOK_<HOOK_NAME> (uppercased), injecting
# context env vars into the subprocess. No-ops silently when the hook env var
# is unset or empty.
#
# Extra KEY=VALUE pairs are exported into the hook subprocess alongside the
# standard context vars (RALPH_CYCLE_NUM, RALPH_MODE, RALPH_STATUS).
#
# Returns 0 always, EXCEPT when HOOK_NAME is "PRE_COMMIT" and
# RALPH_HOOK_PRE_COMMIT_STRICT=true — then a non-zero hook exit returns 1.
run_hook() {
    local hook_name="$1"
    shift

    # Resolve command from RALPH_HOOK_<HOOK_NAME>
    local var_name="RALPH_HOOK_${hook_name}"
    local cmd="${!var_name:-}"

    # No-op silently when hook is not configured
    [ -z "$cmd" ] && return 0

    # Audit log before execution (always, for traceability)
    log "HOOK [$hook_name]: $cmd"

    # Build extra env export statements from remaining KEY=VAL args
    local extra_exports=""
    local kv
    for kv in "$@"; do
        # Validate KEY=VAL format before exporting
        if [[ "$kv" == *=* ]]; then
            local key="${kv%%=*}"
            local val="${kv#*=}"
            extra_exports="${extra_exports}export ${key}='${val}';"
        fi
    done

    local hook_timeout="${RALPH_HOOK_TIMEOUT:-60}"
    local hook_rc=0

    # Execute in an isolated subshell via bash -c to scope env vars.
    # Context vars are interpolated at call time (not exposed to parent process).
    # The hook command is passed as $1 to avoid word-splitting on eval.
    run_with_timeout "$hook_timeout" bash -c "
        export RALPH_CYCLE_NUM='${RALPH_CYCLE_NUM:-0}'
        export RALPH_MODE='${RALPH_MODE:-unknown}'
        export RALPH_STATUS='${RALPH_STATUS:-}'
        ${extra_exports}
        cd '${DOCS_DIR:-.}'
        eval \"\$1\"
    " -- "$cmd" || hook_rc=$?

    # Handle exit code based on hook type and strict mode
    if [ "$hook_rc" -ne 0 ]; then
        if [ "$hook_name" = "PRE_COMMIT" ] && \
           [ "${RALPH_HOOK_PRE_COMMIT_STRICT:-false}" = "true" ]; then
            log_warn "HOOK [$hook_name] failed (exit $hook_rc) — commit skipped (strict mode)"
            return 1
        fi
        log_warn "HOOK [$hook_name] failed (exit $hook_rc), continuing"
    fi

    return 0
}
