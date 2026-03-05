# SAM — Project Context

**Platform**: macOS 26+ (Tahoe) | **Language**: Swift 6 | **Framework**: SwiftUI + SwiftData | **Schema**: SAM_v33

**Related Docs**:
- `CLAUDE.md` (repo root) — Product philosophy, AI behavior rules, code standards
- `changelog.md` — Completed phase history (Phases A–Z + post-phase features through March 2026)
- `SAM-LinkedIn-Integration-Spec.md` / `SAM-Facebook-Integration-Spec.md` — Platform-specific specs

---

## 1. What SAM Is

SAM is a **native macOS coaching assistant** for independent financial strategists at WFG. It observes interactions (Calendar, Contacts, Mail, iMessage, Phone, FaceTime, LinkedIn, Facebook), transforms them into evidence, generates AI-backed insights, and provides outcome-focused coaching at both the relationship and business level.

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
5. Add settings UI (folder picker, import status, unmatched count)

### 5.6 Voice Analysis (Standard for All Platforms)

Every social platform import that captures the user's own content (posts, articles, share comments) should include a voice analysis step:

1. Collect 3-5 recent content samples from the user's posts/articles
2. Run AI voice analysis: "Analyze the writing voice and style..."
3. Store `writingVoiceSummary` in the platform's profile DTO
4. Include the voice summary in `coachingContextFragment()`
5. `ContentAdvisorService.generateDraft()` uses `buildVoiceBlock(for:)` to inject platform-appropriate voice matching into draft generation prompts

Cross-platform fallback: If a platform has no voice data, the draft generator uses voice data from any connected platform (preferring Substack > LinkedIn > Facebook), adapted for the target platform's tone.

Currently implemented for: **Substack** (article excerpts), **LinkedIn** (share comments), **Facebook** (user posts).

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
| **DeducedRelation** | Family relationships from Contacts data | personA, personB, type, confirmed |
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

---

## 9. Roadmap

### ~~Priority 3 — Global Clipboard Capture Hotkey~~ ✅ Completed (Mar 5, 2026)

`EvidenceSource.clipboardCapture`, `GlobalHotkeyService` (⌃⇧V via NSEvent global monitor + AXIsProcessTrusted), `ClipboardParsingService` (AI conversation parsing), `ClipboardCaptureWindowView` (4-phase: parse → review → save → error, inline person picker autocomplete), menu command, Settings toggle + Accessibility status. See `changelog.md` for full details. No schema change.

### Priority 4 — LinkedIn as Reply Channel

Surface LinkedIn alongside iMessage/email in channel recommendations. Draft reply UI with copy button. Uses existing `linkedInProfileURL` for deep-link.

### Priority 5 — WhatsApp Direct Database Integration *(Deferred: feasibility verification needed)*

Unencrypted SQLite at `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`. Verify `NSOpenPanel` + security-scoped bookmark grants persistent read access before building.

### Priority 6— Data migration and backup*

Create a process to allow the user to backup data.
Create a process to allow the user to migrate data from older versions of SAM SwiftData stores to the current version.

### Priority 7+ — Future

- Review and update tooltips
- iOS companion app (read-only)
- Custom activity types
- API integrations (WFG back-office)
- Team collaboration

---

**Document Version**: 33.1
**Last Updated**: March 4, 2026 — Substack Integration implemented (SAM_v33): SubstackImport @Model, SubstackService RSS+CSV parsing, SubstackImportCoordinator (Track 1 feed fetch + Track 2 subscriber pipeline), UserSubstackProfileDTO, BusinessProfileService Substack context, ContentAdvisorService Substack voice rules, OutcomeEngine Substack cadence, SubstackImportSettingsView, backup support. Substack added to Grow section as scored platform (SubstackProfileAnalystService, auto-analysis after feed fetch, Audience & Reach section). ContentDraftSheet includes Substack. Grow page auto-refreshes on any profile analysis update (.samProfileAnalysisDidUpdate notification).
