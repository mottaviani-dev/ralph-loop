#!/bin/bash
# Test: snapshot/restore operations (RL-053)
# Usage: bash tests/test_snapshot.sh
# Exit 0 = all tests passed, Exit 1 = failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

enable_subshell_counters

# Source lib/common.sh with required globals
# shellcheck disable=SC2034
SKIP_CLAUDE_CHECK=1
_cleanup_pids=()
_cleanup_files=()

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/snapshot.sh
source "$SCRIPT_DIR/../lib/snapshot.sh"

# Temp dirs for test isolation
CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# Helper: create a minimal _state/ directory for testing
create_test_state() {
    local dir="$1"
    mkdir -p "$dir/_state"
    echo '{"total_cycles": 5}' > "$dir/_state/work-state.json"
    echo '{"total_cycles": 3, "cycle_count": 3}' > "$dir/_state/frontier.json"
    echo "# Test journal" > "$dir/_state/journal.md"
    echo '{"tasks": []}' > "$dir/_state/tasks.json"
}

# -----------------------------------------------------------------------
# Test 1: Snapshot creates directory with state files
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 1: Snapshot creates directory with state files ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
create_test_state "$tmpdir"

run_snapshot "test-snap" >/dev/null 2>&1

if [ -d "$SNAPSHOTS_DIR/test-snap" ]; then
    pass "Snapshot directory created"
else
    fail "Snapshot directory NOT created"
fi

if [ -f "$SNAPSHOTS_DIR/test-snap/work-state.json" ] && \
   [ -f "$SNAPSHOTS_DIR/test-snap/journal.md" ] && \
   [ -f "$SNAPSHOTS_DIR/test-snap/tasks.json" ]; then
    pass "State files copied to snapshot"
else
    fail "State files NOT copied to snapshot"
fi
)

# -----------------------------------------------------------------------
# Test 2: Auto-generated name format
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 2: Auto-generated name format ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
create_test_state "$tmpdir"

output=$(run_snapshot "" 2>&1)

# Find the auto-generated snapshot directory
auto_name=$(find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | head -1)

if echo "$auto_name" | grep -qE '^[0-9]{8}-[0-9]{6}$'; then
    pass "Auto-generated name matches YYYYMMDD-HHMMSS format ($auto_name)"
else
    fail "Auto-generated name does not match expected format" "Got: '$auto_name'"
fi
)

# -----------------------------------------------------------------------
# Test 3: Named snapshot --snapshot=my-name
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 3: Named snapshot ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
create_test_state "$tmpdir"

run_snapshot "my-name" >/dev/null 2>&1

if [ -d "$SNAPSHOTS_DIR/my-name" ]; then
    pass "Named snapshot 'my-name' created"
else
    fail "Named snapshot 'my-name' NOT created"
fi
)

# -----------------------------------------------------------------------
# Test 4: Metadata file written with expected fields
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 4: Metadata file written ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
create_test_state "$tmpdir"

run_snapshot "meta-test" >/dev/null 2>&1

meta_file="$SNAPSHOTS_DIR/meta-test/.snapshot-meta.json"
if [ -f "$meta_file" ]; then
    pass "Metadata file exists"
else
    fail "Metadata file NOT created"
fi

# Verify required fields
name_val=$(jq -r '.name' "$meta_file" 2>/dev/null)
assert_equals "Metadata name field" "$name_val" "meta-test"

timestamp_val=$(jq -r '.timestamp' "$meta_file" 2>/dev/null)
if [ -n "$timestamp_val" ] && [ "$timestamp_val" != "null" ]; then
    pass "Metadata has timestamp"
else
    fail "Metadata missing timestamp"
fi

created_by_val=$(jq -r '.created_by' "$meta_file" 2>/dev/null)
assert_equals "Metadata created_by field" "$created_by_val" "manual"

work_val=$(jq -r '.work_cycles' "$meta_file" 2>/dev/null)
if [ "$work_val" -ge 0 ] 2>/dev/null; then
    pass "Metadata has numeric work_cycles ($work_val)"
else
    fail "Metadata work_cycles not numeric" "Got: '$work_val'"
fi

mode_val=$(jq -r '.mode' "$meta_file" 2>/dev/null)
assert_equals "Metadata mode field (both work and discovery present)" "$mode_val" "both"
)

# -----------------------------------------------------------------------
# Test 5: Duplicate name rejected
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 5: Duplicate name rejected ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
create_test_state "$tmpdir"

run_snapshot "dup-test" >/dev/null 2>&1

exit_code=0
output=$(run_snapshot "dup-test" 2>&1) || exit_code=$?

assert_equals "Duplicate snapshot exits non-zero" "$exit_code" "1"
assert_contains "Error mentions already exists" "$output" "already exists"
)

# -----------------------------------------------------------------------
# Test 6: Invalid name rejected
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 6: Invalid name rejected ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
create_test_state "$tmpdir"

# Test names with spaces
exit_code=0
output=$(run_snapshot "bad name" 2>&1) || exit_code=$?
assert_equals "Name with space rejected" "$exit_code" "1"

# Test names with slashes
exit_code=0
output=$(run_snapshot "bad/name" 2>&1) || exit_code=$?
assert_equals "Name with slash rejected" "$exit_code" "1"

# Test names with dots
exit_code=0
output=$(run_snapshot "bad.name" 2>&1) || exit_code=$?
assert_equals "Name with dot rejected" "$exit_code" "1"
)

# -----------------------------------------------------------------------
# Test 7: Snapshot without _state/ fails
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 7: Snapshot without _state/ fails ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
# Do NOT create _state/

exit_code=0
output=$(run_snapshot "no-state" 2>&1) || exit_code=$?

assert_equals "Snapshot without _state/ exits non-zero" "$exit_code" "1"
assert_contains "Error mentions _state/" "$output" "_state/"
)

# -----------------------------------------------------------------------
# Test 8: Restore overwrites _state/
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 8: Restore overwrites _state/ ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
SNAPSHOT_RESTORE_YES=true
create_test_state "$tmpdir"

# Create snapshot
run_snapshot "restore-test" >/dev/null 2>&1

# Corrupt state
echo "corrupted" > "$STATE_DIR/work-state.json"

# Restore
run_restore "restore-test" >/dev/null 2>&1

# Verify state is back to original
content=$(cat "$STATE_DIR/work-state.json" 2>/dev/null)
if echo "$content" | jq -e '.total_cycles == 5' >/dev/null 2>&1; then
    pass "State restored to original content"
else
    fail "State NOT restored" "Got: $content"
fi
)

# -----------------------------------------------------------------------
# Test 9: Restore removes .snapshot-meta.json from _state/
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 9: Restore removes .snapshot-meta.json from _state/ ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
SNAPSHOT_RESTORE_YES=true
create_test_state "$tmpdir"

run_snapshot "meta-clean" >/dev/null 2>&1
run_restore "meta-clean" >/dev/null 2>&1

if [ ! -f "$STATE_DIR/.snapshot-meta.json" ]; then
    pass ".snapshot-meta.json removed from restored _state/"
else
    fail ".snapshot-meta.json still present in restored _state/"
fi
)

# -----------------------------------------------------------------------
# Test 10: Restore removes stale lock
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 10: Restore removes stale lock from restored state ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
SNAPSHOT_RESTORE_YES=true
create_test_state "$tmpdir"

# Create a lock directory inside _state/ before snapshotting
mkdir -p "$STATE_DIR/.ralph-loop.lock"
echo "12345" > "$STATE_DIR/.ralph-loop.lock/pid"

run_snapshot "lock-test" >/dev/null 2>&1

# Remove the lock from current state (so it doesn't interfere)
rm -rf "$STATE_DIR/.ralph-loop.lock"

# Restore — the lock from the snapshot should be removed
run_restore "lock-test" >/dev/null 2>&1

if [ ! -d "$STATE_DIR/.ralph-loop.lock" ]; then
    pass "Stale lock directory removed from restored state"
else
    fail "Stale lock directory still present in restored state"
fi
)

# -----------------------------------------------------------------------
# Test 11: Restore nonexistent snapshot fails
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 11: Restore nonexistent snapshot fails ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
SNAPSHOT_RESTORE_YES=true
create_test_state "$tmpdir"

exit_code=0
output=$(run_restore "does-not-exist" 2>&1) || exit_code=$?

assert_equals "Restore nonexistent snapshot exits non-zero" "$exit_code" "1"
assert_contains "Error mentions not found" "$output" "not found"
)

# -----------------------------------------------------------------------
# Test 12: List output includes metadata
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 12: List output includes metadata ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
create_test_state "$tmpdir"

# Create two snapshots
run_snapshot "snap-alpha" >/dev/null 2>&1
sleep 1
run_snapshot "snap-beta" >/dev/null 2>&1

output=$(run_list_snapshots 2>&1)

assert_contains "List shows snap-alpha" "$output" "snap-alpha"
assert_contains "List shows snap-beta" "$output" "snap-beta"
assert_contains "List shows Name header" "$output" "Name"
assert_contains "List shows Timestamp header" "$output" "Timestamp"
assert_contains "List shows Size header" "$output" "Size"
)

# -----------------------------------------------------------------------
# Test 13: List with no snapshots
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 13: List with no snapshots ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
SNAPSHOTS_DIR="$tmpdir/_snapshots"
# Do NOT create _snapshots/

output=$(run_list_snapshots 2>&1)

assert_contains "No snapshots message" "$output" "No snapshots found"
)

# -----------------------------------------------------------------------
# Test 14: .tmp-* dirs excluded from list
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 14: .tmp-* dirs excluded from list ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
create_test_state "$tmpdir"

# Create a real snapshot
run_snapshot "real-snap" >/dev/null 2>&1

# Create a partial .tmp- directory (simulating interrupted snapshot)
mkdir -p "$SNAPSHOTS_DIR/.tmp-partial"
echo '{}' > "$SNAPSHOTS_DIR/.tmp-partial/work-state.json"

output=$(run_list_snapshots 2>&1)

assert_contains "Real snapshot shown" "$output" "real-snap"
if echo "$output" | grep -qF ".tmp-partial"; then
    fail ".tmp-partial directory shown in listing"
else
    pass ".tmp-partial directory excluded from listing"
fi
)

# -----------------------------------------------------------------------
# Test 15: SNAPSHOT_RESTORE_YES=true skips prompt
# -----------------------------------------------------------------------
(
echo ""
echo "=== Test 15: SNAPSHOT_RESTORE_YES=true skips prompt ==="

tmpdir=$(mktemp -d)
CLEANUP_DIRS+=("$tmpdir")
STATE_DIR="$tmpdir/_state"
SNAPSHOTS_DIR="$tmpdir/_snapshots"
SNAPSHOT_RESTORE_YES=true
create_test_state "$tmpdir"

run_snapshot "prompt-skip" >/dev/null 2>&1

# Modify state
echo "modified" > "$STATE_DIR/journal.md"

# Restore with SNAPSHOT_RESTORE_YES=true (no tty needed)
exit_code=0
output=$(run_restore "prompt-skip" 2>&1) || exit_code=$?

assert_equals "Restore succeeds without tty" "$exit_code" "0"

content=$(cat "$STATE_DIR/journal.md" 2>/dev/null)
assert_equals "State restored correctly" "$content" "# Test journal"
)

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
print_summary "snapshot"
