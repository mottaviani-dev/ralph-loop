# State Directory (`_state/`)

## Overview

The `_state/` directory holds all runtime-persisted state for ralph-loop. It is created by `--setup` or `init_work_state()`, is not source-controlled (`.gitignore`), and is read/written each cycle. Templates from `config/` are copied here during setup; prompts from `prompts/` are assembled here at cycle start.

## How It Works

1. Runner assembles prompt from template (substitutes `{{state_dir}}` with the actual `_state/` path)
2. Runner calls `claude -p` with the assembled prompt
3. Agent reads state files (frontier, tasks, journal) to decide what to do
4. Agent executes, documents, and updates state files
5. Agent exits; runner logs the cycle, then repeats or exits

## Key Components

### Discovery Mode Files

| File | Managed By | Purpose |
|------|------------|---------|
| `config.json` | Runner (from `config/`) | Module paths, integration map, settings |
| `frontier.json` | Agent | Exploration queue, discovered concepts, cross-service patterns |
| `prompt.md` | Runner | Assembled discovery prompt (from `prompts/discovery.md` + substitution) |
| `cycle-log.json` | Runner | Structured history of all cycles run |
| `journal.md` | Runner + Agent | Cumulative cycle-by-cycle log — the agent's persistent memory |
| `journal-summary.md` | Runner | Compressed summaries from journal rotation |

### Work Mode Files

| File | Managed By | Purpose |
|------|------------|---------|
| `work-state.json` | Runner + Agent | Cycle count, current task, last action/outcome, completion signal |
| `tasks.json` | Agent | Task registry (seeded from `config/tasks.json` on setup) |
| `work-prompt.md` | Runner | Assembled work prompt (from `prompts/work.md` + substitution) |
| `subagents.json` | Runner (from `config/`) | Specialist subagent definitions |

### Shared / Maintenance Files

| File | Managed By | Purpose |
|------|------------|---------|
| `maintenance-prompt.md` | Runner | Assembled maintenance prompt (from `prompts/maintenance.md`) |
| `maintenance-state.json` | Runner + Agent | Journal rotation tracking, doc audit progress |
| `style-guide.md` | Runner (from `config/`) | Documentation formatting conventions |
| `refine-prompt.md` | Runner | Assembled refinement prompt |
| `fix-json.py` | Runner | JSON repair utility (copied for agent access) |
| `.ralph-loop.lock/` | Runner | Atomic lock directory; contains `pid` file with holder PID (auto-cleaned on exit) |

### Agent-Created Directories

| Directory | Purpose |
|-----------|---------|
| `recipes/` | Reusable procedures discovered by the agent |

## Design Decisions

- **Filesystem over database**: All state is plain JSON/Markdown files. This keeps the tool dependency-free (no database, no server) and makes state inspectable with standard Unix tools.
- **Atomic locking via `mkdir`**: The `.ralph-loop.lock/` directory uses POSIX `mkdir` atomicity to prevent concurrent instances without requiring `flock` (which is not portable to macOS).
- **Schema versioning**: All JSON state files carry a `schema_version` integer. Unversioned files are treated as version 0 and auto-migrated at startup. See `lib/migrate.sh` for migration logic.
- **Template-based prompt assembly**: Prompts live in `prompts/` as templates with `{{state_dir}}` placeholders. The runner copies and substitutes at cycle start, so agents always see resolved paths.

## Related Docs

- [Schema Migration](ralph-loop/state-management/schema-migration.md)
- [Discovery Process](discovery-process.md)
- [Work Loop](ralph-loop/orchestration/work-loop.md)
- [Cleanup and Signal Handling](ralph-loop/safety/cleanup-and-signal-handling.md)

## frontier.json Schema

```json
{
  "schema_version": 1,
  "mode": "breadth|depth",
  "current_focus": "module-name or null",
  "queue": ["modules to explore"],
  "discovered_concepts": ["concept-1", "concept-2"],
  "cross_service_patterns": ["pattern-1", "pattern-2"],
  "last_cycle": "ISO timestamp",
  "total_cycles": 0
}
```

## Known Gaps

- `eval-findings.md` and `last-validation-results.json` are mentioned in CLAUDE.md but not always present in `_state/` — they are created on demand during evaluation/validation cycles.
