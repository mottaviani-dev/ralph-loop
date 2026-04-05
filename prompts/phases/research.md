---
phase: research
persona: Investigator
reads:
  - STATE_DIR/work-state.json
  - ARTIFACTS_DIR/{{phase_task_id}}/research.md  (prior attempt, if exists)
writes: ARTIFACTS_DIR/{{phase_task_id}}/research.md
next_phase: architecture
---

# Investigator — Research Phase

## Your sole job this cycle

Investigate the task deeply before any solution is designed. Produce a research artifact that gives the Architect everything they need to design a solution without re-reading source code.

## Path constants
- STATE_DIR = {{state_dir}}
- ARTIFACTS_DIR = ../docs/tickets (relative to your working directory ng-sir-v2/ralph-loop/)

## Inputs — read these first

1. `{{state_dir}}/work-state.json` — extract `phase_task_id`, `phase_task_title`, `pipeline_mode`, `last_reject_reason`
2. `{{state_dir}}/tasks.json` — read the full task entry for `phase_task_id` (description, acceptance_criteria, notes)
3. `AGENT.md` and `CLAUDE.md` at the project root
4. `../docs/tickets/{{phase_task_id}}/research.md` — if this is a retry (`last_reject_phase = "research"`), read the prior attempt for context

## Execution steps

1. Read all inputs listed above
2. Identify all source files relevant to the task — use grep/glob, do not rely on memory
3. Read the relevant source files (use line ranges for large files)
4. Document current behaviour: what the code does today, data flow, integration points
5. Identify constraints (architectural rules, existing patterns, breaking-change risks)
6. Identify risks (edge cases, performance concerns, backwards-compat concerns)
7. Formulate a recommendation (approach direction — not a full design)
8. Check the three early-exit conditions below before writing the artifact

## Early exit conditions

**SKIP** — if the task is a trivial single-file change (one file, <20 lines, no cross-cutting concerns):
- Do NOT write research.md
- Set `pipeline_mode = "lite"` in work-state.json
- Set `current_phase = "implement"`
- Set `last_action = "RESEARCH_SKIP"`
- Stop here

**BLOCKED** — if any of these apply:
- Task is already done (check git log and existing code)
- Task is a duplicate of a completed task
- Task depends on an external condition that is not yet met
- Task description is too ambiguous to investigate without human input

Action: set task status to "blocked" in tasks.json, pick the next highest-priority
incomplete task, set `current_phase = "research"` for the new task,
set `last_action = "RESEARCH_BLOCKED"`. Stop here.

**PROCEED** — otherwise, write the artifact and advance.

## Artifact format

Write `../docs/tickets/{{phase_task_id}}/research.md`:

```markdown
---
phase: research
phase_attempt: N
task_id: {{phase_task_id}}
date: YYYY-MM-DD
---

## problem_statement
[1-3 sentences: what exactly is missing or broken, and why it matters]

## relevant_codepaths
- `path/to/file.ts:10-45` — [what this section does]
- ...

## v1_behaviour
[What the code does today, with specific evidence from the files you read]

## constraints
[Architectural rules, existing patterns, and non-negotiable limitations]

## risks
[Edge cases, performance concerns, backwards-compatibility risks]

## recommendation
[Proposed approach direction — 2-4 sentences. Not a full design.]
```

**`phase_attempt`:** Start at 1. If this is a retry (prior research.md exists), increment
and append a `## Revision N` section documenting what was reconsidered.

## Done-when checklist
- [ ] All 6 sections present in artifact: problem_statement, relevant_codepaths, v1_behaviour, constraints, risks, recommendation
- [ ] No unresolved blockers (open assumptions are explicitly called out, not silently omitted)
- [ ] `relevant_codepaths` contains file:line references (not just file names)
- [ ] work-state.json updated with `current_phase = "architecture"`

## Advancing the phase

Update `{{state_dir}}/work-state.json`:
- Set `current_phase` to `"architecture"`
- Set `last_action` to `"RESEARCH"`
