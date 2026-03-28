# Work Loop Orchestration

## Overview

The work loop is ralph-loop's primary execution mode for autonomous task-driven implementation. It invokes `claude -p` in a continuous loop, where each cycle reads task state, assembles a prompt with runtime context, runs the agent, captures output, validates results, and optionally commits changes. The loop self-terminates when the agent signals all tasks complete, safety limits are exceeded, or the operator interrupts.

## How It Works

```
Operator runs: ./run.sh --work (or --work-once)
        |
        v
  ┌─────────────────────┐
  │  init_work_state()   │  Ensure _state/ exists, copy templates,
  │  (lib/work.sh:85)    │  migrate schemas, create missing files
  └──────────┬──────────┘
             v
  ┌─────────────────────┐
  │  run_preflight_      │  Execute all validation_commands from
  │  validation()        │  tasks.json, write baseline results to
  │  (lib/work.sh:176)   │  last-validation-results.json
  └──────────┬──────────┘
             v
  ┌─────────────────────┐
  │  work_loop_should_  │◄─── Check stop conditions:
  │  continue()          │     - all_tasks_complete signal
  │  (lib/work.sh:638)   │     - MAX_WORK_CYCLES reached
  │                      │     - RALPH_BUDGET_LIMIT exceeded
  │                      │     - consecutive failures >= MAX_CONSECUTIVE_FAILURES
  │                      │     - stalemate >= MAX_STALE_CYCLES
  │                      │     - empty tasks >= MAX_EMPTY_TASK_CYCLES
  └──────────┬──────────┘
             v (continue)
  ┌─────────────────────┐
  │  run_work_cycle()    │  Single cycle execution:
  │  (lib/work.sh:425)   │
  │  1. Periodic maint.  │  Trigger maintenance if due
  │  2. Assemble prompt  │  apply_prompt_vars() + inject validation + learnings
  │  3. invoke_claude_   │  Run agent with timeout via run_with_timeout()
  │     agent()          │
  │  4. Journal append   │  Append output to journal.md, rotate if > 500 lines
  │  5. Cycle log        │  Record to cycle-log.json (with token/cost data)
  │  6. Validate JSON    │  Repair corrupted state files via fix-json.py
  │  7. Post-validation  │  Run task-specific validation_commands
  │  8. Stalemate check  │  Compare git diff hash with previous cycle
  │  9. Commit           │  Stage + commit (respecting exclusions + validation gate)
  └──────────┬──────────┘
             v
        sleep N seconds ──► loop back to work_loop_should_continue()
```

## Key Components

| File | Responsibility |
|------|---------------|
| `run.sh:264-307` | Work mode entry point: init, banner, preflight, main loop |
| `run.sh:308-319` | Work-once mode: single cycle without looping |
| `lib/work.sh:425-590` | `run_work_cycle()` — the core single-cycle orchestrator |
| `lib/work.sh:638-724` | `work_loop_should_continue()` — six stop conditions |
| `lib/work.sh:85-143` | `init_work_state()` — self-contained state initialization |
| `lib/work.sh:176-233` | `run_preflight_validation()` — baseline validation at startup |
| `lib/work.sh:236-302` | `run_post_work_validation()` — per-cycle validation |
| `lib/work.sh:322-394` | `commit_work_changes()` — validation-gated commit with exclusions |
| `lib/work.sh:22-82` | `_check_validation_cmd()` — 3-layer command safety (audit/allowlist/denylist) |
| `lib/common.sh:451-522` | `invoke_claude_agent()` — shared agent runner with timeout and token tracking |
| `lib/common.sh:145-190` | `run_with_timeout()` — portable macOS-safe timeout with watchdog |
| `lib/common.sh:675-777` | `apply_prompt_vars()` — `{{placeholder}}` substitution engine |
| `lib/common.sh:780-804` | `check_stalemate()` — git-diff-based no-change detection |
| `lib/cleanup.sh` | Signal handlers, PID + temp file cleanup on exit/interrupt |

## Design Decisions

### Agent autonomy with runner safety rails
The agent decides what to work on and when tasks are done (`all_tasks_complete` flag in `work-state.json`). The runner enforces mechanical safety limits only: consecutive failures, stalemate detection, budget caps, and max cycle counts. This separation keeps the agent prompt-agnostic while preventing runaway execution.

### Validation-gated commits
`commit_work_changes()` checks `last-validation-results.json` before committing. If any validation command failed, changes are preserved uncommitted so the next cycle can fix them. This prevents broken code from accumulating in the commit history. The gate is bypassed by `VALIDATE_BEFORE_COMMIT=false`.

### Prompt assembly pipeline
Each cycle rebuilds the prompt fresh from `prompts/work.md` (never the cached `_state/work-prompt.md`). The prompt goes through three enrichment stages: (1) `apply_prompt_vars()` resolves `{{placeholders}}` from built-ins, `.ralph-loop.json`, and `RALPH_VAR_*` env vars; (2) previous cycle's validation results are appended; (3) recent entries from `LEARNINGS.md` are injected as compound learning context.

### Portable timeout without GNU coreutils
`run_with_timeout()` uses background processes and a watchdog pattern instead of GNU `timeout` (unavailable on macOS by default). The watchdog sends SIGTERM, waits 10s, then SIGKILL. Both the command PID and watchdog PID are tracked in `_cleanup_pids[]` for signal-safe cleanup.

### Git commit exclusions
`WORK_GIT_EXCLUDE_DEFAULTS` prevents committing `_state/`, `.env`, `*.key`, `*.pem`, and other sensitive files. Operators can extend via `RALPH_GIT_EXCLUDE`. Pathspecs use `:(exclude)` syntax applied to both `git status` checks and `git add`.

### Stalemate detection via git diff hashing
Each cycle hashes `git diff HEAD --stat` combined with `git status --porcelain` (includes untracked files). Consecutive identical hashes increment `_stale_cycle_count`. This catches the agent spinning without making progress, even if it produces output.

## Related Docs

- [State Directory](../../state-directory.md) — schema for `work-state.json`, `tasks.json`, and other runtime files
- [Ralph Loop Paradigm](../../ralph-loop.md) — conceptual overview of the loop model
- [Discovery Process](../../discovery-process.md) — parallel discovery mode orchestration

## Known Gaps

- The maintenance cycle trigger within work mode (`should_run_maintenance()` in `lib/maintenance.sh`) was not fully traced — the interval logic and journal rotation during work mode merit their own documentation.
- `DRY_RUN` mode's `_print_dry_run_report()` diagnostic output is documented in `lib/common.sh` but not tested end-to-end.
- The webhook notification system (`notify()`) supports event filtering but the payload schema is not formally documented beyond the code.
