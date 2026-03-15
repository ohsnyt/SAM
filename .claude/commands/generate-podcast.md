# Generate Podcast from SAM Documentation

You are generating an audio podcast showcasing SAM's features using Qwen3-TTS (MLX CustomVoice model). This is a fully automated pipeline: read source material, write dialog, generate audio chunks, stitch them together, and produce a finished MP3. **Zero user interaction required.**

The user may optionally provide a source file path as an argument: $ARGUMENTS
If no argument is provided, use `SAM/1_Documentation/NotebookLM/about-sam.md` as the default source.

---

## Pipeline Overview

1. **Read** the source document
2. **Write** a two-voice podcast script as natural conversation
3. **Chunk** the script by speaker — one speaker per chunk
4. **Generate** audio for each chunk using Qwen3-TTS CustomVoice via mlx_audio
5. **Concatenate** all WAV chunks into one file
6. **Convert** to MP3
7. **Clean up** temporary files

---

## Step 1: Read Source Material

Read the source document specified above. Also read any related topic files in `SAM/1_Documentation/NotebookLM/topics/` to enrich the conversation with specific details.

**Critical**: Strip ALL references to "WFG", "World Financial Group", or any WFG-specific organizational details. Replace with generic references like "your firm", "your organization", or "the industry". SAM must be presented as a tool for independent financial strategists generally.

---

## Step 2: Write the Podcast Script

Write a natural two-person conversational script. The voices are:

- **S1** (voice: **Ryan**) — The host. Male. Curious, warm, asks good questions, reacts naturally. Guides the listener through the story.
- **S2** (voice: **Vivian**) — The expert. Female. Knows SAM deeply, explains with enthusiasm and concrete examples. Confident but not salesy.

### Script Rules

1. **Open with a hook** — S1 sets the scene with a relatable problem financial strategists face. Do NOT open with "Welcome to..." or podcast boilerplate.
2. **Conversational, not scripted** — Use contractions, sentence fragments, interruptions, reactions. Real people say "Right, exactly" and "Wait, so you mean..." and "That's the thing though..."
3. **Concrete examples always** — Never say "it helps you manage relationships." Say "So if you had coffee with a client named John on Tuesday and he mentioned his daughter's graduating next month, SAM picks that up from your notes and three weeks later reminds you to send a congratulations text — with a draft already written."
4. **Natural non-verbal sounds** — Sprinkle these sparingly for realism. Available tags: `(laughs)`, `(sighs)`, `(clears throat)`, `(chuckle)`. Use at most one every 3-4 exchanges. Never more than one per chunk.
5. **Build momentum** — Start with the relationship problem, move through daily workflow (briefing, coaching, notes), expand to business intelligence, touch on events and content, land on privacy/security, close with the emotional payoff.
6. **No jargon** — No "SwiftData", "LLM", "on-device inference", "CoreML". Say "runs on your Mac" not "uses Apple FoundationModels". Say "SAM" not "the language model".
7. **End strong** — Close with S1 reflecting on what it would feel like to have SAM, and S2 confirming with a specific, vivid example. Final line should leave the listener wanting to try it.
8. **Target length**: 2500-3500 words of dialog (produces roughly 8-12 minutes of audio).

### Formatting

Write the script as a single text block with `[S1]` and `[S2]` tags. **Always start with `[S1]`**. **Always alternate between `[S1]` and `[S2]`** — never have the same speaker twice in a row. Each speaker turn should be 1-3 sentences (targeting 8-15 seconds of speech per turn).

Example format:
```
[S1] So here's something I keep hearing from financial advisors — they say the hardest part of their job isn't the financial planning. It's keeping track of all the people. [S2] Right, and that's not just a feeling. When you've got forty, fifty, sixty clients, plus leads, plus recruits, plus referral partners — things slip. A follow-up gets missed, a relationship goes cold, and you don't even notice until it's too late. [S1] And traditional CRMs don't really solve that, do they? [S2] No, because a CRM is basically a database. You put data in, you pull data out. It tells you what happened, but it never tells you what to do next.
```

---

## Step 3: Chunk the Script by Speaker

Split the completed script so that **each chunk contains exactly one speaker's turn**. This ensures Qwen3-TTS generates a consistent voice per chunk.

Chunking rules:
- Split at every `[S1]` / `[S2]` tag boundary
- Each chunk file contains the raw text of a single speaker turn (strip the `[S1]`/`[S2]` tag from the text — the voice is controlled by the `--voice` parameter instead)
- Never split mid-sentence within a turn
- Maintain speaker order metadata so the correct voice is assigned during generation

Write each chunk to a separate temporary text file: `/tmp/sam-podcast/chunks/chunk_001.txt`, `chunk_002.txt`, etc. Also write a manifest file `/tmp/sam-podcast/manifest.txt` with one line per chunk in the format:
```
chunk_001 Ryan
chunk_002 Vivian
chunk_003 Ryan
chunk_004 Vivian
...
```

Create the directories first:
```bash
mkdir -p /tmp/sam-podcast/chunks /tmp/sam-podcast/wav SAM/1_Documentation/NotebookLM/podcasts
```

---

## Step 4: Generate Audio

### Model & Voices

- **Model**: `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit`
- **S1 (host, male)**: `--voice Ryan`
- **S2 (expert, female)**: `--voice Vivian`

The CustomVoice model has built-in named voices that are inherently consistent across chunks. No reference audio or voice cloning needed.

### Generation Command

For each chunk, read the manifest to determine the voice, then run:

```bash
python3 -m mlx_audio.tts.generate \
  --model mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit \
  --text "$(cat /tmp/sam-podcast/chunks/chunk_NNN.txt)" \
  --voice VOICE_NAME \
  --output_path /tmp/sam-podcast/wav \
  --file_prefix chunk_NNN
```

Run chunks **sequentially** (not in parallel). After each generation, verify the WAV file exists before proceeding. If a chunk fails, retry once. If it fails again, log the error and continue — a missing chunk is better than a stuck pipeline.

Qwen3-TTS generates at roughly 1x real-time speed. A 15-second chunk takes ~15 seconds to generate. For a full podcast (8-12 minutes of audio), expect generation to take 10-15 minutes total. Run each command with a 120-second timeout.

---

## Step 5: Concatenate WAV Files

Use ffmpeg to concatenate all generated WAV chunks in order:

```bash
# Build concat list
ls -1 /tmp/sam-podcast/wav/chunk_*.wav | sort | while read f; do echo "file '$f'"; done > /tmp/sam-podcast/concat.txt

# Concatenate
ffmpeg -f concat -safe 0 -i /tmp/sam-podcast/concat.txt \
  -c copy /tmp/sam-podcast/full_podcast.wav -y
```

---

## Step 6: Convert to MP3

```bash
ffmpeg -i /tmp/sam-podcast/full_podcast.wav \
  -codec:a libmp3lame -qscale:a 2 \
  "SAM/1_Documentation/NotebookLM/podcasts/sam-podcast-$(date +%Y%m%d).mp3" -y
```

Quality scale 2 produces ~190kbps VBR — excellent quality for speech.

---

## Step 7: Clean Up and Report

Remove temporary files:
```bash
rm -rf /tmp/sam-podcast
```

Report:
- Source document used
- Number of chunks generated
- Number of chunks that succeeded / failed
- Total audio duration (use `ffprobe` to check)
- Final MP3 file path and size
- Any chunks that failed (with the text that failed, so the user can diagnose)

---

## Error Handling

- If `python3 -m mlx_audio.tts.generate` is not available, stop and tell the user to install mlx-audio: `pip install mlx-audio`
- If `ffmpeg` is not available, stop and tell the user to install it: `brew install ffmpeg`
- If the source document doesn't exist, stop and report the error
- If more than 25% of chunks fail generation, stop and report — something is wrong with the TTS setup
- Never leave `/tmp/sam-podcast` behind on failure — always clean up

---

## Quality Checklist (verify before generating audio)

Before proceeding to Step 4, review the script against these criteria:
- [ ] No WFG or World Financial Group references remain
- [ ] Script starts with [S1]
- [ ] Speakers strictly alternate [S1] [S2] [S1] [S2]...
- [ ] Non-verbal tags used sparingly (max 1 every 4 chunks, ~8-12 total in full script)
- [ ] No technical jargon (no SwiftData, CoreML, LLM, FoundationModels)
- [ ] Concrete examples with names and scenarios throughout
- [ ] Opening hooks the listener with a relatable problem
- [ ] Closing leaves the listener wanting to try SAM
- [ ] Manifest file correctly alternates Ryan / Vivian voices
