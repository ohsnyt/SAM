#!/bin/bash
#
# prompts.sh — edit SAM's polish/summary prompts WITHOUT rebuilding.
#
# Breakthrough #2: prompt iteration via UserDefaults.
#
# SAM's TranscriptPolishService and MeetingSummaryService both check for
# a UserDefaults override before falling back to their hardcoded defaults.
# This script lets you edit the active prompts as plain text files and
# push them into the running SAM process — no Xcode rebuild, no relaunch.
#
# Combined with the stage cache (Breakthrough #1), editing a polish prompt
# and re-running a scenario takes ~2-5 seconds: Whisper + diarization hit
# the cache, only polish + summary recompute.
#
# Workflow:
#   ./prompts.sh init               # one-time: copy live defaults to working files
#   $EDITOR ~/.../prompts/polish.txt
#   ./prompts.sh apply polish       # write working file → UserDefaults
#   ./run-test.sh short-single-point
#   # observe result, edit, repeat
#
# Other commands:
#   ./prompts.sh apply summary
#   ./prompts.sh apply all
#   ./prompts.sh reset polish       # remove UserDefaults override → fall back to source default
#   ./prompts.sh reset all
#   ./prompts.sh show polish        # print the active (override or default) prompt
#   ./prompts.sh status             # quick snapshot of which overrides are active
#   ./prompts.sh diff polish        # diff active working file against source default
#   ./prompts.sh paths              # print all relevant paths
#

set -euo pipefail

BUNDLE_ID="sam.SAM"
POLISH_KEY="sam.ai.transcriptPolishPrompt"
SUMMARY_KEY="sam.ai.meetingSummaryPrompt"

# Sandbox path detection — same as run-test.sh.
if [[ -n "${SAM_TESTKIT_ROOT:-}" ]]; then
    TESTKIT_ROOT="$SAM_TESTKIT_ROOT"
elif [[ -d "$HOME/Library/Containers/sam.SAM/Data/Documents/SAM-TestKit" ]]; then
    TESTKIT_ROOT="$HOME/Library/Containers/sam.SAM/Data/Documents/SAM-TestKit"
else
    TESTKIT_ROOT="$HOME/Documents/SAM-TestKit"
fi

PROMPTS_DIR="$TESTKIT_ROOT/prompts"
DEFAULTS_DIR="$PROMPTS_DIR/defaults"

# Resolve a kind name (polish|summary) into:
#   working file path, defaults file path, UserDefaults key, friendly name
resolve_kind() {
    case "$1" in
        polish)
            WORKING="$PROMPTS_DIR/polish.txt"
            DEFAULT_FILE="$DEFAULTS_DIR/polish.txt"
            DEFAULT_KEY="$POLISH_KEY"
            FRIENDLY="polish"
            ;;
        summary)
            WORKING="$PROMPTS_DIR/summary.txt"
            DEFAULT_FILE="$DEFAULTS_DIR/summary.txt"
            DEFAULT_KEY="$SUMMARY_KEY"
            FRIENDLY="summary"
            ;;
        *)
            echo "✘ Unknown prompt kind: $1 (expected: polish, summary, or all)" >&2
            exit 1
            ;;
    esac
}

require_defaults() {
    if [[ ! -f "$DEFAULTS_DIR/polish.txt" || ! -f "$DEFAULTS_DIR/summary.txt" ]]; then
        echo "✘ Default prompts not found in $DEFAULTS_DIR" >&2
        echo "" >&2
        echo "  These are written by SAM's TestInboxWatcher on launch." >&2
        echo "  Make sure SAM is built (Debug) and currently running, then try again." >&2
        exit 1
    fi
}

usage() {
    cat <<EOF
prompts.sh — manage SAM's polish/summary prompt overrides without rebuilding

Usage:
  $0 init                    Copy live defaults into editable working files
  $0 apply <kind>            Write working file → UserDefaults (kind: polish, summary, all)
  $0 reset <kind>            Remove UserDefaults override (kind: polish, summary, all)
  $0 show <kind>             Print the active prompt (override or default)
  $0 status                  Show which overrides are currently active
  $0 diff <kind>             Diff working file against source default
  $0 paths                   Print all relevant paths

Workflow:
  1. ./prompts.sh init                       (one-time)
  2. \$EDITOR $PROMPTS_DIR/polish.txt
  3. ./prompts.sh apply polish
  4. ./run-test.sh short-single-point        (cache reuses Whisper + diarize)
  5. iterate
EOF
}

cmd_paths() {
    cat <<EOF
Bundle ID:           $BUNDLE_ID
TestKit root:        $TESTKIT_ROOT
Prompts directory:   $PROMPTS_DIR
  ├── polish.txt           (your editable working copy)
  ├── summary.txt          (your editable working copy)
  └── defaults/            (read-only, written by SAM on launch)
      ├── polish.txt
      └── summary.txt

Sandboxed plist:     $HOME/Library/Containers/sam.SAM/Data/Library/Preferences/sam.SAM.plist
UserDefaults keys:
  polish:            $POLISH_KEY
  summary:           $SUMMARY_KEY
EOF
}

cmd_init() {
    require_defaults

    local force=false
    if [[ "${1:-}" == "--force" ]]; then
        force=true
    fi

    for kind in polish summary; do
        resolve_kind "$kind"
        if [[ -f "$WORKING" && "$force" == false ]]; then
            echo "⏭  $WORKING already exists (use --force to overwrite)"
            continue
        fi
        cp "$DEFAULT_FILE" "$WORKING"
        echo "✅ Initialized $WORKING"
    done

    echo ""
    echo "Edit either file, then run: ./prompts.sh apply <polish|summary|all>"
}

apply_one() {
    resolve_kind "$1"
    if [[ ! -f "$WORKING" ]]; then
        echo "✘ Working file missing: $WORKING" >&2
        echo "  Run: ./prompts.sh init" >&2
        return 1
    fi

    local content
    content="$(cat "$WORKING")"

    if [[ -z "$content" ]]; then
        echo "✘ $WORKING is empty — refusing to push an empty prompt to UserDefaults" >&2
        return 1
    fi

    # `defaults write -string` accepts a single argument with embedded
    # newlines. Bash preserves them inside the double-quoted "$content".
    defaults write "$BUNDLE_ID" "$DEFAULT_KEY" -string "$content"

    # Force-read so cfprefsd flushes the new value before the next test.
    defaults read "$BUNDLE_ID" "$DEFAULT_KEY" > /dev/null

    local size
    size=$(wc -c < "$WORKING" | tr -d ' ')
    local hash
    hash=$(shasum -a 256 "$WORKING" | awk '{print substr($1,1,12)}')
    echo "✅ Applied $FRIENDLY prompt -> UserDefaults (${size} bytes, sha256=${hash}...)"
}

cmd_apply() {
    if [[ $# -lt 1 ]]; then
        echo "✘ usage: $0 apply <polish|summary|all>" >&2
        exit 1
    fi
    if [[ "$1" == "all" ]]; then
        apply_one polish
        apply_one summary
    else
        apply_one "$1"
    fi
    echo ""
    echo "Next run of ./run-test.sh will pick up the new prompt(s)."
    echo "Whisper + diarize hit the stage cache; only polish/summary recompute."
}

reset_one() {
    resolve_kind "$1"
    if defaults read "$BUNDLE_ID" "$DEFAULT_KEY" >/dev/null 2>&1; then
        defaults delete "$BUNDLE_ID" "$DEFAULT_KEY"
        echo "✅ Reset $FRIENDLY override (will fall back to source default)"
    else
        echo "⏭  $FRIENDLY override was not set"
    fi
}

cmd_reset() {
    if [[ $# -lt 1 ]]; then
        echo "✘ usage: $0 reset <polish|summary|all>" >&2
        exit 1
    fi
    if [[ "$1" == "all" ]]; then
        reset_one polish
        reset_one summary
    else
        reset_one "$1"
    fi
}

cmd_show() {
    if [[ $# -lt 1 ]]; then
        echo "✘ usage: $0 show <polish|summary>" >&2
        exit 1
    fi
    resolve_kind "$1"
    if defaults read "$BUNDLE_ID" "$DEFAULT_KEY" >/dev/null 2>&1; then
        echo "─── $FRIENDLY (UserDefaults override) ──────────────────────"
        defaults read "$BUNDLE_ID" "$DEFAULT_KEY"
    else
        require_defaults
        echo "─── $FRIENDLY (source default) ────────────────────────────"
        cat "$DEFAULT_FILE"
    fi
}

cmd_status() {
    require_defaults
    echo "═══ Prompt Override Status ═══"
    echo ""
    for kind in polish summary; do
        resolve_kind "$kind"
        if defaults read "$BUNDLE_ID" "$DEFAULT_KEY" >/dev/null 2>&1; then
            local override_size
            override_size=$(defaults read "$BUNDLE_ID" "$DEFAULT_KEY" | wc -c | tr -d ' ')
            local override_hash
            override_hash=$(defaults read "$BUNDLE_ID" "$DEFAULT_KEY" | shasum -a 256 | awk '{print substr($1,1,12)}')
            local default_hash
            default_hash=$(shasum -a 256 "$DEFAULT_FILE" | awk '{print substr($1,1,12)}')
            local marker="(differs from default)"
            if [[ "${override_hash}" == "${default_hash}" ]]; then
                marker="(matches default)"
            fi
            printf "  %-8s OVERRIDE  %s bytes  %s... %s\n" "${FRIENDLY}" "${override_size}" "${override_hash}" "${marker}"
        else
            printf "  %-8s default   (no override set)\n" "${FRIENDLY}"
        fi

        if [[ -f "$WORKING" ]]; then
            local working_hash
            working_hash=$(shasum -a 256 "$WORKING" | awk '{print substr($1,1,12)}')
            printf "  %-8s working   %s\n           sha256=%s...\n" "" "${WORKING}" "${working_hash}"
        else
            printf "  %-8s working   (not initialized — run ./prompts.sh init)\n" ""
        fi
        echo ""
    done
}

cmd_diff() {
    if [[ $# -lt 1 ]]; then
        echo "✘ usage: $0 diff <polish|summary>" >&2
        exit 1
    fi
    require_defaults
    resolve_kind "$1"
    if [[ ! -f "$WORKING" ]]; then
        echo "✘ Working file missing: $WORKING" >&2
        echo "  Run: ./prompts.sh init" >&2
        exit 1
    fi
    diff -u "$DEFAULT_FILE" "$WORKING" || true
}

# ─── Dispatch ───────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    usage
    exit 0
fi

CMD="$1"
shift || true

case "$CMD" in
    init)    cmd_init "$@" ;;
    apply)   cmd_apply "$@" ;;
    reset)   cmd_reset "$@" ;;
    show)    cmd_show "$@" ;;
    status)  cmd_status ;;
    diff)    cmd_diff "$@" ;;
    paths)   cmd_paths ;;
    -h|--help|help) usage ;;
    *)
        echo "✘ Unknown command: $CMD" >&2
        echo "" >&2
        usage >&2
        exit 1
        ;;
esac
