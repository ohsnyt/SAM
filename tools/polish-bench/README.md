# polish-bench

A/B harness for comparing MLX models on the transcript-polish task.

The main app's polish pipeline (`SAM/Services/TranscriptPolishService.swift`)
sends speaker-attributed transcripts through Qwen 3 8B via MLX to fix ASR
artifacts (spacing around percentages, mis-transcribed proper nouns, broken
sentence joins across chunk boundaries, etc.) without rewording the content.

When a new MLX model ships — Qwen 3.5 9B, Llama 4, whatever comes next — we
need to know quickly whether it's actually better for *this* task before
swapping it into the production hybrid. That's what this tool does.

## What it measures

For each (model, transcript) pair:

| Metric                   | What it tells us |
|--------------------------|------------------|
| `properNounRetention`    | Fraction of client/company names that survive intact. **Top signal.** A new model that scores lower here is actively making Sarah's notes worse. |
| `jargonRetention`        | Fraction of industry terms (IUL, SEP-IRA, K-1, S&P 500, …) preserved. Second signal — models love to "correct" jargon into plausible-sounding wrong words. |
| `numberRetention`        | Fraction of dollar amounts, percentages, dates preserved after the prompt's expected space-fix normalizations. |
| `lengthRatio`            | `output_chars / input_chars`. Target ≈ 1.0. Deviation means the model is summarizing or padding. |
| `speakerLabelDelta`      | `abs(output_unique_labels − input_unique_labels)`. Non-zero ⇒ invented or dropped speaker turns. |
| `thinkLeakChars`         | Characters leaked from `<think>…</think>` reasoning blocks past the sanitizer. Should always be `0`. |
| `preambleLeaked`         | Did "Here is the cleaned transcript:" survive? |
| `addedHedgeCount`        | "I think", "perhaps", "it seems" the model added. Non-zero ⇒ editorializing. |
| `latencyMs`              | Wall-clock time per transcript. Includes chunk splitting and all chunk polish calls. |

The bench uses the exact same chunking and system prompt as the production
`TranscriptPolishService` — so results translate directly to what Sarah
would experience in the app.

## Prerequisites

- macOS 26+, Xcode 17+, Apple silicon
- The models you want to bench must already be cached on disk from a prior
  run of SAM (or `huggingface-cli download`). The bench itself does **not**
  download — it would be too slow to make a mistake twice.

Models ship through `MLXModelManager.downloadModel(id:)`; or from the
command line:

```bash
# Example — populate the cache for Qwen 3 8B and Qwen 3.5 9B
hf download mlx-community/Qwen3-8B-4bit
hf download mlx-community/Qwen3.5-9B-MLX-4bit
# Optional: OptiQ mixed-precision variant — same 4-bit budget, spends
# extra bits on the layers that matter most for precise recall.
hf download mlx-community/Qwen3.5-9B-OptiQ-4bit
```

## Usage

Build via `xcodebuild`, **not** `swift build` — MLX's Metal shaders only
compile through the Xcode build system (per the mlx-swift README). The
`build.sh` wrapper does this and drops the binary + `mlx-swift_Cmlx.bundle`
(which contains `default.metallib`) into `./build/`:

```bash
cd tools/polish-bench
./build.sh

# Two-model comparison (recommended — also writes unified diffs between
# the two polished outputs for each fixture)
./build/polish-bench \
  --models mlx-community/Qwen3-8B-4bit,mlx-community/Qwen3.5-9B-MLX-4bit

# Single-model baseline (no diffs, just metrics)
./build/polish-bench \
  --models mlx-community/Qwen3-8B-4bit

# Custom fixtures or output dir
./build/polish-bench \
  --models mlx-community/Qwen3-8B-4bit \
  --fixtures ~/my-transcripts \
  --output  ~/Desktop/polish-run
```

> If you see `MLX error: Failed to load the default metallib`, you built
> with `swift build` instead of `./build.sh`. The executable needs the
> sibling `mlx-swift_Cmlx.bundle` next to it — that's why the wrapper
> copies both into `./build/`.

## Output layout

```
polish-bench-2026-04-21T12-30-00Z/
├── mlx-community_Qwen3-8B-4bit/
│   ├── jargon-and-names.polished.txt
│   ├── jargon-and-names.metrics.json
│   └── … one pair per fixture
├── mlx-community_Qwen3.5-9B-Instruct-4bit/
│   └── …
├── diff-<A>-vs-<B>/
│   └── jargon-and-names.diff.txt   # unified diff between the two models' outputs
├── run.json                         # all metrics, machine-readable
└── summary.md                       # the scan-me-first table
```

`summary.md` contains two sections: an **Overall** table with per-model
averages, and a **Per-fixture breakdown** showing where specific models
drop off (a model can average 92% noun retention but crater to 40% on the
jargon-stressing fixture — the overall table hides that, the per-fixture
one surfaces it).

## Adding fixtures

Any `.txt` file in the fixtures directory becomes a bench case. Each one
may be paired with two optional companion files:

```
my-transcript.txt             # required
my-transcript.nouns.txt       # one proper noun per line
my-transcript.jargon.txt      # one domain term per line
```

Both companions use `#` for comment lines and ignore blanks. If either is
missing, the corresponding retention metric reports `100%` (nothing to
measure), so presence/absence matters.

See `tools/test-kit/scenarios/jargon-and-names.{nouns,jargon}.txt` for a
reference pair.

## When to update

Keep the prompt and chunker in `PolishPipeline.swift` in sync with
`SAM/Services/TranscriptPolishService.swift`. The bench is only useful if
its prompt matches what ships in production — otherwise a new model might
look worse here simply because the bench's prompt is stale.
