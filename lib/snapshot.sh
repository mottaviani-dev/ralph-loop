#!/bin/bash
# lib/snapshot.sh — State snapshot and restore operations.
#
# Provides three functions:
#   run_snapshot [name]     — copy _state/ to _snapshots/<name>/ with metadata
#   run_restore <name>      — overwrite _state/ from a named snapshot
#   run_list_snapshots      — list available snapshots with metadata and sizes
#
# Dependencies: lib/common.sh (log*, iso_date, acquire_run_lock)
# Globals used: STATE_DIR, SNAPSHOTS_DIR, SNAPSHOT_RESTORE_YES

# run_snapshot — create a point-in-time copy of _state/.
# Uses atomic temp-dir-then-rename to prevent partial snapshots.
# No lock required — read-only copy of _state/.
run_snapshot() {
    local name="${1:-}"

    # Validate _state/ exists and is non-empty
    if [ ! -d "$STATE_DIR" ] || [ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
        log_error "Cannot snapshot: _state/ does not exist or is empty. Run --setup first."
        exit 1
    fi

    # Auto-generate name if not provided
    if [ -z "$name" ]; then
        name=$(date '+%Y%m%d-%H%M%S')
    fi

    # Validate name (filesystem-safe characters only)
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        log_error "Invalid snapshot name '$name'. Use only letters, numbers, hyphens, and underscores."
        exit 1
    fi

    # Reject duplicate names
    if [ -d "$SNAPSHOTS_DIR/$name" ]; then
        log_error "Snapshot '$name' already exists. Choose a different name or remove the existing snapshot."
        exit 1
    fi

    # Create snapshots directory
    mkdir -p "$SNAPSHOTS_DIR"

    # Copy state to temp directory (BSD-safe: no -a flag)
    local tmp_dir="$SNAPSHOTS_DIR/.tmp-$name"
    cp -r "$STATE_DIR" "$tmp_dir"

    # Extract cycle counts from state files (if present)
    local work_cycles=0
    local discovery_cycles=0
    local mode="unknown"

    if [ -f "$tmp_dir/work-state.json" ]; then
        work_cycles=$(jq -r '.cycle // .total_cycles // 0' "$tmp_dir/work-state.json" 2>/dev/null || echo "0")
    fi
    if [ -f "$tmp_dir/frontier.json" ]; then
        discovery_cycles=$(jq -r '.cycle_count // .total_cycles // 0' "$tmp_dir/frontier.json" 2>/dev/null || echo "0")
    fi

    # Determine mode based on which state files exist
    local has_work=false
    local has_discovery=false
    [ -f "$tmp_dir/work-state.json" ] && has_work=true
    [ -f "$tmp_dir/frontier.json" ] && has_discovery=true

    if [ "$has_work" = true ] && [ "$has_discovery" = true ]; then
        mode="both"
    elif [ "$has_work" = true ]; then
        mode="work"
    elif [ "$has_discovery" = true ]; then
        mode="discovery"
    fi

    # Write metadata file
    jq -n \
        --arg name "$name" \
        --arg timestamp "$(iso_date)" \
        --arg created_by "manual" \
        --argjson work_cycles "$work_cycles" \
        --argjson discovery_cycles "$discovery_cycles" \
        --arg mode "$mode" \
        '{name: $name, timestamp: $timestamp, created_by: $created_by, work_cycles: $work_cycles, discovery_cycles: $discovery_cycles, mode: $mode}' \
        > "$tmp_dir/.snapshot-meta.json"

    # Atomic rename
    mv "$tmp_dir" "$SNAPSHOTS_DIR/$name"

    log_success "Snapshot '$name' created at $SNAPSHOTS_DIR/$name"
}

# run_restore — overwrite _state/ from a named snapshot.
# Acquires the run lock to prevent concurrent loop modification.
run_restore() {
    local name="${1:-}"

    # Validate name provided
    if [ -z "$name" ]; then
        log_error "Usage: --restore=<name>"
        exit 1
    fi

    # Validate snapshot exists
    if [ ! -d "$SNAPSHOTS_DIR/$name" ]; then
        log_error "Snapshot '$name' not found."
        # List available snapshots if any exist
        if [ -d "$SNAPSHOTS_DIR" ]; then
            local available
            available=$(find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.tmp-*' -exec basename {} \; 2>/dev/null | sort)
            if [ -n "$available" ]; then
                log_error "Available snapshots:"
                echo "$available" | while read -r s; do
                    echo "  - $s"
                done
            fi
        fi
        exit 1
    fi

    # Acquire run lock to prevent concurrent modification
    acquire_run_lock

    # Confirmation prompt (unless SNAPSHOT_RESTORE_YES=true)
    if [ "$SNAPSHOT_RESTORE_YES" != "true" ]; then
        printf "Restore snapshot '%s'? This will overwrite _state/. [y/N] " "$name"
        local answer
        read -r answer < /dev/tty || answer=""
        case "$answer" in
            y|Y) ;;
            *)
                log "Restore cancelled."
                exit 0
                ;;
        esac
    fi

    # Remove current state and copy snapshot
    rm -rf "$STATE_DIR"
    cp -r "$SNAPSHOTS_DIR/$name" "$STATE_DIR"

    # Remove metadata file (belongs in snapshots, not state)
    rm -f "$STATE_DIR/.snapshot-meta.json"

    # Remove stale lock directory if copied from snapshot
    rm -rf "$STATE_DIR/.ralph-loop.lock"

    log_success "State restored from snapshot '$name'"
}

# run_list_snapshots — list available snapshots with metadata and sizes.
# Excludes partial .tmp-* directories from the listing.
run_list_snapshots() {
    # Check if snapshots directory exists and has subdirectories
    if [ ! -d "$SNAPSHOTS_DIR" ]; then
        echo "No snapshots found."
        return 0
    fi

    local snapshot_dirs
    snapshot_dirs=$(find "$SNAPSHOTS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.tmp-*' -exec basename {} \; 2>/dev/null | sort)

    if [ -z "$snapshot_dirs" ]; then
        echo "No snapshots found."
        return 0
    fi

    # Print table header
    printf "%-25s %-28s %-14s %-18s %s\n" "Name" "Timestamp" "Work Cycles" "Discovery Cycles" "Size"
    printf "%-25s %-28s %-14s %-18s %s\n" "----" "---------" "-----------" "----------------" "----"

    echo "$snapshot_dirs" | while read -r dir_name; do
        local meta_file="$SNAPSHOTS_DIR/$dir_name/.snapshot-meta.json"
        local timestamp="-"
        local work_cycles="-"
        local discovery_cycles="-"
        local size

        size=$(du -sh "$SNAPSHOTS_DIR/$dir_name" 2>/dev/null | cut -f1 | tr -d '[:space:]')

        if [ -f "$meta_file" ] && jq empty "$meta_file" 2>/dev/null; then
            timestamp=$(jq -r '.timestamp // "-"' "$meta_file" 2>/dev/null)
            work_cycles=$(jq -r '.work_cycles // "-"' "$meta_file" 2>/dev/null)
            discovery_cycles=$(jq -r '.discovery_cycles // "-"' "$meta_file" 2>/dev/null)
        else
            if [ ! -f "$meta_file" ]; then
                log_warn "Snapshot '$dir_name': missing .snapshot-meta.json"
            fi
        fi

        printf "%-25s %-28s %-14s %-18s %s\n" "$dir_name" "$timestamp" "$work_cycles" "$discovery_cycles" "$size"
    done
}
