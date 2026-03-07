# SAM — Project Context

**Platform**: macOS 26+ (Tahoe) | **Language**: Swift 6 | **Framework**: SwiftUI + SwiftData | **Schema**: SAM_v34

**Related Docs**:
- `CLAUDE.md` (repo root) — Product philosophy, AI behavior rules, code standards
- `changelog.md` — Completed phase history (Phases A–Z + post-phase features through March 2026)
- `SAM-LinkedIn-Integration-Spec.md` / `SAM-Facebook-Integration-Spec.md` — Platform-specific specs

---

## 1. What SAM Is

SAM is a **native macOS coaching assistant** for independent financial strategists at WFG. It observes interactions (Calendar, Contacts, Mail, iMessage, Phone, FaceTime, WhatsApp, LinkedIn, Facebook), transforms them into evidence, generates AI-backed insights, and provides outcome-focused coaching at both the relationship and business level.

**Core invariants**:
- Apple Contacts and Calendar are the **systems of record** — SAM enriches but never replaces
- Social platform imports create **standalone SamPerson records** — never write to Apple Contacts without explicit user action
- **All AI processing is on-device** — no cloud, no telemetry
- AI is primarily assistive, but **autonomous for background analysis and recommendations**
- All actions that **write to external data sources** (Contacts, Calendar, iMessages, etc.) require explicit user approval — which may be granted via Settings (e.g., permission to update Contacts with enrichment data)

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
┌───────────▼────────────┐  ┌────▼─────────────────────────┐
│      Services          │  │       Repositories            │
│  actor, external APIs  │  │  @MainActor, SwiftData CRUD   │
│  return Sendable DTOs  │  │                               │
└───────────┬────────────┘  └────┬─────────────────────────┘
            │                    │
┌───────────▼────────────┐  ┌────▼─────────────────────────┐
│   External APIs        │  │        SwiftData              │
│ CNContactStore, EK,    │  │   SamPerson, SamOutcome,     │
│ FoundationModels, MLX  │  │   BusinessGoal, etc.         │
└────────────────────────┘  └──────────────────────────────┘
```

**Rules**: Views never touch raw CNContact/EKEvent. All actor-boundary data is `Sendable` DTOs. One CNContactStore, one EKEventStore (never create duplicates). Repositories use `SAMModelContainer.shared`.

### 2.2 AI: Two Layers + RLM Orchestration

**Layer 1 — Relationship Intelligence (foreground, <5s response)**:
Note analysis, meeting pre-briefs, follow-up drafts, health scoring, outcome generation, channel recommendations.

**Layer 2 — Business Intelligence (background, `TaskPriority.background`)**:
Pipeline analytics, production trends, time allocation, pattern detection, content suggestions, scenario projections, strategic digest.

**RLM Pattern**: The `StrategicCoordinator` (Swift, not LLM) decomposes business reasoning into focused sub-problems, dispatches specialist analysts (PipelineAnalyst, TimeAnalyst, PatternDetector, ContentAdvisor) in parallel via `TaskGroup`, then synthesizes results deterministically. Each specialist receives <2000 tokens of pre-aggregated data. All numerical computation happens in Swift — LLMs interpret and narrate. Results cached with TTL (pipeline=4h, patterns=24h, projections=12h).

See `CLAUDE.md` for the full RLM architecture description and priority hierarchy.

---

## 3. AI Output Quality Standards

Every piece of AI output must meet these standards. These are non-negotiable design principles for all coaching, suggestions, and analysis.

### 3.1 Concrete, Not Vague

Every suggestion must include specific names, specific context, and a ready-to-use artifact.

| Bad | Good |
|-----|------|
| "Follow up with John" | "Follow up with John about the IUL quote from your Feb 15 meeting. Draft: 'Hi John, I wanted to check in on the IUL we discussed...'" |
| "Lead numbers are low" | "You need 5 more leads to hit your Q2 goal. 3 contacts show interest: [names + evidence]. Here's an outreach script for each." |
| "Harmonize credentials across platforms" | "LinkedIn says 'MBA, Finance' but Facebook says 'Business degree'. Paste this on LinkedIn: '...' Paste this on Facebook: '...'" |

### 3.2 Copy-Paste Ready

All drafts, profile text suggestions, and scripts should be complete and ready to use — not instructions on what to write.

### 3.3 People-Specific

Business observations must always connect to named individuals. "Pipeline is slow" becomes "These 3 applicants have stalled: [names], here's why and what to do about each."

### 3.4 Ask When You Don't Know *(Implemented — Phase 2)*

When SAM lacks information to be specific, it shows an **inline prompt** (`InlineGapPromptView`) above outcome cards:
- `KnowledgeGap` value type (id, question, placeholder, icon, storageKey)
- `OutcomeEngine.detectKnowledgeGaps()` checks for: missing referral sources, content topics, associations, untracked goal progress
- Answers stored in UserDefaults (`sam.gap.*` keys), fed into AI context via `gapAnswersContext()`
- Injected into: `buildEnrichmentContext()`, `generateDraftMessage()`, `DailyBriefingService.buildMorningDataBlock()`
- Max 1 gap prompt shown at a time; disappears after answer

### 3.5 Noise Prevention

- Surface only what's actionable **right now** in any given view
- Completed, stale, or low-confidence items hidden by default
- Prefer **one excellent suggestion** over five mediocre ones
- Every outcome card should pass the test: "Can the user act on this in the next 2 hours?"

---

## 4. Contact Lifecycle Management *(Implemented — SAM_v32, March 4, 2026)*

Contacts have a lifecycle beyond active/inactive. `ContactLifecycleStatus` enum on `SamPerson` controls visibility, suggestions, and outreach:

### 4.1 Contact States

| State | Enum Value | Behavior |
|-------|------------|----------|
| **Active** | `.active` | Normal — appears in lists, receives suggestions, contributes to metrics |
| **Archived** | `.archived` | Hidden from active lists but searchable. Dead leads, former clients who moved on, accidental adds. No suggestions generated. |
| **DNC (Do Not Contact)** | `.dnc` | Flagged — SAM never generates outreach suggestions. Still visible in history for audit. Not overridden on re-import. |
| **Deceased** | `.deceased` | Special archived state — prevents all outreach. Life event record preserved. Not overridden on re-import. |
| **Never Added** | N/A | Unknown sender marked "Never" via `UnknownSender` model — reversible, searchable in a dedicated view |

`SamPerson.isArchived` is preserved as a computed `@Transient` property (`lifecycleStatus != .active`) for backward compatibility across 13+ filter sites. `isArchivedLegacy` stored with `@Attribute(originalName: "isArchived")` for schema column continuity.

### 4.2 Broader Contact Matching

When importing from social platforms, SAM should:
1. Scan **all** Apple Contacts (not just the SAM group) for matches
2. Present matches to the user: "Found 12 LinkedIn connections already in your Contacts but not in SAM"
3. Offer to move matched contacts into the SAM group in Apple Contacts
4. This is a one-time prompt per import, with "Don't ask again" option

### 4.3 Noise Reduction

The user's active contact list should only contain people relevant to their current business. Archiving, DNC, and "Never" are all tools for reducing noise. OutcomeEngine scanner #13 proactively suggests archiving contacts with no evidence in 12+ months and no pipeline-relevant roles (Client/Applicant/Agent).

---

## 5. Social Platform Import Principles

All platform importers follow the same architecture. Platform-specific details belong in their respective spec files.

### 5.1 Two-Track Model

**Track 1 — Data About the User**: Profile, career, skills, certifications → feeds `BusinessProfileService.contextFragment()` → injected into all AI specialist prompts. Stored as JSON in UserDefaults (`sam.{platform}Profile`).

**Track 2 — Data About Contacts**: Connections, messages, endorsements, recommendations → enriches contacts via `PendingEnrichment` + creates evidence via `EvidenceRepository`. Unmatched contacts go to `UnknownSenderRepository`.

### 5.2 Architecture Pattern

```
{Platform}Service (actor)           → Pure parsing, returns Sendable DTOs
{Platform}ImportCoordinator (@MainActor @Observable) → Matching, dedup, persistence
Existing repositories               → No changes needed
```

Coordinator follows standard `ImportStatus` pattern: idle → parsing → preview → importing → success/error.

### 5.3 Contact Matching Priority

1. **Platform profile URL** — exact match, highest confidence
2. **Email address** — match via ContactsService
3. **Phone number** — match via SamPerson.phoneAliases
4. **Fuzzy display name** — last resort, flag for user review

### 5.4 Key Rules

- Social imports create **standalone SamPerson** records (`contactIdentifier: nil`)
- Evidence dedup key: `{platform}:{identifier}:{timestamp}` stored in `sourceUID`
- Watermark-based incremental import (`sam.{platform}.lastImportDate` in UserDefaults)
- User profile (Track 1) always replaced wholesale — no watermark needed
- Touch scoring via `IntentionalTouch` model + `TouchScoringEngine.computeScores()`

### 5.5 Adding a New Platform

1. Request and inspect a real data export — verify actual column headers and formats
2. Classify every file as Track 1, Track 2, or discard
3. Define DTOs, create `{Platform}Service` actor, create coordinator
4. Integrate with existing `EnrichmentRepository`, `EvidenceRepository`, `UnknownSenderRepository`
4b. If the platform export includes the user's own posts/articles, implement voice analysis (see §5.6) and store `writingVoiceSummary` in the platform DTO
5. Add File → Import → {Platform} menu item that opens a standalone sheet (see §5.7)
6. If the platform's export is async (user requests → platform emails a download link), implement the auto-detection pipeline (see §5.7)

### 5.6 Voice Analysis (Standard for All Platforms)

Every social platform import that captures the user's own content (posts, articles, share comments) should include a voice analysis step:

1. Collect 3-5 recent content samples from the user's posts/articles
2. Run AI voice analysis: "Analyze the writing voice and style..."
3. Store `writingVoiceSummary` in the platform's profile DTO
4. Include the voice summary in `coachingContextFragment()`
5. `ContentAdvisorService.generateDraft()` uses `buildVoiceBlock(for:)` to inject platform-appropriate voice matching into draft generation prompts

Cross-platform fallback: If a platform has no voice data, the draft generator uses voice data from any connected platform (preferring Substack > LinkedIn > Facebook), adapted for the target platform's tone.

Currently implemented for: **Substack** (article excerpts), **LinkedIn** (share comments), **Facebook** (user posts).

### 5.7 Auto-Detection Import Pipeline *(Implemented — Substack + LinkedIn, March 6, 2026)*

Many social platforms use an **asynchronous export** model: the user requests their data, the platform prepares it (minutes to hours), emails a download link, and the user downloads a ZIP/archive. SAM provides a reusable auto-detection pipeline for this pattern.

#### Architecture

```
┌─────────────────────────────────────────────────────────┐
│              Import Sheet (SwiftUI)                     │
│  State machine driven by {Platform}SheetPhase enum      │
│  Phases: setup → scanning → zipFound → processing →     │
│          awaitingReview → complete                       │
│  Fallback: noZipFound → watchingEmail → emailFound →    │
│            watchingFile → (loops back to scanning)       │
└──────────┬──────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────┐
│         {Platform}ImportCoordinator                      │
│  beginImportFlow()     — routes by config state          │
│  scanDownloadsFolder() — ~/Downloads pattern match       │
│  processZip(url:)      — unzip + parse + match           │
│  startEmailWatcher()   — 5-min Mail.app polling          │
│  startFileWatcher()    — 30s ~/Downloads polling         │
│  scheduleReminder()    — calendar-gap-aware reschedule   │
│  resumeWatchersIfNeeded() — persist across app restart   │
└──────────┬──────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────┐
│         SystemNotificationService                        │
│  {PLATFORM}_EXPORT notification category                 │
│  "Open Export Page" action → opens URL + file watcher    │
│  "Remind Me Later" action → free-calendar-gap reschedule │
└─────────────────────────────────────────────────────────┘
```

#### Sheet Phase State Machine

Every platform that uses async exports should define a `{Platform}SheetPhase` enum with these cases:

| Phase | Trigger | Description |
|-------|---------|-------------|
| `.setup` | No prior config | First-time: platform credentials/URL entry + manual file picker |
| `.scanning` | Has config + prior import | Scan ~/Downloads for matching archive |
| `.zipFound(info)` | Archive found newer than last import | Preview: filename, date, size; Confirm/Decline |
| `.processing` | User confirms | Unzip → parse → match (progress indicator) |
| `.awaitingReview` | Parse complete | Show matched/unmatched summary; user confirms |
| `.noZipFound` | No matching archive | Instructions + "Download Data..." + optional email watcher |
| `.watchingEmail` | User clicks "Watch for Email" | Polls Mail.app every 5 min for export-ready email (2-day timeout) |
| `.emailFound(url)` | Export email detected | macOS notification + "Open Download Page" button |
| `.watchingFile` | User clicks download link | Polls ~/Downloads every 30s for new archive (2-day timeout) |
| `.complete(stats)` | Import confirmed | Summary + optional "Delete source file?" |
| `.failed(message)` | Any error | Error message + Retry button |

#### Prerequisites

- **Entitlement**: `com.apple.security.files.downloads.read-write` — required for real ~/Downloads access (sandbox returns container otherwise). Already added; benefits all platforms.
- **Mail access**: Email watcher requires `MailImportCoordinator.shared.mailEnabled` and configured accounts. Graceful fallback when unavailable.

#### Implemented Platforms

| Platform | File Pattern | Email Sender | Sheet | Coordinator |
|----------|-------------|--------------|-------|-------------|
| Substack | `substack-*.zip` | `substack.com` | `SubstackImportSheet` | `SubstackImportCoordinator` |
| LinkedIn | `Complete_LinkedInDataExport_*.zip`, `Basic_LinkedInDataExport_*.zip` | `linkedin.com` | `LinkedInImportSheet` | `LinkedInImportCoordinator` |
| Facebook | `*facebook*.zip` (case-insensitive) | `facebook.com`, `facebookmail.com` | `FacebookImportSheet` | `FacebookImportCoordinator` |

#### Adapting for a New Platform

To add auto-detection for another async-export platform:

1. **Define file patterns**: Each platform uses different export filenames. Add pattern matching to `scanDownloadsFolder()`.
2. **Define email patterns**: Each platform sends different export notification emails. Add sender/subject filters to `pollForExportEmail()`.
3. **Create the sheet**: Copy `SubstackImportSheet.swift`, `LinkedInImportSheet.swift`, or `FacebookImportSheet.swift` as a template. Replace platform-specific setup sections.
4. **Add notification category**: Register `{PLATFORM}_EXPORT` in `SystemNotificationService.configure()` with Open/Remind actions.
5. **Wire menu item**: `File → Import → {Platform}...` opens the sheet. Remove `.disabled()` — the sheet handles all states.
6. **Add watcher persistence**: Use `sam.{platform}.emailWatcherActive` / `fileWatcherActive` / `StartDate` keys. Call `resumeWatchersIfNeeded()` from `configure(container:)`.
7. **Add termination cleanup**: Call `{Platform}ImportCoordinator.shared.cancelAll()` from `SAMAppDelegate.applicationShouldTerminate`.

#### UserDefaults Keys (per platform)

```
sam.{platform}.feedURL                    — platform config (if applicable)
sam.{platform}.lastSubscriberImportDate   — watermark for auto-scan
sam.{platform}.emailWatcherActive         — Bool, persists across restarts
sam.{platform}.emailWatcherStartDate      — Date, for timeout calculation
sam.{platform}.fileWatcherActive          — Bool
sam.{platform}.fileWatcherStartDate       — Date
sam.{platform}.extractedDownloadURL       — String, cached download URL
```

#### Implementation Reference

First implementation: **Substack** (March 6, 2026)
- `SubstackImportCoordinator.swift` — full auto-detection pipeline
- `SubstackImportSheet.swift` — standalone sheet with all 11 phases
- `SystemNotificationService.swift` — `SUBSTACK_EXPORT` category
- `SAMApp.swift` — menu item + sheet + ZIP detection listener

---

## 6. Data Models (Summary)

All models use SwiftData lightweight migration. Enum storage uses `rawValue` pattern with `@Transient` computed property.

| Model | Purpose | Key Fields |
|-------|---------|------------|
| **SamPerson** | Contact anchor + CRM | roleBadges, pipeline stage, social URLs, phone aliases, cadence |
| **SamContext** | Households, businesses, groups | kind, members |
| **SamEvidenceItem** | Observations from all channels | source, sourceUID, snippet, linkedPeople |
| **SamNote** | User notes + AI analysis | action items, topics, life events, discovered relationships |
| **SamInsight** | AI-generated per-person insights | category, content, confidence |
| **SamOutcome** | Coaching suggestions | kind, priority, deadline, action lane, sequence info |
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
| **PendingEnrichment** | Contact update candidates | field, proposed/current value, source, status |
| **IntentionalTouch** | Social touch events | platform, type, direction, weight, dedup key |
| **LinkedInImport** | Import audit record | date, counts, status |
| **FacebookImport** | Import audit record | date, counts, status |
| **NotificationTypeTracker** | LinkedIn notification types seen | platform, type, counts |
| **ProfileAnalysisRecord** | Profile analysis results | platform, score, JSON |
| **EngagementSnapshot** | Engagement metrics per period | platform, period, metrics |
| **SocialProfileSnapshot** | Cross-platform profile storage | platform, identity, data blobs |

**Non-SwiftData**: `UserLinkedInProfileDTO`, `UserFacebookProfileDTO` — stored as JSON in UserDefaults, injected into AI prompts via `BusinessProfileService.contextFragment()`.

---

## 7. Key Patterns & Gotchas

### Permissions
Never trigger surprise dialogs. Always check authorization before access.

### Concurrency
Services are `actor`. Repositories are `@MainActor`. Views are implicit `@MainActor`. All boundary data must be `Sendable` DTOs. No `nonisolated(unsafe)`.

### SwiftData
- Enum storage: `rawValue` + `@Transient` computed property
- Search: fetch-all + in-memory filter (Swift 6 predicate capture limitation)
- Container: `SAMModelContainer.shared` singleton
- List selection: UUID-based, not model references
- `@Relationship` must have explicit inverses for many-to-many
- Cross-context insertion: fetch target model from the SAME context doing the insert
- Batch delete fails on MTM nullify inverses — sever relationships first, then delete individually

### @Observable + UserDefaults
Use `@ObservationIgnored` with manual UserDefaults for settings. Stored properties with explicit setter methods for UserDefaults sync (computed properties bypass SwiftUI observation).

### Background AI Tasks
- `TaskPriority.background` for all Layer 2 work
- `Task.yield()` every ~10 iterations in batch loops
- Check `Task.isCancelled` at specialist call boundaries
- Cache with TTL; never re-run if fresh
- Pause if user is actively typing/navigating

### LLM Prompts
Never use pipe-separated options as JSON example values — LLMs echo them literally. Use concrete examples with a separate reference section.

### Security-Scoped Bookmarks
Bookmark the **directory** (not file) for SQLite to cover WAL/SHM companions. `.fileImporter` URLs require `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.

---

## 8. Schema Versions

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
| v31 | + FacebookImport; SamPerson + facebook fields; UnknownSender + facebook fields |
| v32 | + ContactLifecycleStatus on SamPerson |
| v33 | + SubstackImport |
| v34 | + Per-category channel prefs (6 fields on SamPerson), companion outcome fields on SamOutcome |

---

## 9. Roadmap

### ~~Priority 3 — Global Clipboard Capture Hotkey~~ ✅ Completed (Mar 5, 2026)

### ~~Priority 4 — LinkedIn as Reply Channel~~ ✅ Completed (Mar 5, 2026)

### ~~Message-Category-Aware Channel Prefs~~ ✅ Completed (Mar 5, 2026)

### ~~Evidence-Gated Social Profile Buttons~~ ✅ Completed (Mar 5, 2026)

### ~~Priority 5 — WhatsApp Direct Database Integration~~ ✅ Completed (Mar 5, 2026)

### ~~Priority 6 — Data Migration & Schema Version Hygiene~~ ✅ Completed (Mar 5, 2026)

### Priority 7 - Update onboarding, helps, tooltips *(in progress)*
- ~~It would be good to have a menu item where all the import calls live. This would make it easier for users to find and bring consistency.~~ ✅ **Done** (Mar 6, 2026) — File menu reorganized per macOS HIG: flat Import items (Substack, LinkedIn, Facebook, Evernote) in File menu; auto-imports (Contacts, Calendar, Mail, iMessage) run automatically at launch.
- ~~Is it possible for SAM to notice features that the User is not utilizing well, and coach the user on how to use those effectively — not all at once, but over days or weeks?~~ ✅ **Done** — FeatureAdoptionTracker (OutcomeEngine scanner #14) surfaces unused features as coaching cards progressively over time.
- ~~First-launch intro sequence~~ ✅ **Done** (Mar 6, 2026) — Replaced 6-slide narrated intro with a 2:39 motivational video. Gives SAM time to process initial data imports and compile first briefing in the background.
- ~~Settings organization~~ ✅ **Done** — Consolidated from 10 tabs → 4 (General, Permissions, Data Sources, AI & Coaching, Business). Legacy Data migration section added to Settings → General. Import status dashboard in Data Sources.
- **Remaining**: Examine onboarding permission flow. Current onboarding requests Contacts + Calendar. Consider adding: MLX model download, macOS notifications permission, iMessage & phone log access. Determine minimal required vs. deferrable permissions.
- **Remaining**: Formalize which settings are deferred to coaching instructions during first hours of operation (social media imports, content posting, compliance settings, etc.) vs. required at startup.
- **Remaining**: Walk user through role confirmation via relationship graph after initial imports complete.

### Priority 8 - Security review
- Can we use TouchID, FaceID, Apple Watch, password to enforce secure access to SAM? Would this be a good thing?
- Is the SAM data (SwiftData, other app data) stored securely at present? Do we need to incorporate encryption?
- Do we need to consider database encryption?
- Do we need to encrypt backups using the same TouchID, FaceID, Apple Watch, password used to unlock SAM?

### Priority 9+ — Future

- Review and update tooltips
- iOS companion app (read-only)
- Custom activity types
- API integrations (WFG back-office)
- Team collaboration

---

**Document Version**: 37
**Last Updated**: March 6, 2026 — File menu reorganized per HIG; intro video replacement; Legacy Data migration in Settings → General; Priority 7 progress tracked.
