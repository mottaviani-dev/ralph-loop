# Prompt Assembly Pipeline

## Overview

The prompt assembly pipeline transforms static markdown templates into fully resolved prompts before each agent invocation. Templates live in `prompts/` with `{{placeholder}}` markers; the pipeline copies them to `_state/` at setup time, reads them at cycle start, substitutes variables from three prioritized sources, optionally appends runtime context (validation results, learnings), and passes the final string to `invoke_claude_agent()`.

## How It Works

```
prompts/*.md  ──(setup)──>  _state/*-prompt.md  ──(cat)──>  raw template string
                                                                 │
                                                      apply_prompt_vars()
                                                                 │
                                                    ┌────────────┴────────────────┐
                                                    │  1. Built-in variables      │
                                                    │  2. Config file variables   │
                                                    │  3. RALPH_VAR_* env vars    │
                                                    └────────────┬────────────────┘
                                                                 │
                                                     resolved prompt string
                                                                 │
                                              ┌──────────────────┴──────────────────┐
                                              │  Mode-specific enrichment (work):   │
                                              │  + validation results injection     │
                                              │  + LEARNINGS.md tail injection      │
                                              └──────────────────┬──────────────────┘
                                                                 │
                                                   invoke_claude_agent(prompt)
```

### Phase 1: Template Provisioning (Setup Time)

During `--setup` or `--auto-setup`, `lib/setup.sh` copies source templates into `_state/`:

| Source | Destination | Used by |
|--------|-------------|---------|
| `prompts/discovery.md` | `_state/prompt.md` | Discovery mode |
| `prompts/work.md` | `_state/work-prompt.md` | Work mode |
| `prompts/maintenance.md` | `_state/maintenance-prompt.md` | Maintenance mode |
| `prompts/refine.md` | `_state/refine-prompt.md` | Refine mode |

Templates are overwritten on each setup but not during normal cycles. Editing `prompts/*.md` requires re-running setup or manually copying to `_state/`.

### Phase 2: Variable Substitution (`apply_prompt_vars`)

`lib/common.sh:691` resolves `{{placeholder}}` markers using bash parameter expansion (`${prompt//pattern/replacement}`). Three variable sources are evaluated in strict priority order:

**1. Built-in variables** (applied first, cannot be overridden):

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{{state_dir}}` | Hardcoded `_state` | `_state` |
| `{{docs_dir}}` | `$DOCS_DIR` env var | `/path/to/project` |
| `{{model}}` | `$CLAUDE_MODEL` | `opus` |
| `{{mode}}` | Function argument | `work`, `discovery` |
| `{{cycle_num}}` | Function argument | `5` |
| `{{git_branch}}` | `git rev-parse --abbrev-ref HEAD` | `main` |
| `{{timestamp}}` | `date -u` (UTC ISO 8601) | `2026-03-28T12:00:00Z` |

**2. Config file variables** from `$DOCS_DIR/.ralph-loop.json`:

```json
{
  "variables": {
    "env": "staging",
    "app_name": "my-app"
  }
}
```

These resolve `{{env}}` and `{{app_name}}` in templates. Reserved built-in names are skipped. Variables that also have a `RALPH_VAR_*` counterpart are skipped (env wins).

**3. `RALPH_VAR_*` environment variables** (highest user priority):

`RALPH_VAR_project=acme` resolves `{{project}}`. Reserved names are blocked even here.

Unresolved placeholders are left intact — no empty-string replacement. There is no recursive expansion: if a variable's value contains `{{another}}`, it stays literal.

### Phase 3: Mode-Specific Enrichment

After `apply_prompt_vars` returns, each mode may append additional context:

**Work mode** (`lib/work.sh:449-491`) appends two optional sections:

1. **Validation results** — If `_state/last-validation-results.json` exists, its contents are appended as a fenced JSON block under a "PREVIOUS CYCLE VALIDATION RESULTS" header. The file is consumed (deleted) after injection.

2. **LEARNINGS.md** — If `$DOCS_DIR/LEARNINGS.md` exists and has >5 lines, the last 50 lines are appended under an "ACCUMULATED LEARNINGS" header, with instructions for the agent to maintain the file.

**Discovery and maintenance modes** pass the substituted prompt directly to `invoke_claude_agent()` without enrichment.

**Refine mode** (`lib/refine.sh:38-48`) strips YAML frontmatter from the template using `awk 'BEGIN{n=0} /^---$/{n++; next} n>=2'` before substitution, then appends a service-specific target section with the service name and docs folder path.

### Phase 4: Dry-Run Diagnostics

When `DRY_RUN=true`, the fully assembled prompt is saved to `_state/dry-run-prompt.md` and a diagnostic report is printed showing: mode, model, timeout, subagent count, CLI args, state files read, and validation commands. Claude is never invoked.

## Key Components

| File | Responsibility |
|------|---------------|
| `lib/common.sh:691` (`apply_prompt_vars`) | Core substitution engine — three-source priority resolution |
| `lib/setup.sh:233-268` | Template provisioning — copies `prompts/*.md` to `_state/` |
| `lib/work.sh:447-491` | Work mode assembly — substitution + validation/learnings injection |
| `lib/discovery.sh:36` | Discovery mode assembly — substitution only |
| `lib/maintenance.sh:51` | Maintenance mode assembly — substitution only |
| `lib/refine.sh:38-48` | Refine mode assembly — frontmatter strip + substitution + target append |
| `lib/common.sh:527` (`_print_dry_run_report`) | Dry-run diagnostic output |
| `tests/test_prompt_vars.sh` | 19-test suite covering all substitution behaviors |

## Design Decisions

**Bash parameter expansion over sed/awk for substitution.** Each `{{var}}` is resolved with `${prompt//\{\{var\}\}/value}`, keeping the entire operation in-process without spawning subprocesses per variable. This is fast and avoids regex escaping issues with sed on user-provided values.

**Three-tier priority with reserved names.** Built-ins are applied first and their names are blocklisted from config/env override. This prevents a malicious `.ralph-loop.json` or env var from redirecting `{{state_dir}}` to an arbitrary path. The priority chain (built-in > env > config) lets operators override project defaults without touching config files.

**Single-pass, no recursive expansion.** Each variable source does one substitution pass. If `RALPH_VAR_a={{state_dir}}`, resolving `{{a}}` produces the literal string `{{state_dir}}`, not `_state`. This prevents injection chains where a user-controlled value could trigger built-in substitution.

**Unresolved placeholders preserved.** Unknown `{{vars}}` stay in the prompt rather than being replaced with empty strings. This makes template errors visible in dry-run output and avoids silent prompt corruption.

**Templates copied at setup, not symlinked.** Setup copies rather than symlinks so that `_state/` is a self-contained snapshot. The agent could theoretically modify its own prompt in `_state/` (risky but possible for self-improvement), while `prompts/` stays as the canonical source.

## Related Docs

- [Agent Invocation & Timeout](../agent-invocation/invoke-and-timeout.md) — consumes the assembled prompt
- [Work Loop](../orchestration/work-loop.md) — work mode cycle that calls prompt assembly
- [Discovery Loop](../orchestration/discovery-loop.md) — discovery mode cycle
- [Maintenance Cycle](../orchestration/maintenance-cycle.md) — maintenance mode cycle
