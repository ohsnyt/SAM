# 09 · State Machines

The discrete state lifecycles SAM tracks. Every transition is logged immutably (`StageTransition`) so velocity, time-in-stage, and stall detection can be computed historically.

## Client pipeline (Lead → Client)

```mermaid
stateDiagram-v2
    [*] --> Lead: identified
    Lead --> Applicant: application started
    Applicant --> Client: policy issued
    Client --> [*]
    Lead --> Archived: no movement / DNC
    Applicant --> Archived: declined / withdrew
    note right of Archived
      ContactLifecycleStatus
      controls visibility:
      .archived / .dnc / .deceased
    end note
```

## Recruiting pipeline (WFG · 7 stages)

```mermaid
stateDiagram-v2
    [*] --> InitialConversation
    InitialConversation --> BPMScheduled: agreed to BPM
    BPMScheduled --> BPMAttended
    BPMAttended --> Decided: candidate signs up
    Decided --> Licensing: enrolls in licensing
    Licensing --> Licensed: passes exam
    Licensed --> Producing: first sale
    Producing --> [*]

    InitialConversation --> Archived: not interested
    BPMScheduled --> Archived: no-show
    Licensing --> Archived: drops out
    note right of Producing
      Mentoring cadence tracked
      via SamEvidenceItem +
      IntentionalTouch
    end note
```

## Contact lifecycle status

```mermaid
stateDiagram-v2
    [*] --> Active: imported / created
    Active --> Archived: stale 12+ months,<br/>no pipeline role
    Active --> DNC: user marks DNC
    Active --> Deceased: life event detected,<br/>user confirms
    Archived --> Active: user reactivates
    DNC --> [*]: never overridden on re-import
    Deceased --> [*]: never overridden on re-import

    note right of Archived
      Hidden but searchable.
      No outcomes generated.
    end note
    note right of DNC
      Visible in history.
      No outreach ever generated.
    end note
```

OutcomeEngine scanner #13 proactively suggests archiving Active contacts with no evidence in 12+ months and no pipeline-relevant role.

## Recording session

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Configuring: tap record
    Configuring --> Recording: speakers + context set
    Recording --> Streaming: TCP/HMAC active
    Streaming --> Recording: reconnect
    Recording --> Finalizing: stop
    Finalizing --> Transcribing: segments closed
    Transcribing --> Diarizing
    Diarizing --> Polishing
    Polishing --> Summarizing
    Summarizing --> AwaitingReview
    AwaitingReview --> Confirmed: user approves
    AwaitingReview --> Discarded: user deletes
    Confirmed --> RetentionSweep
    RetentionSweep --> [*]
    Discarded --> [*]

    note right of RetentionSweep
      Raw audio +
      verbatim transcript
      destroyed.
      Derived outputs preserved.
    end note
```

## Event participation

```mermaid
stateDiagram-v2
    [*] --> NotInvited
    NotInvited --> DraftReady: invitation drafted
    DraftReady --> HandedOff: Mail.app opened
    HandedOff --> Invited: SentMailDetectionService confirms send
    Invited --> ReminderSent: scheduled reminder fires
    Invited --> Responded: RSVP received
    ReminderSent --> Responded
    Responded --> [*]

    note right of HandedOff
      SentMailDetectionService
      retries: 1s, 3s, 8s, 15s, 30s
      after Mail.app focus loss
    end note
```

## Outcome lifecycle

```mermaid
stateDiagram-v2
    [*] --> Pending: OutcomeEngine generates
    Pending --> InProgress: user starts
    Pending --> Skipped: user dismisses
    Pending --> Done: user completes
    InProgress --> Done
    InProgress --> Skipped

    Skipped --> [*]: 7-day suppression<br/>blocks regeneration
    Done --> [*]: 7-day suppression<br/>blocks regeneration
    Pending --> Suppressed: muted kind /<br/>archived person /<br/>24h duplicate window

    note right of Done
      CalibrationService records
      act/dismiss; weights feed
      OutcomeEngine prioritization
    end note
```

## Why these are state machines (not flags)

- **Stage transitions are auditable**. `StageTransition` records every move with timestamp + note. Conversion rates and time-in-stage come from this log, not from the current `RecruitingStage`.
- **Lifecycle states gate behavior**. Coaching, outcomes, outreach drafts all consult `ContactLifecycleStatus` before generating. Never override DNC or Deceased on re-import.
- **Recording states drive UI affordances**. The phone shows different controls per state; Mac shows different review surfaces.
- **Outcome states feed calibration**. Skip/Done aren't just visual states — they update the per-kind weights that prioritize tomorrow's outcomes.
