# CLAUDE.md — ralph-loop

## Project Overview

Bash runner that orchestrates Claude Code agents in a continuous loop with filesystem-persisted state. Each cycle invokes `claude -p` with a prompt assembled from `prompts/` templates and injects runtime state via placeholder substitution.

Three modes: **discovery** (explore and document codebases), **work** (self-directed implementation cycles), **maintenance** (journal rotation, doc audit, state cleanup).

All project-specific context comes from the target repo's `CLAUDE.md` and `AGENT.md`, not from ralph-loop's prompts. The prompts are generic and project-agnostic.

## Architecture

| Component | Purpose |
|-----------|---------|
| `run.sh` | Main orchestrator (~1500 lines bash). All modes, argument parsing, state management, agent invocation, timeout handling, commit logic. |
| `fix-json.py` | JSON repair utility. Takes `<input_file> <output_file>` arguments. Stdlib Python 3 only (re, sys, json) — no pip dependencies. Fixes unescaped backslashes, missing commas between elements. |
| `lib/migrate.sh` | Schema version tracking and incremental migration for `_state/` files. Per-file migration functions, `migrate_all()` orchestrator, `prune_migration_backups()` cleanup. |
| `config/` | Template configs copied to `_state/` on setup: `modules.json`, `subagents.json`, `tasks.json`, `style-guide.md`. Optionally `mcp-servers.json` for MCP integration. |
| `prompts/` | Agent prompt templates: `discovery.md`, `work.md`, `maintenance.md`. Contains `{{state_dir}}` placeholder substituted at runtime with the actual `_state/` path. |
| `docs/` | Conceptual documentation: `ralph-loop.md` (paradigm), `discovery-process.md`, `state-directory.md` (state schema). |
| `lib/common.sh:invoke_claude_agent()` | Shared agent invocation: `build_claude_args`, temp-file management, `run_with_timeout`, exit-code mapping, globals `LAST_AGENT_OUTPUT/STATUS/DURATION`. Must never be called in a subshell (`$(invoke_claude_agent ...)`) — breaks `_cleanup_files` registration. |

### Runtime State (`_state/`)

**Runtime-generated directory** — created by `--setup` or `init_work_state()`. Not source-controlled (listed in `.gitignore`). State files are read at the start of each cycle and updated at the end. The runner copies templates from `config/` during setup and assembles prompts from `prompts/` at cycle start.

Key files:

| File | Purpose |
|------|---------|
| `work-state.json` | Cycle count, current task, last action/outcome, completion signal |
| `tasks.json` | Agent-managed task registry (copied from `config/tasks.json` on setup) |
| `journal.md` | Full cycle-by-cycle log — the agent's persistent memory |
| `config.json` | Module paths and service configuration |
| `work-prompt.md` | Assembled prompt with `{{state_dir}}` replaced — the actual prompt sent to `claude -p` |
| `prompt.md` | Assembled discovery prompt |
| `recipes/` | Reusable procedures discovered by the agent |
| `eval-findings.md` | Evaluation results from EVALUATE cycles |
| `last-validation-results.json` | Validation output injected into next cycle |
| `.ralph-loop.lock/pid` | Atomic directory lock preventing concurrent instances (auto-cleaned on exit) |

**Note:** `prompts/work.md` contains the literal `{{state_dir}}` placeholder. Agents reading the template directly will see the placeholder, not a real path. The substitution happens in `run.sh` when assembling the runtime prompt.

**Schema versioning:** All state files carry a `schema_version` integer field. Current versions are defined in `lib/migrate.sh` as `EXPECTED_*_VERSION` constants. Unversioned files (missing `schema_version`) are treated as version 0 and auto-migrated at startup. Backups are written to `<file>.pre-migrate.<timestamp>` before any mutation and pruned during `--maintenance` cycles (files older than 7 days).

**Journal rotation:** Work mode (`--work` / `--work-once`) triggers journal rotation after every cycle if `journal.md` exceeds `JOURNAL_MAX_LINES`. Additionally, if `_state/maintenance-prompt.md` is present, a full AI maintenance cycle runs every `MAINTENANCE_CYCLE_INTERVAL` work cycles (same interval as discovery mode).

## Prerequisites & Commands

**Dependencies:** `jq`, `claude` CLI (authenticated), Python 3, Git

| Command | Purpose |
|---------|---------|
| `./run.sh --once` | Single discovery cycle |
| `./run.sh --work-once` | Single work cycle |
| `./run.sh --work` | Continuous work loop until all tasks done/blocked |
| `./run.sh --maintenance` | Force maintenance cycle |
| `./run.sh --setup` | Initialize `_state/` directory with empty state files |
| `./run.sh --auto-setup` | Auto-detect sibling project modules + setup |
| `./run.sh --refine` | Refine all service docs (digests, compression, cross-refs) |
| `./run.sh --refine=SERVICE` | Refine a specific service |
| `./run.sh --commit` | Commit pending docs changes |
| `./run.sh --status` | Show discovery state |
| `./run.sh --work-status` | Show task progress summary |
| `./run.sh --summary` | Print aggregate cycle statistics from `cycle-log.json` |
| `./run.sh --migrate` | Migrate `_state/` files to current schema versions |
| `./run.sh --reset` | Reset all state files |
| `./run.sh --help` | Print usage and environment variable reference |

**Dry run (no commits):** `SKIP_COMMIT=true ./run.sh --work-once`

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DOCS_DIR` | Parent of `run.sh` | Target project root directory |
| `CLAUDE_MODEL` | `opus` | Model selection (`sonnet` for speed, `opus` for depth) |
| `SKIP_COMMIT` | `false` | Skip auto-commit after each cycle |
| `SKIP_PERMISSIONS` | `true` | Skip Claude CLI permission prompts |
| `WORK_AGENT_TIMEOUT` | `900` | Seconds per agent invocation (15 min) |
| `MAX_CONSECUTIVE_FAILURES` | `3` | Abort after N consecutive cycle failures |
| `MAX_STALE_CYCLES` | `5` | Abort after N cycles with zero git changes |
| `MAX_WORK_CYCLES` | `0` | Max work cycles; 0 = unlimited |
| `MAX_DISCOVERY_CYCLES` | `0` | Max discovery cycles; 0 = unlimited |
| `MAX_EMPTY_TASK_CYCLES` | `3` | Abort after N consecutive cycles with 0 total tasks |
| `VALIDATE_BEFORE_COMMIT` | `true` | Run validation before committing; skip commit on failure |
| `USE_AGENTS` | `true` | Enable specialist subagent delegation |
| `DISCOVERY_ONLY` | `false` | Skip maintenance cycles entirely |
| `ENABLE_MCP` | `false` | Enable MCP server integration (requires `config/mcp-servers.json`) |
| `JOURNAL_KEEP_LINES` | `300` | Lines retained after journal rotation (work mode); overridable via environment |
| `VALIDATE_COMMANDS_STRICT` | `false` | Block (not just warn) validation commands matching dangerous patterns |
| `VALIDATE_COMMANDS_ALLOWLIST` | _(unset)_ | Colon-separated ERE patterns; when set, only matching commands are permitted |
| `NOTIFY_WEBHOOK_URL` | _(unset)_ | HTTP endpoint for webhook notifications. When empty, all notifications are silently skipped. |
| `NOTIFY_ON` | `complete,error,stalemate,budget` | Comma-separated event filter. Valid tokens: `complete`, `error`, `stalemate`, `budget`, `cycle` (per-cycle verbose, opt-in). |
| `RALPH_VERBOSE_CLEANUP` | `false` | Log each PID killed and file removed during cleanup |
| `RALPH_BUDGET_LIMIT` | _(unset)_ | Stop loop after cumulative API spend reaches this amount (USD). Unset = unlimited. Requires `TRACK_TOKENS=true`. |
| `TRACK_TOKENS` | `true` | Enable per-cycle token/cost capture via `--output-format json` |

`MAINTENANCE_CYCLE_INTERVAL` is hardcoded to `10` in `run.sh` (not overridable via env).
`JOURNAL_MAX_LINES` is hardcoded to `500` in `run.sh` — rotation threshold for `journal.md`.

## Development Conventions

### Bash
- `set -e` at top of `run.sh` — all commands must handle errors properly
- macOS-safe `sed -i ''` — never use GNU `sed -i` (no space before `''` on macOS)
- Portable `awk` — no GNU-specific extensions
- Use `run_with_timeout()` shim for timeouts — GNU `timeout` is not available on macOS by default
- Use existing logging functions: `log`, `log_success`, `log_error`, `log_warn`
- New env vars follow the pattern: `VAR="${VAR:-default}"`
- New CLI flags must be added to both the argument parser `case` block and the `--help` output

### JSON
- All JSON manipulation via `jq` — never build JSON by string concatenation
- State files repaired automatically by `fix-json.py` when parsing fails

### Python
- Stdlib only — no pip dependencies, no third-party imports
- `fix-json.py` uses incremental regex passes — add new repair passes to the `fix_json()` function

### Prompts
- Use `{{state_dir}}` placeholder for all state directory paths — never hardcode `_state`
- Edit source files in `prompts/` — files in `_state/` are overwritten each cycle
- Edit config templates in `config/` — they are copied to `_state/` on setup

## Verification

Run the full test suite:
```bash
make test
```
This runs:
- `pytest tests/test_fix_json.py` — 53 tests + 3 expected failures for `fix-json.py`
- `bash tests/test_validate_env.sh` — `validate_env()` input validation
- `bash tests/test_commit_scoping.sh` — `commit_work_changes()` git pathspec exclusions
- `bash tests/test_pid_deregistration.sh` — `_deregister_cleanup_pids()` exact-match logic
- `bash tests/test_check_stalemate.sh` — `check_stalemate()` counter and abort logic
- `bash tests/test_work_loop.sh` — `work_loop_should_continue()` stop conditions
- `bash tests/test_discovery_loop.sh` — `discovery_loop_should_continue()` stop conditions
- `bash tests/test_arg_parsing.sh` — `run.sh` flag parsing smoke tests
- `bash tests/test_validation_safety.sh` — `_check_validation_cmd()` denylist/allowlist logic
- `bash tests/test_locking.sh` — `acquire_run_lock()` PID-file locking
- `bash tests/test_validation_exit_codes.sh` — exit code capture in validation pipeline
- `bash tests/test_migration.sh` — schema versioning and migration logic

**Static analysis:**
```bash
make lint   # runs shellcheck on run.sh, lib/*.sh, and tests/*.sh
```

**After changing `run.sh`:**
```bash
bash -n run.sh && make lint            # syntax + static analysis
make test                              # full suite
```

**After changing `fix-json.py`:**
```bash
python3 -m py_compile fix-json.py
make test-python
```

**After changing a prompt in `prompts/`:**
Run `SKIP_COMMIT=true ./run.sh --work-once` (or `--once`) and inspect `_state/work-prompt.md`.

## Extension Points

- **Adding a new run mode:** Add the flag to the argument parser section of `run.sh` -> add a `case` entry in the main dispatch -> implement the handler function -> add to `--help` output
- **Adding a config field:** Update the template in `config/modules.json` (or relevant config) -> update the `init_*` function that copies it to `_state/`
- **Modifying a prompt:** Edit the source file in `prompts/` — never edit `_state/work-prompt.md` directly, it is overwritten at the start of each work cycle
- **Adding a JSON repair pass:** Add a new regex substitution to `fix_json()` in `fix-json.py`, following the existing incremental pass pattern
- **Adding a schema migration:** Increment the relevant `EXPECTED_*_VERSION` constant in `lib/migrate.sh` → add a new `if [ "$from_version" -eq N ]; then` block in the corresponding `_migrate_*_step()` function → add a test case in `tests/test_migration.sh`. Also update the inline JSON literal in `init_work_state()` or `run_setup()` to reflect the new schema.
- **Adding a new state file:** Add `EXPECTED_<NAME>_VERSION=1` constant → `_migrate_<name>_step()` function → `migrate_<name>()` function → call from `migrate_all()` → add inline JSON with `"schema_version":1` to its creation site.

## Self-Development Warning

Running ralph-loop's work mode against the ralph-loop repo itself creates a circular reference. The agent reads this CLAUDE.md, then attempts to create and execute tasks for the ralph-loop project.

This is safe if tasks are scoped carefully, but can trigger runaway self-modification if the agent decides to "improve" `run.sh` or the prompts without explicit boundaries. Specific risks:
- Agent rewrites `run.sh` in ways that break the loop mid-execution
- Agent modifies `prompts/work.md`, changing its own instructions for subsequent cycles
- Agent removes safety features (timeout, stalemate detection) it perceives as obstacles

**Recommendation:** When running work mode against ralph-loop itself, seed `AGENT.md` with explicit, bounded requirements. Avoid open-ended goals like "improve the system."

## Security: Validation Command Execution

Validation commands in `tasks.json` are executed as the invoking user with full filesystem access (no kernel-level sandboxing on macOS). The runner inherits all environment variables, including `ANTHROPIC_API_KEY` and any secrets present in the shell environment. Working directory at execution time is `$DOCS_DIR` (target project root), which may contain `.env`, `*.pem`, or `*.key` files.

The `_check_validation_cmd()` function in `lib/work.sh` provides three defence layers:

1. **Audit logging** — every validation command is logged via `log_warn "VALIDATION EXEC: $cmd"` before execution.
2. **Denylist detection** — commands are checked against dangerous patterns (`rm -rf`, `curl`, `wget`, `eval`, `sudo`, `ssh`, `git push --force`, etc.).
   - **`VALIDATE_COMMANDS_STRICT=true`** blocks commands matching the denylist. Default is `false` (warn-only, backward-compatible).
3. **Allowlist filtering** — **`VALIDATE_COMMANDS_ALLOWLIST`** (colon-separated ERE patterns): when set, only matching commands are permitted. Example: `VALIDATE_COMMANDS_ALLOWLIST="^npm :^make :^pytest :^go test"`.

The denylist detects high-signal patterns but is not exhaustive. Pattern-based detection can be bypassed by a deliberately adversarial agent via obfuscation. For high-assurance environments, use `VALIDATE_COMMANDS_ALLOWLIST`.

**Recommendation:** Audit `_state/tasks.json` before running in environments with access to production credentials. See also `## Self-Development Warning` for ralph-loop-on-ralph-loop risks.

## Maintenance

Update this file whenever architecture, commands, conventions, or environment variables change.

`prompts/work.md` instructs the work agent to update CLAUDE.md at the end of every cycle — follow that instruction when working inside this repo. Keep entries factual, evidence-based, and concise. Remove or correct entries that become stale.
