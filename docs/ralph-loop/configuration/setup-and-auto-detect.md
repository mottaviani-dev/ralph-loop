# Setup and Auto-Detection

## Overview

The setup system initializes the `_state/` runtime directory that ralph-loop requires before any discovery or work cycle can execute. It provisions empty state files, copies prompt templates and config from `config/`, and optionally auto-detects sibling project directories to populate `config.json` and `subagents.json` without manual configuration.

Three entry paths exist: explicit `--setup` (scaffolds from templates), `--auto-setup` (detects projects then scaffolds), and the first-run wizard (interactive prompt on first discovery run).

## How It Works

```
User invokes ralph-loop
        │
        ├── --setup ──────────────────► run_setup()
        │                                 ├─ migrate_all() on any pre-existing files
        │                                 ├─ Copy config template → _state/config.json
        │                                 ├─ Copy prompts → _state/*.md
        │                                 ├─ Copy subagents, tasks, style-guide, fix-json
        │                                 ├─ init_work_state() → _state/work-state.json
        │                                 ├─ Create frontier.json, cycle-log.json,
        │                                 │   maintenance-state.json, journal.md
        │                                 └─ exit 0
        │
        ├── --auto-setup ────────────► auto_detect_modules()
        │                                 ├─ Scan $DOCS_DIR/*/ for project markers
        │                                 ├─ Write detected modules to _state/config.json
        │                                 └─ auto_detect_subagents()
        │                                       └─ Generate _state/subagents.json
        │                              └──► run_setup() (same as above)
        │
        └── --once (no config) ──────► check_first_run()
                                          ├─ Detect: config.json missing or empty modules
                                          ├─ auto_detect_modules() silently
                                          ├─ Interactive prompt: [a]uto / [m]anual
                                          │   ├─ "a" → auto_detect_subagents + run_setup
                                          │   └─ "m" → print_manual_setup + exit
                                          └─ Continue to discovery if "a" chosen
```

### Module Auto-Detection (`auto_detect_modules`)

Scans immediate subdirectories of `$DOCS_DIR` and classifies each by file markers:

| Marker File | Detected Type |
|-------------|--------------|
| `composer.json` | `backend` |
| `angular.json` | `frontend` |
| `nuxt.config.js` / `nuxt.config.ts` | `frontend` |
| `package.json` (fallback) | `frontend` |
| `.git` directory (no other markers) | `reference` |
| Loose `.ts`, `.vue`, `.php` files | `module` |

Directories are skipped if they match: `docs`, `ralph-loop`, `node_modules`, `public`, `tests`, hidden dirs (`.*`), or underscore-prefixed dirs (`_*`).

Detection writes directly to `_state/config.json` — never mutates source-controlled `config/modules.json`. If a `config/modules.json` template exists, modules are merged into that template's structure (preserving taxonomy); otherwise a default taxonomy is generated.

### Subagent Auto-Generation (`auto_detect_subagents`)

Iterates over modules in `_state/config.json` and generates a specialist definition for each:

- Description: `"<Type> developer for <name>"`
- Prompt: includes the module's working directory path
- If a `CLAUDE.md` exists in the module root, the prompt instructs the agent to read it
- All subagents get the same tool set: `Read, Write, Edit, Glob, Grep, Bash`
- Model: `"inherit"` (uses parent session's model)

### State File Provisioning (`run_setup`)

Creates the full `_state/` directory with these files:

| File | Source | Notes |
|------|--------|-------|
| `config.json` | `config/modules.json` or auto-detect | Skipped if already populated |
| `prompt.md` | `prompts/discovery.md` | Discovery prompt template |
| `maintenance-prompt.md` | `prompts/maintenance.md` | Maintenance prompt template |
| `work-prompt.md` | `prompts/work.md` | Work prompt template |
| `refine-prompt.md` | `prompts/refine.md` | Refine prompt template |
| `subagents.json` | `config/subagents.json` or auto-detect | Skipped if already populated |
| `tasks.json` | `config/tasks.json` | Work mode task registry |
| `style-guide.md` | `config/style-guide.md` | Documentation style guide |
| `fix-json.py` | `fix-json.py` (project root) | JSON repair utility |
| `work-state.json` | `init_work_state()` | Canonical schema with stats |
| `frontier.json` | Inline JSON literal | Empty queue, zero cycles |
| `cycle-log.json` | Inline JSON literal | Empty cycles array |
| `maintenance-state.json` | Inline JSON literal | Zero rotation, empty audit |
| `journal.md` | `touch` | Empty file |
| `journal-summary.md` | `touch` | Empty file |

Before creating files, `run_setup` calls `migrate_all()` to upgrade any pre-existing state files to current schema versions.

### Work Mode Initialization (`init_work_state`)

Called both from `run_setup` and independently at work mode entry (`run.sh:264`). Creates files only if missing, making it safe to call repeatedly:

- `work-state.json`: cycle count, current task, action history, per-action-type stats
- `tasks.json`: copies from `config/tasks.json` template or creates minimal scaffold
- `work-prompt.md`: always refreshed from `prompts/work.md` (picks up edits between runs)
- `subagents.json`: always refreshed from `config/subagents.json`
- `cycle-log.json`, `journal.md`, `config.json`: created with minimal defaults if missing

### Frontier Initialization (`init_frontier`)

Called after `check_first_run` in the `--once` path and at the start of continuous discovery. Seeds the frontier queue with all module names from `config.json` — but only on the very first run (queue length 0 and total cycles 0). Subsequent runs never re-seed.

### First-Run Wizard (`check_first_run`)

Triggers when `_state/config.json` is missing or has zero modules. Provides an interactive TTY prompt (`read -r ... </dev/tty`) with two choices:

- **Auto-configure**: runs `auto_detect_modules` + `auto_detect_subagents` + `run_setup`, then continues to discovery
- **Manual setup**: prints a guide showing the expected `modules.json` and `subagents.json` structure, then exits

The wizard only runs in discovery mode (`--once` or continuous) — work mode calls `init_work_state` directly without the interactive prompt.

## Key Components

| File | Responsibility |
|------|---------------|
| `lib/setup.sh` | All setup logic: auto-detection, first-run wizard, `run_setup`, `init_frontier` |
| `lib/work.sh:85` | `init_work_state()` — work-mode-specific state initialization |
| `config/modules.json` | Template config copied to `_state/` on setup |
| `config/subagents.json` | Template subagent definitions copied to `_state/` |
| `config/tasks.json` | Template task registry copied to `_state/` |
| `run.sh:161-262` | Argument parsing and dispatch for `--setup` and `--auto-setup` |

## Design Decisions

**Auto-detection writes to `_state/`, not `config/`**: The source-controlled `config/` directory holds templates. Auto-detection output goes to `_state/` (gitignored) so that generated configs don't pollute the repository. This separation means you can re-run `--auto-setup` without dirtying the working tree.

**Marker-based project type detection**: The detection hierarchy (composer.json → angular.json → nuxt.config → package.json → .git → loose files) is ordered from most specific to least specific. This avoids misclassifying a Laravel project that also has a `package.json` for frontend tooling.

**`init_work_state` is idempotent**: Uses `if [ ! -f ... ]` guards for most files, so calling it multiple times never overwrites existing state. The exception is `work-prompt.md` and `subagents.json`, which are always refreshed to pick up template edits between runs.

**`run_setup` calls `migrate_all` first**: If a user runs `--setup` on an existing `_state/` directory (e.g., after upgrading ralph-loop), migrations run before any file is overwritten. This ensures schema compatibility without data loss.

**First-run wizard reads from `/dev/tty`**: Standard input may be piped or redirected in automated environments. Reading from `/dev/tty` ensures the interactive prompt works even when stdin is not a terminal.

## Related Docs

- [Prompt Assembly](./prompt-assembly.md) — how templates copied during setup are processed at runtime
- [Schema Migration](../state-management/schema-migration.md) — the migration system called by `run_setup`
- [Discovery Loop](../orchestration/discovery-loop.md) — where `check_first_run` and `init_frontier` are called
- [Work Loop](../orchestration/work-loop.md) — where `init_work_state` is called
