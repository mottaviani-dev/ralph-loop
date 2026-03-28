# Cleanup and Signal Handling

## Overview

The cleanup system ensures ralph-loop leaves no orphaned processes, temporary files, or stale lock directories when the runner exits — whether from normal completion, operator interrupt (Ctrl-C), or SIGTERM. It uses a trap-based architecture with two global registries (`_cleanup_pids[]` and `_cleanup_files[]`), a two-phase PID escalation strategy (SIGTERM → SIGKILL), and a watchdog to prevent stuck processes from blocking shutdown.

## How It Works

```
Signal received (EXIT, INT, TERM)
        |
        v
  ┌──────────────────────────┐
  │  Trap fires               │  INT: set _interrupted=true, call _do_cleanup, exit 130
  │  (run.sh:118-120)         │  TERM: set _interrupted=true, call _do_cleanup, exit 143
  │                           │  EXIT: call _do_cleanup (normal or post-signal)
  └───────────┬──────────────┘
              v
  ┌──────────────────────────┐
  │  _do_cleanup()            │  Guard: if _cleanup_done=true, return immediately
  │  (lib/cleanup.sh:13)      │  Prevents double-execution when signal + EXIT both fire
  └───────────┬──────────────┘
              v
  ┌──────────────────────────┐
  │  Phase 1: SIGTERM         │  Background subshell iterates _cleanup_pids[]
  │  (lib/cleanup.sh:27-40)   │  Sends SIGTERM to each live PID + its children (pkill -P)
  └───────────┬──────────────┘
              v
        sleep 2
              v
  ┌──────────────────────────┐
  │  Phase 2: SIGKILL         │  Re-checks survivors, sends kill -9 + pkill -9 -P
  │  (lib/cleanup.sh:43-54)   │
  └───────────┬──────────────┘
              v
  ┌──────────────────────────┐
  │  10s Watchdog             │  Kills the PID-cleanup subshell if it hangs
  │  (lib/cleanup.sh:59)      │  Prevents stuck processes from blocking shutdown
  └───────────┬──────────────┘
              v
  ┌──────────────────────────┐
  │  File cleanup             │  Iterates _cleanup_files[], runs rm -rf on each
  │  (lib/cleanup.sh:73-79)   │  Includes lock dirs, temp files, agent output files
  └───────────┬──────────────┘
              v
  ┌──────────────────────────┐
  │  Tmp-glob cleanup         │  rm -f $STATE_DIR/*.tmp
  │  (lib/cleanup.sh:82)      │  Catches any temp files not individually registered
  └──────────────────────────┘
```

### Global Registries

Two bash arrays accumulate resources for cleanup throughout execution:

- **`_cleanup_pids[]`** — PIDs of background processes (agent subprocesses, watchdog timers). Registered by `run_with_timeout()` when it spawns the command and its watchdog. Deregistered by `_deregister_cleanup_pids()` after normal completion.

- **`_cleanup_files[]`** — Paths to temporary files and lock directories. Registered by `invoke_claude_agent()` (agent output temp files), `acquire_run_lock()` (lock directory), and `acquire_workspace_lock()` (workspace lock directory).

### PID Lifecycle

```bash
# In run_with_timeout() — lib/common.sh:145
"$@" &                              # spawn command
local cmd_pid=$!
( ... sleep "$secs" ... ) &         # spawn watchdog
local watchdog_pid=$!
_cleanup_pids+=("$cmd_pid" "$watchdog_pid")   # register

wait "$cmd_pid"                     # wait for completion
# ... kill watchdog ...
_deregister_cleanup_pids "$cmd_pid" "$watchdog_pid"  # deregister
```

The `_deregister_cleanup_pids()` function (lib/common.sh:131) performs exact-match removal of both PIDs in a single pass, rebuilding the array to compact any empty slots accumulated from prior cycles. This avoids substring corruption (e.g., PID "12" matching "123").

### Subshell Prohibition

`invoke_claude_agent()` must never be called in a subshell (e.g., `out=$(invoke_claude_agent ...)`). In a subshell, `_cleanup_files+=()` modifies a copy of the array that is discarded when the subshell exits, leaving temp files unregistered in the parent process's EXIT trap.

### Locking

`acquire_run_lock()` (lib/common.sh:197) enforces single-instance execution per `STATE_DIR`:

1. **Atomic mkdir** — `mkdir "$lock_dir"` is atomic on POSIX filesystems. Success means the lock is acquired; the caller's PID is written inside.
2. **Stale detection** — If `mkdir` fails, the existing PID file is read and probed with `kill -0`. If the holder is dead, the lock is reclaimed with a single retry.
3. **Cleanup registration** — The lock directory is appended to `_cleanup_files[]` so the EXIT trap removes it automatically.
4. **Legacy migration** — Removes any plain PID file (`ralph-loop.pid`) left by pre-RL-030 installations.

The workspace lock (`acquire_workspace_lock()` in lib/workspace.sh:94) uses the same pattern with a separate lock directory (`.ralph-workspace.lock`).

### Double-Execution Guard

When a signal trap (INT/TERM) fires, the handler calls `_do_cleanup` and then `exit`. The `exit` triggers the EXIT trap, which calls `_do_cleanup` again. The `_cleanup_done` boolean (set to `true` on first entry) prevents the cleanup body from executing twice.

## Key Components

| File | Responsibility |
|------|---------------|
| `lib/cleanup.sh` | Defines `_do_cleanup()`, global registries, `_cleanup_done` guard |
| `run.sh:118-120` | Installs signal traps for EXIT, INT, TERM |
| `lib/common.sh:131` | `_deregister_cleanup_pids()` — exact-match PID removal |
| `lib/common.sh:145` | `run_with_timeout()` — registers/deregisters PIDs around command execution |
| `lib/common.sh:197` | `acquire_run_lock()` — atomic mkdir lock with stale recovery |
| `lib/common.sh:451` | `invoke_claude_agent()` — registers temp output files |
| `lib/workspace.sh:94` | `acquire_workspace_lock()` — parallel lock for workspace mode |

## Design Decisions

**Two-phase PID escalation (SIGTERM → 2s → SIGKILL)**: Gives cooperative processes a chance to terminate cleanly before force-killing. The 2-second grace period is short enough to avoid noticeable delay on operator interrupt.

**Background subshell + 10s watchdog for PID cleanup**: The entire PID kill sequence runs in a background subshell with a hard 10-second watchdog. This prevents a hung process from blocking the EXIT trap indefinitely — file cleanup and lock removal always proceed.

**Atomic mkdir over flock**: `flock` is not portable to all macOS configurations. `mkdir` is atomic on POSIX filesystems and requires no external tools. The trade-off is a TOCTOU window between checking the stale PID and reclaiming the lock, but this is acceptable since ralph-loop is typically single-operator.

**Exact-match PID deregistration (RL-011)**: Early versions used substring matching which could corrupt the PID array (e.g., removing PID "12" would also match "123"). The current implementation uses strict string equality in a rebuild loop.

**Subshell prohibition for invoke_claude_agent**: A design constraint documented in code comments. Since bash arrays are process-local, registering cleanup resources in a subshell is silently lost. This is enforced by convention, not runtime checks.

**RALPH_VERBOSE_CLEANUP opt-in**: Cleanup logging is off by default to keep normal output clean. Setting `RALPH_VERBOSE_CLEANUP=true` enables per-PID and per-file logging for debugging stuck-cleanup scenarios.

## Related Docs

- [Agent Invocation and Timeout](../agent-invocation/invoke-and-timeout.md) — uses `run_with_timeout()` which registers PIDs
- [Validation Command Safety](validation-command-safety.md) — validation commands also execute under timeout and cleanup
- [Setup and Auto-Detect](../configuration/setup-and-auto-detect.md) — `acquire_run_lock()` is called at all entry points

## Known Gaps

- No runtime enforcement of the subshell prohibition — a future caller could accidentally break cleanup registration with `out=$(invoke_claude_agent ...)` without any error or warning.
- The TOCTOU window in stale lock reclamation could theoretically allow two instances through if they race at exactly the right moment, though this is unlikely in practice.
- `_cleanup_files` entries are never deduplicated — if the same path were registered twice, `rm -rf` would run twice (harmless but wasteful).
