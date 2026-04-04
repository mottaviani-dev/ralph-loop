# Discovery Process

## Overview

Iterative process for documenting a codebase through automated exploration. Ralph-loop's discovery mode (`--once` or continuous) invokes Claude with `prompts/discovery.md` to explore one module or feature per cycle, producing structured documentation in `docs/`.

## How It Works

Each discovery cycle follows this flow:

```
┌─────────────────────────────────────────────────────────────────┐
│                     DISCOVERY CYCLE                              │
│                                                                  │
│   STARTUP ──> EXPLORE ──> DOCUMENT ──> UPDATE STATE ──>         │
│      │                                        │                  │
│      └────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────┘
```

### Startup Sequence
1. Read `_state/config.json` for module paths
2. Read `_state/journal.md` and `_state/journal-summary.md` for prior discoveries
3. Read `_state/frontier.json` for current focus and exploration queue

### Explore
- Discover features by examining actual code entry points (routes, components, services, models)
- Feature-first approach: trace concrete features end-to-end, not abstract patterns
- Evidence over inference — only document what is found in code

### Document
- Write concept documentation under `docs/`
- Capture business rules, design decisions, and edge cases
- Follow the [style guide](../config/style-guide.md) conventions

### Update State
- Update `_state/frontier.json` with discovered concepts and next targets
- Log findings in `_state/journal.md`
- Track gaps in `docs/<module>/_gaps.md` files

## Key Components

| File | Responsibility |
|------|---------------|
| `prompts/discovery.md` | Discovery agent prompt template |
| `_state/frontier.json` | Exploration queue and discovered concepts |
| `_state/config.json` | Module paths and service configuration |
| `_state/journal.md` | Cycle-by-cycle discovery log |

## Design Decisions

- **Feature-driven, not pattern-driven**: The discovery prompt explicitly rejects abstract exploration targets (e.g., "error-handling-patterns") in favor of concrete features traced end-to-end. This avoids speculative documentation.
- **One outcome per cycle**: Each invocation completes exactly one discovery cycle, keeping output focused and reviewable.
- **State in filesystem**: All discovery state lives in `_state/` JSON files rather than in-memory, enabling restart and resume across sessions.

## Related Docs
- [State Directory](state-directory.md)
- [Ralph Loop Overview](ralph-loop.md)

## Known Gaps
- Documentation output structure varies by project — no enforced directory template exists yet.
