# Discovery Process

Iterative process for documenting a codebase through automated exploration.

## Loop Structure

Each module goes through this cycle:

```
┌─────────────────────────────────────────────────────────────────┐
│                     DISCOVERY LOOP                              │
│                                                                 │
│   EXPLORE ──> DOCUMENT ──> VALIDATE ──> REFINE ──>             │
│      │                                        │                 │
│      └────────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 1: EXPLORE
- Read codebase structure
- Identify domain concepts
- Map integrations and data flows
- Note patterns and anti-patterns

### Phase 2: DOCUMENT
- Write concept documentation
- Create API/contract summaries
- Document business rules
- Capture edge cases

### Phase 3: VALIDATE
- Cross-reference with tests
- Verify against actual behavior
- Check for gaps

### Phase 4: REFINE
- Update based on findings
- Plan next iteration
- Update progress tracking

## Tracking Files

Each documented module maintains:

```
docs/<module>/
├── README.md              # Module overview
├── features/              # Domain feature documentation
├── _gaps.md               # Known missing documentation
└── ...                    # Category-specific subdirs
```

## Iteration Cadence

1. **Per-session**: Pick one module or concept area
2. **Explore**: Investigate the codebase starting from entry points
3. **Document**: Capture findings immediately
4. **Track**: Update frontier.json and gaps
5. **Commit**: Save state for next iteration
