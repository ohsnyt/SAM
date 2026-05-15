# Analyze Inference Failures

Read SAM's DEBUG-only inference-failure captures, look for patterns across them, and propose specific code-level changes to resolve the root cause. This skill is the diagnose-and-suggest half of the failure-learning loop. The capture half is implemented in `SAM/Services/InferenceFailureCapture.swift` and writes JSON files automatically whenever MLX inference fails in a debug build.

The goal of any single invocation is to leave the user with **(a) a clear diagnosis of why a class of failure is occurring**, and **(b) a concrete proposed code change they can accept, reject, or refine** — small enough to ship as one commit, with the failing capture as the test case it must clear.

---

## Inputs

### Captures directory
`~/Library/Containers/sam.SAM/Data/Library/Application Support/Diagnostics/InferenceCaptures/`

Every `*.json` file (except `_throttle_state.json`) is a captured failure. Filename format:
```
<yyyy-MM-dd_HH-mm-ss>_<task-slug>_<errorClass>_<uuid8>.json
```

### Capture schema (`CapturedInferenceFailure`)
```
schemaVersion        Int       (currently 1)
id                   String    (UUID)
capturedAt           Date      (ISO8601)
task: { label, source, priority }
backend              String    ("mlx")
modelID              String?
errorClass           Enum      (emptyResponse | streamError | modelUnavailable | other)
errorMessage         String
durationSeconds      Double
maxTokensRequested   Int
diagnostics: {
    hadThinkBlock                Bool   (output contained <think>)
    endedInsideThink             Bool   (orphan opening <think> survived stripping — model ran out of budget mid-reasoning)
    outputCharsBeforeStrip       Int
    outputCharsAfterStrip        Int
    systemPromptChars            Int
    userPromptChars              Int
    systemPromptApproxTokens     Int    (chars/4)
    userPromptApproxTokens       Int
}
prompts: {
    systemPrompt   String?
    userPrompt     String
    rawOutput      String?   (full output before <think> strip; nil for non-emptyResponse failures)
}
```

### Source files to reference
- `SAM/Services/AIService.swift` — `generateWithMLX` is the throw site; the strip logic and `maxTokens = 4096` default live here.
- `SAM/Services/InferenceRegistry.swift` — `InferenceTask` shape (`label` is what groups captures).
- `SAM/Services/InferenceFailureCapture.swift` — capture/throttle implementation, if questions about the data come up.

---

## Workflow

### 1. Survey the captures directory
List every `*.json` file. Report counts:
- Total captures
- Captures per `errorClass`
- Captures per `task.label`
- Oldest and newest `capturedAt`

If the directory is empty, say so and stop — there's nothing to analyze yet.

### 2. Group and pick a target class
Group captures by `(task.label, errorClass)`. The class with the highest count is usually the right place to start, unless the user named a specific task to look at. Within the chosen group, read **all** capture files (full JSON, not just filenames) so you can compare prompts and diagnostic flags side by side.

### 3. Build the diagnostic profile
For the chosen group, compute:

| Signal | What it tells you |
|---|---|
| % with `hadThinkBlock=true` and `outputCharsAfterStrip=0` | Model emitted only reasoning; never produced an answer. Token-budget exhaustion. |
| % with `endedInsideThink=true` | Same root cause, harder evidence: stream ended mid-`<think>`. |
| `durationSeconds` distribution | Long (>30s) + empty output = ran the budget. Short + empty = early stop / template issue. |
| `userPromptApproxTokens` distribution | Are the failures clustered at high prompt lengths? |
| `systemPromptApproxTokens` distribution | Same for system. Large system prompts on Qwen3 can squeeze the answer budget. |
| `maxTokensRequested` | The cap that was actually applied. Default is 4096; if all failures used 4096 with think-overflow, that's the lever. |
| `rawOutput` content | Read it. Patterns: does it always end inside reasoning? Does it ever produce structured output that fails JSON parsing? Does it hallucinate XML tags? Are there `<|im_end|>` artifacts? |

State the profile in 3–6 bullet points. Be specific with numbers: "5 of 7 captures (71%) ended inside `<think>`, all at `maxTokensRequested=4096`, with `userPromptApproxTokens` averaging 1800."

### 4. Form the diagnosis
Translate the profile into a one-paragraph root cause. Common patterns to be ready for — but **do not pattern-match without checking the data first**:

- **Think-budget exhaustion** — `hadThinkBlock=true` and (`endedInsideThink=true` OR `outputCharsAfterStrip=0`) across most captures. The model is reasoning until it hits `maxTokens` and never gets to the answer.
- **Prompt overflow** — duration is short, output is empty or nonsensical, and prompt tokens are very high (>3000). Context window is being truncated before the assistant turn.
- **Streaming abort** — `errorClass=streamError`, no `rawOutput`, durations vary. Likely a cancellation race or model-load issue, not a prompt problem.
- **Template/format collision** — output present but doesn't parse / is empty after strip. Look for stray special tokens in the raw output.
- **Task-specific overload** — only one `task.label` fails; others on the same model don't. The task's prompt itself is the problem, not the backend.

If the data doesn't match a known pattern, say so explicitly and describe what you *did* see.

### 5. Propose a code change
Output a concrete proposal. The bar: **specific enough that the user can say "yes, apply it" and you can immediately edit the file.** Prefer the smallest change that addresses the diagnosis.

Common change shapes for this codebase:

- **Per-task `maxTokens` override** — extend `generateWithMLX`/`generateNarrative` to look up a per-task budget (keyed on `task.label`). Implement as a small lookup table or as a property on `InferenceTask`. Recommend a specific value justified by the data ("Patterns specialist needs ≥6000 tokens because median raw output before stripping is ~5400 chars").
- **Disable thinking for narrowly-scoped tasks** — append `/no_think` or set `enable_thinking=false` in the chat template for tasks where reasoning is more noise than help. Reference the specific task labels.
- **Prompt restructure** — if the prompt is the problem (too long, ambiguous schema, conflicting instructions), propose the *specific* rewrite. Quote the existing prompt section and the proposed replacement.
- **Per-call retry with fallback config** — on `emptyResponse`, retry once with `enable_thinking=false` and the same prompt before falling through to FoundationModels. Implement as a single-shot, not a loop.
- **Circuit-breaker policy adjustment** — if the diagnosis is "this failure shouldn't latch the session," propose the change to `AIService.swift` (around line 286–333) to scope the latch to a specific `(task, errorClass)` rather than session-wide.

For each proposal include:
- The file(s) and approximate line(s) to change
- The smallest viable diff (described or sketched)
- The expected behavior change
- How you'd know it worked — usually: re-run the failing scenario from the capture's prompt and confirm a non-empty post-strip output

### 6. Hand off
Print a short summary block at the end:

```
Diagnosis:    <one sentence>
Evidence:     <N captures, K% matching signature>
Proposed fix: <one-line description>
Files:        <paths>
Verification: <how to test once applied>
```

Then ask the user: *"Apply this fix?"* — and if they accept, make the edit, build, and append an entry to `1_Documentation/inference_lessons.md` (create the file if it doesn't exist) with the date, the signature of the failure, the diagnosis, and the change applied. That lessons doc is how this learns into future builds.

---

## Things to avoid

- Don't propose changes that aren't backed by the captures you actually read. If you only have one capture, say so and recommend waiting for more data rather than over-generalizing.
- Don't speculate about FoundationModels failures — this capture system only records MLX failures (by design).
- Don't suggest removing the circuit breaker entirely; it exists to prevent MLX C++ teardown crashes. Scope adjustments are fine; deletion is not.
- Don't suggest changes outside `SAM/Services/` or task-specific prompt files unless the captures clearly point there.
- Don't auto-apply fixes without the user's explicit "yes." This is a propose-then-act skill, not a propose-then-do-anyway skill.
- Don't worry about Sarah's build. The capture is `#if DEBUG` only — these files don't exist on release builds.
