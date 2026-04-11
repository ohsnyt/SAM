# SAM Test Harness

A Mac-only pipeline test loop that **bypasses the iPhone, network, and microphone entirely**. Built to make development cycle iteration radically faster than device-only testing.

---

## Why this exists

Without the harness, every change to the transcription pipeline (Whisper, diarization, polish, summary, edge-case handling) requires:

1. Apply code changes
2. Rebuild Mac + iPhone in Xcode (~2-3 min each)
3. Install on phone
4. Find a quiet place
5. Record real audio in real time
6. Observe what happens
7. Share Console.app logs
8. Wait for diagnosis

That's **15-30 minutes per iteration**. Most of which is wasted because the iPhone, network, and microphone aren't actually exercising any new code.

The harness collapses that to **~30-90 seconds per iteration** by:

- Running synthetic audio through the **exact same pipeline** as a real iPhone upload
- Capturing detailed JSON results to disk for inspection
- Recording metrics so we can verify the speedup is real
- Requiring zero device interaction

---

## One-time setup

### 1. Install dependencies

```bash
brew install jq sox
```

`jq` is for parsing the result JSON. `sox` is for concatenating per-utterance AIFF files into a single WAV. (`ffmpeg` works as a fallback if you prefer.)

### 2. Build SAM in Xcode (Debug configuration)

The test harness is **DEBUG-only** — it's compiled out of Release builds with `#if DEBUG`. There's zero risk of activating it in shipped versions.

```
Xcode → SAM scheme → Product → Build (⌘B)
```

Then **launch SAM**. On launch, the test harness automatically:
- Creates `~/Documents/SAM-TestKit/` with `inbox/`, `outbox/`, `metrics/`, `processed/`, and `logs/` subdirectories
- Starts polling the inbox once per second
- Logs `📬 TestInboxWatcher started — polling ...` to Console.app

Leave SAM running in the background. It only consumes resources when you drop a fixture in the inbox.

### 3. Verify the harness is alive

```bash
ls ~/Documents/SAM-TestKit/
# Should show: inbox/  logs/  metrics/  outbox/  processed/
```

If you don't see those directories, the watcher isn't running. Check Console.app for `TestInboxWatcher` errors.

---

## Daily workflow

### Run a single scenario

```bash
cd /path/to/SAM/tools/test-kit
./run-test.sh short-single-point
```

What happens:

1. The script reads `scenarios/short-single-point.txt` (a plain-text dialogue script)
2. `say` synthesizes each line to AIFF using a different macOS voice per speaker (Alex, Samantha, Daniel, Karen)
3. The AIFFs are concatenated and converted to a 16 kHz mono WAV
4. The WAV + a `.json` metadata file land in `~/Documents/SAM-TestKit/inbox/`
5. SAM's `TestInboxWatcher` picks them up within a second
6. The reprocess pipeline runs (transcribe → diarize → polish → summarize)
7. A detailed result JSON appears in `~/Documents/SAM-TestKit/outbox/`
8. The script polls the outbox, pretty-prints the result, and exits

A typical short scenario completes in **30-60 seconds**, dominated by Whisper inference time.

### Run all scenarios as a sweep

```bash
./run-all.sh
```

Iterates through every `scenarios/*.txt` file, runs each, and prints a summary table at the end. Use `--skip-long` to skip long-form scenarios for a fast smoke test:

```bash
./run-all.sh --skip-long
```

### Inspect a specific result

```bash
cat ~/Documents/SAM-TestKit/outbox/<scenario-timestamp>-result.json | jq .
```

The result includes:

```json
{
  "scenarioID": "short-single-point",
  "success": true,
  "wallClockSeconds": 28.3,
  "input": { "durationSeconds": 14.5, "expectedTopics": 1, ... },
  "output": {
    "segmentCount": 3,
    "speakerCount": 1,
    "summaryActionItems": 1,
    "summaryTopics": 1,
    "summaryTLDR": "Brief reminder...",
    "transcriptSample": "[00:00] Speaker: Okay, this is...",
    "polishedSample": "..."
  }
}
```

### View the metrics report

```bash
./metrics-report.sh           # all-time summary
./metrics-report.sh today     # only today's runs
./metrics-report.sh week      # last 7 days
```

Sample output:

```
════════════════════════════════════════════════════════════
  SAM Test Harness — Effectiveness Report (today)
════════════════════════════════════════════════════════════

  Total cycles:    24
  Succeeded:       22
  Failed:          2
  Success rate:    91.7%

  Wall clock per cycle (successes only)
    Average:       42.1s
    Fastest:       18.4s
    Slowest:       312.7s
    vs. realtime:  0.34× (lower is better)

  Estimated speedup vs. device-only cycle (15 min baseline):
    21.4× faster per scenario

  Per-scenario averages:
    four-speaker-conference          61.2s avg (3 runs)
    long-five-topic                 287.4s avg (2 runs)
    medium-three-topic               48.7s avg (5 runs)
    numbers-and-dates                32.1s avg (4 runs)
    short-single-point               19.8s avg (6 runs)
    silence-mixed                    24.6s avg (4 runs)
```

The **`vs. realtime`** number is the key headline metric. It's wall-clock time divided by audio duration. A value of 0.34× means the harness processes audio at 3× realtime — fast enough that even a 30-minute scenario runs in 10 minutes of wall time.

---

## Writing new scenarios

A scenario is a plain text file in `tools/test-kit/scenarios/`. Format:

```
# description: Two-minute intro meeting with new client
# expectedSpeakers: 2
# expectedTopics: 2
# expectedActionItems: 3

ALEX: Hi Karen, thanks for coming in. What brings you in today?
KAREN: I want to talk about my retirement plan and my kids' college funding.
ALEX: Great, let's start with retirement. Tell me about your timeline.
...
```

**Rules**:
- One utterance per line
- Speaker label is UPPERCASE followed by a colon
- Recognized speakers: `ALEX`, `SAMANTHA`, `DANIEL`, `KAREN` (mapped to macOS voices)
- Lines starting with `#` are comments / metadata
- Blank lines are ignored
- The metadata comments (`# expectedSpeakers:`, etc.) are echoed back in the result JSON for verification

**Tips**:
- Use real numbers, dates, and proper nouns to test ASR accuracy
- Include at least one explicit action item per topic
- Keep utterances natural-length (5-20 seconds each); very long utterances stress the windowing logic
- Mix male/female voices to test diarization

---

## Diagnosing failures

### Test times out

`TestInboxWatcher` may not be running. Check:

```bash
ls -la ~/Documents/SAM-TestKit/inbox/
# Your test files should still be there
```

If they are, the watcher isn't picking them up. Possible causes:

1. SAM is not running → launch it
2. SAM is a Release build → rebuild as Debug
3. SAM crashed → check Console.app

### Result shows `success: false`

Check the `error` field. Common causes:

- **"Whisper returned 0 segments"** — audio file is silent, corrupted, or shorter than the model's minimum (300 ms)
- **"Persistence failed"** — SwiftData write error, usually a schema mismatch after a model change
- **"SAFETY REJECT"** — the safety check refused to overwrite existing data because the new transcription was suspiciously sparse. The original session is preserved.

### Result shows odd transcript content

Check `output.transcriptSample` for the first 50 segments. If you see:

- **`<|...|>` Whisper tokens** — the token-stripping fix isn't applied. Rebuild.
- **Concatenated words like "daysbefore"** — the dedup boundary join isn't using `rebuildText`. Check `WhisperTranscriptionService.swift`.
- **Wrong proper nouns** — the polish service may be working off raw segments. Check that polish ran (look at `polishedSample`).

---

## Files

```
SAM/Services/TestInboxWatcher.swift     # The watcher service (DEBUG only)
tools/test-kit/
├── generate-audio.sh                   # Synthesize WAV from scenario script
├── run-test.sh                         # Drive a single test cycle
├── run-all.sh                          # Run every scenario sequentially
├── metrics-report.sh                   # Aggregate cycles.jsonl into a report
└── scenarios/
    ├── short-single-point.txt
    ├── medium-three-topic.txt
    ├── long-five-topic.txt
    ├── numbers-and-dates.txt
    ├── silence-mixed.txt
    └── four-speaker-conference.txt
```

`~/Documents/SAM-TestKit/` (created on first launch):

```
~/Documents/SAM-TestKit/
├── inbox/              # Drop fixtures here (.wav + .json pairs)
├── outbox/             # Result JSON appears here per fixture
├── processed/          # Source files moved here after processing
├── metrics/
│   └── cycles.jsonl    # One JSON line per cycle, append-only
└── logs/               # Future: per-cycle detailed logs
```

---

## What this harness doesn't cover

These still require real iPhone testing — but they're a much smaller subset of bugs:

- iPhone microphone capture quirks
- Real-world acoustic conditions (room noise, distance)
- Network failure modes (WiFi flap, cellular handoff)
- Bonjour discovery edge cases
- iPhone UI behavior, gestures, navigation

For everything else — and that's the majority of pipeline bugs — use the harness.

---

## Effectiveness metric (the bar)

The **headline metric** I track in `metrics-report.sh` is **estimated speedup vs. device cycle**, measured against a 15-minute baseline (a conservative estimate of how long a real device-driven test cycle takes).

**Current target: ≥10× speedup average across all scenarios.**

**Stretch target: ≥30× for short scenarios (≤60s audio).**

If we're not hitting these, the harness needs more work. If we are, we should look for the next 5× improvement on top.
