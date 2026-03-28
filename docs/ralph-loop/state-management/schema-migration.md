# Schema Migration

## Overview

The schema migration system ensures `_state/` JSON files stay compatible as ralph-loop evolves. Each state file carries an independent `schema_version` integer, and `lib/migrate.sh` applies incremental, idempotent transforms to bring files from any prior version to the current expected version. This eliminates manual migration steps when upgrading ralph-loop — the runner heals its own state on startup.

## How It Works

```
startup (--work, --setup, --migrate)
  │
  ▼
migrate_all()
  ├── migrate_work_state()
  ├── migrate_tasks()
  ├── migrate_frontier()
  ├── migrate_cycle_log()
  └── migrate_maintenance_state()
        │
        ▼
  _migrate_file(file, expected_version, callback)
        │
        ├── file missing?  → no-op
        ├── version >= expected?  → no-op
        └── version < expected:
              1. backup → <file>.pre-migrate.<epoch>
              2. loop: callback(file, step) for each version increment
              3. log success
```

### Per-File Migration Flow

`_migrate_file()` is the core engine. It:

1. **Reads current version** — `jq '.schema_version // 0'` (missing field = version 0)
2. **Short-circuits** if already at or above the expected version
3. **Creates a timestamped backup** before any mutation (`<file>.pre-migrate.<epoch>`)
4. **Walks version steps** — calls the per-file callback once per version increment (0→1, 1→2, etc.)

Each callback function (e.g. `_migrate_work_state_step`) contains `if [ "$from_version" -eq N ]` blocks — one per schema transition. All mutations use `jq` piped to a `.tmp` file, then `mv` for atomic replacement.

### Managed State Files

| File | Expected Version | v0→v1 Transform |
|------|-----------------|-----------------|
| `work-state.json` | 1 | Adds `schema_version`, `action_history` (array), `stats` (cycle counters) |
| `tasks.json` | 1 | Adds `schema_version` (agents sometimes drop it) |
| `frontier.json` | 1 | Adds `schema_version` |
| `cycle-log.json` | 1 | Adds `schema_version` |
| `maintenance-state.json` | 1 | Adds `schema_version`, `last_rotation_cycle`, `audit_progress` |

All v0→v1 transforms use `jq`'s `//` (alternative) operator to preserve existing values while backfilling missing fields.

### Trigger Points

Migration runs automatically at three call sites:

1. **`run_setup()`** (`lib/setup.sh:221`) — migrates before recreating/copying templates, so pre-existing state is preserved
2. **`init_work_state()`** (`lib/work.sh:90`) — migrates before reading state at work-cycle start, ensuring the agent always sees current schema
3. **`--migrate` flag** (`run.sh:448`) — explicit manual trigger, acquires run lock first

Discovery mode does not call `migrate_all` directly — it relies on setup having run first.

### Backup Lifecycle

Migration backups accumulate in `_state/` as `*.pre-migrate.<epoch>` files. `prune_migration_backups()` deletes backups older than 7 days using macOS-compatible `find -mtime +7`. This runs during maintenance cycles to prevent `_state/` bloat.

## Key Components

| File | Responsibility |
|------|---------------|
| `lib/migrate.sh` | All migration logic: version constants, `_migrate_file()` engine, per-file step functions, `migrate_all()` orchestrator, `prune_migration_backups()` |
| `lib/setup.sh:221` | Calls `migrate_all()` during `--setup` / `--auto-setup` |
| `lib/work.sh:90` | Calls `migrate_all()` at work-cycle init |
| `run.sh:448` | `--migrate` CLI handler |
| `tests/test_migration.sh` | 12-test suite covering all files, idempotency, backups, pruning |

## Design Decisions

**Independent per-file versioning** — Each state file has its own `schema_version` and migration function rather than a single global version. This allows files to evolve independently and avoids forcing a full-state migration when only one file's schema changes. The trade-off is more boilerplate per file, but state files change infrequently.

**Incremental step functions** — Migrations walk through each version step sequentially (0→1→2→…) rather than jumping directly to the target. This keeps each step small and composable, and allows intermediate versions to coexist safely.

**Idempotent by construction** — `_migrate_file()` checks `schema_version` before doing anything. A file at the expected version is never touched, never backed up. This means `migrate_all()` can safely run on every startup without performance cost.

**Atomic writes via tmp+mv** — All `jq` transforms write to `${file}.tmp` then `mv` to the target. This prevents corruption if the process is killed mid-write. The backup is created before any mutation, so the original is always recoverable.

**Version 0 for legacy files** — Files missing `schema_version` are treated as version 0 via `jq '.schema_version // 0'`. This gracefully handles files written by older versions of ralph-loop or by agents that don't include the field.

## Related Docs

- [Work Loop](../orchestration/work-loop.md) — calls `migrate_all()` at init
- [Maintenance Cycle](../orchestration/maintenance-cycle.md) — calls `prune_migration_backups()`
- [Prompt Assembly](../configuration/prompt-assembly.md) — state files are inputs to prompt construction

## Known Gaps

- All five managed files are currently at version 1. The multi-step migration path (v0→v1→v2→…) is designed but untested beyond the first step since no file has reached v2 yet.
- `prune_migration_backups()` uses `find -mtime +7` which counts 24-hour periods, not calendar days — a minor semantic difference on macOS vs GNU find.
