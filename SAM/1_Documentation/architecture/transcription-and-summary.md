# Transcription, Recording Context & Summary Pipelines

SAM records meetings, recruiting interviews, board sessions, and training lectures. Different session shapes route through different summary pipelines.

## Recording Context Types

`RecordingContext` covers six session shapes:

- `.clientMeeting`
- `.prospectingCall`
- `.recruitingInterview`
- `.annualReview`
- `.trainingLecture`
- `.boardMeeting`

Each routes to a dedicated `MeetingSummaryService.systemInstruction(for:)` branch with a specialized prompt validated in `sam-bench` (see `/Users/david/Swift/sam-bench/FINDINGS.md`).

### Compliance Coverage

Client-meeting-shaped contexts (`.clientMeeting`, `.prospectingCall`, `.recruitingInterview`, `.annualReview`) are compliance-tracked. `.trainingLecture` and `.boardMeeting` are not.

### Per-Context Prompt Overrides (Settings → Prompt Lab)

```
sam.ai.meetingSummaryPrompt
sam.ai.prospectingSummaryPrompt
sam.ai.recruitingSummaryPrompt
sam.ai.annualReviewSummaryPrompt
sam.ai.trainingSummaryPrompt
sam.ai.boardSummaryPrompt
```

## MeetingSummary Auditable Fields

Three fields beyond the basic decisions / actions / topics capture audit-grade content, validated in `sam-bench` as +16pp recall on client-meeting scenarios:

- **`retentionSignals`** — verbatim quotes about consulting another advisor or surrendering
- **`numericalReframing`** — original + revised figures preserved in one entry (e.g. "8–10% revised to 5–6%")
- **`complianceStrengths`** — hedging, disclosure, refusals-to-guarantee as a counterweight to `complianceFlags`

Backward-compatible JSON: missing fields decode as empty arrays.

## Lecture Summaries (Map-Then-Synthesize)

`.trainingLecture` recordings bypass the standard client-meeting summary path and run through `LectureSummaryPipeline`:

```
chunk → extract → deterministic scaffold → reasoner → core → details
```

Swift-side enforcement wraps both the reasoner's ordered points and the final keyPoints. Validated against anchor rubrics in `tools/summary-bench` — median 88% on the reference transcripts.

Pipeline failures fall through to the legacy `refineLectureSummary` path so the user always gets a summary. Sessions that never finished summarizing can be backfilled from **Settings → Prompt Lab → Transcript Maintenance**.
