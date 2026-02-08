# Ralph Loop Implementation

Ralph Loop is a continuous iteration paradigm for AI agents. Named after Ralph Wiggum (The Simpsons), it represents persistent iteration until success.

## Core Principle

Continuous reinvection of the same prompt while the agent observes evolving file states. External validation determines success, not the model's self-assessment.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         RALPH LOOP                              │
│                                                                 │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐ │
│   │  Task    │───►│ Execute  │───►│ Validate │───►│ Complete?│ │
│   │Definition│    │  Agent   │    │ External │    │          │ │
│   └──────────┘    └──────────┘    └──────────┘    └────┬─────┘ │
│        ▲                                               │       │
│        │              ┌────────────────────────────────┘       │
│        │              │                                        │
│        │         NO   ▼    YES                                 │
│        │         ┌────┴────┐                                   │
│        └─────────┤ Update  │──────► EXIT                       │
│                  │ State   │                                   │
│                  └─────────┘                                   │
└─────────────────────────────────────────────────────────────────┘
```

## State Persistence

Ralph shifts memory from LLM context to filesystem:

| File | Purpose |
|------|---------|
| `progress.md` | Cumulative log: accomplishments, obstacles, patterns |
| `tasks.json` | Structured task registry with status and acceptance criteria |
| `discoveries.md` | New findings and questions |
| Git history | Observable change differentials |

## Validation Mechanisms

External signals determine completion (not LLM self-assessment):

- Tests passing
- Type checking clean
- Lint passing
- Build successful
- Documentation coverage metrics
- Human review checkpoints

## Best Practices

1. **Start Human-in-the-Loop** — Observe and refine before autonomous runs
2. **Define Scope Precisely** — Vague criteria cause endless loops
3. **Set Iteration Limits** — Always have max-iterations safeguard
4. **Small Steps** — One feature per iteration with full validation
5. **Track Progress Explicitly** — Document patterns and pitfalls
6. **Prioritize High-Risk First** — Reserve unattended mode for stable work

## Sources

- [From ReAct to Ralph Loop - Alibaba Cloud](https://www.alibabacloud.com/blog/from-react-to-ralph-loop-a-continuous-iteration-paradigm-for-ai-agents_602799)
- [Building Effective Agents - Anthropic](https://www.anthropic.com/research/building-effective-agents)
