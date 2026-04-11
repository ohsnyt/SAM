#!/bin/bash
#
# generate-audio.sh — synthesize a test conversation WAV from a scenario script.
#
# A scenario script is a plain text file with one line per utterance:
#   ALEX: This is the agent speaking. I want to talk about retirement.
#   SAMANTHA: Sure, I have several questions about that.
#   ALEX: Great. First, what's your target retirement date?
#
# Recognized speaker labels (must be UPPERCASE, ending with a colon):
#   ALEX     → macOS voice "Alex"      (male, agent-like)
#   SAMANTHA → macOS voice "Samantha"  (female, client-like)
#   DANIEL   → macOS voice "Daniel"    (male, deeper)
#   KAREN    → macOS voice "Karen"     (female, alternative)
#
# Other lines that don't match a speaker pattern are ignored (comments, blank lines).
#
# Usage:
#   ./generate-audio.sh <scenario.txt> <output.wav>
#
# Example:
#   ./generate-audio.sh scenarios/short-single-point.txt /tmp/short.wav
#

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <scenario.txt> <output.wav>" >&2
    exit 1
fi

SCENARIO="$1"
OUTPUT="$2"

if [[ ! -f "$SCENARIO" ]]; then
    echo "Scenario file not found: $SCENARIO" >&2
    exit 1
fi

# Working directory for per-utterance .aiff files
WORK_DIR=$(mktemp -d -t sam-test-audio.XXXXXX)
trap "rm -rf '$WORK_DIR'" EXIT

UTTERANCE_LIST="$WORK_DIR/utterances.txt"
: > "$UTTERANCE_LIST"

# Map speaker label → say voice name. Using a case statement for
# compatibility with macOS's bundled Bash 3.2 (no associative arrays).
voice_for_speaker() {
    case "$1" in
        ALEX)     echo "Alex" ;;
        SAMANTHA) echo "Samantha" ;;
        DANIEL)   echo "Daniel" ;;
        KAREN)    echo "Karen" ;;
        *)        echo "" ;;
    esac
}

INDEX=0
LINE_NUM=0

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    LINE_NUM=$((LINE_NUM + 1))

    # Skip blank lines and comments
    [[ -z "${LINE// }" ]] && continue
    [[ "$LINE" =~ ^[[:space:]]*# ]] && continue

    # Match SPEAKER: text pattern
    if [[ "$LINE" =~ ^([A-Z]+):[[:space:]]*(.+)$ ]]; then
        SPEAKER="${BASH_REMATCH[1]}"
        TEXT="${BASH_REMATCH[2]}"
        VOICE=$(voice_for_speaker "$SPEAKER")

        if [[ -z "$VOICE" ]]; then
            echo "Warning: line $LINE_NUM unknown speaker '$SPEAKER', skipping" >&2
            continue
        fi

        UTTERANCE_FILE=$(printf "%s/utterance-%04d.aiff" "$WORK_DIR" "$INDEX")
        say -v "$VOICE" -o "$UTTERANCE_FILE" -r 175 -- "$TEXT"
        echo "$UTTERANCE_FILE" >> "$UTTERANCE_LIST"
        INDEX=$((INDEX + 1))
    fi
done < "$SCENARIO"

if [[ $INDEX -eq 0 ]]; then
    echo "No valid utterances found in $SCENARIO" >&2
    exit 1
fi

echo "Generated $INDEX utterances from $SCENARIO" >&2

# Concatenate all utterances into a single AIFF
COMBINED_AIFF="$WORK_DIR/combined.aiff"

# Use sox if available; fall back to building a long AppleScript afconvert chain
if command -v sox >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    sox $(cat "$UTTERANCE_LIST") "$COMBINED_AIFF"
else
    # cat the AIFF files using ffmpeg if available, else fall back to a
    # plain concatenation via afconvert in a temp script
    if command -v ffmpeg >/dev/null 2>&1; then
        FFMPEG_LIST="$WORK_DIR/ffmpeg-list.txt"
        : > "$FFMPEG_LIST"
        while IFS= read -r f; do
            echo "file '$f'" >> "$FFMPEG_LIST"
        done < "$UTTERANCE_LIST"
        ffmpeg -y -f concat -safe 0 -i "$FFMPEG_LIST" -c copy "$COMBINED_AIFF" >/dev/null 2>&1
    else
        # Last-resort: use afconvert in a loop. Each pass appends one file.
        # Slower but always available on macOS.
        FIRST=$(head -n 1 "$UTTERANCE_LIST")
        cp "$FIRST" "$COMBINED_AIFF"
        # afconvert can't append, so we'd need a different tool. Bail out.
        echo "Error: sox or ffmpeg required to concatenate audio. Install with:" >&2
        echo "  brew install sox" >&2
        echo "  brew install ffmpeg" >&2
        exit 1
    fi
fi

# Convert AIFF → 16-bit PCM WAV at 16 kHz mono (matches Whisper's preferred format)
# afconvert is built into macOS so this always works.
afconvert "$COMBINED_AIFF" "$OUTPUT" \
    -d LEI16@16000 \
    -c 1 \
    -f WAVE >/dev/null

echo "Wrote $OUTPUT" >&2

# Print duration so the caller can use it as metadata
afinfo "$OUTPUT" 2>/dev/null | awk -F': ' '/duration/ {print $2}' | head -1
