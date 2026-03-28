# Ralph Loop

Ralph Loop is a continuous iteration paradigm for AI agents. Named after Ralph Wiggum (The Simpsons), it represents persistent iteration until success.

## Core Principle

Continuous reinvocation of the same prompt while the agent observes evolving file states. External validation determines success, not the model's self-assessment.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         RALPH LOOP                              │
│                                                                 │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐ │
│   │  Task    │───>│ Execute  │───>│ Validate │───>│ Complete?│ │
│   │Definition│    │  Agent   │    │ External │    │          │ │
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

## State Persistence

Ralph shifts memory from LLM context to filesystem:

| File | Purpose |
|------|---------|
| `work-state.json` | Cycle count, last action, stats |
| `tasks.json` | Structured task registry with status and acceptance criteria |
| `journal.md` | Cumulative log: actions, outcomes, learnings |
| `LEARNINGS.md` | Compound learning: patterns, gotchas, conventions |
| `recipes/` | Reusable step-by-step procedures |
| Git history | Observable change differentials |

## Validation Mechanisms

External signals determine completion (not LLM self-assessment):

- Tests passing
- Type checking clean
- Lint passing
- Build successful
- Documentation coverage metrics
- Human review checkpoints

## Safety Mechanisms

- **Stalemate detection** — Abort after N cycles with zero file changes
- **Failure limit** — Abort after N consecutive cycle failures
- **Timeout** — Each cycle has a configurable deadline
- **JSON repair** — Auto-fix common LLM JSON syntax errors
- **Context clearing** — Each cycle gets a fresh context window

## Compound Learning

The META-IMPROVE action (every 10 cycles) creates a compound learning loop:

1. Analyze the last 10 cycles for patterns
2. Write reusable recipes to `_state/recipes/`
3. Update `LEARNINGS.md` at the project root
4. Propose prompt improvements to `_state/prompt-improvements.md`

Future cycles read `LEARNINGS.md` during startup, benefiting from all previous discoveries.

## Best Practices

1. **Start Human-in-the-Loop** — Observe and refine before autonomous runs
2. **Define Scope Precisely** — Vague criteria cause endless loops
3. **Set Iteration Limits** — Always have max-iterations safeguard
4. **Small Steps** — One action per iteration with full validation
5. **Track Progress Explicitly** — Document patterns and pitfalls
6. **Write Good CLAUDE.md** — The agent's effectiveness is bounded by its project context
7. **Use AGENT.md for Requirements** — Structured specs produce better autonomous work

## Lifecycle Hooks

Ralph-loop supports user-defined shell commands at six lifecycle boundaries, configured via `RALPH_HOOK_*` environment variables. Hooks are an operator-level feature — they run with full shell access and are not subject to the validation command denylist.

### Hook Points

| Hook | Env var | When it fires |
|------|---------|---------------|
| `PRE_CYCLE` | `RALPH_HOOK_PRE_CYCLE` | Before each agent invocation (both modes) |
| `POST_CYCLE` | `RALPH_HOOK_POST_CYCLE` | After agent exits, before journal append |
| `PRE_COMMIT` | `RALPH_HOOK_PRE_COMMIT` | After change detection, before `git add` |
| `POST_COMMIT` | `RALPH_HOOK_POST_COMMIT` | After `git commit` succeeds |
| `ON_COMPLETE` | `RALPH_HOOK_ON_COMPLETE` | When all work tasks complete (work mode only) |
| `ON_ERROR` | `RALPH_HOOK_ON_ERROR` | On consecutive-failure abort (both modes) |

### Context Variables

Every hook subprocess receives these environment variables:

| Variable | Example | Notes |
|----------|---------|-------|
| `RALPH_CYCLE_NUM` | `42` | Current cycle counter |
| `RALPH_MODE` | `work` | `work` or `discovery` |
| `RALPH_STATUS` | `success` | `success`, `failed`, or `timeout` (post-cycle hooks) |
| `RALPH_EXIT_CODE` | `0` | Raw agent exit code (post-cycle hooks) |
| `RALPH_COMMIT_MSG` | `docs: work cycle 5` | Commit message used (post-commit hooks) |

### Failure Semantics

- **All hooks except `PRE_COMMIT`**: non-zero exit is logged as a warning and swallowed. The loop continues.
- **`PRE_COMMIT` with `RALPH_HOOK_PRE_COMMIT_STRICT=false` (default)**: same — failure logged, commit proceeds.
- **`PRE_COMMIT` with `RALPH_HOOK_PRE_COMMIT_STRICT=true`**: non-zero exit aborts the commit. Changes are preserved for the next cycle.

All hooks are run through `run_with_timeout` with a `RALPH_HOOK_TIMEOUT`-second deadline (default: 60s). A timed-out hook is treated as a non-zero exit.

### Usage Examples

```bash
# Refresh OAuth tokens before each cycle
RALPH_HOOK_PRE_CYCLE="./scripts/refresh-tokens.sh" ./run.sh --work

# Run lint-staged before committing, abort on failure
RALPH_HOOK_PRE_COMMIT="npm run lint-staged" \
RALPH_HOOK_PRE_COMMIT_STRICT=true \
  ./run.sh --work

# Notify Slack after every successful commit
RALPH_HOOK_POST_COMMIT='curl -s -X POST $SLACK_WEBHOOK -d "{\"text\":\"Committed: $RALPH_COMMIT_MSG\"}"' \
  ./run.sh --work

# Run cleanup script on error abort
RALPH_HOOK_ON_ERROR="./scripts/cleanup-on-error.sh" ./run.sh --work
```

### Security

Hooks run as the invoking user with full filesystem access. All configured commands are audit-logged (`HOOK [name]: cmd`) before execution. In environments with production credentials, audit hook commands before running. See also: *Security: Validation Command Execution* in `CLAUDE.md`.

## Sources

- [From ReAct to Ralph Loop — Alibaba Cloud](https://www.alibabacloud.com/blog/from-react-to-ralph-loop-a-continuous-iteration-paradigm-for-ai-agents_602799)
- [Building Effective Agents — Anthropic](https://www.anthropic.com/research/building-effective-agents)
- [snarktank/ralph — PRD-driven agent loop](https://github.com/snarktank/ralph)
- [umputun/ralphex — Extended ralph with multi-agent review](https://github.com/umputun/ralphex)
- [Anthropic Ralph Wiggum Plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum)
- [Self-Improving Coding Agents — Addy Osmani](https://addyosmani.com/blog/self-improving-agents/)
