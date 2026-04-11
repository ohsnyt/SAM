#!/bin/bash
#
# run-all.sh — run every scenario in scenarios/ sequentially.
#
# Useful for regression sweeps and for establishing baseline metrics
# after a code change. Prints a per-scenario summary as it goes and
# the full metrics report at the end.
#
# Usage:
#   ./run-all.sh                    # all scenarios
#   ./run-all.sh --skip-long        # skip scenarios > 60s expected
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

SKIP_LONG=false
if [[ "${1:-}" == "--skip-long" ]]; then
    SKIP_LONG=true
fi

START_TIME=$(date +%s)
COUNT=0
SUCCEEDED=0
FAILED=0

echo "═══ Running all scenarios in $SCENARIOS_DIR ═══"
echo ""

for SCENARIO_FILE in "$SCENARIOS_DIR"/*.txt; do
    [[ -e "$SCENARIO_FILE" ]] || continue
    NAME=$(basename "$SCENARIO_FILE" .txt)

    if [[ "$SKIP_LONG" == true ]] && [[ "$NAME" == *"long"* || "$NAME" == *"stress"* ]]; then
        echo "⏭  Skipping $NAME (long scenario)"
        continue
    fi

    COUNT=$((COUNT + 1))
    echo "▶ [$COUNT] $NAME"

    if "$SCRIPT_DIR/run-test.sh" "$NAME" > /tmp/sam-test-result.json 2>&1; then
        # Parse the success field from the result JSON (last few lines should
        # be valid JSON; the wrapping log lines go to stderr)
        SUCCESS=$(jq -r '.success // false' /tmp/sam-test-result.json 2>/dev/null || echo "false")
        WALL=$(jq -r '.wallClockSeconds // 0 | tostring' /tmp/sam-test-result.json 2>/dev/null || echo "0")
        SEGS=$(jq -r '.output.segmentCount // 0' /tmp/sam-test-result.json 2>/dev/null || echo "0")
        SPEAKERS=$(jq -r '.output.speakerCount // 0' /tmp/sam-test-result.json 2>/dev/null || echo "0")

        if [[ "$SUCCESS" == "true" ]]; then
            SUCCEEDED=$((SUCCEEDED + 1))
            printf "  ✅ %ss / %s segments / %s speakers\n" "$WALL" "$SEGS" "$SPEAKERS"
        else
            FAILED=$((FAILED + 1))
            ERROR=$(jq -r '.error // "unknown"' /tmp/sam-test-result.json 2>/dev/null)
            printf "  ❌ FAILED: %s\n" "$ERROR"
        fi
    else
        FAILED=$((FAILED + 1))
        echo "  ❌ run-test.sh exited with error"
    fi
done

TOTAL_ELAPSED=$(($(date +%s) - START_TIME))
echo ""
echo "═══ Sweep complete: $SUCCEEDED succeeded, $FAILED failed in ${TOTAL_ELAPSED}s ═══"
echo ""

# Print the metrics report scoped to today
"$SCRIPT_DIR/metrics-report.sh" today
