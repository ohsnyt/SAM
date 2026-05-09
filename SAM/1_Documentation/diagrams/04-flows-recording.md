# 04 · Recording → Summary Flow

End-to-end lifecycle of a meeting recording from capture (phone or Mac) to compliance-tracked summary, including post-confirmation retention sweep.

## Sequence

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Field as SAMField (iPhone)
    participant Mac as SAM (Mac)
    participant TCP as TCP/HMAC stream
    participant Whisper as WhisperTranscriptionService
    participant Diar as DiarizationService
    participant Polish as TranscriptPolishService
    participant Summary as MeetingSummaryService
    participant Compl as ComplianceScanner
    participant Repo as Repositories
    participant Retain as RetentionService

    User->>Field: Start recording (set context, speakers)
    Note over Field: clientMeeting / prospectingCall<br/>recruitingInterview / annualReview<br/>trainingLecture / boardMeeting

    loop While recording
        Field->>TCP: stream audio segments
        TCP->>Mac: AudioReceivingService persists segments
    end

    User->>Field: Stop
    Field->>TCP: finalize session
    TCP->>Mac: TranscriptionSessionCoordinator.ingest
    Mac->>Whisper: transcribe segments
    Whisper-->>Mac: raw segments + timestamps
    Mac->>Diar: cluster speakers (if enrolled)
    Diar-->>Mac: speaker labels per segment
    Mac->>Polish: polish raw → readable transcript
    Polish-->>Mac: polished transcript

    alt clientMeeting / prospecting / recruiting / annualReview
        Mac->>Summary: systemInstruction(for: context)
        Summary->>Summary: extract decisions, actions,<br/>topics, retentionSignals,<br/>numericalReframing,<br/>complianceStrengths
        Summary-->>Mac: MeetingSummary DTO
        Mac->>Compl: scan summary + draft outputs
        Compl-->>Mac: flags + strengths
    else trainingLecture
        Mac->>Summary: LectureSummaryPipeline<br/>(map → extract → scaffold → reasoner → core)
        Summary-->>Mac: lecture summary
        Note over Mac: NOT compliance-tracked
    else boardMeeting
        Mac->>Summary: board prompt
        Summary-->>Mac: board summary
    end

    Mac->>Repo: persist transcript + summary + audit
    Mac->>Field: push summary (TCP or CloudKit)
    Field-->>User: review summary

    User->>Mac: confirm derived outputs
    Mac->>Retain: schedule destruction
    Retain->>Retain: delete raw audio +<br/>verbatim transcript
    Note over Retain: WFG compliance —<br/>derived outputs preserved,<br/>raw evidence destroyed
```

## Notable behaviors

- **Recording context drives the prompt**: each `RecordingContext` case routes to a dedicated `MeetingSummaryService.systemInstruction(for:)` branch validated in `sam-bench`. Per-context overrides live in `sam.ai.{context}SummaryPrompt` UserDefaults.
- **Lecture pipeline is map-then-synthesize**: chunked extraction → deterministic scaffold → reasoner → core → details. Falls through to legacy `refineLectureSummary` on failure so the user always gets *something*. Median 88% on anchor rubrics.
- **Compliance fields are auditable**: `retentionSignals` (verbatim quotes about consulting another advisor or surrendering), `numericalReframing` ("8-10% revised to 5-6%"), `complianceStrengths` (hedging, refusals-to-guarantee). These add +16pp recall on client-meeting scenarios vs. plain decisions/actions/topics.
- **Retention sweep is mandatory**: WFG policy says don't record. SAM destroys raw audio + verbatim transcript after the user confirms the derived outputs. See memory `project_compliance_data_lifecycle.md`.
- **Long recordings need chunking**: a 73-min recording exceeds Apple Intelligence's 4096-token limit for polish + summary — see memory `feedback_context_window_overflow.md`.
- **Sync paths**: bulk audio over TCP/HMAC same-LAN; final summary can also sync via CloudKit (briefing path) for off-LAN review.

## See also

- [05-flows-note-to-outcome.md](05-flows-note-to-outcome.md) — how confirmed summaries feed evidence and outcomes.
- [09-state-recording.md](09-state-recording.md) — recording session state machine.
