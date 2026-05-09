# 02 · Containers & Components

SAM's internal architecture: layers, key coordinators, and the boundaries between them.

## Layered architecture

```mermaid
flowchart TB
    subgraph Views["Views (SwiftUI · @MainActor)"]
        TodayView["Today / Briefing"]
        PeopleView["People / Detail"]
        BusinessView["Business / Pipelines / Goals"]
        GrowView["Grow / Content / Events"]
        SettingsView["Settings / Prompt Lab"]
        FieldUI["SAMField UI<br/>(record · trips · briefing)"]
    end

    subgraph Coordinators["Coordinators (@MainActor @Observable)"]
        direction LR
        Capture["Capture<br/>NoteAnalysis · TranscriptionSession<br/>MeetingPrep · PostEventEval"]
        Coaching["Coaching<br/>OutcomeEngine · CoachingAdvisor<br/>InsightGenerator · DailyBriefing"]
        Pipeline["Pipeline<br/>PipelineTracker · RoleRecruiting<br/>StageTransitions"]
        BI["BI / Strategy<br/>StrategicCoordinator<br/>ScenarioProjection · GoalProgress"]
        Imports["Imports<br/>Contacts · Calendar · Mail<br/>LinkedIn · Facebook · Substack"]
        Trips["Trips<br/>TripIngest · BackupCoordinator"]
    end

    subgraph Services["Services (actor · external I/O)"]
        AppleSvc["Apple<br/>ContactsService · CalendarService<br/>MailDatabaseService · iMessageService"]
        AISvc["AI<br/>AIService · MLXModelManager<br/>NoteAnalysis · MeetingSummary<br/>CoachingPlanner · ContentAdvisor"]
        Specialists["RLM Specialists<br/>PipelineAnalyst · TimeAnalyst<br/>PatternDetector · LifeEventCoaching"]
        Audio["Audio<br/>WhisperTranscription · Diarization<br/>SpeakerEmbedding · Polish"]
        Sync["Sync<br/>CloudSyncService · DevicePairing<br/>AudioReceiving"]
        Compose["Compose / Compliance<br/>ComposeService · ComplianceScanner<br/>SentMailDetection"]
    end

    subgraph Repos["Repositories (@MainActor · SwiftData CRUD)"]
        direction LR
        PeopleRepo["People · Evidence · Notes<br/>Outcomes · Insights"]
        BizRepo["Pipeline · Production · Goals<br/>TimeTracking · IntentionalTouch"]
        EventRepo["Events · ContentPosts<br/>Compliance · Enrichment · Undo"]
        TripRepo["Trips · UnknownSender<br/>Commitments · GoalJournal"]
    end

    subgraph Storage["Storage"]
        SwiftData[("SwiftData<br/>SAM_v34")]
        Defaults[("UserDefaults<br/>profiles, watermarks")]
        Keychain[("Keychain<br/>secrets · pairing")]
        Bookmarks[("Security-scoped<br/>bookmarks (Mail dir)")]
    end

    Views --> Coordinators
    Coordinators --> Services
    Coordinators --> Repos
    Services --> AppleAPI["CN/EK · Foundation · MLX"]
    Services --> Defaults
    Services --> Keychain
    Services --> Bookmarks
    Repos --> SwiftData
    FieldUI -.-> Coordinators

    classDef view fill:#0a84ff,color:#fff,stroke:#0a84ff
    classDef coord fill:#5e5ce6,color:#fff,stroke:#5e5ce6
    classDef svc fill:#ff9f0a,color:#fff,stroke:#ff9f0a
    classDef repo fill:#34c759,color:#fff,stroke:#34c759
    classDef store fill:#8e8e93,color:#fff,stroke:#8e8e93
    class TodayView,PeopleView,BusinessView,GrowView,SettingsView,FieldUI view
    class Capture,Coaching,Pipeline,BI,Imports,Trips coord
    class AppleSvc,AISvc,Specialists,Audio,Sync,Compose svc
    class PeopleRepo,BizRepo,EventRepo,TripRepo repo
    class SwiftData,Defaults,Keychain,Bookmarks,AppleAPI store
```

## Boundary rules

| Layer | Concurrency | What it can do | What it cannot do |
|---|---|---|---|
| **Views** | `@MainActor` (implicit) | Render DTOs / `@Observable` coordinators | Touch raw `CNContact`, `EKEvent`, or SwiftData models directly |
| **Coordinators** | `@MainActor @Observable` | Orchestrate flows, hold UI state, call services + repos | Block the main thread on I/O or AI |
| **Services** | `actor` | Wrap external APIs (Apple, AI, network) | Hold UI state or `@MainActor` references |
| **Repositories** | `@MainActor` | SwiftData CRUD against `SAMModelContainer.shared` | Make external calls |
| **Across boundaries** | — | Pass `Sendable` DTOs only | No `nonisolated(unsafe)` |

## Two-layer AI, RLM-orchestrated

```mermaid
flowchart LR
    subgraph L1["Layer 1 · Foreground (<5s)"]
        Note["Note analysis"]
        Pre["Meeting pre-brief"]
        Draft["Draft messages"]
        Health["Health scoring"]
    end

    subgraph L2["Layer 2 · Background (TaskPriority.background)"]
        SC["StrategicCoordinator<br/>(Swift, deterministic)"]
        SC --> PA["PipelineAnalyst<br/>(LLM)"]
        SC --> TA["TimeAnalyst<br/>(LLM)"]
        SC --> PD["PatternDetector<br/>(LLM)"]
        SC --> CA["ContentAdvisor<br/>(LLM)"]
        PA --> Synth["Synthesis<br/>(Swift)"]
        TA --> Synth
        PD --> Synth
        CA --> Synth
        Synth --> Digest["StrategicDigest<br/>(cached, TTL)"]
    end

    L1 -.->|never blocks| L2
    L2 -.->|yields to| L1

    classDef layer1 fill:#34c759,color:#fff,stroke:#34c759
    classDef layer2 fill:#5e5ce6,color:#fff,stroke:#5e5ce6
    classDef swift fill:#ff9f0a,color:#fff,stroke:#ff9f0a
    class Note,Pre,Draft,Health layer1
    class PA,TA,PD,CA layer2
    class SC,Synth swift
```

**Why this structure**: Each specialist sees only its slice of pre-aggregated data (<2000 tokens). All numerical math happens in Swift, not the LLM. The coordinator resolves conflicts deterministically. See `CLAUDE.md` for the full RLM rationale.

## Key cross-cutting services

- **`SAMModelContainer.shared`** — the single SwiftData container. All repos read/write through it.
- **`ContactsService` / `CalendarService`** — only place `CNContactStore`/`EKEventStore` instances are created.
- **`AIService` / `MLXModelManager`** — gate all model calls; serialize on unified-memory Macs (see memory `feedback_parallel_inference_jobs.md`).
- **`CalibrationService`** — tracks per-kind act/dismiss/rating to adapt outcome weighting.
- **`RetentionService`** — destroys raw audio + verbatim transcripts after derived outputs are confirmed (compliance).

## See also

- [03-data-models.md](03-data-models.md) — what the repositories store.
- [06-flows-rlm-orchestration.md](06-flows-rlm-orchestration.md) — RLM call graph in detail.
