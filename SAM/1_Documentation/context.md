# SAM — Project Context

**Platform**: macOS 26+ (Tahoe) | **Language**: Swift 6 | **Framework**: SwiftUI + SwiftData | **Schema**: SAM_v34

This document carries only the context that future development is most likely to need. Deep references for self-contained subsystems live in satellite docs:

- `CLAUDE.md` (repo root) — Product philosophy, AI behavior rules, code standards
- `changelog.md` — Completed phase history (Phases A–Z + post-phase features)
- `scaling-roadmap.md` — Phase 0–4 plan for data-growth observability and architectural scaling
- `social-import-pipeline.md` — Async export auto-detection pipeline (Substack / LinkedIn / Facebook)
- `app-lock-architecture.md` — Lock state, overlays, draft preservation, security primitives
- `crash-recovery.md` — Startup hardening, crash detection, Safe Mode
- `compliance-architecture.md` — Practice-type compliance scanning rules and maintenance
- `contact-photo-and-invitations.md` — Photo write-back to Contacts, rich invitations + sent-mail detection
- `transcription-and-summary.md` — Recording contexts, auditable summary fields, lecture pipeline
- `text-scaling.md` — `samFont` / `samTextScale` font scaling rules
- `accepted-warnings.md` — Warnings we live with on purpose, with reasons

---

## 1. What SAM Is

A **native macOS coaching assistant** for independent financial strategists at WFG. SAM observes interactions (Calendar, Contacts, Mail, iMessage, Phone, FaceTime, WhatsApp, LinkedIn, Facebook), transforms them into evidence, generates AI-backed insights, and provides outcome-focused coaching at both the relationship and business level.

**Core invariants**:
- Apple Contacts and Calendar are the **systems of record** — SAM enriches but never replaces
- Social platform imports create **standalone SamPerson records** — never write to Apple Contacts without explicit user action
- **All AI processing is on-device** — no cloud, no telemetry
- AI is primarily assistive, but **autonomous for background analysis and recommendations**
- All actions that **write to external data sources** (Contacts, Calendar, iMessages, etc.) require explicit user approval — which may be granted via Settings for recurring operations

---

## 2. Architecture

### 2.1 Layered Structure

```
┌─────────────────────────────────────────────────────────┐
│                     Views (SwiftUI)                     │
│           @MainActor, render DTOs/ViewModels            │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│                    Coordinators                          │
│    @MainActor @Observable, business logic orchestration  │
└───────────┬─────────────────────┬───────────────────────┘
            │                     │
┌───────────▼────────────┐  ┌─────▼─────────────────────┐
│      Services          │  │       Repositories         │
│  actor, external APIs  │  │  @MainActor, SwiftData CRUD│
│  return Sendable DTOs  │  │                            │
└───────────┬────────────┘  └─────┬─────────────────────┘
            │                     │
┌───────────▼────────────┐  ┌─────▼─────────────────────┐
│   External APIs        │  │        SwiftData            │
│ CNContactStore, EK,    │  │   SamPerson, OutcomeBundle, │
│ FoundationModels, MLX  │  │   BusinessGoal, etc.        │
└────────────────────────┘  └─────────────────────────────┘
```

**Rules**: Views never touch raw CNContact / EKEvent. All actor-boundary data is `Sendable` DTOs. One CNContactStore, one EKEventStore (never create duplicates). Repositories use `SAMModelContainer.shared`.

**AppKit interop**: SwiftUI-first, but specific window-level behaviors require AppKit. The sidebar toggle uses `NSTitlebarAccessoryViewController` (`SidebarToggleConfigurator.swift`) to pin the toggle next to the traffic lights. Other AppKit interop: NSTextView for rich editing, AppleScript bridges, security-scoped bookmarks.

### 2.2 AI: Two Layers + RLM Orchestration

**Layer 1 — Relationship Intelligence (foreground, <5s response)**: Note analysis, meeting pre-briefs, follow-up drafts, health scoring, outcome generation, channel recommendations.

**Layer 2 — Business Intelligence (background, `TaskPriority.background`)**: Pipeline analytics, production trends, time allocation, pattern detection, content suggestions, scenario projections, strategic digest.

**RLM Pattern**: `StrategicCoordinator` (Swift, not LLM) decomposes business reasoning into focused sub-problems, dispatches specialist analysts (PipelineAnalyst, TimeAnalyst, PatternDetector, ContentAdvisor) in parallel via `TaskGroup`, then synthesizes results deterministically. Each specialist receives <2000 tokens of pre-aggregated data. All numerical computation happens in Swift — LLMs interpret and narrate. Results cached with TTL (pipeline=4h, patterns=24h, projections=12h).

See `CLAUDE.md` for the full RLM architecture description and priority hierarchy.

---

## 3. AI Output Quality Standards

Every piece of AI output must meet these standards. Non-negotiable design principles for all coaching, suggestions, and analysis.

### 3.1 Concrete, Not Vague

Every suggestion must include specific names, specific context, and a ready-to-use artifact.

| Bad | Good |
|-----|------|
| "Follow up with John" | "Follow up with John about the IUL quote from your Feb 15 meeting. Draft: 'Hi John, I wanted to check in on the IUL we discussed...'" |
| "Lead numbers are low" | "You need 5 more leads to hit your Q2 goal. 3 contacts show interest: [names + evidence]. Here's an outreach script for each." |

### 3.2 Copy-Paste Ready

All drafts, profile text suggestions, and scripts should be complete and ready to use — not instructions on what to write.

### 3.3 People-Specific

Business observations must always connect to named individuals. "Pipeline is slow" becomes "These 3 applicants have stalled: [names], here's why and what to do about each."

### 3.4 Ask When You Don't Know

When SAM lacks information to be specific, it shows an inline prompt (`InlineGapPromptView`) above outcome cards. Answers stored in UserDefaults (`sam.gap.*`), fed into AI context via `gapAnswersContext()`. Max 1 gap prompt shown at a time.

### 3.5 Noise Prevention

- Surface only what's actionable **right now** in any given view
- Completed, stale, or low-confidence items hidden by default
- Prefer **one excellent suggestion** over five mediocre ones
- Every outcome card should pass the test: "Can the user act on this in the next 2 hours?"
- **Outcome dedup respects user choices**: `OutcomeRepository.hasRecentlyActedOutcome()` suppresses regeneration of outcomes the user dismissed or completed for 7 days. The 24-hour active-duplicate window (`hasSimilarOutcome`) remains for pending/inProgress outcomes.

### 3.6 Bundled Outreach

Per-person outreach outcomes are aggregated into a single `OutcomeBundle` rather than one outcome per topic. The bundle generator collapses multiple signals (life event, stale cadence, pending follow-up) into one card with sub-items. Dismissals at the sub-item level are preserved across regeneration via `OutcomeDismissalRecord`.

---

## 4. Contact Lifecycle Management

Contacts have a lifecycle beyond active/inactive. `ContactLifecycleStatus` on `SamPerson` controls visibility, suggestions, and outreach.

| State | Enum | Behavior |
|-------|------|----------|
| **Active** | `.active` | Normal — appears in lists, receives suggestions, contributes to metrics |
| **Archived** | `.archived` | Hidden from active lists but searchable. No suggestions. |
| **DNC** | `.dnc` | SAM never generates outreach. Still visible in history. Not overridden on re-import. |
| **Deceased** | `.deceased` | Special archived state — prevents all outreach. Life event preserved. |
| **Never Added** | n/a | Unknown sender marked "Never" via `UnknownSender` model — reversible, searchable |

`SamPerson.isArchived` is a computed `@Transient` property (`lifecycleStatus != .active`) for backward compat across 13+ filter sites. `isArchivedLegacy` stored with `@Attribute(originalName: "isArchived")` for schema column continuity.

**Broader contact matching**: When importing from social platforms, scan **all** Apple Contacts (not just the SAM group) for matches and offer to move matched contacts into the SAM group (one-time prompt per import, with "Don't ask again").

**Noise reduction**: OutcomeEngine scanner #13 proactively suggests archiving contacts with no evidence in 12+ months and no pipeline-relevant roles.

---

## 5. Social Platform Imports

Detailed pipeline in `social-import-pipeline.md`. The headline rules:

- Social imports create **standalone SamPerson** records (`contactIdentifier: nil`)
- Coordinator follows standard `ImportStatus` pattern: idle → parsing → preview → importing → success/error
- Long-running import flows live in **standalone Window scenes** (`import-linkedin`, `import-facebook`, `import-substack`, `import-evernote`), not main-window sheets — so a background-coordinator sheet cannot dismiss them mid-review. Triggered via notifications observed by `AppShellView`'s `SocialImportWindowObservers`.
- Two-track DTO model: Track 1 = user profile (always replaced wholesale, fed into AI prompts); Track 2 = contact data (incremental via watermark)
- Voice analysis (user's writing samples) is standard for any platform with the user's posted content

---

## 6. Data Models

All models use SwiftData lightweight migration. Enum storage uses `rawValue` pattern with `@Transient` computed property.

| Model | Purpose | Key Fields |
|-------|---------|------------|
| **SamPerson** | Contact anchor + CRM | roleBadges, pipeline stage, social URLs, phone aliases, cadence, familyReferences |
| **SamContext** | Households, businesses, groups | kind, members |
| **SamEvidenceItem** | Observations from all channels | source, sourceUID, snippet, linkedPeople, isAllDay, calendarAvailability |
| **SamNote** | User notes + AI analysis | action items, topics, life events, discovered relationships |
| **SamInsight** | AI-generated per-person insights | category, content, confidence |
| **SamOutcome** | Coaching suggestions (non-outreach) | kind, priority, deadline, action lane, sequence info |
| **OutcomeBundle** | Per-person bundled outreach (replaces per-topic SamOutcomes) | person, subItems, priority |
| **OutcomeSubItem** | One topic within an OutcomeBundle | kind, payload, dismissedAt |
| **OutcomeDismissalRecord** | Survives bundle regeneration to honor user skips | personID, kind, dismissedAt |
| **WeeklyBundleRating** | User rating of a bundle's coaching quality | bundle, rating, week |
| **CoachingProfile** | Singleton — user coaching preferences | encouragement style, patterns |
| **TimeEntry** | Time tracking (10 WFG categories) | category, duration, source event |
| **SamUndoEntry** | 30-day undo snapshots | operation type, serialized snapshot |
| **StageTransition** | Immutable pipeline audit log | person, fromStage, toStage, timestamp |
| **RecruitingStage** | Current recruiting state per person | 7 WFG stages |
| **ProductionRecord** | Policies/products per person | type, status, carrier, premium, dates |
| **StrategicDigest** | Cached BI output | type, content, feedback tracking |
| **ContentPost** | Social posting tracker | platform, topic, postedAt |
| **BusinessGoal** | User-defined targets | type, target, start/end, progress |
| **ComplianceAuditEntry** | Draft audit trail | channel, flags, original/final draft |
| **DeducedRelation** | Family relationships from Contacts data | personA, personB, type, confirmed, rejected |
| **FamilyReference** | Note-discovered family/personal relationships on SamPerson | name, relationship, linkedPersonID, sourceNoteID |
| **PendingEnrichment** | Contact update candidates | field, proposed/current value, source, status |
| **IntentionalTouch** | Social touch events | platform, type, direction, weight, dedup key |
| **LinkedInImport / FacebookImport / SubstackImport** | Import audit records | date, counts, status |
| **NotificationTypeTracker** | LinkedIn notification types seen | platform, type, counts |
| **ProfileAnalysisRecord** | Profile analysis results | platform, score, JSON |
| **EngagementSnapshot** | Engagement metrics per period | platform, period, metrics |
| **SocialProfileSnapshot** | Cross-platform profile storage | platform, identity, data blobs |
| **SamEvent** | Event/workshop management | title, format, status, startDate, RSVP, autoReplyUnknownSenders, presentation |
| **EventParticipation** | Event ↔ Person join with RSVP | event, person, rsvpStatus, inviteStatus, sent/responded timestamps |
| **SamPresentation** | Reusable presentation library | title, description, topicTags, fileAttachments, talkingPoints |
| **GoalJournalEntry** | Distilled learnings from goal check-in conversations | goalID, headline, JSON fields for what's working/not, barriers, commitments |
| **RoleDefinition** | Role specs for recruiting pipeline | title, description, idealProfile, scoringCriteria |
| **EventEvaluation** | Post-event workshop analysis | participantAnalyses, feedback, topQuestions, contentGapSummary, ratings |
| **Sphere / Trajectory / TrajectoryStage / PersonSphereMembership / PersonTrajectoryEntry** | Phase 1 relationship model — Spheres ("My Practice"), Trajectories (Funnel/Stewardship/Campaign/Service/Covenant), stages, and per-person placements | See Phase 1 note below |

**Non-SwiftData**: `UserLinkedInProfileDTO`, `UserFacebookProfileDTO`, `UserSubstackProfileDTO` — stored as JSON in UserDefaults, injected into AI prompts via `BusinessProfileService.contextFragment()`.

**Phase 1 Relationship Model**: First-launch bootstrap creates a `"My Practice"` Sphere (with `isBootstrapDefault: true`), gated by `UserDefaults["sam.migration.sphereBootstrapDone"]`. WFG users additionally get a Funnel-mode `"Client Pipeline"` Trajectory with `Lead → Applicant → Client` stages, and every existing Person is seeded with a `PersonSphereMembership` plus a `PersonTrajectoryEntry` where pipeline stage can be derived. Phase 8 routes coordinator + view stage reads through `PersonStageResolver`; legacy `roleBadges`-as-stage-proxy reads are catalogued in `phase0_audit.md` §2.

---

## 7. Concurrency & SwiftData Patterns

### Concurrency

- Services are `actor`. Repositories and Views are `@MainActor`. Coordinators are `@MainActor @Observable`.
- All actor-boundary data must be `Sendable` DTOs.
- No `nonisolated(unsafe)`.

### SwiftData

- **Enum storage**: `rawValue` + `@Transient` computed property
- **Search**: fetch-all + in-memory filter (Swift 6 predicate capture limitation)
- **Container**: `SAMModelContainer.shared` singleton
- **List selection**: UUID-based, not model references
- **`@Relationship`**: many-to-many must have explicit inverses
- **Batch delete** fails on MTM nullify inverses — sever relationships first, then delete individually

### SwiftData Single-Context Rule (critical)

`@MainActor` repositories whose models are bound by SwiftUI `@Query` must **share `container.mainContext`** rather than constructing a private `ModelContext`. Cross-context references crash later — not at the write site — with:

> Fatal error: This backing data was detached from a context without resolving attribute faults

The stack trace typically points at a faulted property getter like `SamPerson.roleBadges.getter`, in the next SwiftUI render after the cross-context mutation.

Two manifestations, same root cause:

1. **Cross-repo writes**: assigning `evidence.linkedPeople = [person]` where `evidence` came from one repo's context and `person` from another. Resolve both endpoints through the repo that owns the mutation target (e.g. `EvidenceRepository.getEmailLookup() / getPhoneLookup()`).
2. **Repo-vs-SwiftUI deletes / mutations**: deleting via a private context leaves the mainContext holding live references to deleted persistent IDs. The next `@Query`-backed render crashes.

**Remediation pattern** (use proactively when touching delete/merge logic):

```swift
func configure(container: ModelContainer) {
    self.container = container
    self.modelContext = container.mainContext   // not ModelContext(container)
}
```

`PeopleRepository` was migrated 2026-05-12 (commit `91fd288`). Other repos (`EvidenceRepository`, `OutcomeRepository`, etc.) still hold private contexts and should follow when next cross-context crash surfaces, or proactively if touching cross-repo writes.

Scalar values (UUIDs, strings, enums) can cross repos freely. The rule applies only to live `PersistentModel` references. Passing a `SamPerson` from a different context into `repo.delete(person:)` silently no-ops — re-fetch by ID inside the repo before mutating.

### Background AI Tasks

- `TaskPriority.background` for all Layer 2 work
- `Task.yield()` every ~10 iterations in batch loops
- Check `Task.isCancelled` at specialist call boundaries
- Cache with TTL; never re-run if fresh
- Pause if user is actively typing/navigating

### LLM Prompts

Never use pipe-separated options as JSON example values — LLMs echo them literally. Use concrete examples with a separate reference section.

### @Observable + UserDefaults

Use `@ObservationIgnored` with manual UserDefaults for settings. Stored properties with explicit setter methods for UserDefaults sync (computed properties bypass SwiftUI observation).

### Security-Scoped Bookmarks

Bookmark the **directory** (not file) for SQLite to cover WAL/SHM companions. `.fileImporter` URLs require `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.

### Graceful Shutdown

If background AI work is in flight (outcome generation, strategic digest, role deduction, briefing refresh, or any active import) at quit, `applicationShouldTerminate` returns `.terminateLater` and `ShutdownCoordinator.settle()` waits up to its default timeout for `BackgroundWorkProbe.isAnyBusy` to clear. A re-entrant guard prevents a second settle pass from racing the in-flight one if the user clicks Quit twice.

---

## 8. Modal Arbitration (Sibling-Sheet Collision Prevention)

macOS allows only **one sheet per window** at a time. When two root-level sheets bind on the same parent (e.g. a LinkedIn import sheet + a post-call capture sheet triggered by a phone call), the second one dismisses the first. SAM's `ModalCoordinator` arbitrates this.

- **`ModalCoordinator`** (`@MainActor @Observable` singleton) arbitrates sheet presentation with priority + conflict policy. `request(priority:policy:identifier:)` returns a `PresentationToken` (UUID + release closure). The active token is the one bound to SwiftUI's `.sheet()` modifier.
- **Priority levels**: `.opportunistic` < `.coaching` < `.userInitiated` < `.critical`. Higher-priority requests can preempt with `.replaceLowerPriority`; same/lower priority queue or drop per `ConflictPolicy`.
- **`.managedSheet(isPresented:priority:identifier:content:)`** — drop-in replacement for `.sheet(isPresented:)` that registers with `ModalCoordinator`. Also handles lock/unlock dismiss + restore for `.coaching`+ priorities; callers do **not** also apply `.restoreOnUnlock`. An item-binding variant exists too.
- **Standalone Window scenes** — Long-running flows that must not be interrupted by background-coordinator sheets live in their own `Window` scenes with stable ids: `import-linkedin`, `import-facebook`, `import-substack`, `import-evernote`. Triggered via notifications (`samShowLinkedInImportWindow`, etc.) observed by `AppShellView`'s `SocialImportWindowObservers` ViewModifier, which calls `@Environment(\.openWindow)`.
- **Nested sheets** — A `.sheet()` *inside* the content of another sheet does **not** suffer from sibling collision (SwiftUI stacks them correctly on macOS) and is intentionally left as plain `.sheet()` with `.restoreOnUnlock` (e.g., `LinkedInImportReviewSheet`, `EventEvaluationImportSheet`, `GoalEntryForm`, `TranscriptionReviewView`, `LifeEventCoachingView`, `CoachingSessionView`).
- **Onboarding** uses `.managedSheet` with `.critical` priority so first-launch flow can never be preempted.

**When adding a new root-level sheet**, use `.managedSheet` with the appropriate priority. Background-generated coaching sheets use `.coaching`. User-clicked-button sheets use `.userInitiated`. First-launch/unrecoverable flows use `.critical`.

---

## 9. App Security, Crash Recovery, Compliance

Lean summary; full detail in satellite docs.

### App Security (`app-lock-architecture.md`)

- **Authentication is mandatory** — SAM always locks on launch and after idle timeout. `LocalAuthentication` (Touch ID + system password fallback). No opt-out.
- **Lock**: `AppLockService` + `LockOverlayCoordinator` (per-window glass overlays) + `ModalCoordinator` (dismisses sheets on lock) + `DraftStore` (in-memory autosave for edit forms, restored on unlock).
- **Auto-unlock prompts** fire on `screenIsUnlocked`, `screensaver.didstop`, `didWake`, and `LockOverlayWindow.didBecomeKey` failsafe.
- **Backup encryption is mandatory** — AES-256-GCM, HKDF-SHA256, `SAMENC1` header.
- **Other primitives** — Clipboard auto-clear (60s, sensitive only), `privacy: .private` for all PII in logs, `KeychainService` for credentials, FileVault for database (no `FileProtectionType.complete`).

### Crash Recovery (`crash-recovery.md`)

- **Startup hardening** every launch: WAL checkpoint, timestamped backup (keeps 3), orphaned FK cleanup, crash-loop guard.
- **Crash report auto-detection** — `sam.cleanShutdown` flag + `.ips` scan; debugger-attached state is tracked and suppresses false positives when the user "stops" from Xcode.
- **Safe Mode** — Hold Option at launch. Skips coordinators / AI; operates on raw SQLite with 7 check categories. Email report → `sam@stillwaiting.org`.

### Compliance (`compliance-architecture.md`)

- Practice-type-driven (WFG Financial Advisor maintained by SAM, General custom-keyword-only).
- WFG profile references the "U.S. Agent Agreement Packet, April 2025" — when the source doc updates and rules change, update both the prompt (`MeetingSummaryService.complianceSectionFinancialAdvisor`) and the Settings disclaimer (`ComplianceSettingsContent.swift`).
- Both AI prompt rules and the keyword scanner (`ComplianceScanner.phrasePatterns`) must be updated together.

---

## 10. Schema Versions

The store filename uses `schemaVersion`. **Additive** schema changes do not bump the version; only **destructive** migrations do. The table below is the chronological history of additive + version-bumping changes.

| Version | Changes |
|---------|---------|
| v16 | Multi-step sequences on SamOutcome |
| v17 | + SamUndoEntry |
| v18 | + TimeEntry, TimeCategory |
| v19 | + StageTransition, RecruitingStage |
| v20 | + ProductionRecord |
| v21 | + SamPerson.preferredCadenceDays |
| v22 | + StrategicDigest, SamDailyBriefing.strategicHighlights |
| v23 | + ContentPost |
| v24 | + BusinessGoal |
| v25 | + ComplianceAuditEntry |
| v26 | + DeducedRelation |
| v27 | Removed .household ContextKind |
| v28 | + PendingEnrichment |
| v29 | + IntentionalTouch, LinkedInImport; UnknownSender extended |
| v30 | + NotificationTypeTracker, ProfileAnalysisRecord, EngagementSnapshot, SocialProfileSnapshot |
| v31 | + FacebookImport, SamPerson + facebook fields; UnknownSender + facebook fields |
| v32 | + ContactLifecycleStatus on SamPerson |
| v33 | + SubstackImport |
| v34 | + Per-category channel prefs (6 fields on SamPerson), companion outcome fields on SamOutcome |
| v34 (additive) | + OutcomeBundle, OutcomeSubItem, OutcomeDismissalRecord, WeeklyBundleRating; + Sphere / Trajectory / TrajectoryStage / PersonSphereMembership / PersonTrajectoryEntry (Phase 1 relationship model) |

---

## 11. Roadmap

### Near-Term Polish

- **LinkedIn Data Export tab**: Review and simplify the multi-step instructions in File → Import → LinkedIn → Data Export tab.

### Role System Evolution (Deferred — Needs Product Clarity)

`RoleDefinition` supports user-defined roles with criteria-based candidate scoring and content generation. Financial Advisor gets seed roles (Referral Partner, WFG Agent Recruit, Client Advocate, Strategic Alliance). A broader vision was considered:

1. **Role template library** — pre-built role catalogs per business type
2. **Per-role AI prompts** — each role carrying its own prompts for candidate scoring, recruiting outreach, conversation analysis, relationship coaching, content generation
3. **General business type depth** — seed roles and coaching personality for non-financial-advisor users

**Decision**: Deferred. The core product question is whether General has a real audience. 98% of users will use one business type. The owner's non-financial roles (ABT Chair, elder roles) work as custom roles inside Financial Advisor.

**Worth doing regardless**: per-role prompt customization benefits Financial Advisor roles just as much. Architectural direction is clear — it's the product question (who is General for?) that needs answering first.

### Priority 9+ — Future

- Custom activity types
- API integrations (WFG back-office)
- Team collaboration

---

**Document Version**: 49
**Last Updated**: 2026-05-12 — Lean rewrite. Promoted Modal Arbitration to a top-level section; promoted standalone Window scenes (LinkedIn / Facebook / Substack / Evernote imports) for long-running flows. Promoted the SwiftData single-context rule to a first-class subsection. Moved deep references (social import pipeline, lock architecture, crash recovery, compliance, contact photo / invitations, transcription, text scaling, accepted warnings) to satellite docs.
