# Discovery Process

Iterative process for documenting a codebase through automated exploration.

## Loop Structure

Each service goes through this cycle:

```
┌─────────────────────────────────────────────────────────────────┐
│                     DISCOVERY LOOP                              │
│                                                                 │
│   EXPLORE ──► DOCUMENT ──► VALIDATE ──► REFINE ──►             │
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
- Review with team knowledge
- Check for gaps

### Phase 4: REFINE
- Update based on findings
- Plan next iteration
- Update progress tracking

## Tracking Files

Each service maintains:

```
<service>/
├── README.md              # Service overview
├── authentication/        # Auth & security documentation
├── data-reporting/        # Import/export, reporting, email templates
├── development-standards/ # Architecture, patterns, testing
├── features/              # Domain feature documentation (by category)
├── infrastructure/        # Deployment, caching, queues, logging
├── integrations/          # Third-party service integrations
└── _gaps.md               # Known missing documentation
```

## Iteration Cadence

1. **Per-session**: Pick one service or concept area
2. **Explore**: Investigate the codebase
3. **Document**: Capture findings immediately
4. **Track**: Update progress and gaps
5. **Commit**: Save state for next iteration
