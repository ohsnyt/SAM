# SAM — Project Context
**Platform**: macOS 26+ (Tahoe)  
**Language**: Swift 6  
**Architecture**: Clean layered architecture with strict separation of concerns  
**Framework**: SwiftUI + SwiftData  
**Last Updated**: February 28, 2026 (Phases A–Z + Advanced Search + Export/Import + Phase AA complete + Strategic Action Coaching Flow + Life Event Coaching + Interactive Content Ideas + ⌘K Command Palette + Coaching Calibration Phases 1–4 + Phase AB Polish + Bug fixes: intro timing, tips state, JSON null, Contacts container, task priorities, schema SAM_v27)

**Related Docs**:
- See `agent.md` for product philosophy, AI architecture, and UX principles
- See `changelog.md` for historical completion notes (Phases A–Z + post-phase features)

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
│   └── SAMModelContainer.swift         ✅ SwiftData container (v26)
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
│   ├── PipelineAnalystService.swift    ✅ Actor — Specialist LLM for pipeline analysis
│   ├── PatternDetectorService.swift    ✅ Actor — Specialist LLM for cross-relationship patterns
│   ├── TimeAnalystService.swift        ✅ Actor — Specialist LLM for time allocation
│   ├── ContentAdvisorService.swift     ✅ Actor — Specialist LLM for content suggestions + draft generation
│   ├── GraphBuilderService.swift      ✅ Actor — Force-directed graph layout + edge assembly + edge bundling
│   ├── CoachingPlannerService.swift   ✅ Actor — AI coaching chat for strategic action planning
│   ├── BestPracticesService.swift     ✅ Actor — Best practices knowledge base (bundled + user)
│   ├── BusinessProfileService.swift  ✅ Actor — Business context profile persistence + AI blocklist + calibration injection
│   ├── CalibrationService.swift     ✅ Actor — Calibration ledger persistence (UserDefaults), signal recording, AI fragment generation
│   ├── SystemNotificationService.swift ✅ @MainActor — macOS system notifications (UNUserNotificationCenter)
│   ├── LifeEventCoachingService.swift ✅ Actor — Event-type-calibrated AI coaching for life events
│   └── NarrationService.swift        ✅ @MainActor — AVSpeechSynthesizer wrapper for narrated intro + future TTS
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
│   ├── StrategicCoordinator.swift      ✅ RLM orchestrator — dispatches specialists, synthesizes
│   ├── GoalProgressEngine.swift       ✅ Live goal progress from existing repos + pace calculation
│   ├── ScenarioProjectionEngine.swift ✅ Deterministic 90-day trailing velocity projections
│   ├── BackupCoordinator.swift        ✅ Export/import .sambackup files (full replace)
│   ├── SearchCoordinator.swift        ✅ Unified search across people, contexts, evidence, notes, outcomes
│   ├── RelationshipGraphCoordinator.swift ✅ Graph data gathering, filtering, layout orchestration
│   └── IntroSequenceCoordinator.swift ✅ First-launch intro slide machine + narration sync
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
│   ├── ContentPostRepository.swift    ✅ CRUD for ContentPost + cadence + streak queries
│   ├── GoalRepository.swift           ✅ CRUD for BusinessGoal + archive
│   ├── ComplianceAuditRepository.swift ✅ CRUD for ComplianceAuditEntry + prune
│   └── DeducedRelationRepository.swift ✅ CRUD for DeducedRelation + confirm
│
├── Models/
│   ├── SAMModels.swift                 ✅ Core models (SamPerson, SamContext, etc.)
│   ├── SAMModels-Notes.swift           ✅ SamNote, SamAnalysisArtifact
│   ├── SAMModels-Supporting.swift      ✅ Value types, enums
│   ├── SAMModels-Undo.swift            ✅ SamUndoEntry, snapshots
│   ├── SAMModels-Pipeline.swift        ✅ StageTransition, RecruitingStage, PipelineType
│   ├── SAMModels-Production.swift     ✅ ProductionRecord, WFGProductType, ProductionStatus
│   ├── SAMModels-Strategic.swift      ✅ StrategicDigest, DigestType
│   ├── SAMModels-ContentPost.swift   ✅ ContentPost, ContentPlatform
│   ├── SAMModels-Goal.swift          ✅ BusinessGoal, GoalType, GoalPace
│   ├── SAMModels-Compliance.swift    ✅ ComplianceAuditEntry
│   ├── BackupDocument.swift          ✅ Backup DTOs (21 Codable structs) + AnyCodableValue
│   └── DTOs/
│       ├── ContactDTO.swift            ✅
│       ├── EventDTO.swift              ✅
│       ├── EmailDTO.swift              ✅
│       ├── EmailAnalysisDTO.swift      ✅
│       ├── NoteAnalysisDTO.swift       ✅
│       ├── EvernoteNoteDTO.swift       ✅
│       ├── StrategicDigestDTO.swift    ✅ All specialist analyst output DTOs + synthesis types
│       ├── ContentDraftDTO.swift      ✅ ContentDraft + LLMContentDraft
│       ├── GraphNode.swift            ✅ Graph node DTO (position, role, health, production)
│       ├── GraphEdge.swift            ✅ Graph edge DTO (9 edge types incl. roleRelationship, weight, direction, deduced relation ID)
│       ├── GraphInputDTOs.swift       ✅ Input DTOs for graph builder (9 types incl. RoleRelationshipLink + DeducedFamilyLink)
│       ├── CoachingSessionDTO.swift   ✅ CoachingMessage, CoachingAction (7 types), CoachingSessionContext, LifeEventCoachingContext
│       ├── BestPracticeDTO.swift      ✅ BestPractice knowledge base entry
│       ├── BusinessProfileDTO.swift   ✅ Business context profile (practice structure, market focus, tools, blocklist)
│       └── CalibrationDTO.swift      ✅ CalibrationLedger (per-kind stats, timing patterns, strategic weights, muted kinds)
│
├── Views/
│   ├── AppShellView.swift              ✅ Navigation shell (4 sidebar items: Today, People, Business, Search)
│   ├── People/                         ✅ People list + detail (initials fallback, coaching preview, urgency strips)
│   ├── Inbox/                          ✅ Evidence triage (accessible via search/contexts)
│   ├── Contexts/                       ✅ Context management (accessible via People → More Details)
│   ├── Awareness/                      ✅ "Today" view — Hero card + Today's Actions + collapsed Review & Analytics + Life Event coaching + IntroSequenceOverlay
│   ├── Notes/                          ✅ Note editing + journal
│   ├── Content/                        ✅ ContentDraftSheet
│   ├── Business/                       ✅ Business dashboard (health summary + 6 tabs: Strategic, Client, Recruiting, Production, Goals, Graph)
│   │   ├── BusinessDashboardView.swift ✅ Top-level BI view (health summary + segmented tabs incl. Graph)
│   │   ├── ClientPipelineDashboardView.swift ✅ Client funnel, metrics, stuck, transitions
│   │   ├── RecruitingPipelineDashboardView.swift ✅ 7-stage funnel, licensing rate, mentoring
│   │   ├── ProductionDashboardView.swift ✅ Status overview, product mix, pending aging, all records
│   │   ├── ProductionEntryForm.swift  ✅ Add/edit production record sheet
│   │   ├── StrategicInsightsView.swift ✅ Strategic digest + recommendation cards + scenario projections
│   │   ├── ScenarioProjectionsView.swift ✅ 2-column projection cards with trend badges
│   │   ├── GoalProgressView.swift     ✅ Goal cards with progress bars + pace indicators
│   │   ├── GoalEntryForm.swift        ✅ Goal create/edit sheet
│   │   ├── RelationshipGraphView.swift ✅ Canvas-based interactive relationship map (now also embedded in Business tab)
│   │   ├── GraphToolbarView.swift     ✅ Zoom/filter/rebuild toolbar for graph
│   │   ├── GraphTooltipView.swift     ✅ Hover tooltip with person summary
│   │   ├── GraphMiniPreviewView.swift ✅ Non-interactive graph thumbnail (deprecated — Graph now embedded in Business tabs)
│   │   ├── StrategicActionSheet.swift ✅ Approach selection sheet when "Act" is clicked
│   │   └── CoachingSessionView.swift  ✅ Chat-style AI coaching session with action buttons
│   ├── Search/                         ✅ SearchView + SearchResultRow
│   ├── Shared/                         ✅ Reusable components (incl. FlowLayout, CommandPaletteView, SAMTips)
│   └── Settings/                       ✅ Tabbed settings (incl. Data Backup + Guidance sections)
│
├── Resources/
│   └── BestPractices.json             ✅ Bundled best practices knowledge base (24 entries, 6 categories)
│
├── Utilities/
│   ├── ComplianceScanner.swift        ✅ Deterministic keyword compliance scanner
│   └── SAMBackupUTType.swift          ✅ UTType.samBackup extension (.sambackup files)
│
└── 1_Documentation/
    ├── context.md                      This file
    ├── changelog.md                    Completed work history
    └── agent.md                        Product philosophy & AI architecture
```

---

## 4. Data Models

### 4.1 Existing Models (Phases A–Z + Deduced Relationships, schema v26)

(All existing models unchanged — see `changelog.md` for full schema. Summary below.)

- **SamPerson** — Contact anchor + CRM enrichment (roles, referrals, channel preferences, phone aliases, preferredCadenceDays, stageTransitions, recruitingStages, productionRecords)
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
- **StrategicDigest** — Cached business intelligence output (pipeline/time/pattern/content summaries, strategic recommendations with feedback tracking)
- **SamDailyBriefing** — `strategicHighlights: [BriefingAction]` field added (Phase V)
- **ContentPost** — Social media posting tracker (platform, topic, postedAt, sourceOutcomeID)
- **BusinessGoal** — User-defined targets (goalType, title, targetValue, startDate, endDate, isActive, notes); progress computed live from existing repos
- **ComplianceAuditEntry** — Draft audit trail (channel, recipient, original/final draft, compliance flags JSON, sent timestamp)
- **DeducedRelation** — Family/household relationships deduced from Apple Contacts related names (personAID, personBID, relationType, sourceLabel, isConfirmed, confirmedAt)

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
- ✅ **Phase T**: Meeting Lifecycle Automation (no schema change)
- ✅ **Phase U**: Relationship Decay Prediction (no schema change)
- ✅ **Phase V**: Business Intelligence — Strategic Coordinator (schema SAM_v22)
- ✅ **Phase W**: Content Assist & Social Media Coaching (schema SAM_v23)
- ✅ **Phase X**: Goal Setting & Decomposition (schema SAM_v24)
- ✅ **Phase Y**: Scenario Projections (no schema change)
- ✅ **Phase Z**: Compliance Awareness (schema SAM_v25)
- ✅ **Advanced Search**: Unified search across people, contexts, evidence, notes, outcomes (no schema change)
- ✅ **Export/Import**: Backup/restore 20 model types + preferences to .sambackup JSON (no schema change)
- ✅ **Phase AA**: Relationship Graph — Visual Network Intelligence (AA.1–AA.7 + advanced interaction + edge bundling + visual polish + accessibility, no schema change)
  - AA.1–AA.7: Core graph, force-directed layout, 9 edge types (incl. roleRelationship), family clustering, bridge indicators, ghost nodes, context menus, keyboard shortcuts
  - Phase 6: Relational-distance selection (double/triple-click + modifier keys), lasso selection (Option+drag), group drag, ripple animation
  - Phase 7: Force-directed edge bundling with polyline control points, label collision avoidance (6 candidate positions)
  - Phase 8: Ghost marching ants, role glyphs at close-up zoom, intelligence overlays (referral hub/betweenness centrality, communication flow, recruiting health, coverage gap), high contrast + reduce transparency + reduce motion accessibility, spring animation presets, drag grid pattern
- ✅ **Deduced Relationships + Me Toggle**: Contact relations import, deduced family edges in graph, Me node toggle, focus mode, Awareness integration (schema SAM_v26)
- ✅ **Household Removal**: Removed `.household` ContextKind from UI/graph, replaced with DeducedRelation-based family clustering; ConsentRequirement.context removed; MeetingBriefing family relations from DeducedRelation; Phase AA specs rewritten for family clusters (schema SAM_v27)
- ✅ **Strategic Action Coaching Flow**: Act button → approach selection → AI coaching chat with action buttons (compose, schedule, draft, note, navigate). Concurrent plan generation with per-recommendation tracking. Best practices knowledge base (24 bundled entries). Constrained AI prompts. macOS system notifications for plan readiness (no schema change)
- ✅ **Life Event Coaching**: Action buttons on Life Event cards (Send Message, Coach Me, Create Note). AI coaching chatbot with event-type-calibrated tone (empathy for loss/health, celebration for milestones, transition support for job changes). Shared FlowLayout extracted. (no schema change)
- ✅ **Interactive Content Ideas**: Content Ideas in Strategic view now persist full structured ContentTopic JSON (keyPoints, suggestedTone, complianceNotes). Each idea is clickable → opens ContentDraftSheet. Backward-compatible with legacy semicolon-separated data. (no schema change)
- ✅ **⌘K Command Palette**: Spotlight-style overlay (⌘K) for quick navigation and people search. Also adds ⌘1–4 sidebar navigation shortcuts. Reuses SearchCoordinator for people search. Static commands: Go to Today/People/Business/Search, New Note, Open Settings. (no schema change)
- ✅ **Coaching Calibration Phase 1**: Business context profile (BusinessProfile DTO + BusinessProfileService) injected into all 6 AI specialist system instructions. Universal blocklist prevents irrelevant suggestions (CRM tools, team references for solo agents, software purchases). Settings > AI > Business Profile section for user configuration. (no schema change)
- ✅ **Coaching Calibration Phases 2–4**: Full feedback system — CalibrationLedger (UserDefaults JSON) tracks per-kind act/dismiss/rating stats, timing patterns, strategic weights, muted kinds, session feedback. CalibrationService actor with cached synchronous accessor. Fixed broken wiring: `shouldRequestRating()` now controls rating frequency, `adjustedWeights()` used in OutcomeEngine. Muted-kind filtering, soft suppress (<15% act rate → 0.3x), per-kind engagement scoring. StrategicCoordinator reads wider calibration weights (0.5–2.0x). `calibrationFragment()` injected into all 6 AI agents via BusinessProfileService. Settings "What SAM Has Learned" section with per-kind progress bars, timing data, strategic weights, mute management, and per-dimension resets. Context menu "Stop suggesting this type" on outcome cards. "Personalized" indicator in queue header after 20+ interactions. Coaching session thumbs up/down feedback. 90-day counter pruning. (no schema change)
- ✅ **Phase AB: In-App Guidance System**: First-launch narrated intro sequence (6 slides, AVSpeechSynthesizer auto-advance with fallback timers) + 12 TipKit contextual coach marks across all major views. NarrationService, IntroSequenceCoordinator, IntroSequenceOverlay, SAMTips with `@Parameter`-based global toggle. "?" toolbar button toggles tips on/off. Settings > General > Guidance section with toggle, Reset All Tips, Replay Intro. BackupCoordinator: added calendarLookbackDays to backup keys. (no schema change)

### Future Phases (Unscheduled)

- **iOS Companion**: Read-only iOS app
- **Custom Activity Types**: User-defined time tracking categories
- **API Integration**: Connect to financial planning software
- **Team Collaboration**: Shared contexts and evidence (multi-user support)

---

## 6. Critical Patterns & Gotchas

(All existing patterns from Phases A–Z remain in effect. See `changelog.md` for full documentation of each. Summary of key rules below.)

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

### 6.7 Background AI Task Rules
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
| v20 | S | + ProductionRecord, WFGProductType, ProductionStatus |
| v21 | U enhancement | + SamPerson.preferredCadenceDays (cadence override) |
| v22 | V | + StrategicDigest, + SamDailyBriefing.strategicHighlights |
| v23 | W | + ContentPost model |
| v24 | X | + BusinessGoal model |
| v25 | Z | + ComplianceAuditEntry model |
| v26 | Deduced Relationships (current) | + DeducedRelation model, DeducedRelationType enum |

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

**Document Version**: 26.0 (Phases A–Z + Advanced Search + Export/Import + Phase AA (complete) + Deduced Relationships + Household Removal + Strategic Action Coaching Flow + Life Event Coaching + Interactive Content Ideas + ⌘K Command Palette + Coaching Calibration Phases 1–4, schema SAM_v27)
**Previous Versions**: See `changelog.md` for version history
**Last Major Update**: February 27, 2026 — Coaching Calibration Phases 2–4: Full feedback system (CalibrationLedger, adaptive weights, muted kinds, soft suppress, "What SAM Has Learned" settings, personalized indicator)
**Clean Rebuild Started**: February 9, 2026
    
