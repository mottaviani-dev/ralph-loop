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
    style-guide.md     # Documentation tone, structure, length rules
  prompts/
    discovery.md       # Main discovery cycle prompt
    maintenance.md     # Journal rotation + doc audit prompt
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

## How the Loop Works

See `docs/ralph-loop.md` for the full paradigm. In short:

1. Runner invokes Claude with the discovery prompt
2. Agent reads `_state/frontier.json`, picks a feature to explore
3. Agent reads source code, writes documentation, updates state
4. Agent exits; runner logs the cycle, sleeps, repeats
5. Every N cycles, a maintenance agent rotates journals and audits docs
