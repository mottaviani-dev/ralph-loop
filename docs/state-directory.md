# Discovery State

State files managed by the Ralph Loop runner.

## Files

| File | Managed By | Purpose |
|------|------------|---------|
| `config.json` | Human | Module paths, integration map, settings |
| `frontier.json` | Agent | What to explore next, discoveries |
| `cycle-log.json` | Runner | History of cycles run (structured) |
| `journal.md` | Runner | Full discovery cycle outputs |
| `maintenance-prompt.md` | Runner | Copied from `prompts/maintenance.md` by both `--setup` and `init_work_state()` (work mode). Required for AI-driven maintenance cycles; absence is non-fatal (bash rotation still bounds journal size). |
| `prompt.md` | Human | Discovery prompt template |
| `.ralph-loop.lock/` | Runner | Atomic lock directory; contains `pid` file with holder PID (auto-cleaned on exit) |

## journal.md

Cumulative log of all discovery cycle outputs. The agent reads this at the start of each cycle to understand what previous sessions discovered.

## frontier.json Schema

```json
{
  "mode": "breadth|depth",
  "current_focus": "module-name or null",
  "queue": ["modules to explore"],
  "discovered_concepts": ["concept-1", "concept-2"],
  "cross_service_patterns": ["pattern-1", "pattern-2"],
  "last_cycle": "ISO timestamp",
  "total_cycles": 0
}
```

## Cycle Flow

1. Runner assembles prompt from template (substitutes `{{state_dir}}`)
2. Runner calls Claude with prompt.md
3. Agent reads frontier.json, decides what to explore
4. Agent explores, documents, updates frontier.json
5. Agent exits
6. Runner logs cycle, sleeps, repeats
