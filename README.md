# Ralph Loop

A general-purpose automation runner for continuous AI agent loops. Works with any codebase — discovery, documentation, implementation, and maintenance all driven by your project's own `CLAUDE.md` and `AGENT.md`.

## What It Does

The runner (`run.sh`) continuously invokes Claude Code agents that:

1. **Discover** — browse source code, identify features, write documentation
2. **Work** — self-direct implementation: research, implement, fix, evaluate
3. **Maintain** — rotate journals, audit docs, prune stale state

State persists on the filesystem (the "Ralph Loop" pattern), so each agent invocation picks up where the last left off. The agent reads project context from your `CLAUDE.md`/`AGENT.md` — no project-specific configuration in the prompts.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         RALPH LOOP                              │
│                                                                 │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐ │
│   │  Read    │───>│ Execute  │───>│ Validate │───>│ Complete?│ │
│   │  State   │    │  Agent   │    │ External │    │          │ │
│   └──────────┘    └──────────┘    └──────────┘    └────┬─────┘ │
│        ^                                               │       │
│        │              ┌────────────────────────────────┘       │
│        │              │                                        │
│        │         NO   v    YES                                 │
│        │         ┌────┴────┐                                   │
│        └─────────┤ Update  │──────> EXIT                       │
│                  │ State   │                                   │
│                  └─────────┘                                   │
└─────────────────────────────────────────────────────────────────┘
```

Key properties:
- **Context stays fresh** — each cycle starts with a new context window
- **Progress lives in files** — not in the LLM's memory
- **External validation** — tests/linters determine success, not self-assessment
- **Stalemate detection** — aborts after N cycles with zero file changes
- **Compound learning** — patterns discovered are saved to `LEARNINGS.md` for future cycles

## Prerequisites

- `jq` — JSON processor (`brew install jq`)
- `claude` — [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Python 3 — for JSON repair utility
- Git — target repos must be git repositories

## Linting

`run.sh` is expected to produce zero [ShellCheck](https://www.shellcheck.net/) warnings.

```bash
# Install ShellCheck (macOS)
brew install shellcheck

# Run the linter
make lint
```

## Quick Start

```bash
# 1. Clone ralph-loop into your project (or as a sibling directory)
cd your-project
git clone <ralph-loop-repo> ralph-loop

# 2. Auto-detect modules and set up state
ralph-loop/run.sh --auto-setup

# 3. Run a single discovery cycle
ralph-loop/run.sh --once

# 4. Or start continuous work loop
ralph-loop/run.sh --work
```

The runner auto-detects project modules by scanning for `package.json`, `composer.json`, `Cargo.toml`, etc. It generates `config/modules.json` and `config/subagents.json` automatically.

## Project Context

Ralph-loop prompts are generic. All project-specific context comes from your repo:

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Architecture, commands, conventions (Claude Code reads this automatically) |
| `AGENT.md` | Requirements, specifications, task definitions (optional) |
| `LEARNINGS.md` | Accumulated patterns and gotchas (auto-created, agent-maintained) |

Write a good `CLAUDE.md` and the agent knows how to work with your codebase.

## Directory Layout

```
ralph-loop/
  run.sh               # The automation engine
  fix-json.py          # Repairs common Claude JSON errors
  config/
    modules.json       # Service paths, integration map (auto-detected or manual)
    subagents.json     # Specialist agent definitions (auto-detected or manual)
    tasks.json         # Empty task template (copied to _state/ on setup)
    style-guide.md     # Documentation structure and conventions
    mcp-servers.json   # MCP server config (optional, for browser/design tools)
  prompts/
    discovery.md       # Discovery cycle prompt (generic)
    maintenance.md     # Journal rotation + doc audit prompt (generic)
    work.md            # Work prompt: research/implement/fix/evaluate (generic)
  docs/
    ralph-loop.md      # The continuous iteration paradigm
    discovery-process.md  # Explore > Document > Validate > Refine
    state-directory.md # Schema for state files
```

## Running

```bash
# Discovery mode
ralph-loop/run.sh --once           # Single discovery cycle
ralph-loop/run.sh                  # Continuous discovery loop (Ctrl+C to stop)
ralph-loop/run.sh --maintenance    # Force maintenance (journal rotation, doc audit)

# Work mode (implementation)
ralph-loop/run.sh --work           # Continuous work loop
ralph-loop/run.sh --work-once      # Single work cycle
ralph-loop/run.sh --work-status    # Check task progress

# Setup
ralph-loop/run.sh --setup          # Initialize state directory
ralph-loop/run.sh --auto-setup     # Auto-detect modules + setup
ralph-loop/run.sh --status         # Check current state
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MODEL` | `opus` | Model to use (`sonnet` for speed, `opus` for depth) |
| `SKIP_PERMISSIONS` | `true` | Skip Claude CLI permission prompts |
| `SKIP_COMMIT` | `false` | Skip auto-commit after each cycle |
| `USE_AGENTS` | `true` | Enable specialist subagent delegation |
| `DISCOVERY_ONLY` | `false` | Skip maintenance cycles |
| `ENABLE_MCP` | `false` | Enable MCP server integration |
| `WORK_AGENT_TIMEOUT` | `900` | Timeout per cycle in seconds (15 min) |
| `MAX_CONSECUTIVE_FAILURES` | `3` | Abort after N consecutive failures |
| `MAX_STALE_CYCLES` | `5` | Abort after N cycles with no file changes |
| `MAX_WORK_CYCLES` | `0` | Max work cycles, 0=unlimited |
| `VALIDATE_BEFORE_COMMIT` | `true` | Run validation before committing (skip commit on failure) |
| `RALPH_GIT_EXCLUDE` | _(none)_ | Space-separated additional git pathspec exclusion patterns for work mode commits (e.g. `"my-secrets/ *.vault"`). Extends the built-in exclusion list; does not replace it. |
| `RALPH_VERBOSE_COMMIT` | `false` | Log every staged file name before committing in work mode. Useful for auditing what the agent committed. |

## Work Mode

Work mode gives the agent full autonomy. It reads `AGENT.md` for requirements, self-decomposes work into tasks, and continuously improves `CLAUDE.md`, `AGENT.md`, and `LEARNINGS.md` every cycle.

### Actions

Each cycle, the agent reads state files and decides ONE action:

1. **RESEARCH** — Explore code to understand patterns before implementing
2. **IMPLEMENT** — Pick a task and write code
3. **FIX** — Retry a failed implementation using a different approach
4. **EVALUATE** — Fresh-eyes review of recent work (evaluator-optimizer pattern)
5. **META-IMPROVE** — Step back, analyze performance, write recipes, deep-update knowledge files

### Key Behaviors

- **Full task autonomy** — The agent creates, rewrites, splits, merges, reprioritizes, and discards tasks freely. No pre-populated task list.
- **Continuous knowledge improvement** — CLAUDE.md and AGENT.md are updated EVERY cycle, not just during META-IMPROVE. The agent treats them as living documents.
- **Full journal access** — The agent reads the complete journal history, not a truncated window. It strategically scans headers then reads relevant entries in detail.
- **Completion signal** — When all tasks are done, the agent sets `all_tasks_complete: true` in work-state.json. The runner validates and exits cleanly.

### State Files

| File | Purpose |
|------|---------|
| `_state/work-state.json` | Current task, cycle count, action stats, completion signal |
| `_state/tasks.json` | Agent-managed task registry (created/rewritten by agent) |
| `_state/journal.md` | Full cycle-by-cycle log — the agent's complete memory |
| `_state/recipes/` | Reusable step-by-step procedures discovered by the agent |
| `_state/eval-findings.md` | Evaluation results from EVALUATE cycles |
| `_state/prompt-improvements.md` | Agent-proposed prompt changes for human review |
| `_state/last-validation-results.json` | Validation results from runner (injected into next cycle) |

### Safety Features

- **Pre-flight validation** — Runs validation at startup to give the first cycle a baseline
- **Validate before commit** — Skips commit if validation fails; broken changes stay for the next cycle to fix
- **Completion detection** — Exits cleanly when agent signals all tasks complete and validation passes
- **Stalemate detection** — Aborts after N consecutive cycles with zero git changes
- **Failure limit** — Aborts after N consecutive cycle failures/timeouts
- **Timeout** — Each cycle has a configurable timeout (default 15 min)
- **JSON repair** — Auto-fixes common JSON syntax errors in state files
- **Truncated validation output** — Validation results are truncated to last 30 lines per command with a summary line, preventing context pollution
- **Scoped git staging** — Work mode commits use pathspec exclusions to prevent accidentally staging `.env` files, `_state/` operational files, `.symphony-workspaces/` worktrees, OS artifacts (`.DS_Store`), and credential files (`*.key`, `*.pem`). Extend the exclusion list per-project with `RALPH_GIT_EXCLUDE`.

### Compound Learning

The agent updates knowledge files **every cycle**:
- `CLAUDE.md` — Architecture insights, patterns, corrections, gotchas
- `AGENT.md` — Task status, priorities, approach changes, fresh metrics
- `LEARNINGS.md` — Reusable patterns, per-directory conventions, failure modes

The journal entry format tracks these updates for accountability.

## Configuring for a New Project

### Automatic (recommended)

```bash
ralph-loop/run.sh --auto-setup
```

This scans sibling directories for code projects and generates config automatically.

### Manual

1. **Edit `config/modules.json`** — define your services:

```json
{
  "modules": {
    "api": {
      "path": "../api",
      "type": "backend",
      "integrates_with": ["frontend"]
    },
    "frontend": {
      "path": "../frontend",
      "type": "frontend",
      "integrates_with": ["api"]
    }
  },
  "docs_root": ".",
  "cycle_sleep_seconds": 10
}
```

2. **Edit `config/subagents.json`** — define specialists (or leave `{}` for auto-generated):

```json
{
  "api": {
    "description": "Backend API developer",
    "prompt": "You are a specialist for the API service. Working directory: ../api",
    "tools": ["Read", "Write", "Edit", "Glob", "Grep", "Bash"],
    "model": "inherit"
  }
}
```

3. **Write `CLAUDE.md`** in your project root — this is where project-specific context lives.

4. **Optionally write `AGENT.md`** — requirements, specs, and task definitions for work mode.

5. **Run setup**: `ralph-loop/run.sh --setup`

## References

- [From ReAct to Ralph Loop — Alibaba Cloud](https://www.alibabacloud.com/blog/from-react-to-ralph-loop-a-continuous-iteration-paradigm-for-ai-agents_602799)
- [Building Effective Agents — Anthropic](https://www.anthropic.com/research/building-effective-agents)
- [snarktank/ralph — PRD-driven agent loop](https://github.com/snarktank/ralph)
- [umputun/ralphex — Extended ralph with multi-agent review](https://github.com/umputun/ralphex)
- [Anthropic Ralph Wiggum Plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum)
