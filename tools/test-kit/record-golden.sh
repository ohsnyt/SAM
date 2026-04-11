#!/bin/bash
#
# record-golden.sh — capture a hand-validated baseline result for regression testing.
#
# Breakthrough #3: LLM-judged regression testing.
#
# Workflow:
#   1. Run a scenario one or more times, manually inspect the result JSON,
#      decide it's correct.
#   2. Run `./record-golden.sh <scenario>` to copy the latest result into
#      `golden/<scenario>.golden.json`.
#   3. From now on, every `./run-test.sh <scenario>` will compare against
#      that golden and report a regression verdict (IDENTICAL /
#      COSMETIC_DRIFT / IMPROVEMENT / REGRESSION / NEEDS_REVIEW).
#
# The golden file is checked into git. Update it deliberately when you
# intentionally improve a prompt or accept stochastic drift.
#
# Usage:
#   ./record-golden.sh <scenario-name>           # capture latest outbox result
#   ./record-golden.sh <scenario-name> --force   # overwrite without confirmation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLDEN_DIR="$SCRIPT_DIR/golden"

# Sandbox path detection — same as run-test.sh.
if [[ -n "${SAM_TESTKIT_ROOT:-}" ]]; then
    TESTKIT_ROOT="$SAM_TESTKIT_ROOT"
elif [[ -d "$HOME/Library/Containers/sam.SAM/Data/Documents/SAM-TestKit" ]]; then
    TESTKIT_ROOT="$HOME/Library/Containers/sam.SAM/Data/Documents/SAM-TestKit"
else
    TESTKIT_ROOT="$HOME/Documents/SAM-TestKit"
fi
OUTBOX="$TESTKIT_ROOT/outbox"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <scenario-name> [--force]" >&2
    echo "" >&2
    echo "Existing goldens:" >&2
    if [[ -d "$GOLDEN_DIR" ]]; then
        for f in "$GOLDEN_DIR"/*.golden.json; do
            [[ -e "$f" ]] || continue
            basename "$f" .golden.json | sed 's/^/  /' >&2
        done
    fi
    exit 1
fi

SCENARIO="$1"
FORCE=false
if [[ "${2:-}" == "--force" ]]; then
    FORCE=true
fi

mkdir -p "$GOLDEN_DIR"

# Find the most recent result for this scenario in the outbox.
LATEST_RESULT=$(ls -t "$OUTBOX"/${SCENARIO}-*-result.json 2>/dev/null | head -1)

if [[ -z "$LATEST_RESULT" ]]; then
    echo "✘ No result found in outbox for scenario '$SCENARIO'" >&2
    echo "  Run: ./run-test.sh $SCENARIO" >&2
    echo "  ...then re-run this script." >&2
    exit 1
fi

GOLDEN_PATH="$GOLDEN_DIR/${SCENARIO}.golden.json"

if [[ -f "$GOLDEN_PATH" && "$FORCE" == false ]]; then
    echo "⚠️  A golden already exists at:"
    echo "    $GOLDEN_PATH"
    echo ""
    echo "  Source result: $LATEST_RESULT"
    echo ""
    read -p "  Overwrite the existing golden? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "  Aborted. Use --force to skip this prompt."
        exit 0
    fi
fi

# Strip volatile fields (timestamp, sessionID, wallClockSeconds, regression
# block) before saving — the golden should compare on PIPELINE OUTPUT only,
# not on bookkeeping fields that change every run.
if command -v jq >/dev/null 2>&1; then
    jq 'del(.timestamp, .sessionID, .wallClockSeconds, .regression)' "$LATEST_RESULT" > "$GOLDEN_PATH"
else
    # Fallback: copy verbatim (the judge will handle the bookkeeping fields
    # gracefully — they're not in the field list it checks)
    cp "$LATEST_RESULT" "$GOLDEN_PATH"
fi

SIZE=$(wc -c < "$GOLDEN_PATH" | tr -d ' ')
echo "✅ Recorded golden: $GOLDEN_PATH (${SIZE} bytes)"
echo ""
echo "  From: $LATEST_RESULT"
echo ""
echo "  Future ./run-test.sh $SCENARIO runs will compare against this golden"
echo "  and report a regression verdict in the result JSON."
