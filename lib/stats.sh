#!/bin/bash
# lib/stats.sh — Cycle statistics reporting.
#
# Dependencies: jq
# Globals used: CYCLE_LOG_FILE

# show_summary: print aggregate statistics from cycle-log.json.
# Read-only — no locks, no env validation required.
# Called from run.sh dispatch: summary) show_summary ;;
show_summary() {
    if [ ! -f "$CYCLE_LOG_FILE" ]; then
        echo "No cycle data. Run --setup first."
        return
    fi

    local cycle_count
    cycle_count=$(jq '.cycles | length' "$CYCLE_LOG_FILE" 2>/dev/null || echo "0")
    if [ "$cycle_count" = "0" ]; then
        echo "No cycles recorded yet."
        return
    fi

    echo ""
    echo "┌──────────────────────────────────────────────────┐"
    echo "│  Cycle Summary                                    │"
    echo "└──────────────────────────────────────────────────┘"
    echo ""

    jq -r '
      .cycles |
      {
        total: length,
        by_type:   (group_by(.type)   | map({key: .[0].type,   value: length}) | from_entries),
        by_status: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
        by_model:  ([.[] | .model // "unknown"] | group_by(.) | map({key: .[0], value: length}) | from_entries),
        total_s:   (map(.duration_seconds) | add),
        avg_s:     (map(.duration_seconds) | add / length | floor),
        p95_s:     (sort_by(.duration_seconds) | .[(length * 0.95 | floor)] // .[-1] | .duration_seconds),
        min_s:     (min_by(.duration_seconds) | .duration_seconds),
        max_s:     (max_by(.duration_seconds) | .duration_seconds)
      } |
      "Total cycles : \(.total)\n" +
      "By type:\n" +
      (.by_type | to_entries | map("  \(.key): \(.value)") | join("\n")) + "\n" +
      "By status:\n" +
      (.by_status | to_entries | map("  \(.key): \(.value)") | join("\n")) + "\n" +
      "By model:\n" +
      (.by_model | to_entries | map("  \(.key): \(.value)") | join("\n")) + "\n" +
      "\nDuration:\n" +
      "  Total   : \(.total_s)s (\(.total_s / 3600 * 100 | floor / 100)h)\n" +
      "  Average : \(.avg_s)s\n" +
      "  p95     : \(.p95_s)s\n" +
      "  Min     : \(.min_s)s\n" +
      "  Max     : \(.max_s)s\n" +
      "\nThroughput  : \(if .total_s > 0 then (.total / (.total_s / 3600) * 100 | floor / 100) else 0 end) cycles/hour"
    ' "$CYCLE_LOG_FILE"
    echo ""
}
