# SAM — Project Context
**Platform**: macOS 26+ (Tahoe)  
**Language**: Swift 6  
**Architecture**: Clean layered architecture with strict separation of concerns  
**Framework**: SwiftUI + SwiftData  
**Last Updated**: March 3, 2026 (Phases A–Z + Advanced Search + Export/Import + Phase AA complete + Strategic Action Coaching Flow + Life Event Coaching + Interactive Content Ideas + ⌘K Command Palette + Coaching Calibration Phases 1–4 + Phase AB Polish + Bug fixes: intro timing, tips state, JSON null, Contacts container, task priorities, schema SAM_v27 + Phase S+: LinkedIn archive import, Unknown Senders triage, Interaction History in PersonDetailView + Contact Enrichment & User Profile Intelligence, schema SAM_v28 + LinkedIn Integration Rebuild: Intentional Touch Scoring, Add/Later review sheet, enhanced triage, schema SAM_v29 + Phase 8: Permissions & Onboarding Audit, Notifications permission step, AI Setup step, step counter, Notifications in Settings + LinkedIn §13 Apple Contacts Batch Sync + §14 SwiftData models, schema SAM_v30)

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
│   ├── BusinessProfileService.swift  ✅ Actor — Business context profile persistence + AI blocklist + calibration injection + LinkedIn profile storage/injection
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
│   ├── IntroSequenceCoordinator.swift ✅ First-launch intro slide machine + narration sync
│   └── ContactEnrichmentCoordinator.swift ✅ Review-and-apply workflow for pending contact enrichments
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
│   ├── DeducedRelationRepository.swift ✅ CRUD for DeducedRelation + confirm
│   └── EnrichmentRepository.swift      ✅ CRUD for PendingEnrichment; dedup by (personID, field, proposedValue); peopleWithEnrichment cache
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
│   ├── SAMModels-Enrichment.swift    ✅ PendingEnrichment @Model; EnrichmentField/Source/Status enums
│   ├── SAMModels-Social.swift        ✅ NotificationTypeTracker, ProfileAnalysisRecord, EngagementSnapshot, SocialProfileSnapshot (schema SAM_v30)
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
│       ├── CalibrationDTO.swift      ✅ CalibrationLedger (per-kind stats, timing patterns, strategic weights, muted kinds)
│       └── UserLinkedInProfileDTO.swift ✅ UserLinkedInProfileDTO + LinkedInPositionDTO/EducationDTO/CertificationDTO; coachingContextFragment
│
├── Views/
│   ├── AppShellView.swift              ✅ Navigation shell (4 sidebar items: Today, People, Business, Search)
│   ├── People/                         ✅ People list + detail (initials fallback, coaching preview, urgency strips, enrichment badge + review sheet)
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

### 4.1 Existing Models (Phases A–Z + Deduced Relationships + Contact Enrichment + LinkedIn Integration Rebuild, schema v29)

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
- **PendingEnrichment** — Per-field contact update candidate (personID soft ref, EnrichmentField, proposedValue, currentValue?, EnrichmentSource, sourceDetail?, EnrichmentStatus: pending/approved/dismissed, createdAt, resolvedAt?). Dedup key: (personID, field, proposedValue). Source can be LinkedIn connection, endorsement, recommendation, or invitation — designed to accept future sources.
- **IntentionalTouch** — A single recorded social touch event (platform, touchType, direction, contactProfileUrl, samPersonID?, date, snippet, weight, source, sourceImportID?, sourceEmailID?). Dedup key: `"platform:touchType:profileURL:minuteEpoch"`. Covers messages, invitations (personalized vs generic), endorsements (given/received), recommendations (given/received), comments, reactions, mentions. Touch scoring uses `TouchScoringEngine.computeScores()` — 1.5× recency bonus for touches within 6 months.
- **LinkedInImport** — Audit record for each LinkedIn archive import event (importDate, archiveFileName, connectionCount, matchedContactCount, newContactsFound, touchEventsFound, messagesImported, status). Enables per-import touch deduplication and import history.
- **UnknownSender** (extended) — Added `intentionalTouchScore: Int`, `linkedInCompany: String?`, `linkedInPosition: String?`, `linkedInConnectedOn: Date?` for LinkedIn-sourced triage contacts.
- **NotificationTypeTracker** (schema SAM_v30) — Tracks which LinkedIn notification types SAM has seen per platform. One record per `(platform, notificationType)` pair. Fields: `firstSeenDate`, `lastSeenDate`, `totalCount`, `setupTaskDismissCount`.
- **ProfileAnalysisRecord** (schema SAM_v30) — Persists profile analysis results in SwiftData (replacing UserDefaults). Fields: `platform`, `analysisDate`, `overallScore`, `resultJson`.
- **EngagementSnapshot** (schema SAM_v30) — Engagement metrics snapshot per platform per period. Prerequisite for §12 EngagementBenchmarker. Fields: `platform`, `periodStart`, `periodEnd`, `metricsJson`, `benchmarkResultJson`.
- **SocialProfileSnapshot** (schema SAM_v30) — Platform-agnostic social profile storage. Prerequisite for §11 CrossPlatformConsistencyChecker. `samContactId` is nil for the user's own profile. Normalized identity + JSON blobs for platform-specific data.

**Non-SwiftData user data (UserDefaults JSON):**
- **UserLinkedInProfileDTO** — User's own LinkedIn profile (headline, current position, education, skills, certifications). Stored as JSON under `sam.userLinkedInProfile`. Accessed via `BusinessProfileService.linkedInProfile()`. Injected into all AI specialist system prompts via `contextFragment()`.

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
- ✅ **Contact Enrichment & User Profile Intelligence** (schema SAM_v28):
  - **Contact Enrichment (Track 1)**: New `PendingEnrichment` SwiftData model + `EnrichmentRepository`. Parse Endorsement_Received/Given, Recommendations_Given, Invitations CSVs. Generate per-field Apple Contacts update candidates from LinkedIn import. `ContactEnrichmentCoordinator` orchestrates review-and-apply workflow. `ContactsService.updateContact()` writes enrichment back to Apple Contacts with SAM note block (`--- SAM ---` delimiter). `PeopleListView` gains "Needs Contact Update" and "Not in Contacts" special filters. `PersonDetailView` shows enrichment banner + `EnrichmentReviewSheet` for per-field approve/dismiss.
  - **User Profile Intelligence (Track 2)**: `UserLinkedInProfileDTO` assembled from Profile.csv, Positions.csv, Education.csv, Skills.csv, Certifications.csv. Stored as JSON in `BusinessProfileService` (UserDefaults). `contextFragment()` now injects `## LinkedIn Profile` section into all 6 AI specialist system prompts.
  - **Pattern**: LinkedIn (and all future social media archives) split into two data tracks: (1) data *about the user* → feeds AI coaching context; (2) data *about contacts* → feeds contact enrichment pipeline. See §13 for the full Social Media Data Extraction Playbook.
- ✅ **LinkedIn Integration Rebuild — Intentional Touch Scoring** (schema SAM_v29):
  - **New models**: `IntentionalTouch` (touch event log with dedup key), `LinkedInImport` (import audit record). `UnknownSender` extended with `intentionalTouchScore`, `linkedInCompany`, `linkedInPosition`, `linkedInConnectedOn`.
  - **New repository**: `IntentionalTouchRepository` — bulk insert with in-memory dedup (`platform:touchType:profileURL:minuteEpoch`), per-profile and per-person fetch, score computation from persisted records, touch attribution backfill when Later contact is promoted.
  - **Extended service**: `LinkedInService` gains parsers for `Recommendations_Received.csv`, `Reactions.csv`, `Comments.csv`; updated endorsement/invitation DTOs with dates; fixed endorsement date formatter (`yyyy/MM/dd HH:mm:ss zzz`) and invitation date formatter (`M/d/yy, h:mm a`).
  - **Coordinator rebuild**: `LinkedInImportCoordinator` now parses all 8 touch CSVs in `loadFolder`, runs `TouchScoringEngine.computeScores()` to score every profile URL, builds `importCandidates: [LinkedInImportCandidate]` sorted by score, exposes `.awaitingReview` status. `confirmImport(classifications:)` takes `[UUID: LinkedInClassification]` map, persists `IntentionalTouch` records, routes "Later" contacts via `UnknownSenderRepository.upsertLinkedInLater()`.
  - **New DTO**: `LinkedInImportCandidateDTO.swift` — `LinkedInImportCandidate` (firstName, lastName, profileURL, email, company, position, connectedOn, touchScore, matchStatus, defaultClassification), `LinkedInMatchStatus` enum, `LinkedInClassification` enum.
  - **New UI**: `LinkedInImportReviewSheet` — two-section sheet (Recommended to Add / No Recent Interaction), per-contact toggles with touch score badge and summary, batch "Add All" button, ⌘↩ to import.
  - **Enhanced triage**: `UnknownSenderTriageSection` shows LinkedIn contacts in a dedicated subsection above regular senders, sorted by touch score, with company/position display and no "Never" option.
  - **Settings**: `LinkedInImportSettingsView` now shows "Review & Import" button (opens sheet) instead of inline confirm; status `.awaitingReview` suppresses the progress indicator.
- ✅ **LinkedIn §13 + §14 — Apple Contacts Batch Sync + Social SwiftData Models** (schema SAM_v30):
  - §13.1: `AppleContactsSyncConfirmationSheet` — post-import batch dialog ("Add LinkedIn URLs to X Apple Contacts?"), single-confirmation batch write via `ContactsService.updateContact`. Only contacts marked "Add" and lacking LinkedIn URL.
  - §13.2: Auto-sync toggle in `LinkedInImportSettingsContent` (UserDefaults `sam.linkedin.autoSyncAppleContactURLs`). When enabled, writes silently in `confirmImport` step 10 without dialog.
  - §14: Four new SwiftData models in `SAMModels-Social.swift`: `NotificationTypeTracker` (replaces IntentionalTouchRepository proxy for setup guidance), `ProfileAnalysisRecord` (SwiftData-backed profile analysis history), `EngagementSnapshot` (§12 prerequisite), `SocialProfileSnapshot` (§11 prerequisite). All additive. Schema SAM_v29 → SAM_v30.
  - `AppleContactsSyncCandidate` DTO added to `LinkedInImportCandidateDTO.swift`.
  - Coordinator: `prepareSyncCandidates`, `performAppleContactsSync`, `dismissAppleContactsSync` methods; `appleContactsSyncCandidates` observable state; `autoSyncLinkedInURLs` UserDefaults property.
- ✅ **Phase 8 — Permissions & Onboarding Audit** (no schema change):
  - Onboarding extended from 8 → 10 steps with step counter ("Step X of 10") in header.
  - **Step 9 — Notifications**: `UNUserNotificationCenter` permission request with explanation of what's missed without it. Skip allowed. "Enable Notifications" / "Skip" footer pair. `checkStatuses()` detects pre-existing grant.
  - **Step 10 — AI Setup**: Mistral 7B download UI (GroupBox with Download/Cancel/Ready states + ProgressView). Polls `MLXModelManager.shared.downloadProgress` every 250ms. If model downloaded before "Start Using SAM", `saveSelections()` writes `aiBackend = "hybrid"` to UserDefaults.
  - **Complete step**: StatusRow/SkippedRow added for Notifications and Enhanced AI.
  - **Settings > Permissions**: Notifications row added to `PermissionsSettingsView` (bell.circle.fill/red, status check on `.task`, Request Access button).
  - **Accessibility permission not added**: No feature requiring it (Priority 2 global hotkey) has been built yet.

### LinkedIn Integration Spec — Coverage Status

Tracking against `SAM-LinkedIn-Integration-Spec.md` (verified by code audit 2026-03-03):

| Section | Title | Status |
|---------|-------|--------|
| §1 | Architecture Overview | Reference only |
| §2 | File Inventory & Schema | Reference only |
| §3 | Data Categories & Classification | Reference only |
| §4 | Contact Import Pipeline | ✅ Complete |
| §5 | Intentional Touch Detection & Scoring | ✅ Complete |
| §6 | Unknown Contact Triage (Add vs Later) | ✅ Complete |
| §7 | De-duplication & Merge Logic | ✅ Complete |
| §8 | LinkedIn Email Notification Monitor | ✅ Complete — `LinkedInEmailParser.swift` (490 lines), `LinkedInImportCoordinator.handleNotificationEvent()` |
| §9 | Notification Setup Guidance System | ✅ Complete — `LinkedInNotificationSetupGuide.swift` (195 lines), 5 monitored types, step-by-step instructions |
| §10 | Profile Analysis Agent | ✅ Complete — `ProfileAnalystService`, `BusinessProfileService`, `ProfileAnalysisDTO` |
| §11 | Cross-Platform Profile Consistency | ⏸ Deferred — **unblocked by Facebook integration** (Priority 2, Phase FB-4). See `SAM-Facebook-Integration-Spec.md` |
| §12 | Engagement Benchmarking & Suggestions | ⏸ Deferred — requires `EngagementSnapshot` model and benchmarking agent. **Facebook data enables cross-platform benchmarking.** |
| §13 | Apple Contacts Sync (LinkedIn URL write-back) | ✅ Complete — batch confirmation dialog (`AppleContactsSyncConfirmationSheet`), auto-sync toggle in Settings, `prepareSyncCandidates`/`performAppleContactsSync` in coordinator |
| §14 | Data Model (SwiftData) | ✅ Complete — all 4 models added in SAM_v30: `NotificationTypeTracker`, `ProfileAnalysisRecord`, `EngagementSnapshot`, `SocialProfileSnapshot` |
| §15 | Agent Definitions | ⚠️ Partial — `LinkedInProfileAnalyzer`, `MessageReplyAdvisor`, `NotificationSetupAdvisor` built; `CrossPlatformConsistencyChecker` and `EngagementBenchmarker` deferred with §11/§12 |

**Overall LinkedIn spec: ~92% complete.** All core user-facing features plus §13 batch sync and §14 data models are complete. Remaining work is §11/§12 (deferred, multi-platform dependency).

### Planned — Priority Order

The following are ordered by recommended implementation priority. Items marked **[Deferred]** require investigation or have a dependency before they can be started.

---

#### ~~Priority 1 — Permissions & Onboarding Audit~~ *(Completed 2026-03-03)*
- ✅ Onboarding extended to 10 steps (Notifications + AI Setup), step counter added, Settings Permissions tab updated. See completed phases above and changelog.

---

#### ~~Priority 1 — LinkedIn §13 Apple Contacts Batch Sync + §14 Missing SwiftData Models~~ *(Completed 2026-03-03)*
- ✅ §13.1 post-import batch confirmation dialog added to `LinkedInImportReviewSheet`
- ✅ §13.2 auto-sync toggle added to `LinkedInImportSettingsContent`
- ✅ §14 four SwiftData models added in `SAMModels-Social.swift`: `NotificationTypeTracker`, `ProfileAnalysisRecord`, `EngagementSnapshot`, `SocialProfileSnapshot` (schema SAM_v30)

---

#### Priority 1 — Facebook Integration *(High — unlocks cross-platform intelligence, second social data source)*

Full specification: `SAM-Facebook-Integration-Spec.md`

Facebook is the second social platform for SAM, unlocking LinkedIn §11 (Cross-Platform Profile Consistency) and §12 (Engagement Benchmarking). Unlike LinkedIn (CSV, professional, email-monitorable), Facebook exports are JSON with different challenges: mojibake text encoding, no profile URLs in friends list, personal-first relationship semantics, and per-directory message threads.

**Phased implementation (6 phases):**

| Phase | Title | Scope | Key Files |
|-------|-------|-------|-----------|
| **FB-1** ✅ | Core Import Pipeline | Parse friends list, UTF-8 repair, candidate matching, review sheet | `FacebookService.swift`, `FacebookImportCoordinator.swift`, `FacebookImportCandidateDTO.swift`, `UserFacebookProfileDTO.swift` |
| **FB-2** ✅ | Messenger & Touch Scoring | Parse all message threads (inbox/e2ee/archived/filtered), comments, reactions, friend requests → IntentionalTouch records | Extend `FacebookService`, reuse `IntentionalTouchRepository` + `TouchScoringEngine` |
| **FB-3** ✅ | User Profile Intelligence & Agent | Parse user's own profile for coaching context, implement Facebook profile analysis agent with personal-tone prompt | `FacebookProfileAnalystService.swift`, `FacebookAnalysisSnapshot.swift`, extend `BusinessProfileService` |
| **FB-4** ✅ | Cross-Platform Consistency | Compare LinkedIn + Facebook profiles, identify cross-platform contacts, implement §11 agent | `CrossPlatformConsistencyService.swift` |
| **FB-5** ✅ | Apple Contacts Sync | Write Facebook URLs back to Apple Contacts (same pattern as LinkedIn §13) | Extend `ContactsService`, `EnrichmentField.facebookURL` |
| **FB-6** ✅ | Polish & Documentation | Settings UI, import history, re-import detection, stale data warning | Settings views, context.md, changelog.md |

**Key technical challenges:**
- **Mojibake repair:** Facebook JSON uses Latin-1 encoded UTF-8 — all strings require `repairFacebookUTF8()` pass after deserialization
- **No profile URLs:** Friends list has only name + timestamp (no URLs, no emails, no company) — matching relies heavily on fuzzy name matching against existing SAM contacts and Apple Contacts
- **Per-directory messages:** Hundreds of `message_1.json` files in nested subdirectories vs LinkedIn's single CSV
- **Agent tone difference:** Facebook agent must be personal/community-focused, never suggesting promotional activity (see spec §8.3 for full prompt)

**Schema change:** SAM_v31 — adds `FacebookImport` model, extends `UnknownSender` with `facebookFriendedOn`, `facebookMessageCount`, `facebookLastMessageDate`

**No email monitoring channel:** Facebook notification emails are too generic to parse. SAM relies on periodic re-imports only.

---

#### Priority 2 — Global Clipboard Capture Hotkey *(High — high ROI, closes the "other channels" gap)*
- Channel-agnostic: captures conversations pasted from LinkedIn web, WhatsApp web, or any platform the user copies from.
- Requires Accessibility permission (`AXIsProcessTrusted()`) — global `CGEventTap`.
- Detects conversation structure in clipboard (multi-line, name/timestamp patterns), parses into individual messages, offers "Capture to SAM" sheet.
- Uses same `sourceUID` dedup scheme as archive imports — if a later archive import finds the same message, the existing record wins silently.
- One user habit covers all channels without dedicated per-platform importers.

---

#### Priority 3 — LinkedIn as Reply Channel *(Medium — completes the LinkedIn integration)*
- Surfaces LinkedIn alongside iMessage/email in channel recommendation logic.
- Draft reply UI: "LinkedIn" option with a copy button (same pattern as existing channels).
- Uses `linkedInProfileURL` already stored on `SamPerson` for deep-link open.
- Low implementation cost since the profile URL infrastructure is already in place.

---

#### Priority 4 — Social Media Export Reminder Flow *(Medium — reduces friction for periodic re-imports)*
- LinkedIn, Facebook and possibly other social media platforms allow data exports can take up to 24 hours after requesting them.
- Establish a low friction way for the User to request data exports from all social media platforms where we need period data updates.
- Surface an appropriate item in Today (and the day overview) when both the user needs to request an export as well as when SAM finds an email that states that the export is ready to download. ("Your LinkedIn export may be ready — import now?").

---

#### Priority 5 — WhatsApp Direct Database Integration *(Medium — [Deferred: feasibility verification needed])*
- Database at `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite` is unencrypted SQLite, schema confirmed (`ZWAMESSAGE` table, `ZISFROMME`, `ZTEXT`, `ZMESSAGEDATE` Apple Epoch, `ZFROMJID`, `ZTOJID`, `ZPUSHNAME`, `ZCHATSESSION → ZWACHATSESSION.ZCONTACTJID`).
- Viable path: user-initiated `NSOpenPanel` file selection + security-scoped bookmark (same pattern as iMessage/CallHistory).
- Watermark on `ZMESSAGEDATE`. Dedup key: `whatsapp:<jid>:<unix_timestamp>:<first50charshash>`.
- **Action needed**: Verify that `NSOpenPanel` + security-scoped bookmark actually grants persistent read access to this specific Group Container path on macOS 15+. Test on a real device before building the importer. Do not start implementation until verified.

---

#### Priority 6 — iOS Companion App *(Low — read-only, adds reach)*
- Read-only iOS companion for reviewing relationship health, today's briefing, and coaching outcomes while away from the Mac.
- Shares SwiftData model definitions; no write operations in v1.
- Requires iCloud sync design decision (CloudKit vs. local-only with handoff).

---

#### Priority 7 — Custom Activity Types *(Low — refinement)*
- User-defined time tracking categories beyond the built-in WFG-relevant set.
- Extends `TimeEntry` model; requires UI in Settings > Time Tracking.

---

#### Priority 8 — API Integration *(Low — future growth)*
- Connect to financial planning or CRM software (e.g. WFG back-office systems).
- Dependent on available APIs and user demand. No design work started.

---

#### Priority 9 — Team Collaboration *(Low — long-term)*
- Shared contexts and evidence across multiple SAM users (e.g. agent teams).
- Requires significant architecture changes: multi-user identity, conflict resolution, permission model.
- Not viable until the single-user product is stable and widely used.

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
| v26 | Deduced Relationships | + DeducedRelation model, DeducedRelationType enum |
| v27 | Household Removal | Removed .household ContextKind; schema cleanup only |
| v28 | Contact Enrichment | + PendingEnrichment model, EnrichmentField/Source/Status enums |
| v29 | LinkedIn Integration Rebuild | + IntentionalTouch, LinkedInImport models; UnknownSender extended |
| v30 | LinkedIn §14 Social Models (current) | + NotificationTypeTracker, ProfileAnalysisRecord, EngagementSnapshot, SocialProfileSnapshot |

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

## 13. Social Media Data Extraction Playbook

This section captures the conceptual framework established during the LinkedIn integration so that future platform imports (Facebook, X/Twitter, WhatsApp, Instagram, etc.) follow the same pattern and take advantage of existing infrastructure.

---

### 13.1 The Two-Track Model: User Data vs. Contact Data

Every social media archive contains two fundamentally different categories of information. Classify all files before writing any parsing code.

**Track 1 — Data About the User**
This is the user's own profile, history, and activity on the platform. It enriches SAM's understanding of the user so that AI coaching is better calibrated to their background, expertise, and context.

| What it includes | How SAM uses it |
|-----------------|-----------------|
| Profile bio, headline, industry, location | Informs AI specialist system prompts via `BusinessProfileService.contextFragment()` |
| Career history / work experience | Current role + trajectory → business coaching context |
| Education | Credential signals for goal-setting and credibility coaching |
| Skills / certifications | Expertise alignment with client/recruit profiles |
| Stated goals / interests | Coaching tone calibration |

**Track 2 — Data About Contacts**
This is information about the people the user knows through the platform — connections, conversation history, endorsements, recommendations. It enriches Apple Contacts records and feeds the relationship intelligence pipeline.

| What it includes | How SAM uses it |
|-----------------|-----------------|
| Connection list (name, employer, title, profile URL) | Diff against Apple Contacts → `PendingEnrichment` for company/title updates |
| Messages / conversations | Evidence items via `EvidenceRepository.bulkUpsertMessages` |
| Endorsements received | Confirms relationship signal; can surface LinkedIn URL enrichment |
| Endorsements given | Relationship signal; identifies people the user values |
| Recommendations given | Strong relationship signal; high-quality context for PersonDetailView |
| Invitations (sent/received) | Directionality of network expansion; prospecting signal |
| Reactions / comments (if exported) | Light engagement signal |

---

### 13.2 Platform Archive Inspection Checklist

Before implementing any new platform importer, do this in order:

1. **Request and download a real data export** from the platform using your own account.
2. **Inventory all files**: List every CSV, JSON, and HTML file. Note file sizes — large files are likely the interesting ones.
3. **Classify each file** as Track 1 (about user) or Track 2 (about contacts), or discard if irrelevant.
4. **Inspect the actual column headers** of every CSV — don't guess. Platform exports often have inconsistent casing, spacing, or column ordering across export versions. Always verify with real data before writing DTOs.
5. **Note date formats**: ISO 8601? Unix timestamp? Apple Epoch (CFAbsoluteTime, used by WhatsApp)? Milliseconds? Document the format for each file.
6. **Note encoding**: UTF-8? UTF-16? Are there BOM markers? LinkedIn CSVs are UTF-8 with BOM on some exports.
7. **Note dedup keys**: What combination of fields uniquely identifies a message or connection? This becomes the `sourceUID` in `SamEvidenceItem`. Pattern: `{platform}:{identifier}:{timestamp}`.
8. **Check for profile URLs**: Does the platform export profile page URLs for contacts? If yes, this is the highest-quality match key — use it for `linkedInProfileURL` / equivalent field on `SamPerson`.
9. **Check for phone/email in contact export**: If present, these are high-confidence enrichment candidates for Apple Contacts.

---

### 13.3 Parsing Architecture

All new platform importers follow the same layered structure:

```
{Platform}Service       (actor in Services/)
    ↓  pure CSV/JSON parsing, returns Sendable DTOs
{Platform}ImportCoordinator   (@MainActor @Observable in Coordinators/)
    ↓  matching, dedup, evidence writing, enrichment generation
EnrichmentRepository / EvidenceRepository   (existing — no changes needed)
```

**`{Platform}Service` (actor)**
- One method per CSV/JSON file: `parseConnections(at:)`, `parseMessages(at:)`, etc.
- Returns arrays of `Sendable` DTOs — no SwiftData models, no Apple framework types
- Uses `parseCSV(at:)` helper (already in `LinkedInService` — consider extracting to a shared utility)
- All methods are `async` — file I/O is always async

**`{Platform}ImportCoordinator` (@MainActor @Observable)**
- Holds the security-scoped bookmark URL for the platform's folder/file
- `loadFolder(url:)` — parse preview without committing; populates `pending*Count` state
- `confirmImport()` — commit: write evidence, generate enrichment, save user profile
- `cancelImport()` — clear all pending state
- Integrates with existing `UnknownSenderRepository` for unmatched contacts
- State follows the `ImportStatus` enum pattern (idle/parsing/preview/importing/success/error)

**DTOs**
- One DTO file per platform in `Models/DTOs/`
- All DTOs: `Sendable` + `Codable` (Codable enables caching and preview if needed)
- `nonisolated` on any computed properties to avoid Swift 6 `@MainActor` inference

---

### 13.4 Contact Matching Strategy (in Priority Order)

When mapping platform contacts to existing `SamPerson` records, always try in this order:

1. **Platform profile URL** — `SamPerson.linkedInProfileURL` or equivalent field. Exact match. Highest confidence.
2. **Email address** — if the platform export includes contact email. Match against Apple Contacts via `ContactsService`.
3. **Phone number** — if exported. Match against `SamPerson.phoneAliases`.
4. **Fuzzy display name** — first + last name normalized (lowercased, diacritics stripped). Use only as a last resort; flag low-confidence matches for user review.

Unmatched contacts go to `UnknownSenderRepository` with a synthetic key `{platform}:{profileURL}` (or `{platform}-unknown-{name}` when no URL). The triage UI surfaces these for the user to link or dismiss.

---

### 13.5 Evidence Dedup Keys

Every platform needs a unique, stable, deterministic `sourceUID` for evidence items:

| Platform | Message dedup key pattern |
|----------|--------------------------|
| LinkedIn | `linkedin:{senderProfileURL}:{ISO8601date}` |
| WhatsApp | `whatsapp:{jid}:{unix_timestamp}:{first50charshash}` |
| Facebook | `facebook:{threadID}:{messageID}` (if exported) or `facebook:{senderID}:{unix_ms}` |
| X/Twitter | `twitter:{DM_conversationID}:{tweetID}` |
| Instagram | `instagram:{threadID}:{timestamp}` |

The dedup key is stored in `SamEvidenceItem.sourceUID`. `EvidenceRepository.bulkUpsertMessages` already handles dedup — if a key exists, the existing record wins silently.

---

### 13.6 Enrichment Fields Available Per Platform

Not every platform provides the same contact metadata. Map available fields to `EnrichmentField` cases:

| EnrichmentField | LinkedIn | Facebook | X | WhatsApp | Notes |
|----------------|----------|----------|---|----------|-------|
| `.company` | ✅ Connections.csv | ✗ | ✗ | ✗ | LinkedIn is primary source |
| `.jobTitle` | ✅ Connections.csv | ✗ | ✗ | ✗ | LinkedIn is primary source |
| `.email` | ✅ Connections.csv | ✅ if exported | ✗ | ✗ | Verify not already in Contacts |
| `.phone` | ✗ | ✅ if exported | ✗ | ✅ JID encodes phone | WhatsApp JID = phone@s.whatsapp.net |
| `.linkedInURL` | ✅ Profile URL | ✗ | ✗ | ✗ | |

When a platform provides a phone number or email, always check if it already exists in Apple Contacts before creating a `PendingEnrichment`. Only propose values that are genuinely new.

---

### 13.7 User Profile Data: What to Extract and How to Use It

For Track 1 (user self-description), the goal is to feed `BusinessProfileService.contextFragment()` so that AI specialists understand who the user is. A richer context fragment produces better-calibrated coaching.

**High-value fields to extract:**
- **Current role and employer** — anchor for all business coaching; makes "grow your practice" advice concrete
- **Career history** — trajectory context; useful for identifying transferable skills and past-life relationships
- **Skills** — what the user is confident doing; prevents coaching suggestions that are out of scope
- **Certifications / credentials** — professional legitimacy signals; useful for content suggestions ("as an SPHR…")
- **Education** — long-horizon relationships (alumni networks); sometimes relevant for recruiting coaching
- **Bio/summary** — often the highest-signal single field; captures how the user describes themselves

**Storage pattern:**
- Serialize to JSON via `Codable`
- Store in `UserDefaults` under a namespaced key (`sam.{platform}Profile`)
- Cache in-memory in `BusinessProfileService`
- `contextFragment()` appends a `## {Platform} Profile` section when the profile is present
- The DTO's `coachingContextFragment` computed property (marked `nonisolated`) formats the data for LLM consumption — headline + current role + top skills + active certifications

**Do not store:**
- Raw biography text verbatim if it's very long — summarize to the most relevant fields
- Historical data the user has edited away (past employers they've removed) — respect their current self-presentation

---

### 13.8 Watermark-Based Incremental Import

All platform importers use a watermark (last import date in UserDefaults) to avoid reprocessing old records on subsequent imports:

```swift
let lastImport = UserDefaults.standard.object(forKey: "sam.{platform}.lastImportDate") as? Date
// On first run: lastImport == nil → process all records
// On subsequent runs: skip records older than lastImport
```

After a successful `confirmImport()`:
```swift
UserDefaults.standard.set(Date(), forKey: "sam.{platform}.lastImportDate")
```

Caveats:
- The watermark is set at confirm time, not parse time — a cancelled import does not advance the watermark
- For platforms where messages may arrive out of order (delayed delivery), consider a small lookback buffer (e.g., watermark minus 7 days) to catch late arrivals
- User profile data (Track 1) is always replaced wholesale — no watermark needed

---

### 13.9 Platform-Specific Notes

**Facebook**
- Data export: Settings → Your Facebook Information → Download Your Information
- Format options: JSON (preferred for parsing) or HTML
- Key files: `messages/inbox/*/message_1.json` (conversations), `profile_information/profile_information.json` (user profile)
- Contact matching: Facebook rarely exports email/phone. Display name matching is the primary fallback.
- Encoding: Facebook JSON uses Latin-1 encoding with unicode escapes for non-ASCII — requires `String(bytes:encoding:.isoLatin1)` or similar decoding step.

**X (Twitter)**
- Data export: Settings → Your Account → Download an archive of your data
- Key files: `data/direct-messages.js`, `data/profile.js`, `data/account.js`
- Format: JavaScript files with a leading variable assignment (`window.YTD.direct_messages.part0 = [...]`) — strip the prefix before JSON parsing
- Contact matching: X handles are stored in DM threads; cross-reference against any stored `xProfileURL` on `SamPerson`

**WhatsApp**
- Database: `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite` (unencrypted SQLite on macOS)
- Key table: `ZWAMESSAGE` (ZISFROMME, ZTEXT, ZMESSAGEDATE in Apple CFAbsoluteTime, ZFROMJID)
- Contact matching: JID format is `{phone}@s.whatsapp.net` — strip suffix to get E.164 phone number → match against Apple Contacts
- **Deferred**: Verify `NSOpenPanel` + security-scoped bookmark grants persistent read access to this Group Container path before implementing (see Priority 5 in §5)
- Date conversion: `ZMESSAGEDATE` is CFAbsoluteTime (seconds since Jan 1, 2001). Convert: `Date(timeIntervalSinceReferenceDate: zmessagedate)`

**Instagram**
- Data export: Settings → Account → Data Download
- Key files: `messages/inbox/*/message_1.json` (same format as Facebook — Meta unified format)
- Parsing code can likely be shared with the Facebook messages parser

---

### 13.10 Adding a New Platform — Implementation Checklist

Use this checklist when starting a new social media importer:

- [ ] Request a real data export from the platform and inspect all files (§13.2)
- [ ] Classify every file as Track 1 (user) or Track 2 (contacts) or discard
- [ ] Define DTOs for each relevant file (`{Platform}ConnectionDTO`, `{Platform}MessageDTO`, `UserXProfileDTO`, etc.)
- [ ] Create `{Platform}Service` actor with one parse method per file
- [ ] Verify all CSV/JSON column headers against real export data before finalizing DTOs
- [ ] Determine dedup key pattern (§13.5)
- [ ] Create `{Platform}ImportCoordinator` following the standard coordinator pattern
- [ ] Add `UserDefaults` watermark key
- [ ] Integrate unmatched contacts with `UnknownSenderRepository` using `{platform}:` key prefix
- [ ] Add enrichment candidate generation using existing `EnrichmentRepository`
- [ ] If Track 1 profile data exists: create `User{Platform}ProfileDTO`, add `save/load` methods to `BusinessProfileService`, extend `contextFragment()`
- [ ] Add settings UI (folder picker or file picker, import status, unmatched count hint)
- [ ] Update `LinkedInImportSettingsView` as a reference — copy the structure
- [ ] Verify: import → check evidence counts → check enrichment candidates → check AI context fragment in logs

---

**Document Version**: 29.0 (Phases A–Z + Advanced Search + Export/Import + Phase AA (complete) + Deduced Relationships + Household Removal + Strategic Action Coaching Flow + Life Event Coaching + Interactive Content Ideas + ⌘K Command Palette + Coaching Calibration Phases 1–4 + Phase AB + Contact Enrichment & User Profile Intelligence + LinkedIn Integration Rebuild, schema SAM_v29)
**Previous Versions**: See `changelog.md` for version history
**Last Major Update**: March 3, 2026 — LinkedIn Integration Rebuild: IntentionalTouch + LinkedInImport models, IntentionalTouchRepository, TouchScoringEngine, LinkedInImportReviewSheet, enhanced UnknownSenderTriageSection, date formatter fixes, schema SAM_v29
**Clean Rebuild Started**: February 9, 2026

