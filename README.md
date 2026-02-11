# Ralph Loop

A white-label automation system for continuous codebase documentation using Claude CLI agents.

## What It Does

The runner (`run.sh`) continuously invokes Claude agents that:

1. **Discover** -- browse source code starting from controllers, commands, and jobs
2. **Document** -- write structured markdown docs for each feature found
3. **Maintain** -- rotate journals, audit cross-service docs, prune stale state

State persists entirely on the filesystem (the "Ralph Loop" pattern), so each agent invocation picks up where the last left off.

## Prerequisites

- `jq` -- JSON processor (`brew install jq`)
- `claude` -- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Python 3 -- for JSON repair utility
- Git -- source repos must be git repositories

## Directory Layout

```
ralph-loop/
  run.sh               # The automation engine
  fix-json.py          # Repairs common Claude JSON errors (unescaped backslashes, missing commas)
  config/
    modules.json       # Service paths, integration map, settings
    subagents.json     # Specialist agent definitions per service
    tasks.json         # Empty task template (copied to _state/ on setup)
    style-guide.md     # Documentation tone, structure, length rules
  prompts/
    discovery.md       # Main discovery cycle prompt
    maintenance.md     # Journal rotation + doc audit prompt
    work.md            # Unified work prompt (plan/research/implement/fix)
  docs/
    ralph-loop.md      # The continuous iteration paradigm
    discovery-process.md  # Explore > Document > Validate > Refine
    state-directory.md # Schema for state files (frontier, cycle-log, journals)
```

## Configuring for a New Project

1. **Edit `config/modules.json`** -- replace the `modules` map with your services:

```json
{
  "modules": {
    "my-api": {
      "path": "../my-api",
      "type": "backend",
      "integrates_with": ["my-frontend"]
    },
    "my-frontend": {
      "path": "../my-frontend",
      "type": "frontend",
      "integrates_with": ["my-api"]
    }
  },
  "docs_root": ".",
  "cycle_sleep_seconds": 10
}
```

2. **Edit `config/subagents.json`** -- define specialist agents for each service (or leave empty `{}` if not using specialists). Each agent needs a `prompt` with the service's working directory and domain expertise.

3. **Edit prompts** -- the discovery prompt (`prompts/discovery.md`) references file paths like `docs/_state/`. Update these to match your docs directory structure.

4. **Run setup** to create the `_state/` directory with initial state files:

```bash
ralph-loop/run.sh --setup
```

## Running

```bash
# Single discovery cycle
ralph-loop/run.sh --once

# Continuous loop (Ctrl+C to stop)
ralph-loop/run.sh

# Force maintenance (journal rotation, doc audit)
ralph-loop/run.sh --maintenance

# Initialize state directory
ralph-loop/run.sh --setup

# Check current state
ralph-loop/run.sh --status
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MODEL` | `opus` | Model to use (`sonnet` for speed, `opus` for depth) |
| `SKIP_PERMISSIONS` | `true` | Skip Claude CLI permission prompts |
| `SKIP_COMMIT` | `false` | Skip auto-commit after each cycle |
| `USE_AGENTS` | `true` | Enable specialist subagent delegation |
| `DISCOVERY_ONLY` | `false` | Skip maintenance cycles |

## Work Mode (Implementation)

Work mode lets the agent self-direct actual code implementation. Instead of documenting existing code, the agent reads project requirements, creates tasks, and implements them cycle by cycle.

### How It Works

Each cycle, the agent reads state files and decides ONE action:

1. **PLAN** — Read requirements docs, create tasks with acceptance criteria and dependencies
2. **RESEARCH** — Explore code to understand patterns before implementing
3. **IMPLEMENT** — Pick the highest-priority unblocked task and write code
4. **FIX** — Retry a failed implementation using a different approach

Tasks are **not pre-populated** — the agent auto-creates them from project requirements (AGENT.md, CLAUDE.md, etc.) during plan cycles.

### Running Work Mode

```bash
# Single work cycle (plan, research, implement, or fix)
ralph-loop/run.sh --work

# Continuous work until all tasks complete or are blocked
ralph-loop/run.sh --work-loop

# Check task progress
ralph-loop/run.sh --work-status
```

### End-to-End Example

```
Cycle 1 (PLAN):    Agent reads AGENT.md → creates 5 tasks in tasks.json
Cycle 2 (RESEARCH): Agent explores existing migration patterns
Cycle 3 (IMPLEMENT): Agent writes migration + model → validation passes
Cycle 4 (IMPLEMENT): Agent writes controller → validation fails (FK issue)
Cycle 5 (FIX):    Agent reads challenge → fixes FK ordering → passes
... continues until all tasks complete or are blocked/failed
```

### External Validation

After each work cycle, the runner reads the current task's `validation_commands` from `tasks.json` and executes them. Results are written to `_state/last-validation-results.json` and injected into the next cycle's prompt so the agent can decide whether to fix or continue.

### State Files

| File | Purpose |
|------|---------|
| `_state/tasks.json` | Task registry with acceptance criteria, attempts, dependencies |
| `_state/work-state.json` | Current task, cycle count, action stats |
| `_state/work-prompt.md` | Active work prompt (copied from `prompts/work.md`) |
| `_state/last-validation-results.json` | Ephemeral validation results from runner |

### Environment Variables (Work Mode)

| Variable | Default | Description |
|----------|---------|-------------|
| `WORK_COMMIT_MSG_PREFIX` | `feat: work cycle` | Commit message prefix for work cycles |

## How the Discovery Loop Works

See `docs/ralph-loop.md` for the full paradigm. In short:

1. Runner invokes Claude with the discovery prompt
2. Agent reads `_state/frontier.json`, picks a feature to explore
3. Agent reads source code, writes documentation, updates state
4. Agent exits; runner logs the cycle, sleeps, repeats
5. Every N cycles, a maintenance agent rotates journals and audits docs
