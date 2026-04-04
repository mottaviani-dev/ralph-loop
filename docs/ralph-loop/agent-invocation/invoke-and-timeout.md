# Agent Invocation and Timeout

## Overview

Every mode in ralph-loop (work, discovery, maintenance, refine) invokes the Claude CLI through a single shared function: `invoke_claude_agent()`. This function handles CLI argument construction, subprocess timeout enforcement, output parsing (including token/cost extraction from JSON envelopes), and exposes results via global variables. It is the only code path that calls the `claude` binary.

## How It Works

```
Caller (work/discovery/maintenance/refine)
  |
  v
invoke_claude_agent(prompt, label, timeout?)
  |
  +-- 1. build_claude_args()        → populates CLAUDE_ARGS[] array
  +-- 2. mktemp output_file         → registered in _cleanup_files[]
  +-- 3. run_with_timeout(timeout, claude CLAUDE_ARGS... prompt)
  |       |
  |       +-- Runs `claude` in background
  |       +-- Spawns watchdog subprocess (SIGTERM after N sec, SIGKILL after N+10)
  |       +-- Registers both PIDs in _cleanup_pids[]
  |       +-- wait for claude → capture exit code
  |       +-- Kill watchdog → deregister PIDs
  |       +-- Return: 0 (success), 124 (timeout), or original exit code
  |
  +-- 4. Map exit code → LAST_AGENT_STATUS
  |       0   → "success"
  |       124 → "timeout"
  |       *   → "failed"
  |
  +-- 5. Parse output (TRACK_TOKENS branch)
  |       JSON mode: extract .result, .total_cost_usd, .usage.*
  |       Plain mode: use raw output as-is
  |
  +-- 6. Set LAST_AGENT_DURATION (elapsed seconds)
  +-- Return 0 always (callers check LAST_AGENT_STATUS)
```

### CLI Argument Construction

`build_claude_args()` (line 399) assembles the `CLAUDE_ARGS` array:

| Flag | Condition | Purpose |
|------|-----------|---------|
| `-p` | Always | Prompt mode (non-interactive) |
| `--model MODEL` | Always | Model selection from `$CLAUDE_MODEL` |
| `--dangerously-skip-permissions` | `SKIP_PERMISSIONS=true` | Bypass permission prompts |
| `--output-format json` | `TRACK_TOKENS=true` | JSON envelope with usage metadata |
| `--mcp-config FILE` | `ENABLE_MCP=true` + file exists | MCP server integration |
| `--agents JSON` | `USE_AGENTS=true` + file exists | Specialist subagent delegation |

The `--agents` flag is added by `invoke_claude_agent` itself (not `build_claude_args`), conditional on `USE_AGENTS=true` and `$SUBAGENTS_FILE` existing. It passes the file contents inline via `$(cat "$SUBAGENTS_FILE")`.

### Timeout Mechanism

`run_with_timeout()` (line 145) implements a portable macOS-compatible timeout since GNU `timeout` is not available by default:

1. Runs the command (`claude ...`) in the background, captures `cmd_pid`
2. Spawns a watchdog subshell that:
   - Sleeps for `$timeout` seconds
   - Sends SIGTERM to `cmd_pid`
   - Waits 10 more seconds, then sends SIGKILL if still alive
3. Both `cmd_pid` and `watchdog_pid` are registered in `_cleanup_pids[]` for the EXIT trap
4. Waits for `cmd_pid` to finish, captures exit code
5. Kills the watchdog and its children, deregisters both PIDs via `_deregister_cleanup_pids()`
6. Maps signal-killed exit codes (143=SIGTERM, 137=SIGKILL) to exit code 124 (conventional "timed out")
7. Timeout of 0 or negative disables the mechanism entirely (runs command directly)

### Subshell Prohibition

`invoke_claude_agent` must never be called in a subshell:

```bash
invoke_claude_agent "$prompt" "Label"     # CORRECT
out=$(invoke_claude_agent "$prompt" ...)  # WRONG
```

The reason: `_cleanup_files+=("$output_file")` modifies a global array. In a subshell, this modification is invisible to the parent process, so temp files and the EXIT trap's `_do_cleanup()` function won't know about them. This is explicitly documented in the function header and enforced by convention.

### Token and Cost Extraction

When `TRACK_TOKENS=true` (the default), Claude outputs a JSON envelope instead of plain text. `invoke_claude_agent` parses this to populate:

| Global | Source | Description |
|--------|--------|-------------|
| `LAST_AGENT_OUTPUT` | `.result` | Agent's text output |
| `LAST_AGENT_COST` | `.total_cost_usd` | API cost in USD |
| `LAST_AGENT_INPUT_TOKENS` | `.usage.input_tokens` | Input token count |
| `LAST_AGENT_OUTPUT_TOKENS` | `.usage.output_tokens` | Output token count |
| `LAST_AGENT_CACHE_READ` | `.usage.cache_read_input_tokens` | Cache hit tokens |
| `LAST_AGENT_CACHE_CREATED` | `.usage.cache_creation_input_tokens` | Cache write tokens |

If JSON parsing fails (malformed output, timeout mid-stream), the raw output is used as-is and token globals remain empty strings. This fallback ensures callers always get something in `LAST_AGENT_OUTPUT`.

### Caller Pattern

All four modes follow an identical pattern after invocation:

```bash
invoke_claude_agent "$prompt" "Label"
local output="$LAST_AGENT_OUTPUT"
local status="$LAST_AGENT_STATUS"
local duration="$LAST_AGENT_DURATION"
```

Then each caller:
1. Appends output to `journal.md` with duration/status/model metadata
2. Logs a cycle entry to `cycle-log.json` (with token data when available)
3. Handles mode-specific post-processing (validation, commits, state updates)

## Key Components

| File | Responsibility |
|------|---------------|
| `lib/common.sh:399-412` | `build_claude_args()` — CLI argument assembly |
| `lib/common.sh:451-522` | `invoke_claude_agent()` — shared invocation, output parsing, status mapping |
| `lib/common.sh:145-190` | `run_with_timeout()` — portable timeout with watchdog subprocess |
| `lib/common.sh:131-139` | `_deregister_cleanup_pids()` — exact-match PID array cleanup |
| `lib/cleanup.sh:13-83` | `_do_cleanup()` — EXIT trap that kills registered PIDs and removes temp files |
| `tests/test_invoke_claude_agent.sh` | 7 unit tests covering status mapping, output capture, --agents flag, custom timeout, missing args |

## Design Decisions

**Single invocation path**: All modes share one function rather than each implementing their own `claude` call. This ensures consistent argument handling, timeout behavior, and token tracking across work, discovery, maintenance, and refine modes. The trade-off is that the function communicates via globals (not return values), but this is forced by the subshell prohibition.

**Globals over return values**: Using `LAST_AGENT_*` globals avoids the need for subshell capture (`$(invoke_claude_agent ...)`), which would break `_cleanup_files` registration. This is an intentional design constraint documented in the function header.

**Portable timeout**: macOS does not ship GNU `timeout`. Rather than requiring a Homebrew dependency, `run_with_timeout` implements the same behavior with background processes and a watchdog. The 10-second grace period between SIGTERM and SIGKILL matches common daemon shutdown conventions.

**PID deregistration**: After `run_with_timeout` completes, both the command PID and watchdog PID are explicitly removed from `_cleanup_pids[]` via `_deregister_cleanup_pids()`. This prevents the EXIT trap from attempting to kill reused PIDs in long-running loops.

**Graceful token parsing fallback**: The JSON parsing uses `jq -r '.result // empty'` with `|| true` to handle malformed output. If the agent times out mid-response or produces non-JSON output, callers still get the raw text. Token globals default to empty strings (not zeros), allowing callers to distinguish "no data" from "zero cost".

## Related Docs

- [Work Loop Orchestration](../orchestration/work-loop.md) — primary consumer of `invoke_claude_agent`
- [Discovery Loop](../orchestration/discovery-loop.md) — discovery mode invocation pattern
- [Maintenance Cycle](../orchestration/maintenance-cycle.md) — maintenance mode invocation pattern
