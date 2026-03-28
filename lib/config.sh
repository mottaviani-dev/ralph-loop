#!/usr/bin/env bash
# lib/config.sh — project-level config file loader for ralph-loop
# Load priority: env vars > $DOCS_DIR/.ralph-loop.json > hardcoded defaults
# Sourced by run.sh immediately after DOCS_DIR is established.

# _apply_config_value CONFIG_PATH JQ_PATH VAR_NAME
# Assigns the jq-extracted value to VAR_NAME only if VAR_NAME is not already
# set in the environment (even if set to empty). Uses printf -v for bash 3.x
# indirect assignment compatibility.
_apply_config_value() {
    local config_path="$1" jq_path="$2" var_name="$3"
    # Skip: env var already set (including explicit empty)
    # shellcheck disable=SC2155
    local is_set="${!var_name+x}"
    [[ -z "$is_set" ]] || return 0

    local value
    # Use jq to check if the key exists and is not null, then extract the value.
    # We cannot use "// empty" because it treats JSON false as falsy.
    value="$(jq -r "if (${jq_path}) == null then \"__NULL__\" else (${jq_path} | tostring) end" "$config_path" 2>/dev/null)" || return 0
    [[ "$value" != "__NULL__" ]] || return 0
    [[ -n "$value" ]] || return 0

    printf -v "$var_name" '%s' "$value"
}

# _apply_config_notify_on CONFIG_PATH VAR_NAME
# Special-cases notify.on which may be a JSON array or a plain string.
_apply_config_notify_on() {
    local config_path="$1" var_name="$2"
    # shellcheck disable=SC2155
    local is_set="${!var_name+x}"
    [[ -z "$is_set" ]] || return 0

    local raw_type value
    raw_type="$(jq -r 'if has("notify") and (.notify | has("on")) then (.notify.on | type) else "null" end' "$config_path" 2>/dev/null)" || return 0
    [[ "$raw_type" != "null" ]] || return 0

    if [[ "$raw_type" == "array" ]]; then
        value="$(jq -r '.notify.on | join(",")' "$config_path" 2>/dev/null)" || return 0
    else
        value="$(jq -r '.notify.on' "$config_path" 2>/dev/null)" || return 0
    fi
    [[ -n "$value" ]] || return 0
    printf -v "$var_name" '%s' "$value"
}

# _apply_config_array CONFIG_PATH JQ_PATH VAR_NAME
# Extracts a JSON array to a space-delimited string and assigns to VAR_NAME.
_apply_config_array() {
    local config_path="$1" jq_path="$2" var_name="$3"
    # shellcheck disable=SC2155
    local is_set="${!var_name+x}"
    [[ -z "$is_set" ]] || return 0

    local value
    value="$(jq -r "(${jq_path} // []) | .[]" "$config_path" 2>/dev/null | tr '\n' ' ')" || return 0
    [[ -n "${value// /}" ]] || return 0  # skip if only whitespace

    printf -v "$var_name" '%s' "$value"
}

_KNOWN_CONFIG_KEYS="model timeout skip_commit skip_permissions max_work_cycles max_discovery_cycles max_consecutive_failures max_stale_cycles max_empty_task_cycles validate_before_commit validate_commands_strict use_agents discovery_only journal_keep_lines enable_mcp verbose_cleanup notify git_exclude"

# _warn_unknown_config_keys CONFIG_PATH
# Emits a warning for any top-level key not in the known-keys list.
_warn_unknown_config_keys() {
    local config_path="$1"
    local keys key
    keys="$(jq -r 'keys[]' "$config_path" 2>/dev/null)" || return 0

    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        if ! echo " $_KNOWN_CONFIG_KEYS " | grep -q " $key "; then
            echo "Warning: unknown key '$key' in .ralph-loop.json (ignored)" >&2
        fi
    done <<< "$keys"
}

# _warn_sensitive_config_fields CONFIG_PATH
# Nudges users away from committing secrets in the config file.
_warn_sensitive_config_fields() {
    local config_path="$1"
    local has_webhook
    has_webhook="$(jq -r 'if (.notify.webhook_url? // "") != "" then "yes" else "no" end' "$config_path" 2>/dev/null)" || return 0
    if [[ "$has_webhook" == "yes" ]]; then
        echo "Warning: .ralph-loop.json contains notify.webhook_url — consider using an env var or .env file for secrets instead" >&2
    fi
}

# load_project_config
# Main entry point. Called from run.sh after DOCS_DIR is set.
load_project_config() {
    local config_path="$DOCS_DIR/.ralph-loop.json"

    # No config file — silent no-op (backward compatible)
    [[ -f "$config_path" ]] || return 0

    # Guard: jq must be available (loader runs before check_dependencies)
    if ! command -v jq >/dev/null 2>&1; then
        echo "Warning: .ralph-loop.json found but jq is not installed; ignoring config file" >&2
        return 0
    fi

    # Validate JSON syntax — fail fast with clear error
    if ! jq empty "$config_path" 2>/dev/null; then
        echo "Error: .ralph-loop.json at '$config_path' is not valid JSON — fix or remove it to continue" >&2
        exit 1
    fi

    _warn_unknown_config_keys "$config_path"
    _warn_sensitive_config_fields "$config_path"

    # Scalar fields
    _apply_config_value "$config_path" ".model"                    "CLAUDE_MODEL"
    _apply_config_value "$config_path" ".timeout"                  "WORK_AGENT_TIMEOUT"
    _apply_config_value "$config_path" ".skip_commit"              "SKIP_COMMIT"
    _apply_config_value "$config_path" ".skip_permissions"         "SKIP_PERMISSIONS"
    _apply_config_value "$config_path" ".max_work_cycles"          "MAX_WORK_CYCLES"
    _apply_config_value "$config_path" ".max_discovery_cycles"     "MAX_DISCOVERY_CYCLES"
    _apply_config_value "$config_path" ".max_consecutive_failures" "MAX_CONSECUTIVE_FAILURES"
    _apply_config_value "$config_path" ".max_stale_cycles"         "MAX_STALE_CYCLES"
    _apply_config_value "$config_path" ".max_empty_task_cycles"    "MAX_EMPTY_TASK_CYCLES"
    _apply_config_value "$config_path" ".validate_before_commit"   "VALIDATE_BEFORE_COMMIT"
    _apply_config_value "$config_path" ".validate_commands_strict" "VALIDATE_COMMANDS_STRICT"
    _apply_config_value "$config_path" ".use_agents"               "USE_AGENTS"
    _apply_config_value "$config_path" ".discovery_only"           "DISCOVERY_ONLY"
    _apply_config_value "$config_path" ".journal_keep_lines"       "JOURNAL_KEEP_LINES"
    _apply_config_value "$config_path" ".enable_mcp"               "ENABLE_MCP"
    _apply_config_value "$config_path" ".verbose_cleanup"          "RALPH_VERBOSE_CLEANUP"

    # Nested notify fields
    _apply_config_value    "$config_path" ".notify.webhook_url"  "NOTIFY_WEBHOOK_URL"
    _apply_config_notify_on "$config_path"                       "NOTIFY_ON"

    # Array field: git_exclude -> RALPH_GIT_EXCLUDE (space-delimited)
    _apply_config_array "$config_path" ".git_exclude" "RALPH_GIT_EXCLUDE"
}
