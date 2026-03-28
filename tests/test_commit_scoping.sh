#!/bin/bash
# Test: commit_work_changes() scopes git add to exclude dangerous files
# Usage: bash tests/test_commit_scoping.sh
# Exit 0 = all tests passed, Exit 1 = failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Source WORK_GIT_EXCLUDE_DEFAULTS from run.sh (extract just the array definition)
eval "$(sed -n '/^WORK_GIT_EXCLUDE_DEFAULTS=(/,/)$/p' "$SCRIPT_DIR/../run.sh")"

# Source the shared helper from lib/work.sh
eval "$(sed -n '/^build_git_exclude_pathspecs()/,/^}/p' "$SCRIPT_DIR/../lib/work.sh")"

CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# -----------------------------------------------------------------------
# Helper: create a test git repo with a mix of safe and dangerous files
# -----------------------------------------------------------------------
setup_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"

    # Initial commit so HEAD exists
    echo "initial" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "init"

    # Safe: source file (tracked new)
    mkdir -p "$dir/src"
    echo "console.log('hello')" > "$dir/src/index.js"

    # Safe: project-root knowledge files
    echo "# Claude context" > "$dir/CLAUDE.md"
    echo "# Agent spec" > "$dir/AGENT.md"

    # DANGEROUS: .env
    echo "DB_PASSWORD=supersecret" > "$dir/.env"
    echo "API_KEY=abc123" > "$dir/.env.local"

    # DANGEROUS: _state/
    mkdir -p "$dir/_state"
    echo '{"cycle": 1}' > "$dir/_state/work-state.json"
    echo "# journal" > "$dir/_state/journal.md"
    echo '{}' > "$dir/_state/frontier.json.broken.1711929600"

    # DANGEROUS: .symphony-workspaces
    mkdir -p "$dir/.symphony-workspaces/agent-1"
    echo "worktree content" > "$dir/.symphony-workspaces/agent-1/file.txt"

    # DANGEROUS: OS artifact
    echo "" > "$dir/.DS_Store"

    # DANGEROUS: secret files
    echo "-----BEGIN RSA PRIVATE KEY-----" > "$dir/deploy.pem"
    echo "mysecret" > "$dir/credentials.key"
}

# -----------------------------------------------------------------------
# Helper: build the exclusion pathspec array using the shared helper
# from lib/work.sh (sourced above). No hardcoded patterns.
# -----------------------------------------------------------------------
build_exclude_args() {
    build_git_exclude_pathspecs
    # Return via global variable (bash 3.2 compatible)
    EXCLUDE_ARGS=("${GIT_EXCLUDE_PATHSPECS[@]}")
}

# -----------------------------------------------------------------------
# Helper: run git add with the PROPOSED exclusion pathspec
# -----------------------------------------------------------------------
run_scoped_git_add() {
    local repo="$1"
    cd "$repo"

    build_exclude_args
    git add -A -- "${EXCLUDE_ARGS[@]}" 2>/dev/null
}

# -----------------------------------------------------------------------
# Helper: run CURRENT broken behavior (git add -A)
# -----------------------------------------------------------------------
run_unscoped_git_add() {
    local repo="$1"
    cd "$repo"
    git add -A 2>/dev/null
}

# -----------------------------------------------------------------------
# Test A: Current behavior — git add -A stages dangerous files (confirms bug)
# -----------------------------------------------------------------------
echo ""
echo "=== Test A: Current behavior (git add -A) stages dangerous files ==="

TMPDIR_A=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_A")

setup_repo "$TMPDIR_A"
run_unscoped_git_add "$TMPDIR_A"

staged=$(git -C "$TMPDIR_A" diff --cached --name-only)

if echo "$staged" | grep -q "^\.env$"; then
    pass ".env IS staged (confirms the bug exists)"
else
    fail ".env was NOT staged — behavior may have changed"
fi

if echo "$staged" | grep -q "_state/"; then
    pass "_state/ files ARE staged (confirms the bug exists)"
else
    fail "_state/ files were NOT staged"
fi

# -----------------------------------------------------------------------
# Test B: Scoped behavior — dangerous files are NOT staged
# -----------------------------------------------------------------------
echo ""
echo "=== Test B: Scoped git add — dangerous files excluded ==="

TMPDIR_B=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_B")
setup_repo "$TMPDIR_B"
run_scoped_git_add "$TMPDIR_B"

staged_b=$(git -C "$TMPDIR_B" diff --cached --name-only)

# Should NOT be staged
for dangerous in ".env" ".env.local" "_state/work-state.json" "_state/journal.md" \
    "_state/frontier.json.broken.1711929600" ".symphony-workspaces/agent-1/file.txt" \
    ".DS_Store" "deploy.pem" "credentials.key"; do
    if echo "$staged_b" | grep -qF "$dangerous"; then
        fail "Dangerous file WAS staged: $dangerous"
    else
        pass "Dangerous file NOT staged: $dangerous"
    fi
done

# Should BE staged
for safe in "src/index.js" "CLAUDE.md" "AGENT.md"; do
    if echo "$staged_b" | grep -qF "$safe"; then
        pass "Safe file WAS staged: $safe"
    else
        fail "Safe file NOT staged (data loss): $safe"
    fi
done

# -----------------------------------------------------------------------
# Test C: RALPH_GIT_EXCLUDE env var adds user-defined exclusions
# -----------------------------------------------------------------------
echo ""
echo "=== Test C: RALPH_GIT_EXCLUDE extends exclusion list ==="

TMPDIR_C=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_C")
setup_repo "$TMPDIR_C"

# Add a custom dangerous file
echo "custom secret" > "$TMPDIR_C/my-custom-secret.txt"

# Run with env var extension
cd "$TMPDIR_C"
build_exclude_args
EXCLUDE_ARGS+=(":(exclude)my-custom-secret.txt")

git add -A -- "${EXCLUDE_ARGS[@]}" 2>/dev/null
staged_c=$(git -C "$TMPDIR_C" diff --cached --name-only)

if echo "$staged_c" | grep -qF "my-custom-secret.txt"; then
    fail "Custom exclusion file WAS staged — RALPH_GIT_EXCLUDE ignored"
else
    pass "Custom exclusion file NOT staged — RALPH_GIT_EXCLUDE honored"
fi

# -----------------------------------------------------------------------
# Test D: Untracked warning filter excludes the right files
# -----------------------------------------------------------------------
echo ""
echo "=== Test D: Untracked warning filter via git ls-files with pathspecs ==="

TMPDIR_D=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_D")
setup_repo "$TMPDIR_D"

cd "$TMPDIR_D"
build_exclude_args

# git ls-files --others --exclude-standard with :(exclude) pathspecs should
# filter out all dangerous files, leaving only safe untracked files.
remaining=$(git ls-files --others --exclude-standard -- "${EXCLUDE_ARGS[@]}" 2>/dev/null)

# Safe files should appear in the remaining list
for safe in "src/index.js" "CLAUDE.md" "AGENT.md"; do
    if echo "$remaining" | grep -qF "$safe"; then
        pass "Untracked safe file IS reported: $safe"
    else
        fail "Untracked safe file NOT reported: $safe"
    fi
done

# Dangerous files should NOT appear
for dangerous in "_state/work-state.json" "_state/journal.md" ".env" ".env.local" \
    ".symphony-workspaces/agent-1/file.txt" ".DS_Store" "deploy.pem" "credentials.key"; do
    if echo "$remaining" | grep -qF "$dangerous"; then
        fail "Excluded file IS reported as untracked: $dangerous"
    else
        pass "Excluded file NOT reported: $dangerous"
    fi
done

# Test that *.broken.* files are excluded
echo "data" > "$TMPDIR_D/_state/frontier.json.broken.1711929600"
remaining2=$(git ls-files --others --exclude-standard -- "${EXCLUDE_ARGS[@]}" 2>/dev/null)
if echo "$remaining2" | grep -qF "broken"; then
    fail "*.broken.* file IS reported as untracked"
else
    pass "*.broken.* file NOT reported"
fi

# -----------------------------------------------------------------------
# Test E: RALPH_GIT_EXCLUDE user patterns are honored in untracked filter
# -----------------------------------------------------------------------
echo ""
echo "=== Test E: RALPH_GIT_EXCLUDE suppresses custom patterns in untracked filter ==="

TMPDIR_E=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_E")
setup_repo "$TMPDIR_E"

# Add a custom file that should be excluded via RALPH_GIT_EXCLUDE
echo "custom build artifact" > "$TMPDIR_E/build.custom"

cd "$TMPDIR_E"

# Without RALPH_GIT_EXCLUDE, build.custom should appear
build_exclude_args
remaining_no_custom=$(git ls-files --others --exclude-standard -- "${EXCLUDE_ARGS[@]}" 2>/dev/null)
if echo "$remaining_no_custom" | grep -qF "build.custom"; then
    pass "build.custom IS reported without RALPH_GIT_EXCLUDE"
else
    fail "build.custom NOT reported without RALPH_GIT_EXCLUDE"
fi

# With RALPH_GIT_EXCLUDE, build.custom should be suppressed
# shellcheck disable=SC2034 # consumed by build_exclude_args from sourced lib
RALPH_GIT_EXCLUDE="*.custom"
build_exclude_args
remaining_with_custom=$(git ls-files --others --exclude-standard -- "${EXCLUDE_ARGS[@]}" 2>/dev/null)
unset RALPH_GIT_EXCLUDE

if echo "$remaining_with_custom" | grep -qF "build.custom"; then
    fail "build.custom IS reported WITH RALPH_GIT_EXCLUDE — user pattern ignored"
else
    pass "build.custom NOT reported WITH RALPH_GIT_EXCLUDE — user pattern honored"
fi

# -----------------------------------------------------------------------
# Test F: No over-broad matching (regression check)
# -----------------------------------------------------------------------
echo ""
echo "=== Test F: No over-broad matching ==="

TMPDIR_F=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_F")
git init -q "$TMPDIR_F"
git -C "$TMPDIR_F" config user.email "test@example.com"
git -C "$TMPDIR_F" config user.name "Test"
echo "initial" > "$TMPDIR_F/README.md"
git -C "$TMPDIR_F" add README.md
git -C "$TMPDIR_F" commit -q -m "init"

# Files that should NOT be excluded (names contain key/secret/pem but don't match *.key etc.)
echo "data" > "$TMPDIR_F/monkey"
echo "data" > "$TMPDIR_F/donkey"
echo "data" > "$TMPDIR_F/mysecret"

cd "$TMPDIR_F"
build_exclude_args
remaining_f=$(git ls-files --others --exclude-standard -- "${EXCLUDE_ARGS[@]}" 2>/dev/null)

for safe in "monkey" "donkey" "mysecret"; do
    if echo "$remaining_f" | grep -qF "$safe"; then
        pass "Non-excluded file IS reported: $safe (no over-broad matching)"
    else
        fail "Non-excluded file NOT reported: $safe (over-broad matching regression)"
    fi
done

# -----------------------------------------------------------------------
# Test G: JSON-sourced RALPH_GIT_EXCLUDE (simulates load_project_config)
# -----------------------------------------------------------------------
echo ""
echo "=== Test G: JSON-sourced git_exclude via RALPH_GIT_EXCLUDE ==="

TMPDIR_G=$(mktemp -d)
CLEANUP_DIRS+=("$TMPDIR_G")
setup_repo "$TMPDIR_G"

# Add files matching JSON-sourced git_exclude patterns
mkdir -p "$TMPDIR_G/vendor/pkg"
echo "vendored" > "$TMPDIR_G/vendor/pkg/dep.js"
echo "lockfile" > "$TMPDIR_G/composer.lock"

cd "$TMPDIR_G"
# Simulate what load_project_config sets from {"git_exclude": ["vendor/", "*.lock"]}
# shellcheck disable=SC2034 # consumed by build_exclude_args from sourced lib
RALPH_GIT_EXCLUDE="vendor/ *.lock "
build_exclude_args
git add -A -- "${EXCLUDE_ARGS[@]}" 2>/dev/null
staged_g=$(git -C "$TMPDIR_G" diff --cached --name-only)
unset RALPH_GIT_EXCLUDE

if echo "$staged_g" | grep -q "vendor/"; then
    fail "vendor/ WAS staged — JSON-sourced git_exclude ignored"
else
    pass "vendor/ NOT staged — JSON-sourced git_exclude honored"
fi

if echo "$staged_g" | grep -q "\.lock$"; then
    fail "*.lock WAS staged — JSON-sourced git_exclude ignored"
else
    pass "*.lock NOT staged — JSON-sourced git_exclude honored"
fi

# Safe files should still be staged
if echo "$staged_g" | grep -qF "src/index.js"; then
    pass "Safe file src/index.js still staged"
else
    fail "Safe file src/index.js NOT staged (data loss)"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
print_summary "commit_scoping"
