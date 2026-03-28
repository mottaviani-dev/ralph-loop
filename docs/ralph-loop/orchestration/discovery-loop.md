# Discovery Loop Orchestration

## Overview

The discovery loop is ralph-loop's documentation-generation mode. It repeatedly invokes a Claude agent with a discovery prompt to explore, document, and catalog features in a target codebase. Each cycle produces one documentation artifact, updates the exploration frontier, and optionally commits changes. The loop runs continuously until safety limits trigger or the operator interrupts, with periodic maintenance cycles interleaved for journal rotation and state cleanup.

## How It Works

```
Operator runs: ./run.sh           (continuous)
          or:  ./run.sh --once    (single cycle)

        |
        v
  ┌─────────────────────┐
  │  Startup sequence    │  check_dependencies, validate_env,
  │  (run.sh:218-225)    │  acquire_run_lock, check_first_run,
  │                      │  validate_json_files, init_frontier
  └──────────┬──────────┘
             v
  ┌─────────────────────┐     ┌─────────────────────────────┐
  │  discovery_loop_     │────►│  Four stop conditions:       │
  │  should_continue()   │ no  │  1. consecutive failures     │
  │  (discovery.sh:134)  │     │  2. stalemate (no changes)   │
  │                      │     │  3. MAX_DISCOVERY_CYCLES      │
  │                      │     │  4. RALPH_BUDGET_LIMIT        │
  └──────────┬──────────┘     └─────────────────────────────┘
             v (continue)
  ┌─────────────────────┐
  │  run_cycle()         │  Single cycle execution:
  │  (discovery.sh:18)   │
  │  1. Maintenance?     │  Trigger if due (every N cycles or journal overflow)
  │  2. Assemble prompt  │  apply_prompt_vars() on prompts/discovery.md
  │  3. invoke_claude_   │  Run agent with timeout
  │     agent()          │
  │  4. Journal append   │  Append output to journal.md
  │  5. Frontier update  │  Increment total_cycles, set last_cycle timestamp
  │  6. Cycle log        │  Record to cycle-log.json (with token/cost data)
  │  7. Validate JSON    │  Repair corrupted state files via fix-json.py
  │  8. Stalemate check  │  Compare git diff hash with previous cycle
  │  9. Commit           │  Stage + commit docs/ only
  └──────────┬──────────┘
             v
        sleep N seconds ──► loop back to discovery_loop_should_continue()
```

### Entry Paths

| Flag | Behavior |
|------|----------|
| `(no flag)` | `run.sh:534` dispatches to `main()` in `lib/discovery.sh:181` — continuous loop |
| `--once` | `run.sh:218` calls startup sequence then `run_cycle()` once, no loop |
| `--discovery-only` | Sets `DISCOVERY_ONLY=true`, skipping maintenance within cycles |
| `--discovery-once` | Combines `--discovery-only` and `--once` |

### Single Cycle (`run_cycle`)

1. **Cycle counter**: Reads `total_cycles` from `frontier.json` and increments.
2. **Maintenance check**: Unless `DISCOVERY_ONLY=true`, calls `should_run_maintenance()` which triggers if cycle count is divisible by `MAINTENANCE_CYCLE_INTERVAL` (10) or journal exceeds `JOURNAL_MAX_LINES` (500).
3. **Prompt assembly**: Reads `_state/prompt.md` (copied from `prompts/discovery.md` at setup) and runs `apply_prompt_vars()` to resolve `{{state_dir}}`, `{{model}}`, `{{cycle_num}}`, etc.
4. **Dry-run exit**: If `DRY_RUN=true`, writes the assembled prompt to `_state/dry-run-prompt.md` and returns without invoking the agent.
5. **Agent invocation**: Calls `invoke_claude_agent()` which builds CLI args, runs `claude -p` via `run_with_timeout()`, and sets `LAST_AGENT_*` globals (output, status, duration, cost/tokens).
6. **Journal append**: Writes a timestamped entry with duration, status, model, and agent output.
7. **State update**: Atomically updates `frontier.json` (total_cycles, last_cycle) and appends to `cycle-log.json`.
8. **Post-cycle**: Validates JSON state files, checks for stalemate, and commits docs/ changes.

### Continuous Loop (`main`)

The `main()` function (discovery.sh:181) performs startup — banner, dependency checks, `check_first_run()` wizard, JSON validation, frontier initialization — then enters a `while discovery_loop_should_continue` loop. Each iteration calls `run_cycle()`, tracks consecutive failures (reset on success, incremented on failure), and sleeps `cycle_sleep_seconds` (from `config.json`, default 10).

### Stop Conditions (`discovery_loop_should_continue`)

| Condition | Variable | Default |
|-----------|----------|---------|
| Consecutive failures | `MAX_CONSECUTIVE_FAILURES` | 3 |
| Stalemate (no git changes) | `MAX_STALE_CYCLES` | 5 |
| Max cycle count | `MAX_DISCOVERY_CYCLES` | 0 (unlimited) |
| Budget cap | `RALPH_BUDGET_LIMIT` | unset (unlimited) |

Budget check uses `get_cumulative_cost()` to sum `cost_usd` from all entries in `cycle-log.json`, compared via `awk` for float comparison.

### Commit Behavior

Discovery commits are scoped exclusively to `docs/`:
- `git status --porcelain docs/` detects changes
- `git add docs/` stages only documentation
- Commit message: `$COMMIT_MSG_PREFIX $cycle_num` (default: `docs: discovery cycle N`)
- Skipped entirely when `SKIP_COMMIT=true`

This is simpler than work-mode commits which have pathspec exclusions, validation gates, and support for code changes outside `docs/`.

### First-Run Wizard

`check_first_run()` (setup.sh:166) detects empty/missing `config.json` modules. If sibling project directories exist, it offers auto-configuration:
- `auto_detect_modules()` scans for `composer.json`, `angular.json`, `nuxt.config.*`, `package.json` to classify projects as backend/frontend/reference/module
- `auto_detect_subagents()` generates specialist agent definitions per module
- `run_setup()` initializes all `_state/` files from templates

### Frontier Initialization

`init_frontier()` (setup.sh:300) populates the frontier queue with module names from `config.json` when both `queue` is empty and `total_cycles` is 0. This seeds the discovery agent's first exploration targets.

## Key Components

| File | Responsibility |
|------|---------------|
| `lib/discovery.sh:18-99` | `run_cycle()` — single discovery cycle orchestrator |
| `lib/discovery.sh:102-131` | `commit_changes()` — docs/-scoped git commit |
| `lib/discovery.sh:134-178` | `discovery_loop_should_continue()` — four stop conditions |
| `lib/discovery.sh:181-225` | `main()` — continuous loop with startup sequence |
| `lib/setup.sh:11-83` | `auto_detect_modules()` — project type detection by file markers |
| `lib/setup.sh:86-119` | `auto_detect_subagents()` — generate specialist agents from modules |
| `lib/setup.sh:166-213` | `check_first_run()` — interactive first-run wizard |
| `lib/setup.sh:216-297` | `run_setup()` — `_state/` directory initialization from templates |
| `lib/setup.sh:300-312` | `init_frontier()` — seed frontier queue from module registry |
| `lib/maintenance.sh:17-37` | `should_run_maintenance()` — interval and journal-overflow triggers |
| `prompts/discovery.md` | Discovery agent prompt template (project-agnostic) |
| `lib/common.sh:451-522` | `invoke_claude_agent()` — shared agent runner |
| `lib/common.sh:675-777` | `apply_prompt_vars()` — placeholder substitution engine |
| `tests/test_discovery_loop.sh` | 11 unit tests covering all stop conditions including budget |

## Design Decisions

### Discovery-scoped commits vs work-mode commits
Discovery commits only touch `docs/` — a simple `git add docs/` + `git commit`. Work mode needs pathspec exclusions for `_state/`, `.env`, secrets, etc. because the agent modifies source code. Discovery's simpler commit logic reflects its read-only relationship with the target codebase: the agent reads code but only writes documentation.

### Frontier-driven exploration over static plans
The frontier (`frontier.json`) acts as a shared queue between the runner and the agent. The runner seeds it with module names; the agent reads it, picks a focus, and updates it with newly discovered features. This creates an emergent exploration path without requiring the operator to pre-plan documentation topics.

### Maintenance interleaving in discovery mode
Rather than running maintenance as a separate process, it is checked at the start of each discovery cycle. The `MAINTENANCE_CYCLE_INTERVAL` (hardcoded 10) and `JOURNAL_MAX_LINES` (hardcoded 500) triggers ensure journals don't grow unbounded and state stays healthy. `DISCOVERY_ONLY=true` disables this for operators who want pure discovery without overhead.

### First-run wizard with auto-detection
Instead of requiring manual `config/modules.json` authoring, `check_first_run()` scans sibling directories for project markers (composer.json, angular.json, etc.) and offers one-key auto-configuration. This reduces setup friction from editing JSON to pressing "a". The wizard is interactive (reads from `/dev/tty`) so it works even when stdin is piped.

### Dry-run mode for prompt debugging
The `DRY_RUN=true` exit point writes the fully-assembled prompt to a file without invoking Claude. This lets operators verify placeholder substitution and prompt content without spending API credits — useful when iterating on `prompts/discovery.md`.

## Related Docs

- [Work Loop Orchestration](work-loop.md) — parallel work mode with validation-gated commits
- [State Directory](../../../docs/state-directory.md) — schema for frontier.json and other runtime files
- [Ralph Loop Paradigm](../../../docs/ralph-loop.md) — conceptual overview of the loop model
- [Discovery Process](../../../docs/discovery-process.md) — discovery methodology and prompt design
