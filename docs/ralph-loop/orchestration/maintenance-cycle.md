# Maintenance Cycle

## Overview

The maintenance cycle keeps documentation and runtime state healthy as cycle counts grow. It rotates the journal when it gets too long, audits documentation quality one file at a time, and cleans up stale state. Maintenance runs automatically every N cycles (default 10) or when the journal exceeds a line threshold, and can also be triggered manually with `--maintenance`.

## How It Works

```
Trigger check (should_run_maintenance)
        │
        ├── cycle_num % 10 == 0 && cycle_num > 0  → "scheduled"
        └── journal.md > 500 lines                 → "journal_overflow"

If triggered:
  1. Assemble prompt from prompts/maintenance.md (apply_prompt_vars)
  2. Invoke Claude agent with assembled prompt
  3. Log cycle to cycle-log.json (type: "maintenance", includes trigger reason)
  4. Run validate_json_files (repair broken JSON in state files)
  5. Run prune_migration_backups (delete *.pre-migrate.* files > 7 days old)
  6. If SKIP_COMMIT != true, commit any docs/ changes
```

### Trigger Paths

Maintenance can be triggered from three entry points:

1. **Discovery mode** (`lib/discovery.sh:24-28`): At the start of each `run_cycle()`, unless `DISCOVERY_ONLY=true`. Uses `$FRONTIER_FILE` for cycle counting.

2. **Work mode** (`lib/work.sh:431-436`): At the start of each `run_work_cycle()`, only if `$MAINTENANCE_PROMPT_FILE` exists (copied from `prompts/maintenance.md` during work state init). Uses `$WORK_STATE_FILE` for cycle counting.

3. **Manual** (`run.sh:232`): The `--maintenance` flag dispatches directly to `run_maintenance_cycle "manual"` without a trigger check.

### Trigger Decision Logic

`should_run_maintenance()` accepts an optional state file (defaults to `$FRONTIER_FILE`). It checks two conditions in order:

1. **Scheduled**: `total_cycles % MAINTENANCE_CYCLE_INTERVAL == 0` and `total_cycles > 0` — returns `"scheduled"`.
2. **Journal overflow**: `journal.md` line count exceeds `JOURNAL_MAX_LINES` (500) — returns `"journal_overflow"`.

If neither condition is met, the function returns non-zero and no maintenance runs.

### What the Agent Does

The maintenance prompt (`prompts/maintenance.md`) instructs the agent to complete tasks in order, stopping after one audit per cycle:

1. **Journal Rotation**: If `journal.md` > 500 lines, compress old entries (keep last 10 cycles), append summary to `journal-summary.md`, update `maintenance-state.json`.

2. **Documentation Quality Audit** (one file per cycle): Pick the next unaudited doc from `docs/`, verify accuracy (code paths still exist), completeness, structure (matches style guide), and cross-reference links. Fix minor issues directly; log major issues to `_gaps.md`.

3. **Queue Cleanup** (if all docs audited): Remove stale `frontier.json` entries, prune `cycle-log.json` to last 50 cycles, verify `discovered_concepts` match actual doc files.

### Journal Rotation (Work Mode — In-Runner)

Work mode has an additional, non-agent journal rotation in the runner itself (`lib/work.sh:528-540`). After every work cycle, if `journal.md` exceeds `JOURNAL_MAX_LINES`:

```bash
echo "<!-- Journal rotated ... -->" > tmp
tail -n $JOURNAL_KEEP_LINES journal.md >> tmp && mv tmp journal.md
```

This is a simple truncation (keep last N lines), distinct from the agent-driven rotation which compresses and summarizes. `JOURNAL_KEEP_LINES` defaults to 300, configurable via environment.

### Post-Cycle Cleanup

After the agent returns, `run_maintenance_cycle()` performs two housekeeping steps:

1. **`validate_json_files()`** (`lib/common.sh:241`): Iterates over all JSON state files (`frontier.json`, `cycle-log.json`, `maintenance-state.json`, `tasks.json`, `work-state.json`). If `jq empty` fails on any file, it backs up the broken copy and runs `fix-json.py` to attempt repair (fixes unescaped backslashes, missing commas).

2. **`prune_migration_backups()`** (`lib/migrate.sh:161`): Deletes `*.pre-migrate.*` files in `_state/` older than 7 days using `find -mtime +7 -delete`. macOS-compatible.

### Commit Scoping

Maintenance commits are scoped to `docs/` only (`git add docs/`). The commit message format is `docs: maintenance cycle (<trigger_reason>)`. This mirrors discovery mode's commit scoping, keeping state files out of version control.

## Key Components

| File | Responsibility |
|------|---------------|
| `lib/maintenance.sh:17` | `should_run_maintenance()` — trigger decision logic |
| `lib/maintenance.sh:42` | `run_maintenance_cycle()` — orchestrate agent, cleanup, commit |
| `prompts/maintenance.md` | Agent instructions for journal rotation, doc audit, queue cleanup |
| `lib/common.sh:241` | `validate_json_files()` — JSON repair pipeline |
| `lib/migrate.sh:161` | `prune_migration_backups()` — stale backup cleanup |
| `lib/work.sh:528` | In-runner journal truncation (work mode only) |
| `lib/discovery.sh:24` | Discovery mode maintenance trigger point |
| `lib/work.sh:431` | Work mode maintenance trigger point |
| `run.sh:232` | Manual `--maintenance` dispatch |

## Design Decisions

**Why two journal rotation mechanisms?** The in-runner rotation (`lib/work.sh`) is a fast, deterministic truncation that prevents unbounded file growth between maintenance cycles. The agent-driven rotation (via prompt) is a more intelligent compression that preserves context by summarizing old entries. The runner rotation acts as a safety net; the agent rotation produces better summaries when it runs.

**Why one-file-per-cycle audits?** Auditing all docs in a single agent invocation would consume excessive tokens and risk timeouts. The one-file approach keeps each maintenance cycle bounded and predictable, matching the project's general principle of one meaningful outcome per cycle.

**Why is trigger checking separate from execution?** `should_run_maintenance()` returns the trigger reason as stdout, which is captured and passed to `run_maintenance_cycle()`. This separation allows the trigger reason to be logged in `cycle-log.json`, making it observable why maintenance ran (scheduled vs. journal overflow vs. manual).

**Why does `DISCOVERY_ONLY` skip maintenance?** When `DISCOVERY_ONLY=true`, the user wants pure discovery with no interleaved side effects. Maintenance modifies state files and can commit docs changes, which could interfere with a discovery-only workflow.

**Why scope commits to `docs/` only?** Maintenance may modify state files (via the agent), but those live in `_state/` which is gitignored. The only version-controlled artifacts maintenance should touch are documentation files.

## Related Docs

- [Work Loop](./work-loop.md) — work mode orchestration that triggers maintenance
- [Discovery Loop](./discovery-loop.md) — discovery mode that triggers maintenance
