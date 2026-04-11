#!/bin/bash
#
# metrics-report.sh — aggregate cycles.jsonl into a development-cycle
# effectiveness report. Used to objectively evaluate whether the test
# harness is delivering the expected speedup over device-only testing.
#
# Tracks the metrics that matter:
#
#   1. Wall-clock per cycle (lower is better — direct measure of speedup)
#   2. Realtime ratio (wall clock / audio duration — <1.0 is faster than realtime)
#   3. Success rate (% of scenarios that completed without error)
#   4. Total scenarios run today / this week (throughput)
#   5. Per-scenario averages (catch slow regressions)
#
# Usage:
#   ./metrics-report.sh                  # all-time summary
#   ./metrics-report.sh today            # only today's runs
#   ./metrics-report.sh week             # last 7 days
#

set -euo pipefail

if [[ -n "${SAM_TESTKIT_ROOT:-}" ]]; then
    TESTKIT_ROOT="$SAM_TESTKIT_ROOT"
elif [[ -d "$HOME/Library/Containers/sam.SAM/Data/Documents/SAM-TestKit" ]]; then
    TESTKIT_ROOT="$HOME/Library/Containers/sam.SAM/Data/Documents/SAM-TestKit"
else
    TESTKIT_ROOT="$HOME/Documents/SAM-TestKit"
fi
METRICS_FILE="$TESTKIT_ROOT/metrics/cycles.jsonl"

if [[ ! -f "$METRICS_FILE" ]]; then
    echo "No metrics file found at $METRICS_FILE" >&2
    echo "Run a test first: ./run-test.sh <scenario-name>" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required. Install: brew install jq" >&2
    exit 1
fi

SCOPE="${1:-all}"

case "$SCOPE" in
    today)
        SINCE=$(date -u +"%Y-%m-%dT00:00:00Z")
        FILTER=". | select(.timestamp >= \"$SINCE\")"
        SCOPE_LABEL="today"
        ;;
    week)
        SINCE=$(date -u -v-7d +"%Y-%m-%dT00:00:00Z" 2>/dev/null || date -u --date="7 days ago" +"%Y-%m-%dT00:00:00Z")
        FILTER=". | select(.timestamp >= \"$SINCE\")"
        SCOPE_LABEL="last 7 days"
        ;;
    all|*)
        FILTER="."
        SCOPE_LABEL="all-time"
        ;;
esac

TOTAL=$(jq -c "$FILTER" "$METRICS_FILE" | wc -l | tr -d ' ')
SUCCESSES=$(jq -c "$FILTER | select(.success == true)" "$METRICS_FILE" | wc -l | tr -d ' ')
FAILURES=$(jq -c "$FILTER | select(.success == false)" "$METRICS_FILE" | wc -l | tr -d ' ')

if [[ "$TOTAL" -eq 0 ]]; then
    echo "No cycles in scope '$SCOPE_LABEL'" >&2
    exit 0
fi

SUCCESS_RATE=$(awk -v s=$SUCCESSES -v t=$TOTAL 'BEGIN { printf "%.1f", (s/t)*100 }')

AVG_WALL_CLOCK=$(jq -c "$FILTER | select(.success == true) | .wallClockSeconds" "$METRICS_FILE" \
    | awk '{ total += $1; count++ } END { if (count > 0) printf "%.1f", total/count; else print "0" }')

AVG_RATIO=$(jq -c "$FILTER | select(.success == true) | .realtimeRatio" "$METRICS_FILE" \
    | awk '{ total += $1; count++ } END { if (count > 0) printf "%.2f", total/count; else print "0" }')

MIN_WALL=$(jq -c "$FILTER | select(.success == true) | .wallClockSeconds" "$METRICS_FILE" | sort -n | head -1)
MAX_WALL=$(jq -c "$FILTER | select(.success == true) | .wallClockSeconds" "$METRICS_FILE" | sort -n | tail -1)

echo "════════════════════════════════════════════════════════════"
echo "  SAM Test Harness — Effectiveness Report ($SCOPE_LABEL)"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Total cycles:    $TOTAL"
echo "  Succeeded:       $SUCCESSES"
echo "  Failed:          $FAILURES"
echo "  Success rate:    ${SUCCESS_RATE}%"
echo ""
echo "  Wall clock per cycle (successes only)"
echo "    Average:       ${AVG_WALL_CLOCK}s"
echo "    Fastest:       ${MIN_WALL}s"
echo "    Slowest:       ${MAX_WALL}s"
echo "    vs. realtime:  ${AVG_RATIO}× (lower is better)"
echo ""

DEVICE_CYCLE_SECONDS=900
if [[ "$AVG_WALL_CLOCK" != "0" ]] && [[ "$AVG_WALL_CLOCK" != "0.0" ]]; then
    SPEEDUP=$(awk -v d=$DEVICE_CYCLE_SECONDS -v h=$AVG_WALL_CLOCK 'BEGIN { printf "%.1f", d/h }')
    echo "  Estimated speedup vs. device-only cycle (15 min baseline):"
    echo "    ${SPEEDUP}× faster per scenario"
    echo ""
fi

echo "  Per-scenario averages:"
jq -c "$FILTER | select(.success == true)" "$METRICS_FILE" \
    | jq -r '.scenarioID + "\t" + (.wallClockSeconds|tostring)' \
    | awk -F'\t' '
        { totals[$1] += $2; counts[$1]++ }
        END {
            for (k in totals) {
                printf "    %-30s  %5.1fs avg (%d run%s)\n", k, totals[k]/counts[k], counts[k], (counts[k]==1?"":"s")
            }
        }' \
    | sort

echo ""
echo "════════════════════════════════════════════════════════════"

if [[ "$FAILURES" -gt 0 ]]; then
    echo ""
    echo "  Recent failures:"
    jq -c "$FILTER | select(.success == false)" "$METRICS_FILE" \
        | tail -5 \
        | jq -r '"    " + .scenarioID + ": " + (.error // "unknown")'
    echo ""
fi
