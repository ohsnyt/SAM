# 05 · Note → Analysis → Outcome Flow

How a saved note becomes evidence, insights, and actionable coaching outcomes — including life event detection and family/relationship discovery.

## Sequence

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant View as PersonDetailView
    participant Coord as NoteAnalysisCoordinator
    participant Notes as NotesRepository
    participant Evid as EvidenceRepository
    participant AI as NoteAnalysisService
    participant Family as FamilyInferenceService
    participant Life as LifeEventCoachingService
    participant People as PeopleRepository
    participant OE as OutcomeEngine
    participant CalSvc as CalibrationService

    User->>View: type / dictate / drop image / paste<br/>(also: drop LinkedIn PDF)
    View->>Coord: save note
    Coord->>Notes: persist SamNote
    Coord->>Evid: emit SamEvidenceItem(.note)

    par Foreground analysis (Layer 1)
        Coord->>AI: analyze content
        AI-->>Coord: actionItems, topics,<br/>discoveredRelationships,<br/>lifeEvents (JSON)
        Coord->>Notes: update SamNote fields
    and Family discovery
        Coord->>Family: infer family/personal links
        Family-->>Coord: FamilyReference candidates
        Coord->>People: write FamilyReference rows
    end

    alt Life event detected (birth, marriage, loss…)
        Coord->>Life: role-appropriate coaching
        Life-->>Coord: empathy / celebration / transition
        Coord->>OE: synthesize outcomes
    end

    Coord->>OE: refresh outcomes for person
    OE->>OE: detectKnowledgeGaps()<br/>(missing referral source,<br/>content topics, etc.)
    OE->>CalSvc: weight by per-kind<br/>act/dismiss history
    OE->>CalSvc: hasRecentlyActedOutcome?<br/>(7-day suppression)
    OE-->>View: updated outcomes + gap prompts

    User->>View: act / skip / done on outcome
    View->>CalSvc: record signal
    CalSvc->>CalSvc: update strategic weights
    Note over CalSvc: feeds back into future<br/>OutcomeEngine prioritization
```

## Why this flow matters

- **Notes are evidence-first**. A saved note immediately becomes a `SamEvidenceItem` so it's visible in interaction history and contributes to relationship health — even before AI analysis finishes.
- **Foreground only**. All of this runs on `@MainActor` with `<5s` budget. If analysis takes longer (e.g., long dictation), the UI shows a "cogitating" indicator and streams partials.
- **Knowledge gaps are inline, not vague**. When SAM lacks data to be specific (no referral source on a recent client, no posting cadence, etc.), it shows a single `InlineGapPromptView` above the outcome cards. Answers feed `gapAnswersContext()` into future drafts. Max 1 gap shown at a time.
- **Calibration is per-kind**. Every `SamOutcome.kind` accrues its own act/dismiss/rating stats in the `CalibrationLedger`. Muted kinds disappear; soft-suppressed kinds get deprioritized; engaging kinds get boosted. The user can review this in **Settings → "What SAM Has Learned"**.
- **Outcome dedup respects user choices**. `OutcomeRepository.hasRecentlyActedOutcome()` blocks regeneration of dismissed/done outcomes for 7 days; the 24-hour active-duplicate window remains for pending/inProgress.
- **LinkedIn PDF dropped on the note bar** runs through `LinkedInPDFParserService` (deterministic, no AI) — creates `PendingEnrichment` rows + a synthesized note that *then* triggers this same flow for relationship discovery.

## See also

- [02-container-components.md](02-container-components.md) — where `OutcomeEngine` and `CalibrationService` sit.
- [06-flows-rlm-orchestration.md](06-flows-rlm-orchestration.md) — how the *background* layer reasons across all outcomes for the strategic digest.
