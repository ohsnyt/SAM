#!/bin/bash
#
# run-test.sh — drive a single SAM pipeline test cycle.
#
# Generates audio from a scenario script, drops the WAV+metadata into
# SAM's TestInboxWatcher inbox, waits for the result to appear in the
# outbox, prints a concise summary.
#
# Requires SAM to be running on the Mac with the TestInboxWatcher
# enabled (DEBUG build).
#
# Usage:
#   ./run-test.sh <scenario-name> [timeout-seconds]
#
# Example:
#   ./run-test.sh short-single-point
#   ./run-test.sh long-five-topic 600
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

# SAM is sandboxed; the watcher's "Documents" is the container's, not ~.
# Allow override via $SAM_TESTKIT_ROOT for unsandboxed dev or custom locations.
if [[ -n "${SAM_TESTKIT_ROOT:-}" ]]; then
    TESTKIT_ROOT="$SAM_TESTKIT_ROOT"
elif [[ -d "$HOME/Library/Containers/sam.SAM/Data/Documents/SAM-TestKit" ]]; then
    TESTKIT_ROOT="$HOME/Library/Containers/sam.SAM/Data/Documents/SAM-TestKit"
else
    TESTKIT_ROOT="$HOME/Documents/SAM-TestKit"
fi
INBOX="$TESTKIT_ROOT/inbox"
OUTBOX="$TESTKIT_ROOT/outbox"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <scenario-name> [timeout-seconds]" >&2
    echo "" >&2
    echo "Available scenarios:" >&2
    if [[ -d "$SCENARIOS_DIR" ]]; then
        for f in "$SCENARIOS_DIR"/*.txt; do
            [[ -e "$f" ]] || continue
            basename "$f" .txt | sed 's/^/  /' >&2
        done
    fi
    exit 1
fi

SCENARIO_NAME="$1"
TIMEOUT_SECONDS="${2:-300}"

SCENARIO_FILE="$SCENARIOS_DIR/$SCENARIO_NAME.txt"
if [[ ! -f "$SCENARIO_FILE" ]]; then
    echo "Scenario not found: $SCENARIO_FILE" >&2
    exit 1
fi

# Make sure SAM is running by checking the test inbox directory exists
mkdir -p "$INBOX" "$OUTBOX"

# Unique fixture name per run so we don't collide with previous runs
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
FIXTURE_NAME="${SCENARIO_NAME}-${TIMESTAMP}"

WAV_PATH="$INBOX/${FIXTURE_NAME}.wav"
META_PATH="$INBOX/${FIXTURE_NAME}.json"
RESULT_PATH="$OUTBOX/${FIXTURE_NAME}-result.json"

echo "▶ Generating audio: $SCENARIO_NAME → $FIXTURE_NAME.wav" >&2
DURATION=$("$SCRIPT_DIR/generate-audio.sh" "$SCENARIO_FILE" "$WAV_PATH" 2>/dev/null || true)

# Use afinfo to get the actual duration; the generate script's stdout
# may not be reliable across systems.
DURATION_RAW=$(afinfo "$WAV_PATH" 2>/dev/null | awk -F': ' '/estimated duration/ {print $2}' | awk '{print $1}')
if [[ -z "$DURATION_RAW" ]]; then
    DURATION_RAW=$(afinfo "$WAV_PATH" 2>/dev/null | awk '/duration:/ {print $2}' | head -1)
fi
DURATION_NUM="${DURATION_RAW:-0}"

echo "  Duration: ${DURATION_NUM}s" >&2

# Build the metadata JSON. Always emit every field; null when missing.
# (Avoids the heredoc-with-echo problem where \n is interpreted literally.)
EXPECTED_TOPICS=$(grep -E "^# expectedTopics:" "$SCENARIO_FILE" 2>/dev/null | sed 's/^# expectedTopics: *//' | head -1 || true)
EXPECTED_ACTIONS=$(grep -E "^# expectedActionItems:" "$SCENARIO_FILE" 2>/dev/null | sed 's/^# expectedActionItems: *//' | head -1 || true)
EXPECTED_SPEAKERS=$(grep -E "^# expectedSpeakers:" "$SCENARIO_FILE" 2>/dev/null | sed 's/^# expectedSpeakers: *//' | head -1 || true)
DESCRIPTION=$(grep -E "^# description:" "$SCENARIO_FILE" 2>/dev/null | sed 's/^# description: *//' | head -1 || true)

# Default missing fields to null (JSON-safe)
[[ -z "$EXPECTED_TOPICS" ]] && EXPECTED_TOPICS="null"
[[ -z "$EXPECTED_ACTIONS" ]] && EXPECTED_ACTIONS="null"
[[ -z "$EXPECTED_SPEAKERS" ]] && EXPECTED_SPEAKERS="null"
[[ -z "$DURATION_NUM" ]] && DURATION_NUM="0"

# Escape any double-quotes in the description
DESCRIPTION_ESCAPED=$(printf '%s' "$DESCRIPTION" | sed 's/"/\\"/g')

cat > "$META_PATH" <<EOF
{
  "scenarioID": "$SCENARIO_NAME",
  "durationSeconds": $DURATION_NUM,
  "sampleRate": 16000,
  "channels": 1,
  "description": "$DESCRIPTION_ESCAPED",
  "expectedTopics": $EXPECTED_TOPICS,
  "expectedActionItems": $EXPECTED_ACTIONS,
  "expectedSpeakers": $EXPECTED_SPEAKERS
}
EOF

echo "▶ Dropped fixture into inbox, waiting for result (timeout: ${TIMEOUT_SECONDS}s)" >&2

# Poll for the result file
START_TIME=$(date +%s)
while [[ ! -f "$RESULT_PATH" ]]; do
    sleep 1
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    if [[ $ELAPSED -ge $TIMEOUT_SECONDS ]]; then
        echo "❌ Timed out waiting for result after ${TIMEOUT_SECONDS}s" >&2
        echo "   Is SAM running? Is TestInboxWatcher enabled (DEBUG build)?" >&2
        exit 2
    fi
    if [[ $((ELAPSED % 10)) -eq 0 ]] && [[ $ELAPSED -gt 0 ]]; then
        echo "  ...still waiting (${ELAPSED}s elapsed)" >&2
    fi
done

ELAPSED_TOTAL=$(($(date +%s) - START_TIME))
echo "✅ Result received after ${ELAPSED_TOTAL}s" >&2
echo "" >&2

# Print the result file directly. The user (or the agent reading this)
# can pipe to jq for formatted output.
cat "$RESULT_PATH"
