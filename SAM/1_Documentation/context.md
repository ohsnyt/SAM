# SAM — Project Context
**Platform**: macOS 26+ (Tahoe)  
**Language**: Swift 6  
**Architecture**: Clean layered architecture with strict separation of concerns  
**Framework**: SwiftUI + SwiftData  
**Last Updated**: February 25, 2026 (Phases A–S complete, schema SAM_v20)

**Related Docs**: 
- See `agent.md` for product philosophy, AI architecture, and UX principles
- See `changelog.md` for historical completion notes (Phases A–R)

---

## 1. Project Overview

### Purpose

SAM is a **native macOS business coaching and relationship management application** for independent financial strategists at World Financial Group. It observes interactions from Apple's Calendar, Contacts, Mail, iMessage, Phone, and FaceTime, transforms them into Evidence, generates AI-backed insights at both the individual relationship and business-wide level, and provides outcome-focused coaching to help the user grow their practice.

**Core Philosophy**:
- Apple Contacts and Calendar are the **systems of record** for identity and events
- SAM is an **overlay CRM + business coach** that enhances but never replaces Apple's data
- AI assists but **never acts autonomously** — all actions require user review
- **Two-layer AI**: foreground relationship intelligence + background business strategy
- **Clean architecture** with explicit boundaries between layers

### Target Platform

- **macOS 26+** (Tahoe) — Glass design language, latest SwiftUI and FoundationModels
- Native SwiftUI interface following macOS Human Interface Guidelines
- Full keyboard shortcuts, menu bar commands, contextual menus
- Swift 6 strict concurrency throughout

---

## 2. Architecture

### 2.1 Clean Layered Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Views (SwiftUI)                     │
│   PeopleListView, AwarenessView, BusinessDashboard...  │
└──────────────────────┬──────────────────────────────────┘
                       │ Uses DTOs + ViewModels
                       ▼
┌─────────────────────────────────────────────────────────┐
│                    Coordinators                         │
│  ContactsImport, OutcomeEngine, StrategicCoordinator   │
│             (Business Logic Orchestration)              │
└───────────┬─────────────────────┬───────────────────────┘
            │                     │
            │ Reads from          │ Writes to
            ▼                     ▼
┌──────────────────────┐  ┌──────────────────────────────┐
│      Services        │  │       Repositories           │
│  ContactsService     │  │   PeopleRepository           │
│  AIService           │  │   BusinessMetricsRepository  │
│  (External APIs)     │  │   (SwiftData CRUD)           │
└──────────────────────┘  └──────────────────────────────┘
            │                     │
            │ Returns DTOs        │ Stores Models
            ▼                     ▼
┌──────────────────────┐  ┌──────────────────────────────┐
│   External APIs      │  │        SwiftData             │
│ CNContactStore       │  │   SamPerson, SamOutcome      │
│ EKEventStore         │  │   BusinessGoal, Production   │
│ FoundationModels     │  │   StageTransition, etc.      │
└──────────────────────┘  └──────────────────────────────┘
```

### 2.2 AI Architecture: Two Layers + RLM Orchestration

```
┌──────────────────────────────────────────────────────────┐
│                    USER INTERFACE                         │
│  Awareness Dashboard │ Business Dashboard │ Person Detail │
└─────────┬────────────────────┬───────────────────────────┘
          │                    │
    ┌─────▼──────────┐  ┌─────▼──────────────────────┐
    │  LAYER 1       │  │  LAYER 2                   │
    │  Relationship  │  │  Business Intelligence     │
    │  Intelligence  │  │  (Background)              │
    │  (Foreground)  │  │                            │
    │                │  │  ┌──────────────────────┐  │
    │  • Note AI     │  │  │Strategic Coordinator │  │
    │  • Meeting     │  │  │     (Swift)          │  │
    │    pre-briefs  │  │  └──┬───┬───┬───┬──────┘  │
    │  • Follow-up   │  │     │   │   │   │         │
    │    drafts      │  │  ┌──▼┐┌─▼─┐┌▼──┐┌▼─────┐  │
    │  • Health      │  │  │Pip││Tim││Pat││Cont. │  │
    │    scoring     │  │  │   ││   ││   ││Advsr │  │
    │  • Outcome     │  │  │LLM││LLM││LLM││LLM   │  │
    │    generation  │  │  └───┘└───┘└───┘└──────┘  │
    │  • Drafts      │  │       ▼ (merge in Swift)  │
    │                │  │  Strategic Digest / Alerts │
    └────────────────┘  └───────────────────────────┘
    Priority: HIGH       Priority: LOW/BACKGROUND
```

**RLM Principles (see agent.md for full description):**
- Each specialist analyst receives <2000 tokens of curated, pre-aggregated data
- All numerical computation (conversion rates, time gaps, revenue) happens in Swift
- The Strategic Coordinator is Swift code, not an LLM — it structures reasoning, dispatches specialists, and synthesizes results deterministically
- Specialist results are cached with TTL (pipeline=4h, patterns=24h, projections=12h)
- Background tasks use `TaskPriority.background` and yield to foreground work

### 2.3 Layer Responsibilities

**Views (SwiftUI)**: Render UI, handle interaction. Use DTOs/ViewModels, never raw CNContact/EKEvent. `@MainActor` implicit.

**Coordinators**: Orchestrate business logic. Coordinate between services and repositories. Follow standard API pattern (§2.4). `@MainActor` when needed for SwiftUI observation.

**Services**: Own external API access. Return only `Sendable` DTOs. Check authorization before all data access. Actor-isolated.

**Repositories**: CRUD for SwiftData models. No external API access. `@MainActor` isolated.

**DTOs**: `Sendable` structs wrapping external data. Cross actor boundaries safely.

### 2.4 Coordinator API Standards

(Unchanged from current — see existing `context.md` §2.4 for the standard `ImportStatus` enum pattern. All new coordinators must follow this pattern.)

---

## 3. Project Structure

```
SAM/SAM/
├── App/
│   ├── SAMApp.swift                    ✅ App entry point, lifecycle, permissions
│   └── SAMModelContainer.swift         ✅ SwiftData container (v20)
│
├── Services/
│   ├── ContactsService.swift           ✅ Actor — CNContact operations
│   ├── CalendarService.swift           ✅ Actor — EKEvent operations
│   ├── NoteAnalysisService.swift       ✅ Actor — On-device note LLM
│   ├── MailService.swift               ✅ Actor — Mail.app AppleScript bridge
│   ├── EmailAnalysisService.swift      ✅ Actor — Email LLM analysis
│   ├── DictationService.swift          ✅ Actor — SFSpeechRecognizer
│   ├── ENEXParserService.swift         ✅ Actor — Evernote ENEX parser
│   ├── AIService.swift                 ✅ Actor — Unified AI (FoundationModels + MLX)
│   ├── MLXModelManager.swift           ✅ Actor — MLX model lifecycle
│   ├── iMessageService.swift           ✅ Actor — SQLite3 chat.db reader
│   ├── CallHistoryService.swift        ✅ Actor — SQLite3 call records
│   ├── MessageAnalysisService.swift    ✅ Actor — Message thread LLM
│   ├── ComposeService.swift            ✅ @MainActor — Send via URL/AppleScript
│   ├── PipelineAnalystService.swift    ⬜ Actor — Specialist LLM for pipeline analysis
│   ├── PatternDetectorService.swift    ⬜ Actor — Specialist LLM for cross-relationship patterns
│   ├── TimeAnalystService.swift        ⬜ Actor — Specialist LLM for time allocation
│   └── ContentAdvisorService.swift     ⬜ Actor — Specialist LLM for content suggestions
│
├── Coordinators/
│   ├── ContactsImportCoordinator.swift ✅ Contact import
│   ├── CalendarImportCoordinator.swift ✅ Calendar import
│   ├── NoteAnalysisCoordinator.swift   ✅ Note save → analyze → store
│   ├── InsightGenerator.swift          ✅ Multi-source insights
│   ├── MailImportCoordinator.swift     ✅ Email import
│   ├── EvernoteImportCoordinator.swift ✅ ENEX import
│   ├── CommunicationsImportCoordinator.swift ✅ iMessage/calls import
│   ├── OutcomeEngine.swift             ✅ Outcome generation + scoring
│   ├── CoachingAdvisor.swift           ✅ Adaptive feedback
│   ├── DailyBriefingCoordinator.swift  ✅ Briefings + sequence triggers
│   ├── UndoCoordinator.swift           ✅ Undo toast display + restore dispatch
│   ├── PipelineTracker.swift           ✅ Funnel metrics, stage transitions, stall detection, production metrics
│   ├── StrategicCoordinator.swift      ⬜ RLM orchestrator — dispatches specialists, synthesizes
│   └── GoalDecomposer.swift            ⬜ Goal → weekly/daily targets → progress tracking
│
├── Repositories/
│   ├── PeopleRepository.swift          ✅ CRUD for SamPerson
│   ├── EvidenceRepository.swift        ✅ CRUD for SamEvidenceItem
│   ├── ContextsRepository.swift        ✅ CRUD for SamContext
│   ├── NotesRepository.swift           ✅ CRUD for SamNote
│   ├── OutcomeRepository.swift         ✅ CRUD for SamOutcome
│   ├── UndoRepository.swift            ✅ CRUD for SamUndoEntry (30-day snapshots)
│   ├── TimeTrackingRepository.swift    ✅ CRUD for TimeEntry with categories
│   ├── PipelineRepository.swift        ✅ CRUD for StageTransition + RecruitingStage
│   ├── ProductionRepository.swift     ✅ CRUD for ProductionRecord + metric queries
│   └── BusinessMetricsRepository.swift ⬜ CRUD for goals
│
├── Models/
│   ├── SAMModels.swift                 ✅ Core models (SamPerson, SamContext, etc.)
│   ├── SAMModels-Notes.swift           ✅ SamNote, SamAnalysisArtifact
│   ├── SAMModels-Supporting.swift      ✅ Value types, enums
│   ├── SAMModels-Undo.swift            ✅ SamUndoEntry, snapshots
│   ├── SAMModels-Pipeline.swift        ✅ StageTransition, RecruitingStage, PipelineType
│   ├── SAMModels-Production.swift     ✅ ProductionRecord, WFGProductType, ProductionStatus
│   └── DTOs/
│       ├── ContactDTO.swift            ✅
│       ├── EventDTO.swift              ✅
│       ├── EmailDTO.swift              ✅
│       ├── EmailAnalysisDTO.swift      ✅
│       ├── NoteAnalysisDTO.swift       ✅
│       ├── EvernoteNoteDTO.swift       ✅
│       ├── PipelineAnalysisDTO.swift   ⬜ Specialist analyst output
│       ├── PatternAnalysisDTO.swift    ⬜ Specialist analyst output
│       ├── TimeAnalysisDTO.swift       ⬜ Specialist analyst output
│       └── StrategicDigestDTO.swift    ⬜ Synthesized business intelligence output
│
├── Views/
│   ├── AppShellView.swift              ✅ Three-column navigation shell
│   ├── People/                         ✅ People list + detail
│   ├── Inbox/                          ✅ Evidence triage
│   ├── Contexts/                       ✅ Context management
│   ├── Awareness/                      ✅ Coaching dashboard
│   ├── Notes/                          ✅ Note editing + journal
│   ├── Business/                       ✅ Business Intelligence dashboard (pipeline)
│   │   ├── BusinessDashboardView.swift ✅ Top-level BI view (segmented Client/Recruiting/Production)
│   │   ├── ClientPipelineDashboardView.swift ✅ Client funnel, metrics, stuck, transitions
│   │   ├── RecruitingPipelineDashboardView.swift ✅ 7-stage funnel, licensing rate, mentoring
│   │   ├── ProductionDashboardView.swift ✅ Status overview, product mix, pending aging, all records
│   │   ├── ProductionEntryForm.swift  ✅ Add/edit production record sheet
│   │   ├── GoalProgressView.swift      ⬜ Goals vs. actuals with pace indicators
│   │   ├── PatternInsightsView.swift   ⬜ Cross-relationship pattern cards
│   │   └── WeeklyDigestView.swift      ⬜ Strategic digest (also in briefing)
│   ├── Shared/                         ✅ Reusable components
│   └── Settings/                       ✅ Tabbed settings
│
├── Utilities/                          ✅ Logging, filters
│
└── 1_Documentation/
    ├── context.md                      This file
    ├── changelog.md                    Completed work history
    └── agent.md                        Product philosophy & AI architecture
```

---

## 4. Data Models

### 4.1 Existing Models (Phases A–S, schema v20)

(All existing models unchanged — see `changelog.md` for full schema. Summary below.)

- **SamPerson** — Contact anchor + CRM enrichment (roles, referrals, channel preferences, phone aliases, stageTransitions, recruitingStages, productionRecords)
- **SamContext** — Households, businesses, groups
- **SamEvidenceItem** — Observations from Calendar/Mail/iMessage/Phone/FaceTime/Notes
- **SamNote** — User notes with LLM analysis (action items, topics, life events, follow-up drafts)
- **SamInsight** — AI-generated per-person insights
- **SamOutcome** — Coaching suggestions with priority scoring, action lanes, sequences
- **CoachingProfile** — Singleton tracking encouragement style and user patterns
- **TimeEntry** — Time tracking with 10-category WFG categorization
- **SamUndoEntry** — 30-day undo snapshots for destructive operations
- **StageTransition** — Immutable pipeline audit log (client + recruiting transitions)
- **RecruitingStage** — Current recruiting pipeline state per person (7 WFG stages)
- **ProductionRecord** — Policies/products per person (product type, status, carrier, premium, dates)

### 4.2 Future Business Models

**BusinessGoal** — User-defined targets
```swift
@Model
final class BusinessGoal {
    var title: String               // "Write 10 policies this quarter"
    var goalTypeRawValue: String    // "production", "recruiting", "prospecting", "time"
    var targetValue: Double         // Numeric target
    var currentValue: Double        // Current progress (updated by trackers)
    var unitLabel: String           // "policies", "agents", "contacts", "hours"
    var startDate: Date
    var endDate: Date
    var isActive: Bool
    var weeklyMilestones: [Double]  // Decomposed weekly targets (computed by GoalDecomposer)
}
```

**StrategicDigest** — Cached business intelligence output
```swift
@Model
final class StrategicDigest {
    var generatedAt: Date
    var digestTypeRawValue: String  // "morning", "evening", "weekly", "onDemand"
    var pipelineSummary: String     // From PipelineAnalyst
    var timeSummary: String         // From TimeAnalyst
    var patternInsights: String     // From PatternDetector
    var contentSuggestions: String  // From ContentAdvisor
    var strategicActions: String    // Synthesized top recommendations
    var rawJSON: String?            // Full structured output for dashboard rendering
}
```

---

## 5. Phase Status & Roadmap

### Completed Phases (see `changelog.md`)

- ✅ **Phase A**: Foundation
- ✅ **Phase B**: Services Layer
- ✅ **Phase C**: Data Layer
- ✅ **Phase D**: People UI
- ✅ **Phase E**: Calendar & Evidence
- ✅ **Phase F**: Inbox UI
- ✅ **Phase G**: Contexts
- ✅ **Phase H**: Notes & Note Intelligence
- ✅ **Phase I**: Insights & Awareness
- ✅ **Phase J**: Email Integration (Parts 1–3c)
- ✅ **Phase K**: Meeting Prep & Follow-Up
- ✅ **Phase L/L-2**: Notes Pro + Redesign
- ✅ **Phase M**: Communications Evidence
- ✅ **Phase N**: Outcome-Focused Coaching Engine
- ✅ **Awareness UX Overhaul**: Dashboard sections, time-of-day coaching, App Intents/Siri
- ✅ **Phase O**: Intelligent Actions + Multi-Step Sequences (schema SAM_v16)
- ✅ **Phase P**: Universal Undo System (schema SAM_v17)
- ✅ **Phase Q**: Time Tracking & Categorization (schema SAM_v18)
- ✅ **Phase R**: Pipeline Intelligence (schema SAM_v19)
- ✅ **Phase S**: Production Tracking (schema SAM_v20)

### Active / Next Phases

---

### ⬜ Phase T: Meeting Lifecycle Automation Enhancement

**Goal**: Close the gap between "meeting happened" and "CRM is fully updated with next actions."

**Impact**: VERY HIGH — the single most time-saving feature from research. Tools like Zocks/Jump charge $100+/month for this.

**Key deliverables**:

**T.1 — Enhanced Pre-Meeting Brief**
- Richer attendee profiles: last 3 interactions, pending action items, life events since last contact, current pipeline stage, product holdings
- Talking points generated by LLM based on relationship context and role
- Brief automatically appears 15 minutes before calendar event start

**T.2 — Post-Meeting Capture Flow**
- When a calendar event ends, trigger structured capture:
  1. Pre-filled note template with attendee names, meeting title, date
  2. Quick-capture sections: Key Discussion Points, Action Items, Follow-Up Needed, Life Events Mentioned
  3. Dictation prominently available on each section
  4. On save → immediate AI analysis → action items extracted → follow-up outcomes auto-generated

**T.3 — Auto Follow-Up Pipeline**
- After post-meeting note is saved and analyzed:
  - Generate personalized follow-up draft (email or iMessage based on channel preference)
  - Create follow-up outcome with appropriate deadline
  - If action items reference other people, create linked outcomes
  - Multi-step sequence: initial follow-up → check-in if no response

**T.4 — Meeting Quality Feedback Loop**
- Track: Did the user write notes? How quickly? Were action items extracted? Was follow-up sent?
- Feed into coaching effectiveness scoring
- Surface in weekly digest: "You documented 8 of 12 meetings this week — up from 5 last week"

---

### ⬜ Phase U: Relationship Decay Prediction

**Goal**: Upgrade from static threshold-based health scoring to velocity-based predictive decay.

**Impact**: HIGH — catches cooling relationships before they go cold.

**Key deliverables**:

**U.1 — Velocity-Based Health Model**
- Compute communication velocity per person: median gap between evidence items over trailing 90 days
- Track velocity trend: accelerating, steady, or decelerating
- Weight by interaction quality: 45-min meeting > email reply > 2-word text
- Factor in reciprocity: is the contact initiating, or always one-directional?

**U.2 — Predictive Alerts**
- "Communication with [Client] has declined 40% over 60 days. Suggested: reference their [life event] and schedule a review."
- Proactive alerts surface 1–2 weeks BEFORE the relationship crosses the static threshold
- Integrated into Awareness dashboard and daily briefing

**U.3 — Engagement Heatmap**
- Visual per-person engagement over time (mini sparkline on People list or Person detail)
- Color-coded: green (healthy), yellow (cooling), red (at risk)

---

### ⬜ Phase V: Business Intelligence — Strategic Coordinator

**Goal**: Implement the RLM-inspired background reasoning system that synthesizes business-level insights.

**Impact**: VERY HIGH — this is the "business plan from divergent data" capability.

**Key deliverables**:

**V.1 — Strategic Coordinator (Swift Orchestrator)**
- `StrategicCoordinator` — `@MainActor @Observable`
- Runs on configurable schedule (default: 6 AM for morning briefing, 6 PM for evening recap, Monday 5 AM for weekly digest)
- Decomposes analysis into specialist tasks
- Dispatches specialists as `TaskGroup` with `.background` priority
- Synthesizes results deterministically in Swift
- Stores `StrategicDigest` for dashboard and briefing consumption
- Yields to foreground work; pauses under thermal pressure

**V.2 — Specialist Analysts (AI Services)**
- `PipelineAnalystService` — Receives stage counts, conversion rates, stall list (all pre-computed in Swift by PipelineTracker). LLM produces narrative assessment + recommendations.
- `TimeAnalystService` — Receives categorized time data (pre-aggregated). LLM identifies imbalances and recommends adjustments.
- `PatternDetectorService` — Receives aggregated behavioral metrics (not raw data). LLM identifies correlations: best referral sources, optimal meeting times, effective communication patterns.
- `ContentAdvisorService` — Receives recent meeting topics, client questions, seasonal context. LLM suggests 3–5 educational content ideas with draft outlines.

**V.3 — Specialist Prompt Design**
- Each specialist prompt is <2000 tokens of context
- Structured output format (JSON) that Swift can parse deterministically
- Prompts exposed in Settings for user tuning
- Version-tracked so re-analysis can be triggered when prompts change

**V.4 — Synthesis & Conflict Resolution**
- Swift aggregation layer merges specialist outputs
- Resolves scheduling conflicts (e.g., more follow-ups recommended than calendar slots available)
- Priority-ranks all recommendations using the existing scoring formula (time urgency + relationship health + role importance + evidence recency + user engagement)
- Formats final output for daily briefing integration and Business Dashboard

**V.5 — Feedback Loop**
- Every strategic recommendation tracks: acted on, dismissed, or ignored
- Coaching effectiveness score computed weekly
- User can rate the weekly digest (thumbs up/down per recommendation)
- Feedback signals adjust specialist prompt emphasis and coordinator prioritization weights over time

---

### ⬜ Phase W: Content Assist & Social Media Coaching

**Goal**: Help the user create educational content for Facebook/LinkedIn — a proven growth driver.

**Impact**: HIGH — research shows consistent educational content is the #1 digital growth lever for independent agents.

**Key deliverables**:

**W.1 — Content Suggestion Engine**
- Analyze recent meeting topics, client questions, and seasonal relevance
- Generate 3–5 post topic suggestions per week as coaching outcomes
- Each suggestion includes: topic, key points to cover, suggested tone, compliance notes
- Surfaced in Action Queue with `.deepWork` action lane

**W.2 — Draft Generation**
- User selects a topic → AI generates a draft post in the user's voice
- Platform-aware: LinkedIn posts are more professional; Facebook posts are more conversational
- Never includes specific product claims, return promises, or comparative statements
- Copy-to-clipboard for pasting into the platform

**W.3 — Posting Cadence Tracking**
- User can log "I posted today" (manual, since SAM doesn't access social platforms)
- Track posting frequency and surface coaching when engagement lapses
- "You haven't posted on LinkedIn in 12 days. Here are 3 topic ideas."
- Integrated into weekly digest

---

### ⬜ Phase X: Goal Setting & Decomposition

**Goal**: Let the user set business goals; SAM decomposes them into actionable weekly/daily targets and tracks progress.

**Impact**: HIGH — connects daily activities to strategic objectives.

**Key deliverables**:

**X.1 — Goal Entry & Management**
- `BusinessGoal` model + UI
- Goal types: Production ("Write 10 policies this quarter"), Recruiting ("Recruit 3 agents this month"), Prospecting ("Contact 5 new leads per week"), Time ("Spend 60% of time on client-facing activities")
- Start/end dates, numeric targets

**X.2 — Goal Decomposition**
- `GoalDecomposer` coordinator
- Breaks quarterly goals into monthly → weekly → daily targets
- Adjusts pace based on progress (behind pace → higher daily targets; ahead → maintenance mode)
- Computation in Swift, narration by LLM

**X.3 — Goal Progress Dashboard**
- `GoalProgressView` — progress bars, pace indicators, projected completion
- "On track" / "Behind pace" / "Ahead" status per goal
- Integrated into morning briefing: "To stay on pace for your Q2 production goal, aim to submit 2 applications this week."

---

### ⬜ Phase Y: Scenario Projections

**Goal**: "If you maintain current pace, here's where you'll be in 3/6/12 months."

**Impact**: MEDIUM — valuable for motivation and planning, but dependent on Phases R–X data.

**Key deliverables**:
- Simple linear projections based on trailing 90-day velocity
- Pipeline throughput projection (new clients per month at current conversion rate)
- Recruiting projection (producing agents per quarter at current licensing rate)
- Revenue estimate range (based on production trends and average policy size)
- All projections clearly labeled as estimates with confidence ranges
- Displayed in Business Dashboard and weekly digest

---

### ⬜ Phase Z: Compliance Awareness

**Goal**: Help the user avoid compliance issues in communications.

**Impact**: MEDIUM — important for regulated financial services but not a primary productivity driver.

**Key deliverables**:
- Flag keywords in draft messages that may need compliance review (return promises, guarantees, comparative claims)
- Visual warning badge on flagged drafts
- Does NOT block sending — advisory only
- Audit trail of AI-generated drafts (what was generated, was it modified before sending)
- Configurable keyword/phrase list in Settings

---

### Future Phases (Unscheduled)

- **Advanced Search**: Full-text search across evidence, notes, mail summaries, and insights
- **Export/Import**: Backup and restore SAM data
- **iOS Companion**: Read-only iOS app
- **Relationship Graph**: Visual network of people, contexts, and connections
- **Custom Activity Types**: User-defined time tracking categories
- **API Integration**: Connect to financial planning software
- **Team Collaboration**: Shared contexts and evidence (multi-user support)

---

## 6. Critical Patterns & Gotchas

(All existing patterns from Phases A–O remain in effect. See `changelog.md` for full documentation of each. Summary of key rules below.)

### 6.1 Permissions — Never trigger surprise dialogs. Always check auth before access.

### 6.2 Concurrency — Services are `actor`, Repositories are `@MainActor`, Views implicit `@MainActor`. All boundary-crossing data must be `Sendable` DTOs.

### 6.3 @Observable + Property Wrappers — Use `@ObservationIgnored` with manual UserDefaults for settings in coordinators.

### 6.4 SwiftData Best Practices
- Enum storage: always `rawValue` pattern with `@Transient` computed property
- Model initialization: provide all required parameters
- Search: fetch-all + in-memory filter (Swift 6 predicate capture limitation)
- Container: singleton `SAMModelContainer.shared`
- List selection: use primitive IDs (UUID), not model references

### 6.5 Store Singletons — One CNContactStore, one EKEventStore. Never create duplicates.

### 6.6 SwiftUI Patterns — Explicit `return` in multi-statement preview closures. `enumerated()` for non-Identifiable collections. UUID-based list selection.

### 6.7 Background AI Task Rules (NEW)
- All Layer 2 (Business Intelligence) tasks use `TaskPriority.background`
- Call `Task.yield()` every ~10 iterations in batch processing loops
- Check `Task.isCancelled` at each specialist call boundary
- If user is actively typing or navigating (detected via focus state), pause background tasks
- Cache specialist results with TTL; never re-run if cache is fresh
- Log all specialist calls and durations to `DevLogStore` for performance tuning

---

## 7. Testing Strategy

### Unit Testing
Each layer tested independently:
- **Services**: Test with real system APIs (requires authorization)
- **Repositories**: Use in-memory `ModelContainer`
- **Coordinators**: Mock services/repositories with protocols
- **Views**: SwiftUI preview data
- **Strategic Coordinator**: Mock specialist services, verify synthesis logic deterministically
- **Specialist Analysts**: Test prompt construction with known data, verify structured output parsing

### Business Intelligence Testing
- Pipeline metrics: Create known stage transitions, verify conversion rates and velocity calculations match expected values
- Goal decomposition: Set known goals with known dates, verify weekly targets are mathematically correct
- Strategic synthesis: Provide known specialist outputs, verify priority ranking and conflict resolution
- Performance: Verify background tasks yield appropriately under simulated load

---

## 8. Common Development Tasks

### Adding a New Feature

**Checklist**:
- [ ] Does it need external API access? → Add to appropriate Service
- [ ] Does it need persistent storage? → Add to appropriate Repository; plan schema migration
- [ ] Does it need business logic? → Create/update Coordinator
- [ ] Does it need AI reasoning? → Which layer? Foreground (Layer 1) or Background (Layer 2)?
- [ ] If Layer 2: Does it need a specialist analyst? Or can it use an existing one?
- [ ] Does it need UI? → Create View using DTOs/ViewModels
- [ ] Is all data crossing actors `Sendable`?
- [ ] Are all CNContact/EKEvent accesses through Services?
- [ ] Does it respect the priority hierarchy? (see agent.md)
- [ ] Can it be tested without launching the full app?

### Adding a New Specialist Analyst

1. Create `XYZAnalystService` as an `actor` in Services/
2. Define input DTO (pre-aggregated data, <2000 tokens when serialized)
3. Define output DTO (structured JSON that Swift can parse)
4. Write the specialist prompt — expose in Settings
5. Register the analyst in `StrategicCoordinator`
6. Add to the `TaskGroup` dispatch in the coordinator's analysis cycle
7. Add synthesis handling in the coordinator's merge step
8. Test: mock input → verify output parsing → verify synthesis integration

---

## 9. Schema Migration Plan

| Version | Phase | Changes |
|---------|-------|---------|
| v16 | O | Multi-step sequences on SamOutcome |
| v17 | P | + SamUndoEntry model |
| v18 | Q | + TimeEntry model, TimeCategory enum |
| v19 | R | + StageTransition, RecruitingStage models |
| v20 | S (current) | + ProductionRecord, WFGProductType, ProductionStatus |
| v21 | V | + StrategicDigest |
| v22 | X | + BusinessGoal |

Each migration uses SwiftData lightweight migration. New models are additive (no breaking changes to existing models). Backfill logic runs once on first launch after migration.

---

## 10. Key Files Reference

### Documentation
- **context.md** (this file): Architecture, active phases, future roadmap
- **changelog.md**: Completed phases, architectural decisions, historical notes
- **agent.md**: Product philosophy, AI architecture, UX principles

### Core Implementation Files
(See §3 for full tree with completion status)

---

## 11. Success Metrics

**Architecture health:**
- ✅ No direct CNContactStore/EKEventStore outside Services/
- ✅ No `nonisolated(unsafe)` escape hatches
- ✅ All concurrency warnings resolved
- ✅ Each layer has cohesive responsibilities
- 🎯 New features take < 1 hour to scaffold
- 🎯 Tests run in < 2 seconds

**Business Intelligence health:**
- 🎯 Background AI tasks never perceptibly slow the UI
- 🎯 Strategic digest generation completes in < 60 seconds total
- 🎯 Each specialist analyst call completes in < 10 seconds
- 🎯 Pipeline metrics refresh in < 1 second (pure Swift computation)
- 🎯 User rates weekly digest as useful >70% of the time (tracked via feedback)

**User impact:**
- 🎯 Time from "meeting ended" to "CRM updated with notes and follow-ups" < 5 minutes
- 🎯 User acts on >50% of coaching outcomes (measured by CoachingAdvisor)
- 🎯 Pipeline stalls identified within 48 hours of threshold breach
- 🎯 Zero compliance-flagged messages sent without user acknowledgment

---

## 12. Development Environment

### Requirements
- macOS 26+ (Tahoe)
- Xcode 18+ (Swift 6)
- Access to Contacts, Calendar, Mail (for testing)
- Security-scoped bookmark grants for iMessage/CallHistory databases

### Build Settings
- Swift Language Version: Swift 6
- Concurrency Checking: Complete (`-strict-concurrency=complete`)
- Minimum macOS Deployment: 26.0

---

**Document Version**: 8.0 (Phase S complete, Business Intelligence architecture, Phases T–Z)
**Previous Versions**: See `changelog.md` for version history
**Last Major Update**: February 25, 2026 — Phase S: Production Tracking complete, schema SAM_v20
**Clean Rebuild Started**: February 9, 2026
    