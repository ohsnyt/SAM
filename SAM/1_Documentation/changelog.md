# SAM — Changelog

**Purpose**: This file tracks completed milestones, architectural decisions, and historical context. See `context.md` for current state and future plans.

---

## March 4, 2026 — Substack Integration (Priority 2)

### Overview
Integrated Substack as a content intelligence source and lead generation channel. Two tracks: **Track 1** parses the public RSS feed to understand writing voice, log posts as ContentPost records, and generate AI voice analysis. **Track 2** imports subscriber CSVs to match against existing contacts and route unmatched subscribers to the UnknownSender triage pipeline. Schema bumped to SAM_v33.

### What Changed
- **ContentPlatform.substack** — New case with orange color and `newspaper.fill` icon
- **TouchPlatform.substack** — New case for Substack subscriber touch events
- **EvidenceSource.substack** — New case (quality weight 0.5, not an interaction)
- **UnknownSender** — Added `substackSubscribedAt`, `substackPlanType`, `substackIsActive` fields
- **SubstackImport @Model** — Tracks import events (post count, subscriber count, match counts)
- **SubstackService** — Actor: RSS feed XMLParser + subscriber CSV parser + HTML stripping
- **UserSubstackProfileDTO** — Codable DTO with `coachingContextFragment` for AI context
- **SubstackImportCoordinator** — Orchestrates both tracks: `fetchFeed()` for Track 1, `loadSubscriberCSV(url:)` + `confirmSubscriberImport()` for Track 2
- **SubstackSubscriberCandidate** — DTO for subscriber matching/classification
- **BusinessProfileService** — Substack profile storage + context injection in `contextFragment()`
- **ContentAdvisorService** — Substack voice consistency rules + Substack platform guidelines for drafts
- **OutcomeEngine** — Substack cadence scanner (14-day nudge for long-form)
- **SubstackImportSettingsView** — Settings UI: feed URL, fetch button, subscriber CSV import, voice summary display
- **BackupDocument + BackupCoordinator** — SubstackImportBackup export/import
- Fixed EvidenceSource exhaustive switches in 5 view files

### Substack in Grow Section & Content Drafts
- **ContentDraftSheet** — Added `.substack` to platform picker (was hardcoded to LinkedIn/Facebook/Instagram)
- **GrowDashboardView** — Added `"substack"` to `SocialPlatformMeta.from()` (orange, newspaper.fill). Substack appears as a scored platform alongside LinkedIn/Facebook. "Network Health" section relabeled to "Audience & Reach" for Substack. Re-Analyze button triggers both LinkedIn and Substack analysis in parallel. Empty state text updated.
- **SubstackProfileAnalystService** — New specialist analyst actor for Substack publication scoring (content quality, posting cadence, topic coverage, audience reach). Produces `ProfileAnalysisDTO` with platform `"substack"`.
- **SubstackImportCoordinator.runProfileAnalysis()** — Builds analysis input from Substack profile data and dispatches to SubstackProfileAnalystService. Auto-triggers after feed fetch.
- **Grow page auto-refresh** — `.samProfileAnalysisDidUpdate` notification posted from `BusinessProfileService.saveProfileAnalysis()`. GrowDashboardView observes and reloads automatically when any platform's analysis completes (LinkedIn, Facebook, Substack).

### Migration Notes
- Schema SAM_v33 adds SubstackImport table. No data migration required (new table only).
- UnknownSender gains 3 nullable fields with defaults — backward-compatible.
- BackupDocument.substackImports is optional — old backups import cleanly.

### Files Summary

| File | Action |
|------|--------|
| `Models/SAMModels-ContentPost.swift` | MODIFY (add `.substack`) |
| `Models/SAMModels-IntentionalTouch.swift` | MODIFY (add `.substack`) |
| `Models/SAMModels-UnknownSender.swift` | MODIFY (add Substack fields) |
| `Models/SAMModels-Supporting.swift` | MODIFY (add `.substack` to EvidenceSource) |
| `Models/SAMModels-SubstackImport.swift` | **NEW** |
| `Models/SAMModels.swift` | MODIFY (add `.samProfileAnalysisDidUpdate` notification) |
| `App/SAMModelContainer.swift` | MODIFY (v33, add SubstackImport) |
| `Services/SubstackService.swift` | **NEW** |
| `Services/SubstackProfileAnalystService.swift` | **NEW** |
| `Models/DTOs/UserSubstackProfileDTO.swift` | **NEW** |
| `Models/DTOs/SubstackImportCandidateDTO.swift` | **NEW** |
| `Coordinators/SubstackImportCoordinator.swift` | **NEW** (incl. `runProfileAnalysis()`) |
| `Repositories/UnknownSenderRepository.swift` | MODIFY (upsertSubstackLater) |
| `App/SAMApp.swift` | MODIFY (coordinator init) |
| `Services/BusinessProfileService.swift` | MODIFY (Substack profile + context + analysis notification) |
| `Services/ContentAdvisorService.swift` | MODIFY (Substack voice rules + platform) |
| `Coordinators/OutcomeEngine.swift` | MODIFY (Substack cadence scanner) |
| `Views/Settings/SubstackImportSettingsView.swift` | **NEW** |
| `Views/Settings/SettingsView.swift` | MODIFY (add Substack DisclosureGroup) |
| `Views/Content/ContentDraftSheet.swift` | MODIFY (add `.substack` to platform picker) |
| `Views/Grow/GrowDashboardView.swift` | MODIFY (Substack platform meta, auto-refresh, relabeled sections) |
| `Models/BackupDocument.swift` | MODIFY (SubstackImportBackup) |
| `Coordinators/BackupCoordinator.swift` | MODIFY (export/import) |
| `Views/Search/SearchResultRow.swift` | MODIFY (add `.substack` switch case) |
| `Views/Awareness/MeetingPrepSection.swift` | MODIFY (add `.substack` switch case) |
| `Coordinators/MeetingPrepCoordinator.swift` | MODIFY (add `.substack` switch case) |
| `Views/Inbox/InboxListView.swift` | MODIFY (add `.substack` switch case) |
| `Views/Inbox/InboxDetailView.swift` | MODIFY (add `.substack` switch case) |
| `Views/People/PersonDetailView.swift` | MODIFY (add `.substack` switch case) |

---

## March 4, 2026 — Top Action Card Prominence (Priority 1: Today View Redesign)

### Overview
Made the top-ranked outcome card in the Action Queue visually prominent so the user can identify their #1 action within 5 seconds. The hero card gets larger typography, more visible rationale, bigger action buttons, and a leading accent bar in the outcome's kind color. All other cards render identically to before. No schema change.

### Changes

**OutcomeCardView** — Added `isHero: Bool = false` parameter (all existing call sites unaffected). When `isHero == true`: title uses `.title3.bold()` (vs `.headline`), rationale uses `.body` with 5-line limit (vs `.subheadline` / 3), next step allows 3 lines (vs 2), action buttons use `.controlSize(.regular)` (vs `.small`), and a 4pt-wide leading accent bar in `kindColor` appears via overlay.

**OutcomeQueueView** — `ForEach` now enumerates `visibleOutcomes` and passes `isHero: index == 0` so only the top-priority card gets hero treatment.

### Priority 1 Completed Items
This completes the second of three Today View Redesign items:
- ✅ Morning briefing as persistent narrative (Phase 4, March 4)
- ✅ Top action card visually prominent (this change)
- Remaining: "Everything else collapsed or removed"

Sidebar Reorganization, Contact Lifecycle, and Suggestion Quality Overhaul were already completed (see entries below).

### Files Summary

| File | Action |
|------|--------|
| `Views/Shared/OutcomeCardView.swift` | MODIFY (isHero param, conditional styling, accent bar) |
| `Views/Awareness/OutcomeQueueView.swift` | MODIFY (enumerated ForEach, isHero pass-through) |

---

## March 4, 2026 — Contact Lifecycle Management

### Overview
Replaced the boolean `isArchived` flag on `SamPerson` with a full `ContactLifecycleStatus` enum supporting four states: active, archived, DNC (do not contact), and deceased. This enables SAM to suppress outreach for contacts that should never be contacted while preserving relationship history for audit purposes. Backward compatibility maintained via a computed `isArchived` property so all 13+ existing filter sites continue working unchanged. Schema: SAM_v32.

### Model & Schema
- **`ContactLifecycleStatus`** enum (active/archived/dnc/deceased) with `rawValue` string storage
- **`SamPerson.lifecycleStatusRawValue`** stored property + `@Transient lifecycleStatus` computed property
- **`SamPerson.isArchivedLegacy`** stored with `@Attribute(originalName: "isArchived")` for schema column continuity
- **`SamPerson.isArchived`** preserved as `@Transient` computed property mapping to `lifecycleStatus != .active`
- One-time v32 migration copies `isArchived=true` to `lifecycleStatusRawValue="archived"`

### Repository & Undo
- **`PeopleRepository.setLifecycleStatus(_:for:)`** — sets status with save
- **Upsert guards** — `upsertContact` and `upsertMe` skip overriding DNC/deceased on re-import
- **`LifecycleChangeSnapshot`** — Codable snapshot for undo support
- **`UndoCoordinator`** extended with `recordLifecycleChange()` and `undoLifecycleChange()`

### UI
- **PersonDetailView** — Toolbar lifecycle submenu (Archive/DNC/Deceased/Reactivate), color-coded status banner (yellow/red/gray), confirmation alerts for DNC and deceased
- **PeopleListView** — Default filter shows active contacts only; `.archived`, `.dnc`, `.deceased` special filters; context menu lifecycle actions; row badges (archive.fill/nosign/heart.slash)

### Intelligence
- **OutcomeEngine scanner #13** — Suggests archiving stale contacts with no evidence in 12+ months and no pipeline-relevant roles (Client/Applicant/Agent)

### Backup
- **BackupDocument** — `lifecycleStatusRawValue` field with backward-compatible import (defaults to "active" if missing, maps `isArchived: true` to "archived")

### Files Summary

| File | Action |
|------|--------|
| `SAMModels-Supporting/ContactLifecycleStatus.swift` | ADD |
| `SAMModels/SamPerson.swift` | MODIFY |
| `SAMModels/SAMModelContainer.swift` | MODIFY (v32 migration) |
| `Repositories/PeopleRepository.swift` | MODIFY |
| `Coordinators/UndoCoordinator.swift` | MODIFY |
| `Coordinators/OutcomeEngine.swift` | MODIFY (scanner #13) |
| `Views/People/PersonDetailView.swift` | MODIFY |
| `Views/People/PeopleListView.swift` | MODIFY |
| `Services/BackupDocument.swift` | MODIFY |
| `Services/BackupCoordinator.swift` | MODIFY |

---

## March 4, 2026 — Suggestion Quality Overhaul: Remaining Items

### Overview
Completed the two remaining items from the Suggestion Quality Overhaul. No schema change, no DTO changes.

### Item 1: Specialist Prompt Upgrades
All 4 StrategicCoordinator specialist LLM prompts now require people-specific, named, concrete output:
- **PipelineAnalystService** — +5 rules: name stuck people with action plans, name pending production person+product+step, risk alerts must name people, top 3 stuck prospects get individual plans
- **TimeAnalystService** — +4 rules: suggest specific time blocks (day+hour), connect to role groups by name, compare 7-day vs 30-day trends, flag dropped habits
- **PatternDetectorService** — +5 rules: reference role groups with numbers, name cold people and roles, concrete next steps naming role groups, reference actual referral partner counts, explain causal relationships
- **ContentAdvisorService** — +4 rules: cite specific meeting/discussion that inspired topic, include copy-paste opening sentence, suggest best platform+day, at least 2 topics must connect to named meetings

### Item 2: Cross-Platform Profile Copy-Paste Text
- **CrossPlatformConsistencyService** — IMPROVEMENTS instruction now requires platform-specific copy-paste text in `example_or_prompt` for every inconsistency
- **ProfileAnalystService** — PROFILE IMPROVEMENTS instruction now requires ready-to-paste LinkedIn text (not instructions on what to write)
- **FacebookProfileAnalystService** — +1 rule: Profile Completeness improvements must contain ready-to-paste Facebook text
- **ProfileAnalysisSheet** — Added `CopyButton` overlay (top-right) and `.textSelection(.enabled)` on improvement `example_or_prompt` blocks

### Files Summary

| File | Action |
|------|--------|
| `Services/PipelineAnalystService.swift` | MODIFY |
| `Services/TimeAnalystService.swift` | MODIFY |
| `Services/PatternDetectorService.swift` | MODIFY |
| `Services/ContentAdvisorService.swift` | MODIFY |
| `Services/CrossPlatformConsistencyService.swift` | MODIFY |
| `Services/ProfileAnalystService.swift` | MODIFY |
| `Services/FacebookProfileAnalystService.swift` | MODIFY |
| `Views/Settings/ProfileAnalysisSheet.swift` | MODIFY |

---

## March 4, 2026 — Phase 4: Today View Polish

### Overview
Three UX improvements to AwarenessView: wider click target for "More" section, removed redundant morning briefing popup sheet, removed redundant briefing toolbar button/popover. No schema change.

### Changes

**AwarenessView** — Replaced `DisclosureGroup` with custom `Button` toggle so the entire row (chevron + text + trailing space) is clickable. Removed morning briefing `.sheet` presentation. Removed briefing popover toolbar button, `showBriefingPopover` state, `briefingTip`, and `TipKit` import. Toolbar now has only the Refresh button.

**PersistentBriefingSection** — Added inline "Start your day" CTA at the bottom of the narrative when `briefing.wasViewed == false`. Orange sunrise icon, warm background. Tapping calls `coordinator.markMorningViewed()` and the CTA disappears.

**DailyBriefingCoordinator** — Removed `showMorningBriefing = true` from `generateMorningBriefing()`. The persistent inline section now handles first-view acknowledgement instead of a popup sheet.

### Files Summary

| File | Action |
|------|--------|
| `Views/Awareness/AwarenessView.swift` | Edit — custom More toggle, remove sheet + toolbar button |
| `Views/Awareness/PersistentBriefingSection.swift` | Edit — inline "Start your day" CTA |
| `Coordinators/DailyBriefingCoordinator.swift` | Edit — stop auto-triggering morning sheet |

---

## March 4, 2026 — Phase 3: Sidebar Reorganization + Business Tab Consolidation

### Overview
Moved Relationship Graph from Business (tab 6 of 6) into People as a toolbar-toggled mode. Consolidated Business from 6 tabs to 4 by merging Client Pipeline and Recruiting into a single Pipeline tab with a sub-picker. No schema change.

### Changes

**AppShellView** — `PeopleMode` enum (`.contacts` / `.graph`), segmented toolbar picker on People section, graph mode shows `RelationshipGraphView` in two-column layout, contacts mode unchanged three-column. Notification handler updated: `.samNavigateToGraph` routes to People + graph mode (was Business). Sidebar migration: `"graph"` → People + graph mode.

**PipelineDashboardView** (new) — Wrapper view with Client/Recruiting sub-segmented control, purely compositional over existing `ClientPipelineDashboardView` and `RecruitingPipelineDashboardView`.

**BusinessDashboardView** — Tabs reduced from 6 to 4: Strategic (0), Pipeline (1), Production (2), Goals (3). Graph tab and `.onReceive(.samNavigateToGraph)` removed.

**PersonDetailView** — `viewInGraph()` simplified: removed `UserDefaults.standard.set("business", ...)` line since notification handler now routes to People.

**GraphMiniPreviewView** — Tap gesture changed from `sidebarSelection = "graph"` to posting `.samNavigateToGraph` notification. Removed unused `@AppStorage` property.

**CommandPaletteView** — Added "Go to Relationship Graph" command (posts `.samNavigateToGraph` notification).

### Files Summary

| File | Action |
|------|--------|
| `Views/AppShellView.swift` | Edit — PeopleMode enum, layout branching, toolbar, notifications, migration |
| `Views/People/PersonDetailView.swift` | Edit — simplified viewInGraph() |
| `Views/Business/PipelineDashboardView.swift` | New — Client+Recruiting wrapper |
| `Views/Business/BusinessDashboardView.swift` | Edit — 6 tabs → 4, removed Graph |
| `Views/Business/GraphMiniPreviewView.swift` | Edit — notification tap, removed @AppStorage |
| `Views/Shared/CommandPaletteView.swift` | Edit — added Graph command |

---

## March 4, 2026 — Phase 2: Suggestion Quality Overhaul

### Overview
Upgraded all OutcomeEngine scanners to produce people-specific, evidence-rich suggestions instead of generic advice. Added rich AI context builder, inline knowledge gap prompts, and goal rate guardrails. No schema change.

### OutcomeEngine Changes (`Coordinators/OutcomeEngine.swift`)

**New: Rich Context Builder**
- `buildEnrichmentContext(for:)` — assembles focused context for AI enrichment: last 3 interactions (source, date, snippet), relationship summary, key themes, pending action items, pipeline stage, production holdings, last note + topics, channel preference, user-provided gap answers. Capped at ~3200 chars (~800 tokens).

**Scanner Upgrades — People-Specific Output**
- **`scanGrowthOpportunities`**: Creates one outcome per stale lead (max 3) with name, days since contact, last interaction snippet, and lead-since date. Replaces generic "Review leads pipeline".
- **`scanRelationshipHealth`**: Adds last interaction context (source, date, snippet) and role-specific insight ("policy review may be overdue" for clients, "application may stall" for applicants).
- **`scanCoverageGaps`**: Includes existing products and searches notes for conversation openers (mentions of education, retirement, family).
- **`scanPastMeetingsWithoutNotes`**: Adds attendee names, meeting time, "yesterday's"/"today's" label to title.
- **`goalOutcomeDetails`**: Includes warmest leads for newClients goal, applicants with pending paperwork for submissions goal.

**Goal Rate Guardrails**
- `goalRateText()` now applies per-type daily maximums (policies: 5/day, clients: 3/day, meetings: 5/day, etc.)
- When daily rate exceeds max, shows weekly rate; when weekly also unreasonable, shows monthly with "significant catch-up needed"
- Same guardrails applied in `DailyBriefingService.briefingGoalRateText()`

**AI Enrichment Upgrades**
- `enrichWithAI()` uses `buildEnrichmentContext()` — prompts AI to name people and reference specific interactions instead of bare role string
- `generateDraftMessage()` uses rich context — instructs AI to reference recent interactions and be personal

**Knowledge Gap Detection**
- `KnowledgeGap` struct — value type with id, question, placeholder, icon, storageKey
- `detectKnowledgeGaps()` — checks for missing referral sources, content topics, associations, untracked goal progress
- `gapAnswersContext()` — formats UserDefaults gap answers as AI context string
- `activeGaps` observable property populated during `generateOutcomes()`

### New View (`Views/Shared/InlineGapPromptView.swift`)
- Compact card: SF Symbol icon + question text + TextField + Save button
- Saves answers to UserDefaults by gap's `storageKey`
- Calls `onAnswered` closure to refresh gap list

### OutcomeQueueView Changes (`Views/Awareness/OutcomeQueueView.swift`)
- Shows max 1 `InlineGapPromptView` above outcome cards when gaps exist
- Refreshes gap list on answer via `gapRefreshToken` state

### DailyBriefingService Changes (`Services/DailyBriefingService.swift`)
- BUSINESS GOALS section uses `briefingGoalRateText()` with same rate guardrails
- USER CONTEXT section injects gap answers into morning narrative data block
- `readGapAnswers()` static helper reads gap answers directly from UserDefaults

### Schema Impact
No schema change. Gap answers stored in UserDefaults (`sam.gap.*` keys).

### Decisions
- Gap answers in UserDefaults (not SwiftData) because they're lightweight strings, not relational data
- Rich context capped at ~800 tokens to keep prompts focused and inference fast
- Max 1 gap prompt visible at a time to avoid overwhelming the user
- Rate guardrails use per-goal-type thresholds rather than a universal cap

---

## March 4, 2026 — Social Import Architecture Fix, Facebook Metadata Display, Onboarding Fixes, MLX Race Fix

### Overview
Corrected the social import pipeline so LinkedIn and Facebook imports create standalone SamPerson records without writing to Apple Contacts. Added Facebook metadata fields to SamPerson and displayed them in PersonDetailView. Fixed onboarding permission button states and the MLX model double-load race condition.

### Social Import Architecture Fix (Critical)

**Problem**: Both LinkedIn and Facebook imports were silently creating Apple Contacts via `ContactsService.createContact()`. The design intent is that social platform imports only create SamPerson records — Apple Contacts should never be written without explicit user action.

**New method: `PeopleRepository.upsertFromSocialImport()`**
- Creates SamPerson with `contactIdentifier: nil` (no Apple Contact link)
- Deduplicates by LinkedIn URL, email, or exact display name
- If an existing SamPerson matches, enriches it with new social data
- Parameters: displayName, linkedInProfileURL?, linkedInConnectedOn?, linkedInEmail?, facebookFriendedOn?, facebookMessageCount, facebookLastMessageDate?, facebookTouchScore

**Files modified:**
- **`PeopleRepository.swift`** — Added `upsertFromSocialImport()` method (~95 lines)
- **`FacebookImportCoordinator.swift`** — Replaced `createAppleContact()` with `upsertFromSocialImport()` in `confirmImport()` Step 3. Removed `createAppleContact()` method and unused `contactsService` reference. Updated `enrichMatchedPerson()` to store messageCount, lastMessageDate, touchScore.
- **`LinkedInImportCoordinator.swift`** — Replaced `createContactsForAddCandidates()` Apple Contact creation with `upsertFromSocialImport()`.
- **`FacebookImportCandidateDTO.swift`** — Updated doc comment: `.add` case now says "Create a standalone SamPerson record".
- **`UnknownSenderTriageSection.swift`** — Split `saveChoices()` into two paths: social platform senders use `upsertFromSocialImport()`, email/calendar senders still create Apple Contacts via existing `ContactsService.createContact()` path.

### Facebook Metadata on SamPerson + PersonDetailView

**New SamPerson fields** (added to `SAMModels.swift`):
```swift
public var facebookMessageCount: Int = 0
public var facebookLastMessageDate: Date?
public var facebookTouchScore: Int = 0
```

**PersonDetailView "Social Platforms" section** (added after Interaction History):
- LinkedIn subsection: blue network icon, connection date, clickable profile URL
- Facebook subsection: indigo person.2.fill icon, friends since date, message count + last message date, touch score badge, clickable profile URL
- Section only appears when social platform data exists

### Facebook Unknown Sender Triage UI

**`UnknownSenderTriageSection.swift`** additions:
- `facebookSenders` computed property filtering by `.facebook` source
- Facebook section grouping with indigo `person.2.fill` icon header
- `FacebookTriageRow` view: indigo badge, message count, friended date, touch score capsule badge
- Updated generic `TriageRow` to show Facebook badge and hide synthetic keys in `latestSubject`
- Added `facebookCoordinator` onChange handler for auto-refresh after import

### Onboarding Permission Button Fixes

**`OnboardingView.swift`** changes:
- Removed `.tint(.red)` from notifications button (was showing red instead of default blue)
- All three permission buttons (Email, Dictation, Notifications): when permission already granted, button shows "Continue" in green and advances to next step instead of being disabled
- Added `alreadyEnabledBadge` helper view with green checkmark + "Permission granted" text
- **Fixed blocking bug**: when Microphone/Speech permission was already enabled, the green button was disabled (`.disabled(micGranted)`) — users could not proceed past this step. Fixed by changing button action to advance when granted and removing `.disabled()` for the granted state.

### MLX Actor Reentrancy Race Fix

**Problem**: `AIService.ensureMLXModelLoaded()` had a race condition — two concurrent callers (morning briefing + outcome engine) both passed the `loadedModelID` guard before either finished loading, causing the model to load twice.

**Root cause**: Swift actors allow interleaving at `await` suspension points. Both callers entered the method, both saw `loadedModelID == nil`, both started loading.

**Fix** (`AIService.swift`): Added continuation-based actor lock:
```swift
private var mlxLoadWaiters: [CheckedContinuation<Void, any Error>]?
```
- First caller sets `mlxLoadWaiters = []` and proceeds with loading
- Subsequent callers detect non-nil `mlxLoadWaiters` and park via `withCheckedThrowingContinuation`
- On completion (success or error), all parked waiters are resumed
- After resume, `mlxLoadWaiters` is set back to `nil`

### Schema Impact
Schema remains at SAM_v31. The three new SamPerson fields (`facebookMessageCount`, `facebookLastMessageDate`, `facebookTouchScore`) are additive with defaults — lightweight migration handles them automatically.

---

## March 3, 2026 — Phase FB-3/4/5: Facebook Profile Intelligence, Cross-Platform Consistency & Apple Contacts Sync

### Overview
Completed the remaining Facebook integration phases: FB-3 (User Profile Intelligence & Analysis Agent), FB-4 (Cross-Platform Consistency), and FB-5 (Apple Contacts Facebook URL Sync). All six Facebook phases are now complete.

### New Files (3)

**`FacebookProfileAnalystService.swift`** — Actor singleton implementing the Facebook profile analysis agent (Spec §8).
- Personal-tone prompt template: community-focused, never salesy, 5 analysis categories: Connection Health, Community Visibility, Relationship Maintenance, Profile Completeness, Cross-Referral Potential
- Reuses `ProfileAnalysisDTO` with `platform: "facebook"` for multi-platform storage
- Same specialist pattern as `ProfileAnalystService.swift` (LinkedIn)

**`FacebookAnalysisSnapshot.swift`** — Lightweight snapshot of import-time Facebook activity data, cached in UserDefaults.
- Friend network: friendCount, friendsByYear
- Messaging activity: messageThreadCount, totalMessageCount, activeThreadCount90Days, topMessaged (top 10)
- Engagement: commentsGivenCount, reactionsGivenCount, friendRequestsSentCount/ReceivedCount
- Profile completeness flags: hasCurrentCity, hasHometown, hasWorkExperience, hasEducation, hasWebsites, hasProfileUri

**`CrossPlatformConsistencyService.swift`** — Actor singleton implementing cross-platform profile consistency checks (Spec §9).
- `compareProfiles()` — Field-by-field comparison of LinkedIn vs Facebook profiles (name, employer, title, location, education, websites)
- `findCrossPlatformContacts()` — Fuzzy name matching to identify contacts on both platforms
- `analyzeConsistency()` — AI analysis of cross-platform consistency with structured JSON output
- DTOs: `CrossPlatformProfileComparison`, `CrossPlatformFieldComparison`, `CrossPlatformFieldStatus`, `CrossPlatformContactMatch`

### Modified Files (5)

**`ProfileAnalysisDTO.swift`** — Made `parseProfileAnalysisJSON()` and `LLMProfileAnalysis.toDTO()` platform-aware with `platform` parameter (default: "linkedIn") so Facebook and cross-platform analyses can reuse the same parsing infrastructure.

**`BusinessProfileService.swift`** — Extended to store Facebook profile data and snapshot.
- Added `saveFacebookProfile()`, `facebookProfileFragment()`, `saveFacebookSnapshot()`, `facebookSnapshot()`
- Updated `contextFragment()` to include `## Facebook Profile` section when available
- New UserDefaults keys: `sam.userFacebookProfile`, `sam.facebookAnalysisSnapshot`

**`FacebookImportCoordinator.swift`** — Integrated FB-3/4 profile analysis and cross-platform consistency.
- Added `ProfileAnalysisStatus` enum and `profileAnalysisStatus`/`latestProfileAnalysis` state
- Added `crossPlatformAnalysisStatus`/`latestCrossPlatformAnalysis`/`crossPlatformComparison`/`crossPlatformOverlapCount` state
- `confirmImport()` now: builds Facebook analysis snapshot, stores Facebook profile in BusinessProfileService, triggers background profile analysis and cross-platform analysis
- New methods: `runProfileAnalysis()`, `buildFacebookAnalysisInput()`, `buildFacebookAnalysisSnapshot()`, `runCrossPlatformAnalysis()`, `loadLinkedInConnectionNames()`

**`FacebookImportSettingsView.swift`** — Added Facebook Presence Analysis section showing analysis status, date, Re-Analyze button, and "View in Grow" navigation link.

**`SAMModels-Enrichment.swift`** — Added `EnrichmentField.facebookURL` case.

**`ContactsService.swift`** — Extended for Facebook URL sync (FB-5).
- `createContact()` now accepts optional `facebookProfileURL` parameter, writes `CNSocialProfileServiceFacebook` social profile
- `updateContact()` handles `.facebookURL` enrichment field, writes Facebook social profile with `CNLabelHome` label

### Design Decisions

- **Platform-aware ProfileAnalysisDTO**: Rather than creating a separate DTO for Facebook analysis, the existing `ProfileAnalysisDTO` is reused with a `platform` discriminator field. `parseProfileAnalysisJSON()` and `LLMProfileAnalysis.toDTO()` now accept a `platform` parameter.
- **FacebookAnalysisSnapshot**: Facebook has no endorsements/recommendations/shares like LinkedIn. The snapshot instead captures messaging activity (thread counts, top contacts, active thread ratio) and profile completeness flags — the data most relevant to Facebook presence health.
- **Cross-Platform Name Matching**: Uses `FacebookService.normalizeNameForMatching()` for consistent name normalization across both platforms. High confidence matches require exact normalized name match.
- **Facebook URL Sync Limitation**: Facebook exports don't include friend profile URLs, so FB-5 mainly adds infrastructure (`EnrichmentField.facebookURL`, Facebook social profile writing in ContactsService) for when URLs become available via manual entry or future API integration.
- **Facebook Label**: Facebook social profiles use `CNLabelHome` (personal) vs LinkedIn's `CNLabelWork` (professional), reflecting the platform's personal-first nature.

---

## March 3, 2026 — Phase FB-1/2/6: Facebook Core Import Pipeline (schema SAM_v31)

### Overview
Implemented Facebook data export import system covering phases FB-1 (Core Import Pipeline), FB-2 (Messenger & Touch Scoring), and FB-6 (Settings UI & Polish). Mirrors the LinkedIn import architecture but adapted for Facebook's JSON format, mojibake text encoding, name-only friend identification (no profile URLs), and per-directory message threads. Schema bumped from SAM_v30 → SAM_v31.

### New Files (7)

**`FacebookService.swift`** — Actor singleton for JSON parsing with UTF-8 mojibake repair.
- Parsers: `parseFriends()`, `parseUserProfile()`, `parseMessengerThreads()` (walks inbox/, e2ee_cutover/, archived_threads/, filtered_threads/), `parseComments()`, `parseReactions()`, `parseSentFriendRequests()`, `parseReceivedFriendRequests()`
- `repairFacebookUTF8()` — converts Latin-1 encoded UTF-8 back to proper UTF-8 (fixes em dashes, accented characters, etc.)
- `normalizeNameForMatching()` — lowercased, diacritic-folded, whitespace-collapsed name key for touch score mapping
- 26 private Decodable structs for Facebook JSON schema deserialization

**`FacebookImportCandidateDTO.swift`** — Import candidate types.
- `FacebookImportCandidate`: displayName (single string, not first/last), friendedOn, messageCount, touchScore, matchStatus, defaultClassification, matchedPersonInfo
- `FacebookMatchStatus`: `.exactMatchFacebookURL`, `.probableMatchAppleContact`, `.probableMatchCrossPlatform`, `.probableMatchName`, `.noMatch`
- `FacebookClassification`: `.add`, `.later`, `.merge`, `.skip`

**`UserFacebookProfileDTO.swift`** — User's own Facebook profile DTO with `coachingContextFragment` computed property for AI prompt injection.

**`SAMModels-FacebookImport.swift`** — SwiftData audit record: `FacebookImport` @Model + `FacebookImportStatus` enum.

**`FacebookImportCoordinator.swift`** — `@MainActor @Observable` singleton orchestrating the full import flow.
- State machine: idle → parsing → awaitingReview → importing → success/failed
- `loadFolder(url:)` — parses all JSON, computes touch scores via `TouchScoringEngine`, builds import candidates with 4-priority matching cascade
- `confirmImport(classifications:)` — enriches matched people, persists IntentionalTouch records, creates Apple Contacts for "Add" candidates, routes "Later" to UnknownSender triage
- Touch scores keyed by normalized display name (not URL, since Facebook exports have no profile URLs)

**`FacebookImportSettingsView.swift`** — Settings UI embedded in DisclosureGroup.
- Step 1: request archive from Facebook (JSON format)
- Step 2: folder picker → preview with friend/message/match counts → Review & Import button
- Status display, last import info, stale import warning

**`FacebookImportReviewSheet.swift`** — Modal review sheet with three sections.
- Probable Matches: side-by-side comparison, Merge/Keep Separate buttons
- Recommended to Add: candidates with touch score > 0 (default: add)
- No Recent Interaction: candidates with no touch signals (default: later)

### Modified Files (9)

- **`SAMModels-UnknownSender.swift`** — Added `facebookFriendedOn`, `facebookMessageCount`, `facebookLastMessageDate` fields
- **`SAMModels-Supporting.swift`** — Added `.facebook` case to `EvidenceSource` enum (quality weight 1.0, icon "person.2.fill")
- **`SAMModelContainer.swift`** — Added `FacebookImport.self` to schema, bumped SAM_v30 → SAM_v31
- **`SAMModels.swift`** — Added `facebookProfileURL` and `facebookFriendedOn` to SamPerson
- **`UnknownSenderRepository.swift`** — Added `upsertFacebookLater()` method mirroring `upsertLinkedInLater()`
- **`BookmarkManager.swift`** — Added `saveFacebookFolderBookmark()` and `hasFacebookFolderAccess`
- **`SettingsView.swift`** — Added Facebook Import DisclosureGroup in Data Sources tab
- **`SearchResultRow.swift`**, **`InboxDetailView.swift`**, **`InboxListView.swift`**, **`PersonDetailView.swift`**, **`MeetingPrepSection.swift`** — Added `.facebook` case to exhaustive `EvidenceSource` switches

### Key Design Decisions
- **Touch score keying by name:** Unlike LinkedIn (URL-keyed), Facebook touch scores keyed by normalized display name since exports have no profile URLs
- **UnknownSender synthetic key:** `"facebook:{normalized-name}-{timestamp}"` ensures uniqueness
- **No message watermark:** Facebook imports are full re-imports (no incremental), unlike LinkedIn's date-based watermark
- **Group thread handling:** Group messages attribute touches to all non-user participants at reduced weight

---

## March 3, 2026 — LinkedIn §13 Apple Contacts Batch Sync + §14 Missing SwiftData Models (schema SAM_v30)

### Overview
Completed the two remaining Priority 1 items from the LinkedIn Integration Spec: §13 Apple Contacts URL write-back with batch confirmation dialog and auto-sync preference, and §14 four missing SwiftData models (`NotificationTypeTracker`, `ProfileAnalysisRecord`, `EngagementSnapshot`, `SocialProfileSnapshot`). Schema bumped from SAM_v29 → SAM_v30.

### §14 — New SwiftData Models (`SAMModels-Social.swift`)

**`NotificationTypeTracker`** — Tracks which LinkedIn (and future platform) notification types SAM has seen. One record per `(platform, notificationType)` pair.
- `platform: String`, `notificationType: String`
- `firstSeenDate: Date?`, `lastSeenDate: Date?`
- `totalCount: Int`, `setupTaskDismissCount: Int`
- Replaces the proxy use of `IntentionalTouchRepository` in `LinkedInNotificationSetupGuide`.

**`ProfileAnalysisRecord`** — Persists profile analysis results in SwiftData instead of UserDefaults, enabling history comparison across imports and backup support.
- `platform: String`, `analysisDate: Date`, `overallScore: Int`, `resultJson: String`

**`EngagementSnapshot`** — Stores engagement metrics per platform per period. Prerequisite for §12 EngagementBenchmarker agent (deferred).
- `platform: String`, `periodStart: Date`, `periodEnd: Date`, `metricsJson: String`, `benchmarkResultJson: String?`

**`SocialProfileSnapshot`** — Platform-agnostic social profile storage. Prerequisite for §11 CrossPlatformConsistencyChecker agent (deferred).
- `samContactId: UUID?` (nil = user's own profile), `platform: String`, `platformUserId: String`, `platformProfileUrl: String`, `importDate: Date`
- Normalized identity: `displayName`, `headline`, `summary`, `currentCompany`, `currentTitle`, `industry`, `location`
- Metrics: `connectionCount`, `followerCount`, `postCount`
- JSON blobs: `websitesJson`, `skillsJson`, `platformSpecificDataJson`

All four models are **additive** (no breaking changes to existing models). Lightweight SwiftData migration handles the schema bump automatically.

### §13 — Apple Contacts LinkedIn URL Sync

**New DTO: `AppleContactsSyncCandidate`** (added to `LinkedInImportCandidateDTO.swift`)
- `displayName: String`, `appleContactIdentifier: String`, `linkedInProfileURL: String`
- Represents a contact whose Apple Contact record lacks the LinkedIn URL but should have it.

**`LinkedInImportCoordinator` additions:**
- `appleContactsSyncCandidates: [AppleContactsSyncCandidate]` — observable array of contacts pending sync
- `autoSyncLinkedInURLs: Bool` — UserDefaults preference (`sam.linkedin.autoSyncAppleContactURLs`)
- `prepareSyncCandidates(classifications:)` — builds the candidate list by searching Apple Contacts for each "Add" contact and checking whether the LinkedIn URL is already present. If `autoSyncLinkedInURLs` is true, writes immediately; otherwise, stores in `appleContactsSyncCandidates` for UI confirmation.
- `performAppleContactsSync(candidates:)` — batch-writes LinkedIn URLs via `ContactsService.updateContact(_:updates:samNoteBlock:)` using the existing `.linkedInURL` enrichment field.
- `dismissAppleContactsSync()` — clears pending candidates without writing ("Not Now").

**`LinkedInImportReviewSheet` additions (§13.1):**
- After `confirmImport` completes, calls `prepareSyncCandidates` (when auto-sync is off).
- If candidates exist, shows `AppleContactsSyncConfirmationSheet` before dismissing.
- `AppleContactsSyncConfirmationSheet` — single-confirmation modal showing: "SAM found LinkedIn profile URLs for X contacts marked Add. Would you like to add their LinkedIn URLs to Apple Contacts?" — scrollable list of contact names, "Add LinkedIn URLs to Apple Contacts" (⌘↩) and "Not Now" (Esc) buttons.
- When auto-sync is enabled, the coordinator handles the write in `confirmImport` step 10 without showing the dialog.

**`LinkedInImportSettingsContent` additions (§13.2):**
- New `autoSyncSection` sub-view: Toggle labeled "Automatically add LinkedIn URLs to Apple Contacts"
- Persisted to `UserDefaults sam.linkedin.autoSyncAppleContactURLs`, synced to `coordinator.autoSyncLinkedInURLs`.

### Key Decisions
- **Scope**: Only "Add" and "merge/skip" candidates — not "Later" contacts, per spec §13.1.
- **Conflict handling**: If Apple Contact already has a LinkedIn URL, the candidate is silently excluded from the sync list (no overwrite, no warning — the existing URL is trusted).
- **No new Contact framework permission needed**: Uses the existing `ContactsService.updateContact` path.
- **§11/§12 shells**: `SocialProfileSnapshot` and `EngagementSnapshot` are intentionally empty shells; they need no population code until §11/§12 are built.

---

## March 3, 2026 — Phase 8: Permissions & Onboarding Audit

### Overview
Extended the first-run onboarding sheet from 8 steps to 10 steps, adding explicit Notifications permission guidance and an MLX model download step. Added a step progress counter ("Step X of 10") to the header. Updated the Settings Permissions tab to include Notifications status and request. No new models. No schema change.

**Spec reference**: `context.md` §5 Priority 1 (highest priority before wider user testing).

### Files Modified
- **`Models/DTOs/OnboardingView.swift`** — primary changes (8 → 10 steps)
- **`Views/Settings/SettingsView.swift`** — Notifications row in `PermissionsSettingsView`

### OnboardingView.swift Changes

**New `OnboardingStep` cases:**
- `.notificationsPermission` — bell.circle.fill (red), 3 bullet points (coaching plans, background analysis, follow-up reminders), orange optional note, granted/denied status UI, "Enable Notifications" / "Skip" footer pair
- `.aiSetup` — cpu.fill (indigo), 3 bullet points (richer summaries, nuanced coaching, better insights), ~4 GB on-device note, GroupBox with Mistral 7B Download/Cancel/Ready states + ProgressView, `.task` checks if model already downloaded on entry

**New `@State` properties:**
```swift
// Notifications
@State private var notificationsGranted = false
@State private var notificationsDenied = false
@State private var skippedNotifications = false

// AI Setup (MLX)
@State private var isMlxDownloading = false
@State private var mlxDownloadProgress: Double = 0
@State private var mlxDownloadError: String?
@State private var mlxModelReady = false
@State private var skippedAISetup = false
```

**Step progress indicator in header:**
- "Step X of 10" subtitle below "Welcome to SAM" on all steps except `.welcome`
- `currentStepNumber` computed from ordered array; `totalSteps = 10`

**Navigation updates:**
- Mic permission success → `.notificationsPermission` (was `.complete`)
- Mic skip → `.notificationsPermission` (was `.complete`)
- `.microphonePermission` → `.notificationsPermission` → `.aiSetup` → `.complete`
- Back: `.complete` → `.aiSetup` → `.notificationsPermission` → `.microphonePermission`

**Footer:**
- `.notificationsPermission` gets its own "Skip" / "Enable Notifications" button pair (same pattern as Mic and Mail)
- `.aiSetup` uses generic "Skip for Now" via `shouldShowSkip`; Download button lives in step body

**`checkStatuses()`** — now also checks `UNUserNotificationCenter.current().notificationSettings()` on launch

**`saveSelections()`** — writes `UserDefaults "aiBackend" = "hybrid"` if `mlxModelReady`

**`completeStep`** — adds StatusRow/SkippedRow for Notifications (bell.circle.fill/red) and Enhanced AI (cpu.fill/indigo) after the Dictation row

**`completionTitle`/`completionMessage`** — includes `skippedNotifications` and `skippedAISetup` in `skippedAny`/`skippedAll` logic

**New helper methods:**
- `requestNotificationsPermission()` — async, calls `UNUserNotificationCenter.requestAuthorization(options:)`, advances to `.aiSetup` on grant
- `startMlxDownload()` — finds first model in `MLXModelManager.shared.availableModels`, calls `downloadModel(id:)`, polls `downloadProgress` every 250ms, sets `mlxModelReady` on completion
- `cancelMlxDownload()` — calls `MLXModelManager.shared.cancelDownload()`

### SettingsView.swift Changes (PermissionsSettingsView)

- Added `import UserNotifications`
- New `@State`: `notificationsStatus: String`, `isRequestingNotifications: Bool`
- Notifications row after Calendar row: bell.circle.fill (red), "Coaching alerts and follow-up reminders (optional)", status text with color, "Request Access" button when not yet requested
- `checkPermissions()` now checks `UNUserNotificationCenter.current().notificationSettings()` → maps to "Authorized" / "Denied" / "Not Requested"
- `notificationsStatusColor` computed property (green/red/secondary)
- `requestNotificationsPermission()` function — calls `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])`
- Help text updated: adds "For Notifications: System Settings → Notifications → SAM" path

### Decisions
- **Accessibility permission NOT added**: No feature that requires it (global hotkey / Priority 2) has been implemented yet. Adding the permission step before the feature would be premature.
- **Notifications marked optional**: SAM functions fully without them. The step explains what's missed (background alerts) and allows skip without friction.
- **MLX step is skippable**: Model download is entirely optional; Apple FoundationModels covers the base case. Hybrid backend only activates if model is downloaded before "Start Using SAM" is tapped.

---

## March 3, 2026 — LinkedIn Integration Rebuild: Intentional Touch Scoring (schema SAM_v29)

### Overview
Rebuilt the LinkedIn import pipeline from a simple message importer into a full relationship-intelligence channel that scores every connection by interaction history before the user decides whether to add them to SAM. This implements Channel A (bulk CSV import) from the LinkedIn Integration Spec, covering Sections 4–7.

### New SwiftData Models (SAM_v29)
- **`IntentionalTouch`** — Records a single social touch event. Fields: platform (rawValue), touchType (rawValue), direction (rawValue), contactProfileUrl, samPersonID?, date, snippet, weight, source (rawValue), sourceImportID?, sourceEmailID?, createdAt. Dedup key: `"platform:touchType:profileURL:minuteEpoch"` prevents re-insertion on subsequent imports.
- **`LinkedInImport`** — Audit record per archive import. Fields: id, importDate, archiveFileName, connectionCount, matchedContactCount, newContactsFound, touchEventsFound, messagesImported, statusRawValue.
- **`UnknownSender`** (extended) — Four new optional fields: `intentionalTouchScore: Int` (default 0), `linkedInCompany: String?`, `linkedInPosition: String?`, `linkedInConnectedOn: Date?`.

### New Supporting Types
- **`TouchPlatform`**, **`TouchType`** (with `baseWeight`), **`TouchDirection`**, **`TouchSource`** — Enums with `rawValue` stored in SwiftData.
- **`IntentionalTouchScore`** DTO — Computed summary: totalScore, touchCount, mostRecentTouch, touchTypes, hasDirectMessage, hasRecommendation, `touchSummary` text.
- **`TouchScoringEngine`** — Pure static scorer. Accepts messages, invitations, endorsements (given/received), recommendations (given/received), reactions, comments. Applies 1.5× recency bonus for touches within 6 months.
- **`IntentionalTouchCandidate`** — Sendable value type for bulk insert. Has `dedupKey` computed property and memberwise init with `weight` defaulting to `touchType.baseWeight`.
- **`LinkedInImportCandidate`** — Sendable DTO representing one unmatched connection in the review sheet. Carries touchScore, matchStatus (.exactMatch/.probableMatch/.noMatch), defaultClassification (.add/.later).
- **`LinkedInMatchStatus`**, **`LinkedInClassification`** — Enums for import review.

### New Repository
- **`IntentionalTouchRepository`** — @MainActor @Observable singleton. `bulkInsert(_:)` deduplicates in-memory against existing records before inserting. `fetchTouches(forProfileURL:)` and `fetchTouches(forPersonID:)` for retrieval. `computeScore(forProfileURL:)` and `computeAllScores()` score from persisted records. `attributeTouches(forProfileURL:to:)` backfills `samPersonID` when a Later contact is promoted. `insertLinkedInImport(_:)` persists audit records.
- **`UnknownSenderRepository`** — Added `upsertLinkedInLater(uniqueKey:displayName:touchScore:company:position:connectedOn:)`: creates or updates an UnknownSender record for a "Later" contact with full LinkedIn metadata. Re-surfaces dismissed records.

### LinkedInService Extensions
- **New parsers**: `parseRecommendationsReceived(at:)`, `parseReactionsGiven(at:)`, `parseCommentsGiven(at:)`, `parseShares(at:)`.
- **Date formatter fixes**: Endorsement dates (`yyyy/MM/dd HH:mm:ss zzz`) — previously used wrong formatter. Invitation "Sent At" dates (`M/d/yy, h:mm a`) — ISO8601DateFormatter was silently failing; added locale-style fallback formatter.
- **Updated DTOs**: `LinkedInEndorsementReceivedDTO` and `LinkedInEndorsementGivenDTO` gain `endorsementDate: Date?`. `LinkedInInvitationDTO` gains `message: String?` and `sentAt: Date?`.

### LinkedInImportCoordinator Rebuild
- `loadFolder` now parses all 8 touch CSVs (messages, connections, endorsements ×2, recommendations ×2, reactions, comments, invitations), calls `TouchScoringEngine.computeScores()`, builds `importCandidates: [LinkedInImportCandidate]` sorted by score descending, and advances to `.awaitingReview` status.
- `confirmImport(classifications:)` replaces the old zero-argument version. Accepts `[UUID: LinkedInClassification]` from the review sheet. Persists `IntentionalTouch` records via `IntentionalTouchRepository.bulkInsert`, creates a `LinkedInImport` audit record, and routes "Later" contacts to `UnknownSenderRepository.upsertLinkedInLater`.
- Added `reprocessForSender` touch attribution backfill: when promoting a Later contact, any existing `IntentionalTouch` records for their profile URL are attributed to the new `SamPerson.id`.
- Added `clearPendingState()` helper to avoid code duplication between cancel and post-confirm cleanup.
- Exposed convenience computed properties: `recommendedToAddCount`, `noInteractionCount`.

### New UI
- **`LinkedInImportReviewSheet`** — Sheet with two `LazyVStack` sections (pinned headers): "Recommended to Add" (score > 0, defaulted ON) and "No Recent Interaction" (score = 0, defaulted OFF). `CandidateRow` shows full name, touch score badge (score > 0), company/position, touch summary, and connection date. Batch "Add All" buttons per section. ⌘↩ to import, ⎋ to cancel.
- **`LinkedInImportSettingsView`** — "Review & Import" button replaces inline "Import". Shows after `loadFolder` completes (status `.awaitingReview`). Progress spinner/status section hidden during review state.
- **`UnknownSenderTriageSection`** — New `linkedInSenders` group shown above regular senders, sorted by `intentionalTouchScore` descending. `LinkedInTriageRow` component shows company/position, touch score badge, connection date, and omits the "Never" radio button (LinkedIn contacts should never be permanently blocked — they're professional contacts).

### Migration Notes
- Schema bump: `"SAM_v28"` → `"SAM_v29"` in all three `ModelConfiguration` locations in `SAMModelContainer.swift`.
- Existing `UnknownSender` records upgrade safely — new fields all have defaults (Int = 0, String? = nil, Date? = nil).
- The `intentionalTouchScore: Int` field without `@Attribute(.unique)` is additive and non-breaking.

---

## March 2, 2026 - Settings Defaults Overhaul & Strategic Coordinator Tuning

### Overview
Corrected six UserDefaults defaults that were shipping with the wrong initial value, added a unified global lookback picker, auto-upgraded the AI backend when an MLX model is present, and ran benchmarks to choose a single supported MLX model. Also investigated and rolled back a prompt-schema change that traded output quality for marginal speed gain.

### Settings Defaults (UserDefaults nil-check pattern)
All boolean defaults that were previously returning `false` when unset now use the `object(forKey:) == nil ? defaultValue : bool(forKey:)` pattern (matching the existing `contentSuggestionsEnabled` convention):
- `outcomeAutoGenerate` — default changed to **`true`** (outcomes now generate on launch out-of-the-box)
- `commsMessagesEnabled` — default changed to **`true`**
- `commsCallsEnabled` — default changed to **`true`**

### Unified Global Lookback Period
- New UserDefaults key `globalLookbackDays` (default **30 days**) replaces three separate per-source lookback pickers.
- `DataSourcesSettingsView` now has a single "History Lookback Period" picker at the top of the Data Sources settings section.
- `CalendarImportCoordinator`, `MailImportCoordinator`, and `CommunicationsImportCoordinator` all fall back to `globalLookbackDays` when their source-specific key is unset.
- Per-source lookback pickers removed from `CalendarSettingsContent`, `MailSettingsView`, and `CommunicationsSettingsView`.
- Onboarding default lookback updated from 14 → 30 days.

### AI Backend Auto-Upgrade
- `CoachingSettingsView` now auto-switches from `foundationModels` to `hybrid` backend immediately after a successful MLX model download.
- On view load, if any model is already downloaded and backend is still `foundationModels`, it auto-upgrades silently.

### Relabeled Relationship Alert Threshold
- Setting label changed from "Relationship alert threshold:" to "Alert threshold for untagged contacts:" with clarified description — it only fires for contacts with no role badge assigned.

### MLX Model Selection — Mistral 7B Only
- Benchmarked Mistral 7B (`mlx-community/Mistral-7B-Instruct-v0.3-4bit`, ~4 GB) vs Llama 3.2 3B on the Harvey seed dataset.
- Results: Both ~54s total wall-clock (parallel specialists). Mistral produced valid JSON on all four specialists and 5 recommendations. Llama produced malformed JSON for Pipeline Health (specialist failed entirely) and only 4 recommendations.
- **Llama 3.2 3B removed from `MLXModelManager.availableModels`**. Mistral 7B is the sole curated MLX model. Simplifies onboarding and eliminates a class of silent JSON failures.

### Strategic Coordinator Diagnostic Logging
- Added `⏱` timing logs at digest start/end and per-specialist in `StrategicCoordinator` and all four specialist services.
- Added `📏` context-size logs (char count + estimated token count) for inputs and Pipeline Health response.
- These logs are retained for ongoing performance monitoring — filter on `⏱` or `📏` in Console.

### `steps` Schema Field — Investigated, Retained
- Hypothesis: removing `"steps": [...]` from the `approaches` JSON schema in `PipelineAnalystService`, `TimeAnalystService`, and `PatternDetectorService` would reduce output tokens and speed up generation.
- Result: Pipeline Health dropped from ~37s to ~35s (within noise). Total digest time unchanged (~47s, Time Balance became bottleneck). More importantly, output quality degraded — fewer recommendations generated and less detail per approach.
- **Reverted**: `"steps": ["Step 1", "Step 2", "Step 3"]` restored to all three services. The `steps` field drives richer model output and is worth the token cost.

---

## March 2, 2026 — Contact Enrichment & User Profile Intelligence (Steps 1–14)

### Overview

Two-track feature built on top of the Phase S+ LinkedIn import infrastructure:

- **Track 1 (Contact Enrichment)**: Parse richer LinkedIn CSVs (endorsements, recommendations, invitations) → generate per-field `PendingEnrichment` candidates → let the user review and approve write-back to Apple Contacts. Surfaces via a "Needs Contact Update" filter in People list, a banner in PersonDetailView, and a per-field review sheet.
- **Track 2 (User Profile Intelligence)**: Parse the user's own LinkedIn profile CSVs (Profile, Positions, Education, Skills, Certifications) → assemble a `UserLinkedInProfileDTO` → store in `BusinessProfileService` → inject into all AI specialist system prompts as a `## LinkedIn Profile` context section.

Schema bumped from SAM_v27 → SAM_v28 (additive: `PendingEnrichment` model).

---

### Architecture Decisions

**Separate `PendingEnrichment` model (not extra fields on SamPerson)**
Enrichment is transient, per-field, and may come from multiple sources (LinkedIn today, call metadata tomorrow). A standalone SwiftData model with a dedup key `(personID, field, proposedValue)` keeps the contact model clean and allows future enrichment sources to plug in without schema changes.

**Separate `ContactEnrichmentCoordinator` (not in LinkedInImportCoordinator)**
The enrichment review-and-apply pipeline is a distinct workflow that will serve future data sources. Keeping it separate from import logic lets each coordinator have a focused responsibility. Same `@MainActor @Observable` singleton pattern as `UnknownSenderRepository`.

**`--- SAM ---` text delimiter in Apple Contacts notes**
Human-readable in Contacts.app, idempotent across repeated write-backs, and preserves user-authored content above the delimiter verbatim. The SAM block below the delimiter is always regenerated cleanly.

**Graceful degradation for `CNContactNoteKey`**
The notes entitlement may not be approved. Rather than a type-method availability check (which doesn't exist on CNContact), we use a try-catch: attempt fetch with note key; if it throws, fall back to base keys and skip the note update. All other enrichment fields (organization, job title, phone, email, LinkedIn social profile) still apply.

**`UserLinkedInProfileDTO` stored in UserDefaults JSON (not SwiftData)**
User profile data is a singleton and only ever replaced wholesale on each import — no per-record querying needed. UserDefaults JSON is the simplest durable store. Cached in `BusinessProfileService` for synchronous access from coordinator context fragments.

**Two-track classification**
LinkedIn data naturally splits into two categories:
- *About the user* (Profile.csv, Positions.csv, Education.csv, Skills.csv, Certifications.csv) → feeds AI context
- *About contacts* (Connections.csv, messages.csv, Endorsement_Received_Info.csv, Endorsement_Given_Info.csv, Recommendations_Given.csv, Invitations.csv) → feeds contact enrichment and relationship evidence

This split is the conceptual foundation for all future social media platform imports.

---

### Step 1 — `PendingEnrichment` SwiftData Model

**New file**: `Models/SAMModels-Enrichment.swift`

`@Model class PendingEnrichment` with:
- `id: UUID`
- `personID: UUID` (soft reference — no SwiftData relationship to avoid cascade complications)
- `fieldRawValue: String` (backing for `EnrichmentField` enum: `company`, `jobTitle`, `email`, `phone`, `linkedInURL`)
- `proposedValue: String`
- `currentValue: String?`
- `sourceRawValue: String` (backing for `EnrichmentSource` enum: `linkedInConnection`, `linkedInEndorsement`, `linkedInRecommendation`, `linkedInInvitation`)
- `sourceDetail: String?`
- `statusRawValue: String` (backing for `EnrichmentStatus` enum: `pending`, `approved`, `dismissed`)
- `createdAt: Date`
- `resolvedAt: Date?`

**Modified**: `App/SAMModelContainer.swift` — Added `PendingEnrichment.self` to `SAMSchema.allModels`, bumped `SAM_v27` → `SAM_v28`. Additive lightweight migration.

---

### Step 2 — `EnrichmentRepository`

**New file**: `Repositories/EnrichmentRepository.swift`

`@MainActor @Observable` singleton:
- `bulkRecord(_:)` — upsert candidates, skip duplicates by `(personID, field, proposedValue)` dedup key
- `fetchPending(for personID:)` → `[PendingEnrichment]`
- `fetchPeopleWithPendingEnrichment()` → `Set<UUID>`
- `pendingCount()` → `Int`
- `approve(_:)` / `dismiss(_:)` — update status + set `resolvedAt`

---

### Step 3 — New LinkedIn CSV Parsers in `LinkedInService`

**Modified**: `Services/LinkedInService.swift`

New DTOs:
- `LinkedInEndorsementDTO` (endorserName, endorserProfileURL, endorseeName, endorseeProfileURL, skillName)
- `LinkedInRecommendationGivenDTO` (recipientName, company, jobTitle, text)
- `LinkedInInvitationDTO` (name, direction, profileURL, sentAt)

New parse methods (all inside the actor):
- `parseEndorsementsReceived(at:)` — parses `Endorsement_Received_Info.csv`
- `parseEndorsementsGiven(at:)` — parses `Endorsement_Given_Info.csv`
- `parseRecommendationsGiven(at:)` — parses `Recommendations_Given.csv`
- `parseInvitations(at:)` — parses `Invitations.csv`

**Critical bug fixed during this step**: The methods from a prior session had been accidentally placed OUTSIDE the actor's closing `}` (which was at line 324, after `parseCSV`). All those orphaned methods caused 81 "Cannot find 'logger' in scope" / "Cannot find 'parseCSV' in scope" errors. Fix: removed the misplaced `}` so the actor's true closing brace encompasses all parse methods.

---

### Step 4 — Enrichment Candidate Generation in `LinkedInImportCoordinator`

**Modified**: `Coordinators/LinkedInImportCoordinator.swift`

New coordinator state:
```swift
private(set) var pendingEndorsementsReceivedCount: Int = 0
private(set) var pendingEndorsementsGivenCount: Int = 0
private(set) var pendingRecommendationsGivenCount: Int = 0
private(set) var pendingInvitationsCount: Int = 0
private(set) var enrichmentCandidateCount: Int = 0
```

In `loadFolder(url:)`: also parses the four new CSVs and records counts.

In `confirmImport()`: new enrichment generation phase — for each matched connection with non-empty company/position, diffs against the person's current Apple Contacts data (organizationName, jobTitle) and creates `PendingEnrichment` records when values differ.

**Also fixed**: `nonEmptyOrNil` String extension was `fileprivate` in LinkedInService.swift and inaccessible here. Replaced with inline nil-coalescing checks. Logger string interpolation also required explicit variable captures for Swift 6 strict concurrency.

---

### Steps 5–6 — `ContactsService.updateContact()` + SAM Note Block

**Modified**: `Services/ContactsService.swift`

New method:
```swift
func updateContact(
    identifier: String,
    updates: [EnrichmentField: String],
    samNoteBlock: String?
) async -> Bool
```

Approach:
1. Fetch `CNContact` with detail keys. Attempt to include `CNContactNoteKey`; if the entitlement is unavailable (try-catch), fall back to base keys and skip the note update — all other field updates still proceed.
2. Apply field updates: `organizationName`, `jobTitle`, append phone/email if not already present, upsert LinkedIn social profile.
3. If note key was successfully fetched and `samNoteBlock` is provided, update the SAM-managed note block using the `--- SAM ---` delimiter pattern: content above the delimiter is preserved verbatim; everything below is replaced with the new block.
4. Execute `CNSaveRequest`.

Note block format:
```
{user's own notes unchanged above this line}
--- SAM ---
Updated: {date}
Roles: {badges}
LinkedIn: connected {date}
Last interaction: {relative time} ({channel})
{abbreviated summary}
```

**Modified**: `SAM_crm.entitlements` — Added `com.apple.security.contacts.contacts-write` key.

**Pattern for CNContactNoteKey availability** (reusable for future integrations):
```swift
// Try with note key; fall back gracefully if entitlement not granted
do {
    contact = try store.unifiedContact(withIdentifier: id, keysToFetch: keysWithNote)
    fetchedWithNote = true
} catch {
    contact = try store.unifiedContact(withIdentifier: id, keysToFetch: baseKeys)
    fetchedWithNote = false
    logger.warning("Note key unavailable: \(error.localizedDescription)")
}
```

---

### Step 7 — `ContactEnrichmentCoordinator`

**New file**: `Coordinators/ContactEnrichmentCoordinator.swift`

`@MainActor @Observable` singleton:
- `peopleWithEnrichment: Set<UUID>` — cached for O(1) filter and badge lookup; refreshed on import completion and enrichment resolution
- `pendingEnrichments(for personID:)` → `[PendingEnrichment]`
- `applyEnrichments(_:for:)` — calls `ContactsService.updateContact()`, marks approved, refreshes cache
- `dismissEnrichments(_:)` — marks dismissed, refreshes cache
- `samNoteBlockContent(for:)` → `String` — generates formatted note block

---

### Step 8 — PeopleListView Special Filters + Enrichment Badge

**Modified**: `Views/People/PeopleListView.swift`

New enum:
```swift
enum PeopleSpecialFilter: String, CaseIterable {
    case needsContactUpdate = "Needs Contact Update"
    case notInContacts = "Not in Contacts"
}
```

Filter logic added to `displayedPeople`:
```swift
if activeSpecialFilters.contains(.needsContactUpdate) {
    list = list.filter { enrichmentCoordinator.peopleWithEnrichment.contains($0.id) }
}
if activeSpecialFilters.contains(.notInContacts) {
    list = list.filter { $0.contactIdentifier == nil && !$0.isMe }
}
```

Badge in `PersonRowView`: blue `arrow.up.circle.fill` icon with `.help("Contact updates available")` when enrichment is pending.

---

### Step 9 — PersonDetailView Enrichment Banner + `EnrichmentReviewSheet`

**Modified**: `Views/People/PersonDetailView.swift`
- Loads `pendingEnrichments` in `.task(id: person.id)` alongside existing contact load
- Conditional banner below header: "{N} contact update(s) available" with chevron, opens review sheet
- Banner uses `arrow.up.circle.fill` icon with `Color.blue.opacity(0.06)` background

**New file**: `Views/People/EnrichmentReviewSheet.swift`
- Per-field toggleable rows: checkbox, field name, source label, current value (strikethrough gray) → proposed value (blue), sourceDetail
- "Apply Selected" button (calls `ContactEnrichmentCoordinator.applyEnrichments`)
- "Dismiss All" button
- Pre-selects all items on appear
- On apply: sheet dismisses, banner disappears, detail view refreshes

---

### Step 10 — LinkedInImportSettingsView Preview Updates

**Modified**: `Views/Settings/LinkedInImportSettingsView.swift`
- Added summary rows for endorsements received/given, recommendations given, and invitations in the preview section
- Added enrichment candidate count in the success status display: "· N contact update(s) queued — see People list"

---

### Step 11 — `UserLinkedInProfileDTO`

**New file**: `Models/DTOs/UserLinkedInProfileDTO.swift`

```swift
public struct UserLinkedInProfileDTO: Codable, Sendable {
    public var firstName, lastName, headline, summary, industry, geoLocation: String
    public var positions: [LinkedInPositionDTO]
    public var education: [LinkedInEducationDTO]
    public var skills: [String]
    public var certifications: [LinkedInCertificationDTO]
    public nonisolated var currentPosition: LinkedInPositionDTO? { ... }
    public nonisolated var coachingContextFragment: String { ... }
}

public struct LinkedInPositionDTO: Codable, Sendable {
    public var companyName, title, description, location, startedOn, finishedOn: String
    public nonisolated var isCurrent: Bool { finishedOn.isEmpty }
}

public struct LinkedInEducationDTO: Codable, Sendable {
    public var schoolName, startDate, endDate, notes, degreeName, activities: String
}

public struct LinkedInCertificationDTO: Codable, Sendable {
    public var name, url, authority, startedOn, finishedOn, licenseNumber: String
}
```

Note: `nonisolated` required on computed properties of `Sendable` structs to prevent Swift 6 implicit `@MainActor` inference — a pattern to follow on all future `Sendable` DTOs with computed properties.

CSV column headers verified against real LinkedIn data export files (Profile.csv, Positions.csv, Education.csv, Skills.csv, Certifications.csv).

---

### Step 12 — User Profile Parsers in `LinkedInService`

**Modified**: `Services/LinkedInService.swift`

Added inside the actor (same fix as Step 3):
```swift
func parseProfile(at url: URL) async -> (firstName: String, lastName: String, ...)
func parsePositions(at url: URL) async -> [LinkedInPositionDTO]
func parseEducation(at url: URL) async -> [LinkedInEducationDTO]
func parseSkills(at url: URL) async -> [String]
func parseCertifications(at url: URL) async -> [LinkedInCertificationDTO]
func parseUserProfile(folder: URL) async -> UserLinkedInProfileDTO?  // composite
```

`parseUserProfile` calls all five sub-parsers in sequence and assembles the DTO. Returns `nil` if Profile.csv is absent (graceful — user may not have exported the Profile subset).

---

### Step 13 — User Profile Storage in `BusinessProfileService`

**Modified**: `Services/BusinessProfileService.swift`

```swift
private let linkedInProfileKey = "sam.userLinkedInProfile"
private var cachedLinkedInProfile: UserLinkedInProfileDTO?

func saveLinkedInProfile(_ profile: UserLinkedInProfileDTO) { ... }
func linkedInProfile() -> UserLinkedInProfileDTO? { ... }   // UserDefaults + in-memory cache
```

Extended `contextFragment()`: appends `## LinkedIn Profile\n{coachingContextFragment}` when a profile is present. This injects the user's headline, current role, certifications, and skills into all six AI specialist system prompts automatically.

---

### Step 14 — User Profile Integration in `LinkedInImportCoordinator`

**Modified**: `Coordinators/LinkedInImportCoordinator.swift`

New state:
```swift
private(set) var userProfileParsed: Bool = false
private var pendingUserProfile: UserLinkedInProfileDTO? = nil
```

In `loadFolder`: parses user profile via `linkedInService.parseUserProfile(folder:)`, sets `userProfileParsed`.

In `confirmImport`: saves parsed profile via `BusinessProfileService.shared.saveLinkedInProfile(_:)`. Logged with position/certification count.

In `cancelImport` and `loadFolder` reset: clears `pendingUserProfile` and `userProfileParsed`.

---

### Files Modified / Created

| File | Action |
|------|--------|
| `Models/SAMModels-Enrichment.swift` | NEW — PendingEnrichment @Model, EnrichmentField/Source/Status enums |
| `App/SAMModelContainer.swift` | MODIFIED — added PendingEnrichment, bumped v27→v28 |
| `Repositories/EnrichmentRepository.swift` | NEW — CRUD + dedup + peopleWithEnrichment cache |
| `Services/LinkedInService.swift` | MODIFIED — new DTOs + 4 contact parsers + 6 user profile parsers; fixed actor scope bug |
| `Coordinators/LinkedInImportCoordinator.swift` | MODIFIED — parse new CSVs, generate enrichment, user profile import |
| `Services/ContactsService.swift` | MODIFIED — updateContact() + SAM note block helper; CNContactNoteKey try-catch |
| `SAM_crm.entitlements` | MODIFIED — added contacts-write entitlement |
| `Coordinators/ContactEnrichmentCoordinator.swift` | NEW — review-and-apply workflow orchestrator |
| `Views/People/PeopleListView.swift` | MODIFIED — PeopleSpecialFilter enum + filters + enrichment badge |
| `Views/People/PersonDetailView.swift` | MODIFIED — enrichment banner + sheet trigger |
| `Views/People/EnrichmentReviewSheet.swift` | NEW — per-field review sheet |
| `Views/Settings/LinkedInImportSettingsView.swift` | MODIFIED — new CSV counts + enrichment candidate count |
| `Models/DTOs/UserLinkedInProfileDTO.swift` | NEW — user profile DTOs + coachingContextFragment |
| `Services/BusinessProfileService.swift` | MODIFIED — saveLinkedInProfile/linkedInProfile + contextFragment injection |

---

## March 2, 2026 - Phase S+: LinkedIn Archive Import, Unknown Sender Triage & UI Polish

### Overview
Full LinkedIn Data Archive import pipeline, surfacing unmatched contacts in Unknown Senders triage, social profile enrichment in Apple Contacts, per-person Interaction History in PersonDetailView, and Unknown Senders sorted by last name. No schema change beyond fields already added in Phase S.

### LinkedIn Import Infrastructure (`LinkedInService`, `LinkedInImportCoordinator`, `LinkedInImportSettingsView`)
- **`LinkedInService`**: Parses LinkedIn's `Connections.csv` (First Name, Last Name, Email Address, Connected On, Company, Position, URL) and `messages.csv` (FROM, TO, DATE, SUBJECT, CONTENT) into `LinkedInConnectionDTO` and `LinkedInMessageDTO` value types.
- **`LinkedInImportCoordinator`**: Watermark-based import (`sam.linkedin.lastImportDate` in UserDefaults). On first run processes all records; subsequent runs skip messages older than the watermark. Matches connections and message senders to existing `SamPerson` records by LinkedIn profile URL first, then fuzzy display-name match. Upserts evidence via `EvidenceRepository.bulkUpsertMessages`. Dedup key: `linkedin:<senderProfileURL>:<ISO8601date>`.
- **`LinkedInImportSettingsView`**: Folder picker (NSOpenPanel), status display, import button. Shows per-phase progress messages during import ("Matching N connections…", "Importing N messages…", "Finalizing…") using `await Task.yield()` to keep UI responsive. Displays unmatched-contact count with orange hint linking to Unknown Senders triage.

### Unmatched Contacts → Unknown Senders Triage
- Connections and message senders that don't match any `SamPerson` are recorded in `UnknownSender` triage with a synthetic `linkedin:<profileURL>` key (or `linkedin-unknown-<name>` when no URL available).
- `UnknownSenderTriageSection` updated: detects `linkedin:` prefix keys, shows network icon badge on LinkedIn entries, renames column header to "Subject / Profile", loads LinkedIn senders on import status change.
- **Promoting a LinkedIn unknown contact** ("Add"): creates Apple Contact with LinkedIn social profile field (`CNSocialProfile` / `CNSocialProfileServiceLinkedIn`), calls `linkedInCoordinator.reprocessForSender(profileURL:)` to re-read `messages.csv` from the last-imported folder (via security-scoped bookmark) and import their full message history. Skips duplicates by `sourceUID`.

### Social Profile Enrichment in Apple Contacts
- `ContactsService.createContact()` now accepts `linkedInProfileURL` parameter and writes a `CNSocialProfile` (service: `CNSocialProfileServiceLinkedIn`) on the new contact — visible in Contacts.app under Social Profiles.

### LinkedIn Profile URL Back-Fill During Message Import
- During the messages import loop, when a person is matched by display name (not by URL), their `linkedInProfileURL` is immediately written onto the `SamPerson` record and the in-memory `byLinkedInURL` lookup table is updated in place. Ensures family members and close contacts who appear in `messages.csv` but not `Connections.csv` (e.g. not formally connected) are correctly linked on first import.
- `PeopleRepository.save()` called after the messages loop to persist back-fills.

### Security-Scoped Bookmark for LinkedIn Folder
- `BookmarkManager` extended with `linkedInFolderBookmarkData`, `saveLinkedInFolderBookmark(_:)`, `resolveLinkedInFolderURL()`, `revokeLinkedInFolderAccess()`. Stale-bookmark refresh handles the LinkedIn key in its 3-branch switch. `SettingsView.clearAllData()` removes `"linkedInFolderBookmark"` key.

### PersonDetailView — Interaction History Section
- New "Interaction History" section added to the primary sections of `PersonDetailView` (below Notes, above Recruiting Pipeline / Production).
- Shows all `SamEvidenceItem` records linked to the person where `source.isInteraction == true`, sorted newest-first.
- Each row: colored source icon, title, snippet (1 line), date.
- Default: 3 items visible. "N more…" button reveals 10 at a time. "Show fewer" collapses back to 3. Resets to 3 when navigating to a different person.
- `EvidenceSource` extended with `iconName: String` (SF Symbol) in `SAMModels-Supporting.swift`; `iconColor: Color` added as a private SwiftUI extension at the bottom of `PersonDetailView.swift`.

### Unknown Senders — Sort by Last Name
- `UnknownSenderRepository.fetchPending()` now sorts client-side by the last word of `displayName` (falling back to `email`), using `localizedCaseInsensitiveCompare`. Replaces previous `emailCount` descending sort.

### Key Files Modified
| File | Change |
|------|--------|
| `Services/LinkedInService.swift` | New — CSV parsers for Connections and messages |
| `Coordinators/LinkedInImportCoordinator.swift` | New — full import pipeline, progress messages, reprocess-for-sender |
| `Views/Settings/LinkedInImportSettingsView.swift` | New — folder picker, progress UI, unmatched count hint |
| `Views/Awareness/UnknownSenderTriageSection.swift` | LinkedIn detection, network icon, reprocess on promote |
| `Services/ContactsService.swift` | LinkedIn social profile on contact creation |
| `Utilities/BookmarkManager.swift` | LinkedIn folder bookmark support |
| `Repositories/PeopleRepository.swift` | `save()`, `setLinkedInProfileURL()` |
| `Repositories/UnknownSenderRepository.swift` | Last-name sort in `fetchPending()` |
| `Views/People/PersonDetailView.swift` | Interaction History section |
| `Models/SAMModels-Supporting.swift` | `EvidenceSource.iconName`, `EvidenceSource.displayName` |
| `Views/Settings/SettingsView.swift` | Clear LinkedIn bookmark on wipe |

### Architecture Decisions
- **`linkedin:` prefix key** as synthetic unique key for contacts without email, enabling triage without conflating with email-keyed records.
- **Back-fill on name match**: rather than requiring a second import pass, immediately writing `linkedInProfileURL` during the messages loop ensures orphaned evidence is re-linked on the same import run.
- **`iconColor` as local SwiftUI extension**: keeps `SAMModels-Supporting.swift` Foundation-only; color is a UI concern isolated to the view layer.
- **Incremental "show more"**: 3 default + 10-at-a-time expansion prevents overwhelming long-history contacts while keeping the primary detail view clean.

---

## February 28, 2026 - Bug Fixes: Intro Timing, Tips State, JSON Null, Contacts Container, Task Priorities

### Overview
Multiple targeted fixes across the intro sequence, TipKit state management, JSON decoding robustness, Apple Contacts container resolution, and task priority scheduling. No schema change.

### Changes

**IntroSequenceCoordinator.swift**:
- **Two-phase fallback timer**: Previous fallback was `fallbackDuration + 10.0` measured from narration start — causing ~30s stalls when `AVAudioBuffer` zero-byte errors prevented `didFinish` from firing. Now: a pre-start timer fires at `fallbackDuration` (covers speech never starting); when `NarrationService.onStart` fires, the pre-start timer is cancelled and a tight post-start timer is set at `fallbackDuration + 3.0` from actual speech start. Stalls now recovered within ~3s instead of 30s.
- **All internal Tasks raised to `.userInitiated`**: Inter-slide delay, `onFinish` callback dispatch, and fallback timers all use `.userInitiated` priority to prevent background import work from starving the intro sequence.
- **Tips enabled on playback start**: `startPlayback()` now calls `SAMTipState.enableTips()` as a safety measure so tips are guaranteed on when the intro plays (the last slide directs users to Tips).
- **Last slide text updated**: `narrationText` changed to direct users to explore Tips and find their briefing in the upper right area of the Today screen. `headline` → "You're Ready", `subtitle` → "Explore Tips, then check your first briefing", `fallbackDuration` → 25.0.

**NarrationService.swift**:
- Added `onStart` callback parameter to `speak()` — optional `@Sendable () -> Void`.
- `SpeechDelegate` now implements `didStart` and fires the callback, enabling the coordinator to anchor post-start fallback timers to actual speech start rather than narration call time.

**SAMApp.swift**:
- Removed `#if DEBUG Tips.resetDatastore()` block that was running on every debug launch and interfering with tip state persistence.
- Added startup guard: if `sam.tips.guidanceEnabled` key is absent from UserDefaults, write `true` — ensures Tips default to on for first-launch users without resetting them on subsequent launches.
- Import tasks lowered to `Task(priority: .utility)` so background contacts/Evernote/calendar imports do not compete with the intro sequence.

**SettingsView.swift**:
- `clearAllData()` now calls `SAMTipState.resetAllTips()` before terminating, so TipKit datastore is wiped along with SwiftData — tips reappear fresh after relaunching from a clean-slate wipe.

**NoteAnalysisService.swift**:
- Fixed JSON decoding crash when LLM returns `"value": null` in `contact_updates`. `LLMContactUpdate.value` changed from `String` to `String?`. Mapping uses `.compactMap` to skip nil values, preventing `DecodingError.valueNotFound`.

**ContactsService.swift**:
- Fixed contact save failure `NSCocoaErrorDomain Code=134040` ("Save failed") caused by creating a new contact in the default iCloud container when the SAM group lived in a different container. Now resolves the SAM group's container via `CNContainer.predicateForContainerOfGroup(withIdentifier:)` before creating the contact, and passes that container ID to `save.add(mutable, toContainerWithIdentifier:)`.

**EvernoteImportCoordinator.swift**:
- Added observable `analysisTaskCount: Int` property, incremented/decremented around each analysis `Task`. `cancelAll()` resets count to 0. Analysis tasks use `Task(priority: .utility)` with `[weak self]` closures.

**ProcessingStatusView.swift**:
- Sidebar activity indicator now shows count-aware label: "Analyzing 1 note…" / "Analyzing N notes…" when `analysisTaskCount > 0`, falling back to the generic label from `NoteAnalysisCoordinator` otherwise.

**IntroSequenceOverlay.swift**:
- Shimmer effect on the welcome slide now repeats every ~2 seconds (1.0s wait → 0.8s sweep → 1.2s reset, loop while on welcome slide) instead of firing once.

### Root Causes Addressed
- **30s intro pauses**: `AVAudioBuffer` zero-byte errors cause `AVSpeechSynthesizer` to stall mid-utterance with `mDataByteSize = 0`; `didFinish` never fires. Two-phase fallback recovers within `fallbackDuration + 3.0s` of actual speech start.
- **Tips showing Off on startup**: `Tips.resetDatastore()` in `#if DEBUG` block was wiping state on every debug launch. Fixed by removal + explicit key guard.
- **Contact save Code=134040**: Contact created in default container (iCloud) while SAM group was in a separate container (e.g., On My Mac). Fixed by resolving group container before contact creation.
- **JSON null crash**: On-device LLM occasionally returns `"value": null` in structured output; Swift `Codable` with non-optional `String` throws. Fixed by making field optional.

---

## February 28, 2026 - Phase AB Polish: Tip System Cleanup + Debug Guard

### Overview
Replaced TipKit-based sidebar tips with simpler, more reliable custom UI. Removed all debug-only tip overrides and guarded the Debug menu behind `#if DEBUG` so it is stripped from Archive builds. No schema change.

### Changes

**AppShellView.swift**:
- Replaced `CommandPaletteTip` TipKit popover (which re-triggered on every sidebar selection) with a plain orange rounded-rect label above the nav links, visible only when Tips are enabled. Text: "Use ⌘K for quick navigation, ⌘1–4 to jump between sections."
- Replaced `TipsToggleTip` TipKit popover on the Tips button with an orange rounded-rect background on the button label itself when Tips are on, and plain secondary styling when off. No TipKit involvement.
- Removed `commandPaletteTip` and `tipsToggleTip` stored properties.

**SAMTips.swift**: Removed `CommandPaletteTip` and `TipsToggleTip` structs and all references to them in `allTipTypes`, `enableTips()`, and `disableTips()`.

**SAMApp.swift**:
- Removed `Tips.showAllTipsForTesting()` from app `init()` (was causing all tips to show on every debug launch).
- Removed `Tips.showAllTipsForTesting()` from the Debug menu Reset Tips action.
- Wrapped `CommandMenu("Debug")` in `#if DEBUG` so the Debug menu is fully stripped from Archive/Release builds.

**SettingsView.swift**: Removed `Tips.showAllTipsForTesting()` call from the Reset All Tips button action.

### Archive Safety
All debug-only code is now properly guarded:
- `Tips.resetDatastore()` on launch — `#if DEBUG` ✓
- `CommandMenu("Debug")` — `#if DEBUG` ✓ (newly added)
- `Tips.showAllTipsForTesting()` — removed entirely ✓

---

## February 28, 2026 - Phase AB Polish: App Icon, Shimmer, Narration Timing

### Overview
Intro sequence polish: app icon on welcome slide with shimmer effect, narration timing fix (removed AVSpeechUtterance delays, coordinator-controlled inter-slide gap). No schema change.

### Changes

**IntroSequenceOverlay.swift**: Welcome slide now displays the SAM app icon (128×128, loaded via `NSApplication.shared.applicationIconImage`) instead of the `brain.head.profile` SF Symbol. App icon has rounded rectangle clip shape, shadow, and a shimmer effect (animated `LinearGradient` overlay in `.screen` blend mode) that triggers 1 second after the slide appears. Other slides unchanged (SF Symbols with pulse animation).

**NarrationService.swift**: Removed `PRE_UTTERANCE_DELAY` and `POST_UTTERANCE_DELAY` global constants. Utterance `preUtteranceDelay` and `postUtteranceDelay` both set to 0. The synthesizer's internal delay handling caused increasing latency between slides — it considers itself "speaking" during delay periods, causing `stopSpeaking()` to interrupt the delay phase with accumulating overhead.

**IntroSequenceCoordinator.swift**: Added `interSlideDelay` (0.75s) controlled by `Task.sleep` in `advanceFromSlide()`. This replaces the AVSpeechUtterance delays with precise coordinator-controlled timing. The delay occurs after `didFinish` fires and the slide advances visually, before narration starts on the next slide.

---

## February 27, 2026 - Phase AB: In-App Guidance System

### Overview
First-launch narrated intro sequence + contextual TipKit coach marks with user toggle. Provides new user onboarding and ongoing feature discoverability. No schema change.

### New Files

**NarrationService.swift**: `@MainActor @Observable` singleton wrapping a single persistent `AVSpeechSynthesizer` (reused across all utterances to avoid CoreAudio session churn). Direct `speak()` API with `onFinish` callback — delegate lifecycle carefully managed to prevent double-advance (didCancel intentionally does NOT fire onFinish; callback is nil'd before stopSpeaking). Voice: Samantha Enhanced (en-US), with global constants for RATE and PITCH_MULTIPLIER. Diagnostic logging on didStart/didFinish/didCancel. Note: AVAudioSession is unavailable on macOS — no audio priority API exists.

**IntroSequenceCoordinator.swift**: `@MainActor @Observable` singleton managing 6-slide intro sequence (welcome, relationships, coaching, business, privacy, getStarted). Each slide has narration text, headline, subtitle, SF Symbol, and fallback duration. Auto-advances via NarrationService `onFinish` callback. Uses `narratingSlide` token to prevent double-advance race between didFinish callback and fallback timer — whichever fires first consumes the token, blocking the other. Generous fallback timers (15–20s + 10s buffer) as safety net only. Coordinator-controlled 0.75s inter-slide delay via `Task.sleep`. UserDefaults key: `sam.intro.hasSeenIntroSequence`. Pause/resume/skip support.

**IntroSequenceOverlay.swift**: Sheet view with 6 slides. `.ultraThinMaterial` background. Frame: 550–750×400–500. Welcome slide shows app icon with shimmer effect; other slides use SF Symbols with pulse animation. Bottom bar: pause/play, 6 progress dots, skip button. "Get Started" on final slide. `interactiveDismissDisabled()`. Respects `accessibilityReduceMotion` (opacity-only transitions).

**SAMTips.swift**: 12 TipKit tip definitions + `SAMTipState` enum with `@Parameter` global toggle. Each tip has `MaxDisplayCount(1)` and `#Rule(SAMTipState.$guidanceEnabled) { $0 == true }`. Tips: TodayHeroCardTip, OutcomeQueueTip, BriefingButtonTip, PeopleListTip, PersonCoachingTip, AddNoteTip, DictationTip, BusinessDashboardTip, StrategicInsightsTip, GoalsTip, CommandPaletteTip, SearchTip.

### Modified Files

**SAMApp.swift**: Added `Tips.configure([.displayFrequency(.immediate)])` in `init()`. Debug menu: "Reset Tips" + "Reset Intro".

**AppShellView.swift**: Intro sheet presentation with `.interactiveDismissDisabled()`. Task checks `hasSeenIntro` after 300ms delay. "?" toolbar button toggles `SAMTipState.guidanceEnabled` (resets datastore on enable). CommandPaletteTip attached to sidebar.

**SettingsView.swift**: Guidance section in General tab — toggle for contextual tips, Reset All Tips button, Replay Intro button.

**AwarenessView.swift**: TodayHeroCardTip on hero card section, BriefingButtonTip on briefing toolbar button.

**OutcomeQueueView.swift**: OutcomeQueueTip on queue header.

**PeopleListView.swift**: PeopleListTip after navigation title.

**PersonDetailView.swift**: PersonCoachingTip on header section.

**NoteEditorView.swift**: DictationTip on mic button.

**InlineNoteCaptureView.swift**: AddNoteTip on note capture area.

**BusinessDashboardView.swift**: BusinessDashboardTip on health summary.

**StrategicInsightsView.swift**: StrategicInsightsTip on strategic content.

**GoalProgressView.swift**: GoalsTip on Add Goal button.

**SearchView.swift**: SearchTip on search area.

**BackupCoordinator.swift**: Added `"calendarLookbackDays"` to `includedPreferenceKeys` (missed during lookback extension work).

### Key Decisions
- TipKit `@Parameter` with `#Rule` macro for production toggle (avoids testing-only APIs like `hideAllTipsForTesting()`)
- AVSpeechSynthesizer delegate pattern: private NSObject subclass because `@Observable` can't conform to `NSObjectProtocol`
- Fallback timers for intro slides: each slide has estimated duration + 5s timeout in case speech synthesis silently fails

---

## February 27, 2026 - Coaching Calibration Phases 2–4 (Full Feedback System)

### Overview
Complete feedback loop that helps SAM learn the user's style, preferences, and what works in their specific market. Builds on Phase 1 (BusinessProfile + universal blocklist). Three phases: signal collection + wiring fixes (Phase 2), adaptive learning engine (Phase 3), transparency + user control (Phase 4). No schema change — all data stored as JSON in UserDefaults via CalibrationLedger.

### Phase 2: Feedback Collection + Wiring

**CalibrationDTO.swift** (new): `CalibrationLedger` Sendable struct with: per-OutcomeKind `KindStat` (actedOn, dismissed, totalRatings, ratingSum, avgResponseMinutes — computed actRate, avgRating), timing patterns (hourOfDayActs, dayOfWeekActs), strategic category weights (0.5–2.0), muted kinds, session feedback (`SessionStat` — helpful/unhelpful). Inherently bounded: 8 OutcomeKinds × 24 hours × 7 days × ~5 categories.

**CalibrationService.swift** (new): Actor with UserDefaults JSON persistence. API: `recordCompletion()`, `recordDismissal()`, `recordRating()`, `recordSessionFeedback()`, `setMuted()`, `calibrationFragment()` (human-readable AI injection), per-dimension resets. `static nonisolated(unsafe) var cachedLedger` for synchronous @MainActor access (populated on init, updated on every save).

**OutcomeQueueView.swift**: Fixed broken rating trigger — replaced `Int.random(in: 1...5) == 1` with `CoachingAdvisor.shared.shouldRequestRating()` (adaptive frequency). Added `CalibrationService.recordCompletion()` in `markDone()` with hour/dayOfWeek/responseMinutes. Added `CalibrationService.recordDismissal()` in `markSkipped()`. Added `CalibrationService.recordRating()` + `CoachingAdvisor.updateProfile()` in rating Submit.

**OutcomeEngine.swift**: Replaced `OutcomeWeights()` defaults with `CoachingAdvisor.shared.adjustedWeights()` in both `generateOutcomes()` and `reprioritize()`.

**BusinessProfileService.swift**: Extended `fullContextBlock()` to `async`, appends `CalibrationService.shared.calibrationFragment()`. All 6 AI agents automatically receive calibration data.

**CoachingSessionView.swift**: Added thumbs-up/thumbs-down session feedback in header. Routes to `CalibrationService.recordSessionFeedback(category:, helpful:)`.

### Phase 3: Adaptive Learning Engine

**CoachingAdvisor.swift**: Enhanced `adjustedWeights()` to read `CalibrationService.cachedLedger`. Fast responder (avg <60min) → timeUrgency 0.35. Slow responder (avg >240min) → timeUrgency 0.20. High dismiss ratio (>70%) → reduced userEngagement. Falls back to CoachingProfile when insufficient calibration data.

**OutcomeEngine.swift**: Muted-kind filtering removes outcomes for muted OutcomeKinds. Soft suppress: kinds with <15% actRate after 20+ interactions get 0.3× priority multiplier. Per-kind engagement: `computePriority()` uses `kindStat.actRate` instead of static 0.5 (after 5+ interactions for that kind).

**StrategicCoordinator.swift**: `computeCategoryWeights()` now reads CalibrationLedger strategic weights (0.5–2.0x range) when available. Falls back to existing digest-based computation (0.9–1.1x) if ledger has no data.

**CalibrationService.swift**: `recomputeStrategicWeights()` computes 0.5–2.0x weights per category from session feedback helpful/unhelpful ratio. `maybePrune()` halves all counters after 90 days to let recent behavior dominate.

### Phase 4: Transparency + User Control

**CoachingSettingsView.swift**: Replaced read-only "Feedback & Learning" with interactive "What SAM Has Learned" section. Per-kind progress bars (act rate) with per-kind reset buttons. Active hours summary (peak hours/days). Strategic focus weights with per-category reset. Muted types list with unmute buttons + "Mute a type" picker. Reset All Learning clears both CoachingProfile and CalibrationLedger.

**OutcomeCardView.swift**: Added `onMuteKind` callback + `.contextMenu` on Skip button with "Stop suggesting [type]" option → sets muted in CalibrationService then triggers skip.

**OutcomeQueueView.swift**: Added "Personalized" indicator (brain icon + label) in queue header when CalibrationLedger has 20+ total interactions.

### Feedback Loop
```
Signal               → Storage            → Processing         → Behavior Change
Done/Skip outcome   → CalibrationLedger  → adjustedWeights() → Priority scoring shifts
1–5 star rating     → CalibrationLedger  → kind act rates    → Low-rate kinds suppressed
Mute via context    → CalibrationLedger  → OutcomeEngine     → Kind completely filtered
Session thumbs      → CalibrationLedger  → category weights  → Strategic recs reweighted
All of the above    → calibrationFragment → All 6 AI agents  → AI suggestions aligned
```

### Files Summary
| File | Action |
|------|--------|
| `Models/DTOs/CalibrationDTO.swift` | NEW |
| `Services/CalibrationService.swift` | NEW |
| `Views/Awareness/OutcomeQueueView.swift` | MODIFY |
| `Coordinators/OutcomeEngine.swift` | MODIFY |
| `Services/BusinessProfileService.swift` | MODIFY |
| `Views/Business/CoachingSessionView.swift` | MODIFY |
| `Coordinators/CoachingAdvisor.swift` | MODIFY |
| `Coordinators/StrategicCoordinator.swift` | MODIFY |
| `Views/Settings/CoachingSettingsView.swift` | MODIFY |
| `Views/Shared/OutcomeCardView.swift` | MODIFY |

---

## February 27, 2026 - Coaching Calibration Phase 1 (Business Context Profile)

### Overview
Introduces a business context profile system that injects core facts about the user's practice into every AI specialist's system instruction. This prevents irrelevant suggestions (e.g., "research CRM tools" when SAM is the CRM, or "have your sales team" for a solo practitioner). Adds a universal blocklist enforced across all 6 AI agents, and a Settings > AI > Business Profile section for user configuration.

### Changes

**BusinessProfileDTO.swift** (new): Sendable DTO with practice structure (solo/team, org, role, experience), market focus (focus areas, recruiting status, geography), tools/capabilities (SAM-is-CRM, social platforms, communication channels), and free-form additional context. Includes `systemInstructionFragment()` method that generates the context block for AI injection.

**BusinessProfileService.swift** (new): Actor service with UserDefaults persistence. Provides `contextFragment()`, `blocklistFragment()`, and `fullContextBlock()` for AI injection. Universal blocklist prevents: software/tool suggestions, hiring suggestions, website/app building suggestions, ad purchases, and (for solo practitioners) team/staff/delegate references.

**SettingsView.swift**: Added "Business Profile" DisclosureGroup at top of AI settings tab with GroupBox sections for Practice Structure, Market Focus, Tools & Capabilities, and Additional Context. Uses existing FlowLayout for toggle button chips.

**PipelineAnalystService.swift**: Injects `BusinessProfileService.shared.fullContextBlock()` into system instruction.

**TimeAnalystService.swift**: Injects `BusinessProfileService.shared.fullContextBlock()` into system instruction.

**PatternDetectorService.swift**: Injects `BusinessProfileService.shared.fullContextBlock()` into system instruction.

**ContentAdvisorService.swift**: Injects `BusinessProfileService.shared.fullContextBlock()` into analyze() and `contextFragment()` into generateDraft().

**CoachingPlannerService.swift**: Updated `buildSystemInstruction()` to accept and inject business context block. Both `generateInitialPlan()` and `generateResponse()` now fetch and pass business context.

**LifeEventCoachingService.swift**: Updated `buildSystemInstruction()` to accept and inject business context block. Both `generateInitialCoaching()` and `generateResponse()` now fetch and pass business context.

### Files Summary
| File | Action |
|------|--------|
| `Models/DTOs/BusinessProfileDTO.swift` | NEW |
| `Services/BusinessProfileService.swift` | NEW |
| `Views/Settings/SettingsView.swift` | MODIFY |
| `Services/PipelineAnalystService.swift` | MODIFY |
| `Services/TimeAnalystService.swift` | MODIFY |
| `Services/PatternDetectorService.swift` | MODIFY |
| `Services/ContentAdvisorService.swift` | MODIFY |
| `Services/CoachingPlannerService.swift` | MODIFY |
| `Services/LifeEventCoachingService.swift` | MODIFY |

---

## February 27, 2026 - ⌘K Command Palette

### Overview
Adds a Spotlight-style ⌘K command palette overlay for quick navigation and people search, plus ⌘1–4 keyboard shortcuts for direct sidebar navigation. Reduces navigation friction for power users.

### Changes

**CommandPaletteView.swift** (new): Sheet overlay with search field, static navigation/action commands, and dynamic people results via SearchCoordinator. Features:
- Auto-focused search field with fuzzy substring matching on command labels
- Arrow key navigation, Enter to select, Escape to dismiss
- Static commands: Go to Today/People/Business/Search, New Note, Open Settings
- People results (top 5) from SearchCoordinator with photo thumbnails, role badges, email
- Selecting a person navigates to People section and selects that person

**AppShellView.swift**: Refactored body to use shared `Group` for command palette sheet and notification handlers (eliminates duplication across 2-column and 3-column layout branches). Added `.sheet(isPresented: $showCommandPalette)`, `.samToggleCommandPalette` and `.samNavigateToSection` notification receivers.

**SAMApp.swift**: Added `CommandGroup(after: .sidebar)` with ⌘K (command palette toggle) and ⌘1–4 (direct sidebar navigation) keyboard shortcuts via `.samNavigateToSection` notifications.

**SAMModels.swift**: Added `.samToggleCommandPalette` and `.samNavigateToSection` notification names.

### Files Summary
| File | Action |
|------|--------|
| `Views/Shared/CommandPaletteView.swift` | NEW |
| `Views/AppShellView.swift` | MODIFY |
| `App/SAMApp.swift` | MODIFY |
| `Models/SAMModels.swift` | MODIFY |

---

## February 27, 2026 - Strategic Action Coaching Flow

### Overview
Transforms the "Act" button on Strategic Actions from a passive "mark as acted on" flag into an active coaching pipeline. When recommendations are generated, each now includes 2-3 implementation approaches. Clicking "Act" opens an approach selection sheet, and selecting an approach launches a chatbot-style planning session that connects to concrete actions (compose, schedule, draft content, create note).

### Phase A: Data Layer — Implementation Approaches
- **StrategicDigestDTO.swift**: Added `ImplementationApproach` struct (id, title, summary, steps, effort), `EffortLevel` enum (quick/moderate/substantial), and `LLMImplementationApproach` parsing type
- **StrategicRec**: Added `approaches: [ImplementationApproach]` property (default empty, backward-compatible)
- **PipelineAnalystService, TimeAnalystService, PatternDetectorService**: Extended LLM prompts to generate 2-3 implementation approaches per recommendation; updated parsing to convert `LLMImplementationApproach` → `ImplementationApproach`
- **StrategicCoordinator**: Updated `synthesize()` to pass approaches through when adjusting priorities; added `condensedBusinessSnapshot()` for bounded coaching context

### Phase B: Approach Selection Sheet
- **StrategicActionSheet.swift** (new): Sheet showing recommendation context + implementation approach cards with effort badges. Each approach has a "Plan This" button that opens the coaching session. Includes "Mark as Done" and "Dismiss" for users who handle things on their own. Empty-approaches fallback shows a "Get Planning Help" button.
- **StrategicInsightsView.swift**: Rewired "Act" button to present StrategicActionSheet instead of directly recording feedback. Added state for action sheet and coaching session flow.

### Phase C: Coaching Chat Session
- **CoachingSessionDTO.swift** (new): `CoachingMessage` (id, role, content, timestamp, actions), `CoachingAction` (id, label, actionType, metadata), `CoachingSessionContext` (recommendation, approach, businessSnapshot)
- **CoachingPlannerService.swift** (new): Actor service managing AI interactions with bounded context windows (~1500 tokens per call). Generates initial plan and follow-up responses. Extracts actionable items from AI text via keyword matching (compose, schedule, draft, note patterns).
- **CoachingSessionView.swift** (new): Chat-style interface with message bubbles, action buttons routed to existing infrastructure (ComposeWindowView, ContentDraftSheet, DeepWorkScheduleSheet, QuickNoteWindow), text input with send, and "Done" button that records feedback.

### Files Created
- `SAM/Views/Business/StrategicActionSheet.swift`
- `SAM/Views/Business/CoachingSessionView.swift`
- `SAM/Models/DTOs/CoachingSessionDTO.swift`
- `SAM/Services/CoachingPlannerService.swift`

### Phase D: Concurrent Plan Generation Fix
- **StrategicInsightsView.swift**: Replaced single-valued state (`preparingPlanForRecID`, `preparedMessages`) with dictionary-based `preparations: [UUID: PlanPreparation]` keyed by recommendation ID. Multiple plans can now generate simultaneously without clobbering each other. Completed plans show "View Plan" / "Discard" buttons instead of auto-opening the coaching session. New `PlanPreparation` struct tracks per-recommendation state (recommendation, approach, messages, isReady).

### Phase E: Best Practices Knowledge Base
- **BestPractices.json** (new): Bundled JSON database of 24 WFG-relevant best practices across 6 categories (pipeline, recruiting, time, content, pattern, general). Each entry includes title, description, and suggested actions.
- **BestPracticeDTO.swift** (new): Sendable DTO for best practice entries (id, title, category, description, suggestedActions).
- **BestPracticesService.swift** (new): Actor service that loads bundled + user-contributed practices from UserDefaults. Queries by category with limit. Supports user CRUD for custom practices.

### Phase F: Constrained Coaching Prompts
- **CoachingPlannerService.swift**: Completely rewritten system instruction with explicit allowlist of actions (compose, schedule, draft, review data, consult upline, visit places, suggest talking points) and blocklist (no tool research, IT hiring, software purchases, website building). Best practices injected into system instruction for grounded advice. Initial plan and follow-up prompts tightened with constraint reminders.
- **CoachingSessionDTO.swift**: Added `reviewPipeline` action type for navigating to Business dashboard.
- **CoachingSessionView.swift**: Added handler for `reviewPipeline` action (posts `.samNavigateToStrategicInsights` notification). Added icon/tint for new action type.
- **SAMModels.swift**: Added `.samNavigateToStrategicInsights` notification name.
- **AppShellView.swift**: Added handler to navigate sidebar to "business" on strategic insights notification.
- **BusinessDashboardView.swift**: Added handler to select Strategic tab (index 0) on strategic insights notification.
- Action extraction updated with new patterns: "review your pipeline" → `.reviewPipeline`, "upline/trainer/field coach" → `.composeMessage` with "Contact Upline" label.

### Phase G: System Notifications for Plan Readiness
- **SystemNotificationService.swift** (new): `@MainActor` service managing macOS system notifications via `UNUserNotificationCenter`. Configures notification categories at app launch. Posts "Coaching Plan Ready" notification when background plan generation completes. Handles notification tap to bring app to foreground and navigate to Strategic Insights. Lazy permission request (first time only).
- **SAMApp.swift**: Added `applicationDidFinishLaunching` to `SAMAppDelegate` for notification service configuration.
- **StrategicInsightsView.swift**: Posts system notification after plan generation completes, so user knows even if they navigated away from the Business tab.

### Files Created
- `SAM/Views/Business/StrategicActionSheet.swift`
- `SAM/Views/Business/CoachingSessionView.swift`
- `SAM/Models/DTOs/CoachingSessionDTO.swift`
- `SAM/Services/CoachingPlannerService.swift`
- `SAM/Resources/BestPractices.json`
- `SAM/Models/DTOs/BestPracticeDTO.swift`
- `SAM/Services/BestPracticesService.swift`
- `SAM/Services/SystemNotificationService.swift`

### Files Modified
- `SAM/Models/DTOs/StrategicDigestDTO.swift`
- `SAM/Services/PipelineAnalystService.swift`
- `SAM/Services/TimeAnalystService.swift`
- `SAM/Services/PatternDetectorService.swift`
- `SAM/Coordinators/StrategicCoordinator.swift`
- `SAM/Views/Business/StrategicInsightsView.swift`
- `SAM/Models/SAMModels.swift`
- `SAM/Views/AppShellView.swift`
- `SAM/Views/Business/BusinessDashboardView.swift`
- `SAM/App/SAMApp.swift`

---

## February 27, 2026 - Interactive Content Ideas

### Overview
Content Ideas in the Business > Strategic view were previously rendered as plain, non-interactive numbered text. Users could not select, copy, or take action on any content idea. Additionally, the persistence layer was discarding structured `ContentTopic` data (keyPoints, suggestedTone, complianceNotes) by flattening to semicolon-separated titles.

### Changes

**StrategicCoordinator.swift**: `persistDigest()` now JSON-encodes the full `[ContentTopic]` array into `contentSuggestions` instead of flattening to semicolon-separated titles. This preserves keyPoints, suggestedTone, and complianceNotes for downstream rendering.

**StrategicInsightsView.swift**: `contentIdeasSection` rewritten to decode structured `ContentTopic` JSON. Each idea is now a clickable button showing the topic title and key points. Clicking opens `ContentDraftSheet` pre-populated with the topic's structured data. Backward-compatible: falls back to semicolon-separated plain text rendering (with text selection enabled) for digests created before this change. Added `selectedContentTopic` state and `.sheet(item:)` for `ContentDraftSheet`.

### Files Modified
| File | Action |
|------|--------|
| `Coordinators/StrategicCoordinator.swift` | MODIFY — JSON-encode ContentTopic array |
| `Views/Business/StrategicInsightsView.swift` | MODIFY — interactive content ideas + ContentDraftSheet |

---

## February 27, 2026 - Life Event Coaching

### Overview
Adds tangible action capabilities to Life Event cards in the Today view. Previously, life events showed only Done/Skip buttons with a copy-only outreach suggestion. Now each card includes Send Message, Coach Me, and Create Note buttons. The "Coach Me" button opens an AI coaching chatbot with event-type-calibrated tone — empathetic for loss/health events, celebratory for milestones, transition-supportive for job changes and retirement.

### Phase H: Life Event Action Buttons + Coaching Chatbot

**New Files:**
- **LifeEventCoachingService.swift**: Actor service with event-type-calibrated AI prompts. `buildSystemInstruction()` selects tone guidance per event type (loss → empathy-first with no business pivot; new_baby/marriage/graduation → celebration then gentle coverage review; job_change/retirement/moving → congratulations + financial planning transition). Action extraction pre-populates person metadata. Follows CoachingPlannerService pattern.
- **LifeEventCoachingView.swift**: Chat-style coaching interface for life events. Mirrors CoachingSessionView structure with message bubbles, action buttons (compose, schedule, note, navigate), and text input. Header shows event icon, person name, event type badge. Uses `.task` for initial coaching load via `LifeEventCoachingService`.
- **FlowLayout.swift** (shared): Extracted `FlowLayout` from CoachingSessionView to `Views/Shared/FlowLayout.swift`. Removed duplicate private copies from CoachingSessionView, MeetingPrepSection, and PersonDetailView.

**Modified Files:**
- **CoachingSessionDTO.swift**: Added `LifeEventCoachingContext` struct (event, personID, personName, personRoles, relationshipSummary) alongside existing `CoachingSessionContext`.
- **LifeEventsSection.swift**: Added 3 action buttons (Send Message/blue, Coach Me/purple, Create Note/green) to each card between outreach suggestion and Done/Skip. Added coaching sheet presentation via `activeCoachingContext` state. Added `resolvePersonID`, `sendMessage`, `createNote`, `openCoaching` handlers using existing payload types (ComposePayload, QuickNotePayload).
- **CoachingSessionView.swift**: Removed private `FlowLayout` (now uses shared version).
- **MeetingPrepSection.swift**: Removed private `FlowLayout` (now uses shared version).
- **PersonDetailView.swift**: Removed private `FlowLayout` (now uses shared version).

### Key Design Decisions
- **Specialize, not generalize**: Created separate `LifeEventCoachingContext` and `LifeEventCoachingService` rather than generalizing the existing strategic coaching system. Life event coaching has fundamentally different prompt needs (emotional tone calibration) and context shape.
- **Reused existing primitives**: `CoachingMessage`, `CoachingAction`, `CoachingAction.ActionType` are shared between strategic and life event coaching.
- **Tone calibration**: AI is instructed to never pitch business services for loss/health events in initial outreach. For celebratory events, financial review is suggested as a separate later conversation, not embedded in the congratulatory message.

### Files Summary

| File | Action |
|------|--------|
| `Services/LifeEventCoachingService.swift` | NEW |
| `Views/Awareness/LifeEventCoachingView.swift` | NEW |
| `Views/Shared/FlowLayout.swift` | NEW (extracted) |
| `Models/DTOs/CoachingSessionDTO.swift` | MODIFY |
| `Views/Awareness/LifeEventsSection.swift` | MODIFY |
| `Views/Business/CoachingSessionView.swift` | MODIFY (remove FlowLayout) |
| `Views/Awareness/MeetingPrepSection.swift` | MODIFY (remove FlowLayout) |
| `Views/People/PersonDetailView.swift` | MODIFY (remove FlowLayout) |

---

## February 27, 2026 - UX Restructuring: Signal Over Noise

### Overview
Major UX overhaul transforming SAM from a feature-dense tool organized by data type into a focused coaching assistant organized by user intent. The goal: answer three questions in under 60 seconds — "What should I do right now?", "Who needs my attention?", and "How is my business doing?"

### Phase 1: Sidebar Consolidation
- **AppShellView.swift**: Reduced sidebar from 7 items (3 sections) to 4 flat items: Today, People, Business, Search
- Simplified layout: only People uses three-column layout; all others use two-column
- Extracted notification handlers into shared `AppShellNotificationHandlers` ViewModifier (eliminates duplication between layout branches)
- Added `@AppStorage` migration in `.onAppear` to remap stale values (`awareness`→`today`, `inbox`→`today`, `contexts`→`people`, `graph`→`business`)
- Removed `InboxDetailContainer` and `ContextsDetailContainer` helper structs from AppShellView (source files remain in project)
- Default sidebar selection changed from `"awareness"` to `"today"`

### Phase 2: Today View (Awareness Restructure)
- **AwarenessView.swift**: Renamed from "Awareness" to "Today"
- Replaced header stat cards with time-of-day greeting (`.largeTitle` bold) + subtle "Updated X ago" timestamp
- Added **Hero Card** zone: shows top-priority coaching outcome in a blue-tinted card with "Top Priority" label, or "You're on track" message when no urgent outcomes
- **Today's Actions** zone: merged actionQueue + todaysFocus sections into flat list with lightweight dividers (no collapsible group headers)
- **Review & Analytics** zone: wrapped 7 review sections in `DisclosureGroup` collapsed by default
- Moved filter bar + insights list below Review section
- Removed StatCard struct, `highPriorityCount`/`followUpCount`/`opportunityCount` computed properties, `collapsedGroups` state, `computedGroupOrder`, and `sectionGroupView`

### Phase 3: People List Improvements
- **PeopleListView.swift (PersonRowView)**: Cached health computation into single `health` property
- Name font upgraded from `.body` to `.headline`
- Replaced generic `person.circle.fill` fallback with colored **initials circle** (color from primary role via `RoleBadgeStyle`)
- Added **coaching preview line** below name: "Follow up — N days since last contact" (high/critical decay), "Engagement slowing" (decelerating velocity), or email fallback
- Added **urgency accent strip** (3pt red/orange bar on leading edge) for high/critical decay risk contacts

### Phase 4: Person Detail Simplification
- **OutcomeRepository.swift**: Added `fetchTopActiveOutcome(forPersonID:)` method
- **PersonDetailView.swift**: Redesigned above-the-fold header:
  - Photo enlarged to 96pt at full opacity with 12pt rounded corners + initials fallback
  - Health status as clear sentence with colored dot ("Healthy — last spoke 3 days ago" / "At risk — 28 days since last contact")
  - SAM recommendation card (blue-tinted) when active outcomes exist for the person
  - Quick action buttons: Call, Email, Add Note (`.bordered`, `.controlSize(.small)`)
  - Primary phone + email shown directly in header
- Reordered sections: Notes first, then Recruiting Pipeline, Production, Relationship Summary
- Added **"More Details"** `DisclosureGroup` (collapsed by default) containing: full contact info, referred by, alerts, contexts, coverages, communication preferences, relationship health details
- Removed Sync Info and Raw Insights sections from UI
- Updated `viewInGraph()` to set sidebar to `"business"` and post `.samNavigateToGraph` notification

### Phase 5: Business Dashboard Improvements
- **BusinessDashboardView.swift**: Added **Business Health Summary** above tabs — 4 metric cards in a grid (Active Pipeline, Clients, Recruiting, This Month)
- Default tab changed to Strategic (index 0)
- Reordered tabs: Strategic → Client Pipeline → Recruiting → Production → Goals → Graph
- Added Graph tab embedding `RelationshipGraphView()`
- Removed `GraphMiniPreviewView` from bottom of dashboard
- Added `.onReceive(.samNavigateToGraph)` to switch to Graph tab
- Navigation title changed from "Pipeline" to "Business"

### Files Modified
| File | Changes |
|------|---------|
| `AppShellView.swift` | Sidebar 7→4, layout simplification, notification ViewModifier |
| `AwarenessView.swift` | Renamed "Today", hero card, flat sections, collapsed review |
| `PeopleListView.swift` | Initials fallback, coaching preview, urgency strip |
| `PersonDetailView.swift` | Header redesign, section reorder, More Details group |
| `OutcomeRepository.swift` | `fetchTopActiveOutcome(forPersonID:)` |
| `BusinessDashboardView.swift` | Health summary, Strategic default, Graph tab |

### No Schema Changes
All changes are view-layer only. No SwiftData model migrations required.

---

## February 27, 2026 - Phase AA Completion: Advanced Interaction, Edge Bundling, Visual Polish + Accessibility (No Schema Change)

### Overview
Completed the remaining 3 implementation phases of the Phase AA Relationship Graph feature. Phase 6 adds relational-distance selection (double/triple-click with modifier key filtering), freehand lasso selection, and group drag for multi-selected nodes. Phase 7 adds force-directed edge bundling with polyline control points and label collision avoidance. Phase 8 adds comprehensive visual polish (ghost marching ants, role glyphs, drag grid, spring presets) and full accessibility support (high contrast, reduce transparency, reduce motion gates) plus four intelligence overlays for advanced network analysis.

### Phase 1: Role Relationship Edges (Previously Completed)
- Added `roleRelationship` case to `EdgeType` enum
- Added `RoleRelationshipLink` DTO
- `RelationshipGraphCoordinator.gatherRoleRelationshipLinks()` connects Me node to all contacts by role
- Role-colored edges with health-based weight; `showMeNode` defaults to `true`
- `gatherRecruitLinks()` fallback to Me node when `referredBy` is nil

### Phase 2: Family Clustering Completion (Previously Completed)
- Group drag: dragging any node in a family cluster moves all members
- Boundary click-to-select: tap inside cluster boundary selects all members
- Collapse/expand: double-click cluster boundary collapses to composite node; double-click composite restores
- ⌘G keyboard shortcut to toggle family clustering

### Phase 3: Bridge Pull/Release (Previously Completed)
- Bridge badge click pulls distant nodes toward bridge node with spring animation
- Release: click bridge again to animate pulled nodes back to original positions
- "Reset All Pulls" in toolbar and canvas context menu
- Ghost silhouettes during hover preview

### Phase 4: Ghost Merge UX (Previously Completed)
- Fuzzy name matching: Levenshtein distance highlights compatible nodes during ghost drag
- Magnetic snap within 40pt of compatible node
- Dissolve/pulse animation on merge confirm (reduce motion gated)
- "Dismiss Ghost" and "Dismiss All Ghosts" context menu items
- Delete key to dismiss selected ghost

### Phase 5: Keyboard Shortcuts + Context Menus (Previously Completed)
- Added ⌘G (toggle families), ⌘B (toggle bundling), ⌘R (reset layout), Delete (dismiss ghost), Space (context menu on selected node) keyboard shortcuts
- Expanded real node context menu: "Select Referral Chain", "Select Downline", "Hide from Graph"
- Canvas context menu: "Fit to View", "Reset Layout", "Toggle Families", "Toggle Edge Bundling", "Release All Pulls", "Unpin All Nodes"

### Phase 6: Selection Mechanics + Group Drag

**Relational-distance selection:**
- Double-click on node: select node + 1-hop neighbors (all edge types)
- Triple-click: select node + 2-hop neighbors
- Modifier key filters: Option = family only, Shift = recruiting only (no modifier = all types)
- `expandSelection(from:hops:edgeTypeFilter:)` method on coordinator performs filtered BFS
- Ripple animation: expanding circle from selected node, nodes highlight as ripple reaches them (reduce motion gated)

**Lasso selection:**
- Option+drag on empty canvas draws freehand lasso path
- Closed path hit tests all nodes via `Path.contains()`
- Shift+Option+drag adds to existing selection
- Dashed accent-color stroke with light fill during drag

**Group drag:**
- Dragging a selected node when multiple are selected moves all selected nodes together
- Preserves relative positions via `groupDragOffsets` map
- All moved nodes become pinned on release

**Navigation change:**
- Double-click repurposed from navigation to selection
- Return/Enter key now navigates to selected person (replacing double-click navigation)

### Phase 7: Edge Bundling + Label Collision Avoidance

**Edge bundling:**
- `GraphBuilderService.bundleEdges()` method: force-directed edge bundling
  - Subdivides each edge into polyline with configurable control points (default 5)
  - 40 iterations of spring attraction between similarly-directed control points (angle < threshold)
  - Compatibility check based on angular similarity
  - Returns `[UUID: [CGPoint]]` map of bundled control point paths
- `edgeBundlingEnabled: Bool` on coordinator (persisted in UserDefaults)
- `recomputeEdgeBundling()` method for background computation
- Bundled edges render as connected quadratic Bézier curves through control points
- ⌘B toggle with toolbar button

**Label collision avoidance:**
- 6 candidate positions: below-center, below-right, below-left, above-center, right, left
- For each label, try positions in priority order; select one with least overlap
- Runs per-frame during Canvas draw (lightweight — only checks visible labels)

### Phase 8: Visual Polish + Accessibility

**Ghost marching ants:**
- `ghostAnimationPhase: CGFloat` state driven by timer task (increments 1pt per 30ms)
- Ghost node strokes use animated `dashPhase` for marching ants effect
- Reduce Motion fallback: static double-dash pattern (4, 2, 2, 4)

**Role glyphs:**
- At Close-up zoom (>2.0×), SF Symbol glyph drawn at 10 o'clock position on each node
- Role → glyph mapping: Client → `person.crop.circle.badge.checkmark`, Agent → `person.crop.circle.badge.fill`, Lead → `person.crop.circle.badge.plus`, etc.
- `roleGlyphName(for:)` helper function

**Intelligence overlays (4 modes):**
- `OverlayType` enum: referralHub, communicationFlow, recruitingHealth, coverageGap
- `activeOverlay: OverlayType?` on coordinator; toggle via toolbar menu
- **Referral Hub Detection**: Brandes betweenness centrality algorithm (`computeBetweennessCentrality()`), top hubs get pulsing glow with centrality label
- **Communication Flow**: Ring size proportional to evidence count for each person
- **Recruiting Tree Health**: Stage-colored dots (green=producing, blue=licensed, yellow=studying, gray=prospect)
- **Coverage Gap**: Indicator on family clusters with incomplete coverage

**High contrast support:**
- `@Environment(\.colorSchemeContrast)` detection
- +1pt node strokes, +0.5pt edge thickness, medium→semibold label font weight

**Reduce transparency support:**
- `@Environment(\.accessibilityReduceTransparency)` detection
- Ghost fills 15%→30%, family cluster fills 6%→15%, label pills fully opaque

**Reduce motion comprehensive gate:**
- All `withAnimation` calls gated on `!reduceMotion`
- Static positions and instant transitions when enabled
- No ripple, no marching ants, no spring physics

**Drag grid pattern:**
- Dot grid at 20pt spacing, 0.5pt radius, 8% foreground opacity
- Appears during any node drag, fades on release

**Spring animation presets:**
- `Spring.responsive` (0.3 response, 0.7 damping) — selection glow bloom
- `Spring.interactive` (0.5 response, 0.65 damping) — pull/release
- `Spring.structural` (0.6 response, 0.8 damping) — layout transitions

### Technical: Type-Checker Timeout Fix
- `graphCanvas` property grew too complex for Swift type checker (~120 lines of chained modifiers)
- Decomposed into: `canvasWithGestures()`, `handleHover()`, `canvasContextMenu`, `accessibilityNodes`, `drawCanvas()`, `handleDragChanged()`, `handleDragEnded()`
- Each extraction reduced modifier chain complexity until type checker could handle it

### Files Modified
- `SAM/Models/DTOs/GraphEdge.swift` — Added `roleRelationship` edge type
- `SAM/Models/DTOs/GraphInputDTOs.swift` — Added `RoleRelationshipLink` DTO
- `SAM/Services/GraphBuilderService.swift` — Role relationship edge generation, `bundleEdges()` method
- `SAM/Coordinators/RelationshipGraphCoordinator.swift` — Role relationship gathering, `expandSelection()`, edge bundling state, intelligence overlay state, `computeBetweennessCentrality()`
- `SAM/Views/Business/RelationshipGraphView.swift` — All rendering, interaction, and accessibility changes (Phases 1–8)
- `SAM/Views/Business/GraphToolbarView.swift` — Role relationship display name, intelligence overlay menu

---

## February 26, 2026 - Remove Household ContextKind — Replace with DeducedRelation (Schema SAM_v27)

### Overview
Removed `.household` from the Context UI and Relationship Graph. Family relationships are now modeled exclusively through `DeducedRelation` (pairwise semantic bonds auto-imported from Apple Contacts). Household contexts still exist in the data layer for backward compatibility but cannot be created in the UI. Meeting briefings now surface family relations between attendees from `DeducedRelation` instead of shared household contexts. Phase AA specs rewritten to use "family cluster" (connected component of deducedFamily edges) instead of "household grouping".

### Schema Changes (SAM_v27)
- Removed `context: SamContext?` property from `ConsentRequirement` (consent belongs on Product + Person, not household)
- Removed `consentRequirements: [ConsentRequirement]` relationship from `SamContext`
- Schema bumped from SAM_v26 to SAM_v27

### Graph Changes
- Removed `EdgeType.household` enum case — family edges are `.deducedFamily` only
- `GraphBuilderService`: household context inputs now produce zero edges (skipped by `default: continue`)
- `RelationshipGraphCoordinator.gatherContextInputs()`: only gathers `.business` contexts
- `RelationshipGraphView.edgeColor()`: removed `.household` green color case
- `GraphToolbarView.EdgeType.displayName`: removed "Household" label

### UI Changes
- `ContextListView`: filter picker and create sheet only offer `.business` (no `.household`); updated empty state text; default kind is `.business`
- `ContextDetailView`: edit picker shows `.household` only if the existing context is already a household (legacy support)
- Preview data updated from `.household` to `.business` in both views

### MeetingPrep Changes
- Added `FamilyRelationInfo` struct (personAName, personBName, relationType)
- Added `familyRelations: [FamilyRelationInfo]` field to `MeetingBriefing`
- Added `findFamilyRelations(among:)` method using `DeducedRelationRepository`
- `findSharedContexts()` now excludes `.household` contexts
- `MeetingPrepSection`: new `familyRelationsSection` displays family relation chips (pink background, figure.2.and.child.holdinghands icon)

### Backup Changes
- Export: `ConsentRequirementBackup.contextID` always set to `nil`
- Import: `context:` parameter removed from `ConsentRequirement` init call
- `ConsentRequirementBackup.contextID: UUID?` kept for backward compat (old backups still decode)

### Test Updates
- `GraphBuilderServiceTests`: household test verifies zero edges; multipleEdgeTypes uses Business; realistic graph converts household contexts to business
- `ContextsRepositoryTests`: all `.household` → `.business`
- `NotesRepositoryTests`: all `.household` → `.business`

### Spec Rewrites (Phase AA)
- `phase-aa-interaction-spec.md`: "Household Grouping Mode" → "Family Clustering Mode"; boundaries from deducedFamily connected components; labels from shared surname
- `phase-aa-relationship-graph.md`: removed `case household` from EdgeType; data dependencies updated for DeducedRelation
- `phase-aa-visual-design.md`: "Household" edge/boundary → "Family (Deduced)"; green → pink

---

## February 26, 2026 - Deduced Relationships + Me Toggle + Awareness Integration (Schema SAM_v26)

### Overview
Three enhancements to the Relationship Graph: (1) Show/Hide "Me" node toggle to optionally display the user's own node and all connections, (2) Deduced household/family relationships imported from Apple Contacts' related names field, displayed as distinct dashed pink edges in the graph with double-click confirmation, (3) Awareness-driven verification flow that creates an outcome navigating directly to the graph in a focused "review mode" showing only deduced relationships.

### New Model

**`DeducedRelation`** (@Model, schema SAM_v26) — `id: UUID`, `personAID: UUID`, `personBID: UUID`, `relationTypeRawValue: String` (spouse/parent/child/sibling/other via `DeducedRelationType` enum), `sourceLabel: String` (original contact relation label), `isConfirmed: Bool`, `createdAt: Date`, `confirmedAt: Date?`. Uses plain UUIDs (not @Relationship) to avoid coupling. `@Transient` computed `relationType` property for type-safe access.

### New Files

**`DeducedRelationRepository.swift`** (Repositories) — `@MainActor @Observable` singleton. Standard configure/fetchAll/fetchUnconfirmed/upsert (dedup by personAID+personBID+relationType in either direction)/confirm/deleteAll. Registered in `SAMApp.configureDataLayer()`.

### Components Modified

**`SAMModels-Supporting.swift`** — Added `DeducedRelationType` enum (spouse/parent/child/sibling/other). Added `.reviewGraph` case to `ActionLane` enum with actionLabel "Review in Graph", actionIcon "circle.grid.cross", displayName "Review Graph".

**`SAMModels.swift`** — Added `DeducedRelation` @Model. Added `.samNavigateToGraph` Notification.Name (userInfo: `["focusMode": String]`).

**`SAMModelContainer.swift`** — Added `DeducedRelation.self` to `SAMSchema.allModels`. Schema bumped from SAM_v25 to SAM_v26.

**`ContactDTO.swift`** — Added `CNContactRelationsKey` to `.detail` KeySet (previously only in `.full`), enabling contact relation import during standard imports.

**`ContactsImportCoordinator.swift`** — Added `deduceRelationships(from:)` step after `bulkUpsert` and re-resolve. Matches contact relation names to existing SamPerson by exact full name or unique given name prefix. Maps CNContact labels (spouse/partner/child/son/daughter/parent/mother/father/sibling/brother/sister) to `DeducedRelationType`. Added `mapRelationLabel()` helper.

**`GraphEdge.swift`** — Added `deducedRelationID: UUID?` and `isConfirmedDeduction: Bool` fields. Added `init()` with default values for backward compatibility. Added `.deducedFamily` case to `EdgeType` enum.

**`GraphInputDTOs.swift`** — Added `DeducedFamilyLink` Sendable DTO (personAID, personBID, relationType, label, isConfirmed, deducedRelationID).

**`GraphBuilderService.swift`** — Added `deducedFamilyLinks: [DeducedFamilyLink]` parameter to `buildGraph()`. Builds `.deducedFamily` edges with weight 0.7, label from sourceLabel, carrying deducedRelationID and isConfirmed status.

**`RelationshipGraphCoordinator.swift`** — Added `showMeNode: Bool` filter state (default false). Added `focusMode: String?` state. Added `DeducedRelationRepository` dependency. `gatherPeopleInputs()` respects `showMeNode` toggle. Added `gatherDeducedFamilyLinks()` data gatherer. Added `confirmDeducedRelation(id:)` (confirms + invalidates cache + rebuilds). Added `activateFocusMode()`/`clearFocusMode()`. `applyFilters()` enhanced with focus mode: when `focusMode == "deducedRelationships"`, restricts to deduced-edge participants + 1-hop neighbors.

**`GraphToolbarView.swift`** — Added "My Connections" toggle in Visibility menu (triggers full `buildGraph()` since Me node inclusion changes data gathering). Added `.deducedFamily` display name "Deduced Family".

**`RelationshipGraphView.swift`** — Deduced edge styling: dashed pink (unconfirmed) / solid pink (confirmed). Edge hit-testing: `hitTestEdge(at:center:)` with `distanceToLineSegment()` (8px threshold). Double-click on unconfirmed deduced edge shows confirmation alert. Edge hover tooltip showing relationship label and confirmation status. Focus mode banner ("Showing deduced relationships — Exit Focus Mode"). Updated `edgeColor(for:)` with `.deducedFamily: .pink.opacity(0.7)`.

**`OutcomeEngine.swift`** — Added `scanDeducedRelationships()` scanner (scanner #10). Creates one batched outcome when unconfirmed deductions exist: "Review N deduced relationship(s)" with `.reviewGraph` ActionLane. `classifyActionLane()` preserves pre-set `.reviewGraph` lane.

**`OutcomeQueueView.swift`** — Added `.reviewGraph` case to `actClosure(for:)`: posts `.samNavigateToGraph` notification with `focusMode: "deducedRelationships"`.

**`AppShellView.swift`** — Added `.samNavigateToGraph` notification listener in both layout branches: sets `sidebarSelection = "graph"` and activates focus mode on coordinator.

**`BackupDocument.swift`** — Added `deducedRelations: [DeducedRelationBackup]` field. Added `DeducedRelationBackup` Codable DTO (21st backup type).

**`BackupCoordinator.swift`** — Full backup/restore support for DeducedRelation: export (fetch + map to DTO), import (Pass 1 insertion), safety backup. Schema version updated to SAM_v26.

### Key Design Decisions
- **Plain UUID references over @Relationship**: DeducedRelation uses personAID/personBID UUIDs rather than SwiftData relationships to keep it lightweight and avoid coupling
- **Edge hit-testing**: Perpendicular distance to line segment with 8px threshold, checked before node hit-testing on double-click
- **Focus mode**: Additive filtering on top of existing role/edge/orphan filters; shows deduced-edge participants + 1-hop neighbors for context
- **Me toggle triggers rebuild**: Since Me node inclusion changes data gathering (not just filtering), the toggle calls `buildGraph()` rather than `applyFilters()`
- **Batched outcome**: One outcome for all unconfirmed deductions rather than per-relationship, to avoid spamming the Awareness queue

---

## February 26, 2026 - Phase AA: Relationship Graph — AA.1–AA.7 (No Schema Change)

### Overview
Visual relationship network intelligence. Canvas-based interactive graph showing people as nodes (colored by role, sized by production, stroked by health) and connections as edges (7 types: household, business, referral, recruiting tree, co-attendee, communication, mentioned together). Force-directed layout with Barnes-Hut optimization for large graphs. Full pan/zoom/select/drag interactivity, hover tooltips, context menus, keyboard shortcuts, and search-to-zoom.

### AA.1: Core Graph Engine

**`GraphNode.swift`** (DTO) — Sendable struct with id, displayName, roleBadges, primaryRole, pipelineStage, relationshipHealth (HealthLevel enum: healthy/cooling/atRisk/cold/unknown), productionValue, isGhost, isOrphaned, topOutcome, photoThumbnail, mutable position/velocity/isPinned. Static `rolePriority` mapping for primary role selection.

**`GraphEdge.swift`** (DTO) — Sendable struct with id, sourceID, targetID, edgeType (EdgeType enum: 7 cases), weight (0–1), label, isReciprocal, communicationDirection. `EdgeType.displayName` extension for UI labels.

**`GraphBuilderService.swift`** (Service/actor) — Assembles nodes/edges from 8 input DTO types (PersonGraphInput, ContextGraphInput, ReferralLink, RecruitLink, CoAttendancePair, CommLink, MentionPair, GhostMention). Force-directed layout: deterministic initial positioning (context clusters + golden spiral), repulsion/attraction/gravity/collision forces, simulated annealing (300 iterations), Barnes-Hut quadtree for n>500. Input DTOs defined in GraphBuilderService.swift.

**`RelationshipGraphCoordinator.swift`** (Coordinator) — `@MainActor @Observable` singleton. Gathers data from 9 dependencies (PeopleRepository, ContextsRepository, EvidenceRepository, NotesRepository, PipelineRepository, ProductionRepository, OutcomeRepository, MeetingPrepCoordinator, GraphBuilderService). Observable state: graphStatus (idle/computing/ready/failed), nodes, edges, selectedNodeID, hoveredNodeID, progress. Filter state: activeRoleFilters, activeEdgeTypeFilters, showOrphanedNodes, showGhostNodes, minimumEdgeWeight. `applyFilters()` derives filteredNodes/filteredEdges from allNodes/allEdges. Health mapping: DecayRisk → HealthLevel.

### AA.2: Basic Graph Renderer

**`RelationshipGraphView.swift`** — SwiftUI Canvas renderer with 4 drawing layers (edges → nodes → labels → selection ring). Coordinate transforms between graph space and screen space. MagnificationGesture for zoom (0.1×–5.0×), DragGesture for pan, onTapGesture for selection. Zoom-dependent detail levels: <0.3× dots only, 0.3–0.8× large labels, >0.8× all labels + photos, >2.0× ghost borders. Node sizing by productionValue (10–30pt radius). `fitToView()` auto-centers and auto-scales to show all nodes.

**`GraphToolbarView.swift`** — ToolbarContent with zoom in/out/fit-to-view buttons, status text, rebuild button.

**`AppShellView.swift`** — Added "Relationship Map" (circle.grid.cross) NavigationLink under Business section. Routed to RelationshipGraphView in detail switch.

### AA.3: Interaction & Navigation

**`GraphTooltipView.swift`** — Hover popover showing person name, role badges (color-coded), health status dot, connection count, top outcome. Material background with shadow.

**`RelationshipGraphView.swift`** enhanced — Hover tooltips via onContinuousHover + hit testing. Right-click context menu (View Person, Focus in Graph, Unpin Node). Double-click navigation to PersonDetailView via .samNavigateToPerson notification. Node dragging (drag on node repositions + pins; drag on empty space pans). Search-to-zoom (⌘F floating field, finds by name, zooms to match). Keyboard shortcuts: Esc deselect, ⌘1 show all, ⌘2 clients only, ⌘3 recruiting tree, ⌘4 referral network. Pinned node indicator (pin.fill icon). Body refactored into sub-computed-properties to avoid type-checker timeout.

**`PersonDetailView.swift`** — Added "View in Graph" toolbar button (circle.grid.cross). Sets coordinator.selectedNodeID, centers viewport on person's node, switches sidebar to graph.

### AA.4: Filters & Dashboard Integration

**`GraphToolbarView.swift`** enhanced — Role filter menu (8 roles, multi-select, color-coded icons, active badge count). Edge type filter menu (7 types, multi-select with display names). Visibility toggles (ghost nodes, orphaned nodes). Scale percentage display.

**`GraphMiniPreviewView.swift`** — Non-interactive Canvas thumbnail showing all nodes (role-colored) and edges (thin lines). Auto-fits to bounds. Click navigates to full graph. Shows node count and loading states.

**`BusinessDashboardView.swift`** — Added GraphMiniPreviewView at bottom of dashboard (visible across all tabs).

### Key Design Decisions (Phase AA)
- **Sidebar entry, not tab**: Graph is a separate sidebar item under Business (not a tab in BusinessDashboardView) because the full-screen Canvas doesn't belong in a ScrollView
- **Canvas over AppKit**: Pure SwiftUI Canvas for rendering — no NSView subclassing needed
- **Filter architecture**: Full graph stored as allNodes/allEdges; filtered view derived reactively via applyFilters(). No rebuild needed for filter changes
- **Ghost nodes**: Created for unmatched name mentions in notes; visual distinction via dashed borders and muted color
- **Force-directed determinism**: Initial positions are deterministic (context clusters at angles, unassigned in spiral), enabling reproducible layouts
- **Layout caching**: Node positions cached in UserDefaults with 24h TTL; >50% match required to restore
- **Auto-refresh**: Notification-driven incremental updates (samPersonDidChange) and full rebuilds (samUndoDidRestore)
- **No schema change**: Phase AA is purely view/coordinator/service layer; all data comes from existing models

### Info.plist
- Added `LSMultipleInstancesProhibited = true` to prevent duplicate app instances

---

## February 26, 2026 - Export/Import (Backup/Restore)

### Overview
Full backup and restore capability for SAM. Exports 20 core model types plus portable UserDefaults preferences to a `.sambackup` JSON file; imports by replacing all existing data with dependency-ordered insertion and UUID-based relationship wiring. No new SwiftData models or schema change.

### New Files

**`SAMBackupUTType.swift`** (Utility) — `UTType.samBackup` extension declaring `com.matthewsessions.SAM.backup` conforming to `public.json`.

**`BackupDocument.swift`** (Models) — Top-level `BackupDocument` Codable struct containing `BackupMetadata` (export date, schema version, format version, counts), `[String: AnyCodableValue]` preferences dict, and 20 flat DTO arrays. `AnyCodableValue` enum wraps Bool/Int/Double/String for heterogeneous UserDefaults serialization with type discriminator encoding. `ImportPreview` struct for pre-import validation. 20 backup DTOs mirror all core @Model classes with relationships expressed as UUID references and image data as base64 strings.

**`BackupCoordinator.swift`** (Coordinators) — `@MainActor @Observable` singleton. `BackupStatus` enum (idle/exporting/importing/validating/success/failed). Export: fetches all 20 model types via fresh `ModelContext`, maps to DTOs, gathers included UserDefaults keys (38 portable preference keys, excludes machine-specific), encodes JSON with `.sortedKeys` + `.iso8601`. Import: creates safety backup to temp dir, severs all MTM relationships first (avoids CoreData batch-delete constraint failures on nullify inverses), deletes all instances individually via generic `deleteAll<T>()` helper, inserts in 4 dependency-ordered passes (independent → people/context-dependent → cross-referencing → self-references), applies preferences. Security-scoped resource access for sandboxed file reads.

### Components Modified

**`SettingsView.swift`** — Added "Data Backup" section to GeneralSettingsView between Dictation and Automatic Reset. Export button triggers `NSSavePanel`, import button triggers `.fileImporter` with destructive confirmation alert showing preview counts. Status display with ProgressView/checkmark/error states.

**`Info.plist`** — Added `UTExportedTypeDeclarations` for `com.matthewsessions.SAM.backup` with `.sambackup` extension.

### Key Design Decisions

- **Export scope**: 20 of 26 model types — excludes regenerable data (SamInsight, SamOutcome, SamDailyBriefing, StrategicDigest, SamUndoEntry, UnknownSender)
- **Import mode**: Full replace (delete all → insert) with safety backup
- **MTM deletion fix**: `context.delete(model:)` batch delete fails on many-to-many nullify inverses; solution is to sever MTM relationships first via `.removeAll()`, then delete instances individually
- **Sandbox**: `.fileImporter` returns security-scoped URLs; must call `startAccessingSecurityScopedResource()` before reading
- **Onboarding**: Not auto-reset after import (same-machine restore is the common case); success message directs user to Reset Onboarding in Settings if needed

---

## February 26, 2026 - Advanced Search

### Overview
Unified search across people, contexts, evidence items, notes, and outcomes. Sidebar entry in Intelligence section. Case-insensitive text matching across display names, email, content, titles, and snippets.

### New Files

**`SearchCoordinator.swift`** (Coordinators) — Orchestrates search across PeopleRepository, ContextsRepository, EvidenceRepository, NotesRepository, OutcomeRepository. Returns mixed-type results.

**`SearchView.swift`** (Views/Search) — Search field with results list, grouped by entity type.

**`SearchResultRow.swift`** (Views/Search) — Row view for mixed-type search results with appropriate icons and metadata.

### Components Modified

**`AppShellView.swift`** — Added "Search" NavigationLink in Intelligence sidebar section, routing to SearchView.

**`EvidenceRepository.swift`** — Added `search(query:)` method for case-insensitive title/snippet matching.

**`OutcomeRepository.swift`** — Added `search(query:)` method for case-insensitive title/rationale/nextStep matching.

---

## February 26, 2026 - Phase Z: Compliance Awareness (Schema SAM_v25)

### Overview
Phase Z adds deterministic keyword-based compliance scanning across all draft surfaces (ComposeWindowView, OutcomeEngine, ContentDraftSheet) plus an audit trail of AI-generated drafts for regulatory record-keeping. SAM users are independent financial strategists in a regulated environment — this phase helps them avoid compliance-sensitive language in communications. All scanning is advisory only; it never blocks sending.

### New Models

**`ComplianceAuditEntry`** (@Model) — Audit trail for AI-generated drafts: `id: UUID`, `channelRawValue: String`, `recipientName: String?`, `recipientAddress: String?`, `originalDraft: String`, `finalDraft: String?`, `wasModified: Bool`, `complianceFlagsJSON: String?`, `outcomeID: UUID?`, `createdAt: Date`, `sentAt: Date?`.

### New Components

**`ComplianceScanner.swift`** (Utility) — Pure-computation stateless keyword matcher. `ComplianceCategory` enum (6 categories: guarantees, returns, promises, comparativeClaims, suitability, specificAdvice) each with displayName, icon, color. `ComplianceFlag` struct (id, category, matchedPhrase, suggestion). Static `scan(_:enabledCategories:customKeywords:)` and `scanWithSettings(_:)` convenience. Supports literal phrase matching and regex patterns (e.g., `earn \d+%`).

**`ComplianceAuditRepository.swift`** (@MainActor @Observable singleton) — `logDraft(channel:recipientName:recipientAddress:originalDraft:complianceFlags:outcomeID:)`, `markSent(entryID:finalDraft:)`, `fetchRecent(limit:)`, `count()`, `pruneExpired(retentionDays:)`, `clearAll()`.

**`ComplianceSettingsContent.swift`** (SwiftUI) — Master toggle, 6 per-category toggles with @AppStorage, custom keywords TextEditor, audit retention picker (30/60/90/180 days), entry count, clear button with confirmation alert. Embedded in SettingsView AI tab as Compliance DisclosureGroup.

### Components Modified

**`ComposeWindowView.swift`** — Added expandable compliance banner between TextEditor and context line. Live scanning via `.onChange(of: draftBody)`. Audit logging on `.task` for AI-generated drafts. `markSent()` call in `completeAndDismiss()`.

**`OutcomeEngine.swift`** — After `generateDraftMessage()` sets `outcome.draftMessageText`, scans draft and logs to ComplianceAuditRepository.

**`OutcomeCardView.swift`** — Added `draftComplianceFlags` computed property. Orange `exclamationmark.triangle.fill` badge when flags found.

**`ContentDraftSheet.swift`** — Added local scanner via `.onChange(of: draftText)`. Merges LLM compliance flags with local scanner flags. Added audit logging on generate and `markSent()` on "Log as Posted".

**`SettingsView.swift`** — Added Compliance DisclosureGroup with `checkmark.shield` icon in AISettingsView.

**`SAMModelContainer.swift`** — Schema bumped to SAM_v25, added `ComplianceAuditEntry.self` to `SAMSchema.allModels`.

**`SAMApp.swift`** — Added `ComplianceAuditRepository.shared.configure(container:)` in `configureDataLayer()`. Added `pruneExpired(retentionDays:)` call on launch.

### Also in this session

**PeopleListView improvements** — Switched from repository-based fetching to `@Query` for reactive updates. Added sort options (first name, last name, email, relationship health). Added multi-select role filtering with leading checkmark icons. Health bar (vertical 3px bar between thumbnail and name, hidden when grey/insufficient data). Role badge icons after name. Filter summary row. Health sort scoring (no-data = -1 bottom, healthy = 1+, at-risk = 3-5+).

**PersonDetailView improvements** — "Add a role" placeholder when no roles assigned. Auto-assign Prospect recruiting stage when Agent role added (removed Start Tracking button). Clickable recruiting pipeline stage dots with regression confirmation alert (removed Advance and Log Contact buttons). Removed duplicate stage info row below dots.

---

## February 26, 2026 - Phase W: Content Assist & Social Media Coaching (Schema SAM_v23)

### Overview
Phase W builds a complete content coaching flow for social media posting: topic suggestions surfaced as coaching outcomes, AI-generated platform-aware drafts with compliance guardrails, posting cadence tracking with streak reinforcement, and briefing integration. Research shows consistent educational content is the #1 digital growth lever for independent financial agents — this phase helps the user create and maintain a posting habit.

### New Models

**`ContentPost`** (@Model) — Lightweight record tracking posted social media content: `id: UUID`, `platformRawValue: String` (+ `@Transient platform: ContentPlatform`), `topic: String`, `postedAt: Date`, `sourceOutcomeID: UUID?`, `createdAt: Date`. Uses UUID reference (not @Relationship) to source outcome.

**`ContentPlatform`** (enum) — `.linkedin`, `.facebook`, `.instagram`, `.other` with `rawValue` storage, `color: Color`, `icon: String` SF Symbol helpers.

**`ContentDraft`** (DTO, Sendable) — `draftText: String`, `complianceFlags: [String]`. Paired with `LLMContentDraft` for JSON parsing from AI responses.

### Model Changes

**`OutcomeKind`** — Added `.contentCreation` case with display name "Content", theme color `.mint`, icon `text.badge.star`, action label "Draft".

### New Components

**`ContentPostRepository`** (@MainActor @Observable singleton) — `logPost(platform:topic:sourceOutcomeID:)`, `fetchRecent(days:)`, `lastPost(platform:)`, `daysSinceLastPost(platform:)`, `postCountByPlatform(days:)`, `weeklyPostingStreak()`, `delete(id:)`.

**`ContentDraftSheet`** (SwiftUI) — Sheet for generating AI-powered social media drafts: platform picker (segmented LinkedIn/Facebook/Instagram), "Generate Draft" button, draft TextEditor (read-only with Edit toggle), compliance flags as orange warning capsules, "Copy to Clipboard" via NSPasteboard, "Log as Posted" → logs to ContentPostRepository + marks outcome completed, "Regenerate" button.

**`ContentCadenceSection`** (SwiftUI) — Review & Analytics section: platform cadence cards (icon + name + days since last post + monthly count, color-coded green/orange/red), posting streak with flame icon, inline "Log a Post" row (platform picker + topic field + button).

### Components Modified

**`OutcomeEngine.swift`** — Two new scanner methods: `scanContentSuggestions()` reads cached StrategicCoordinator digest for ContentTopic data (falls back to direct ContentAdvisorService call), maps top 3 to `.contentCreation` outcomes with JSON-encoded topic in `sourceInsightSummary`; `scanContentCadence()` checks LinkedIn (10d) and Facebook (14d) thresholds, creates nudge outcomes. `classifyActionLane()` maps `.contentCreation` → `.deepWork`.

**`ContentAdvisorService.swift`** — Added `generateDraft(topic:keyPoints:platform:tone:complianceNotes:)` with platform-specific guidelines (LinkedIn: 150-250 words professional; Facebook: 100-150 words conversational; Instagram: 50-100 words hook-focused), strict compliance rules (no product names, no return promises, no comparative claims), returns `ContentDraft`.

**`OutcomeQueueView.swift`** — Content creation outcomes intercept `actClosure` before the `actionLane` switch, routing to `ContentDraftSheet`. Added `parseContentTopic(from:)` helper to decode JSON-encoded `ContentTopic` from `sourceInsightSummary`.

**`AwarenessView.swift`** — Added `.contentCadence` to `AwarenessSection` enum, placed in `reviewAnalytics` group after `.streaks`.

**`StreakTrackingSection.swift`** — Added `contentPosting: Int` to `StreakResults`, computed via `ContentPostRepository.shared.weeklyPostingStreak()`. Shows "Weekly Posting" streak card with `text.badge.star` icon.

**`DailyBriefingCoordinator.swift`** — `gatherWeeklyPriorities()` checks LinkedIn (10d) and Facebook (14d) cadence, appends `BriefingAction` with `sourceKind: "content_cadence"` to Monday weekly priorities.

**`CoachingSettingsView.swift`** — Added `contentSuggestionsEnabled` toggle (default true) in Autonomous Actions section with description caption.

**`SAMModelContainer.swift`** — Schema bumped to SAM_v23, added `ContentPost.self` to `SAMSchema.allModels`.

**`SAMApp.swift`** — Added `ContentPostRepository.shared.configure(container:)` in `configureDataLayer()`.

### Files Summary
| File | Action | Description |
|------|--------|-------------|
| `Models/SAMModels-ContentPost.swift` | NEW | ContentPlatform enum + ContentPost @Model |
| `Repositories/ContentPostRepository.swift` | NEW | CRUD, cadence queries, weekly streak |
| `Models/DTOs/ContentDraftDTO.swift` | NEW | ContentDraft + LLMContentDraft DTOs |
| `Views/Content/ContentDraftSheet.swift` | NEW | AI draft generation sheet |
| `Views/Awareness/ContentCadenceSection.swift` | NEW | Cadence tracking section |
| `Models/SAMModels-Supporting.swift` | MODIFY | + .contentCreation OutcomeKind |
| `Views/Shared/OutcomeCardView.swift` | MODIFY | Display extensions for .contentCreation |
| `App/SAMModelContainer.swift` | MODIFY | Schema SAM_v22 → SAM_v23 |
| `App/SAMApp.swift` | MODIFY | Configure ContentPostRepository |
| `Coordinators/OutcomeEngine.swift` | MODIFY | Content scanners + action lane |
| `Services/ContentAdvisorService.swift` | MODIFY | + generateDraft() method |
| `Views/Awareness/OutcomeQueueView.swift` | MODIFY | Wire ContentDraftSheet |
| `Views/Awareness/AwarenessView.swift` | MODIFY | + .contentCadence section |
| `Views/Awareness/StreakTrackingSection.swift` | MODIFY | + posting streak |
| `Coordinators/DailyBriefingCoordinator.swift` | MODIFY | Content cadence in weekly priorities |
| `Views/Settings/CoachingSettingsView.swift` | MODIFY | + contentSuggestionsEnabled toggle |

### Key Design Decisions
- **UUID reference, not @Relationship** — ContentPost uses `sourceOutcomeID: UUID?` to avoid inverse requirements on SamOutcome
- **JSON round-trip for ContentTopic** — Outcome's `sourceInsightSummary` stores full ContentTopic as JSON so the draft sheet can reconstruct topic/keyPoints/tone/complianceNotes without re-fetching
- **Manual post logging** — SAM doesn't access social platforms directly; user confirms posting with "Log as Posted"
- **Compliance-first AI drafts** — System prompt enforces strict financial services compliance rules; compliance flags surface as orange warnings
- **Cadence thresholds** — LinkedIn 10 days, Facebook 14 days; nudge outcomes limited to one per 72h to avoid noise

---

## February 26, 2026 - Role-Aware Velocity Thresholds + Per-Person Cadence Override (Schema SAM_v21)

### Overview
Enhanced Phase U's velocity-aware relationship health with three improvements: (1) per-role velocity thresholds — Client/Applicant relationships trigger decay alerts at lower overdue ratios (1.2–1.3×) than Vendor/External Agent (2.0–4.0×), reflecting differing urgency levels; (2) per-person cadence override — users can set manual contact cadence (Weekly/Biweekly/Monthly/Quarterly) on any person, overriding the computed median-gap cadence; (3) "Referral Partner" role integrated into every role-based threshold system (45-day static threshold, matching Client).

### New Types

**`RoleVelocityConfig`** (struct, `Sendable`) — Per-role velocity thresholds: `ratioModerate` (overdue ratio for moderate risk), `ratioHigh` (for high risk), `predictiveLeadDays` (alert lead time). Static factory `forRole(_:)` maps roles: Client (1.3/2.0/14d), Applicant (1.2/1.8/14d), Lead (1.3/2.0/10d), Agent (1.5/2.5/10d), Referral Partner (1.5/2.5/14d), External Agent (2.0/3.5/21d), Vendor (2.5/4.0/30d).

### Model Changes

**`SamPerson`** — Added `preferredCadenceDays: Int?` (nil = use computed median gap). Additive optional field, lightweight migration.

**`RelationshipHealth`** — Added `effectiveCadenceDays: Int?` (user override or computed, used for all health logic), `predictiveLeadDays: Int` (role-aware alert lead time). `statusColor` now checks `effectiveCadenceDays` instead of `cadenceDays`.

### Components Modified

**`MeetingPrepCoordinator.swift`** — Added `RoleVelocityConfig` struct. `assessDecayRisk()` now uses `RoleVelocityConfig.forRole(role)` instead of hard-coded 1.5/2.5 ratios. `computeHealth()` applies `preferredCadenceDays` override before computing overdue ratio and predicted overdue. `staticRoleThreshold()` and `colorThresholds()` both include "Referral Partner" (45d, green:14/yellow:30/orange:45).

**`OutcomeEngine.swift`** — `scanRelationshipHealth()` uses `health.predictiveLeadDays` instead of hard-coded 14. `roleImportanceScore()` adds "Referral Partner" at 0.5. `roleThreshold()` adds "Referral Partner" at 45d.

**`InsightGenerator.swift`** — `RoleThresholds.forRole()` adds "Referral Partner" (45d, no urgency boost).

**`DailyBriefingCoordinator.swift`** — Predictive follow-ups use `health.predictiveLeadDays / 2` instead of hard-coded 7. Both threshold switch blocks add "Referral Partner" at 45d.

**`EngagementVelocitySection.swift`** — Overdue filter uses `health.decayRisk >= .moderate` instead of `ratio >= 1.5` (already role-aware via `assessDecayRisk`). Uses `effectiveCadenceDays` for display.

**`PersonDetailView.swift`** — New `cadencePreferenceView` below channel preference picker: Automatic/Weekly/Every 2 weeks/Monthly/Quarterly menu. Shows "(computed: ~Xd)" hint when set to Automatic with sufficient data.

**`WhoToReachOutIntent.swift`** — `roleThreshold()` adds "Referral Partner" at 45d.

**`RoleFilter.swift`** — Added `.referralPartner` case with display representation "Referral Partner" and badge mapping.

**`SAMModelContainer.swift`** — Schema bumped to `SAM_v21`.

### Files Modified
| File | Action | Description |
|------|--------|-------------|
| `Coordinators/MeetingPrepCoordinator.swift` | MODIFY | RoleVelocityConfig, role-aware assessDecayRisk, cadence override in computeHealth, referral partner thresholds |
| `Models/SAMModels.swift` | MODIFY | + SamPerson.preferredCadenceDays: Int? |
| `App/SAMModelContainer.swift` | MODIFY | Schema SAM_v20 → SAM_v21 |
| `Views/People/PersonDetailView.swift` | MODIFY | Cadence picker UI |
| `Coordinators/OutcomeEngine.swift` | MODIFY | Role-aware predictive lead, referral partner in role switches |
| `Coordinators/InsightGenerator.swift` | MODIFY | Referral partner in RoleThresholds |
| `Coordinators/DailyBriefingCoordinator.swift` | MODIFY | Role-aware predictive lead, referral partner in threshold switches |
| `Views/Awareness/EngagementVelocitySection.swift` | MODIFY | decayRisk-based filter, effectiveCadenceDays |
| `Intents/WhoToReachOutIntent.swift` | MODIFY | Referral partner threshold |
| `Intents/RoleFilter.swift` | MODIFY | + .referralPartner case |

### Architecture Decisions
- **Role-scaled velocity**: Vendors at 2× cadence overdue are far less concerning than Applicants at 2× — thresholds scale accordingly
- **Cadence override stored on model**: `preferredCadenceDays` on `SamPerson` rather than a separate settings table — simpler and co-located with the person
- **Effective cadence pattern**: `effectiveCadenceDays` is always used for health logic; raw `cadenceDays` preserved for "computed cadence" display hint
- **Referral Partner = Client-tier cadence**: 45-day static threshold with moderate velocity sensitivity (1.5×/2.5×) — valuable relationships that need regular but not aggressive contact

---

## February 26, 2026 - Phase U: Relationship Decay Prediction (No Schema Change)

### Overview
Upgraded SAM's relationship health evaluation from static threshold-based scoring to velocity-aware predictive decay. All health systems now use cadence-relative scoring (median gap between interactions), quality-weighted interactions (meetings count more than texts), velocity trend detection (are gaps growing or shrinking?), and predictive overdue estimation. This catches cooling relationships 1–2 weeks before static thresholds fire. No schema migration — all computation uses existing `SamEvidenceItem` linked relationships.

### New Types

**`VelocityTrend`** (enum) — Gap acceleration direction: `.accelerating` (gaps shrinking), `.steady`, `.decelerating` (gaps growing — decay signal), `.noData`.

**`DecayRisk`** (enum, `Comparable`) — Overall risk assessment combining overdue ratio + velocity trend: `.none`, `.low`, `.moderate`, `.high`, `.critical`. Used to color-code health indicators and trigger predictive alerts.

### Components Modified

**`SAMModels-Supporting.swift`** — Added `EvidenceSource` extension with `qualityWeight: Double` (calendar=3.0, phoneCall/faceTime=2.5, mail=1.5, iMessage=1.0, note=0.5, contacts=0.0, manual=1.0) and `isInteraction: Bool` (false for contacts and notes).

**`MeetingPrepCoordinator.swift`** — Major changes:
- Added `VelocityTrend` and `DecayRisk` enums near `ContactTrend`
- Extended `RelationshipHealth` with 6 new fields: `cadenceDays` (median gap), `overdueRatio` (currentGap/cadence), `velocityTrend`, `qualityScore30` (quality-weighted 30-day score), `predictedOverdueDays`, `decayRisk`
- `statusColor` now uses decay risk when velocity data is available; falls back to static role-based thresholds when <3 interactions
- Rewrote `computeHealth(for:)` to use `person.linkedEvidence` directly (no more `evidenceRepository.fetchAll()` + filter), with full velocity computation
- Added private helpers: `computeVelocityTrend(gaps:)` (split gaps into halves, compare medians — >1.3× ratio = decelerating), `computePredictedOverdue(cadenceDays:currentGapDays:velocityTrend:)` (extrapolate days until 2.0× ratio), `assessDecayRisk(overdueRatio:velocityTrend:daysSince:role:)` (combine overdue ratio + velocity + static threshold into DecayRisk), `staticRoleThreshold(for:)` (matching OutcomeEngine/InsightGenerator thresholds)

**`PersonDetailView.swift`** — Enhanced `RelationshipHealthView`:
- Velocity trend arrows replace simple trend when cadence data available (accelerating=green up-right, steady=gray right, decelerating=orange down-right)
- New row: cadence chip ("~every 12 days"), overdue ratio chip ("1.8×" in orange/red), quality score chip ("Q: 8.5")
- Decay risk badge (capsule): "Moderate Risk" / "High Risk" / "Critical" shown only when risk >= moderate
- Predicted overdue caption: "Predicted overdue in ~5 days"
- Existing frequency chips (30d/60d/90d) preserved

**`EngagementVelocitySection.swift`** — Replaced inline `computeOverdue()` with `MeetingPrepCoordinator.shared.computeHealth(for:)`. Added `predictedPeople` computed property for people not yet overdue but with `decayRisk >= .moderate`. UI shows overdue entries as before, plus new "Predicted" subsection below. `OverdueEntry` struct now includes `decayRisk` and `predictedOverdueDays` fields.

**`PeopleListView.swift`** — Added 6pt health status dot in `PersonRowView` trailing HStack, before role badge icons. Uses `MeetingPrepCoordinator.shared.computeHealth(for:).statusColor`. Hidden for `person.isMe` and people with no linked evidence.

**`OutcomeEngine.swift`** — `scanRelationshipHealth()` now generates two types of outreach outcomes:
1. Static threshold (existing): priority 0.7 when days >= role threshold
2. Predictive (new): priority 0.4 when `decayRisk >= .moderate` AND `predictedOverdueDays <= 14`, even if static threshold hasn't fired. Rationale includes "Engagement declining — predicted overdue in X days". Skips predictive if already past static threshold.

**`InsightGenerator.swift`** — `generateRelationshipInsights()` now generates predictive decay insights in addition to static threshold insights. Predictive insight created when: `velocityTrend == .decelerating` AND `overdueRatio >= 1.0` AND `decayRisk >= .moderate`. Title: "Engagement declining with [Name]". Body includes cadence, current gap, predicted overdue. Priority: `.medium`. Skips if static-threshold insight already exists for same person.

**`DailyBriefingCoordinator.swift`** — `gatherFollowUps()` now includes predictive entries for people with `decayRisk >= .moderate` and `predictedOverdueDays <= 7`. Reason: "Engagement declining — reach out before it goes cold". Interleaved with static entries, still capped at 5 total sorted by days since interaction.

### Files Modified
| File | Action | Description |
|------|--------|-------------|
| `Models/SAMModels-Supporting.swift` | MODIFY | `qualityWeight` + `isInteraction` on EvidenceSource |
| `Coordinators/MeetingPrepCoordinator.swift` | MODIFY | VelocityTrend, DecayRisk, extended RelationshipHealth, rewritten computeHealth() |
| `Views/People/PersonDetailView.swift` | MODIFY | Enhanced RelationshipHealthView with velocity fields |
| `Views/Awareness/EngagementVelocitySection.swift` | MODIFY | Centralized health + predictive subsection |
| `Views/People/PeopleListView.swift` | MODIFY | 6pt health dot on PersonRowView |
| `Coordinators/OutcomeEngine.swift` | MODIFY | Predictive outreach outcomes |
| `Coordinators/InsightGenerator.swift` | MODIFY | Predictive decay insights |
| `Coordinators/DailyBriefingCoordinator.swift` | MODIFY | Predictive follow-ups in briefing |

### Architecture Decisions
- **No schema change**: All velocity computation derives from existing `person.linkedEvidence` relationship — no new persisted fields needed
- **Centralized computation**: `computeHealth(for:)` is the single source of truth; `EngagementVelocitySection` no longer duplicates gap calculation
- **Direct relationship traversal**: Switched from `evidenceRepository.fetchAll()` + filter to `person.linkedEvidence` for better performance
- **Graceful degradation**: Velocity features require ≥3 interactions; below that, falls back to static threshold logic
- **Conservative predictions**: Only surfaces predictive alerts when gap is already ≥80% of cadence AND decelerating; avoids false positives

---

## February 26, 2026 - Phase T: Meeting Lifecycle Automation (No Schema Change)

### Overview
Connected SAM's existing meeting infrastructure into a coherent lifecycle: enriched pre-meeting attendee profiles with interaction history, pending actions, life events, pipeline stage, and product holdings; AI-generated talking points per meeting; auto-expanding briefings within 15 minutes of start; structured post-meeting capture sheet (replacing plain-text templates); auto-created outcomes from note analysis action items; enhanced meeting quality scoring with follow-up detection; and weekly meeting quality stats in Monday briefings.

### Components Modified

**`MeetingPrepCoordinator`** — Extended `AttendeeProfile` with 5 new fields: `lastInteractions` (last 3 interactions from evidence), `pendingActionItems` (from note action items), `recentLifeEvents` (last 30 days from notes), `pipelineStage` (from role badges), `productHoldings` (from ProductionRepository). Added `talkingPoints: [String]` to `MeetingBriefing`. New `generateTalkingPoints()` method calls AIService with attendee context and parses JSON array response. `buildBriefings()` is now async.

**`MeetingPrepSection`** — `BriefingCard` auto-expands when meeting starts within 15 minutes (computed in `init`). New `talkingPointsSection` shows AI-generated talking points with lightbulb icons. Expanded attendee section now shows per-attendee interaction history, pending actions, life events, and product holdings inline.

**`PostMeetingCaptureView`** (NEW) — Structured sheet with 4 sections: Discussion (TextEditor), Action Items (dynamic list of text fields with + button), Follow-Up (TextEditor), Life Events (TextEditor). Per-section dictation buttons using DictationService pattern. Saves combined content as a note linked to attendees, triggers background NoteAnalysisCoordinator analysis. `PostMeetingPayload` struct for notification-driven presentation.

**`DailyBriefingCoordinator`** — `createMeetingNoteTemplate()` now posts `.samOpenPostMeetingCapture` notification instead of creating plain-text notes directly. Still creates follow-up outcome. New meeting quality stats in `gatherWeeklyPriorities()`: computes average quality score for past 7 days, adds "Improve meeting documentation" action if below 60.

**`NoteAnalysisCoordinator`** — Added Step 10 after Step 9: `createOutcomesFromAnalysis()`. For each pending action item with a linked person, maps action type to `OutcomeKind`, urgency to deadline, deduplicates via `hasSimilarOutcome()`, creates `SamOutcome` with draft message text. Max 5 outcomes per note.

**`MeetingQualitySection`** — Reweighted scoring: Note(35) + Timely(20) + Action items(15) + Attendees(10) + Follow-up drafted(10) + Follow-up sent(10) = 100. New `checkFollowUpSent()` detects outgoing communication (iMessage/email/phone/FaceTime) to attendees within 48h of meeting end. Added `followUpSent` field to `ScoredMeeting`. "No follow-up" tag in missing list.

**`SAMModels`** — Added `.samOpenPostMeetingCapture` notification name.

**`AppShellView`** — Listens for `.samOpenPostMeetingCapture` notification. Stores `@State postMeetingPayload: PostMeetingPayload?`. Presents `PostMeetingCaptureView` as `.sheet(item:)` in both two-column and three-column layouts.

### Files
| File | Status |
|------|--------|
| `Coordinators/MeetingPrepCoordinator.swift` | MODIFIED — Enhanced AttendeeProfile, talking points, async buildBriefings |
| `Views/Awareness/MeetingPrepSection.swift` | MODIFIED — Auto-expand, talking points section, enriched attendee display |
| `Views/Awareness/PostMeetingCaptureView.swift` | NEW — Structured 4-section capture sheet with dictation |
| `Coordinators/DailyBriefingCoordinator.swift` | MODIFIED — Notification-based capture, weekly meeting stats |
| `Coordinators/NoteAnalysisCoordinator.swift` | MODIFIED — Step 10: auto-create outcomes from action items |
| `Views/Awareness/MeetingQualitySection.swift` | MODIFIED — Follow-up detection, reweighted scoring |
| `Models/SAMModels.swift` | MODIFIED — .samOpenPostMeetingCapture notification name |
| `Views/AppShellView.swift` | MODIFIED — Post-meeting capture sheet listener |

### What did NOT change
- `SamNote` model — no new fields needed
- `SamOutcome` model — existing fields suffice
- `OutcomeEngine` — scanner pattern unchanged
- `InlineNoteCaptureView` — still available for quick notes
- Schema version — stays at SAM_v20

---

## February 25, 2026 - Phase S: Production Tracking (Schema SAM_v20)

### Overview
Added production tracking for policies and products sold per person. Includes a `ProductionRecord` model (product type, status, carrier, premium), `ProductionRepository` with CRUD and metric queries, production metrics in `PipelineTracker`, a Production dashboard tab in BusinessDashboardView, per-person production sections on PersonDetailView for Client/Applicant contacts, and cross-sell intelligence via coverage gap detection in `OutcomeEngine`.

### Data Models
- **`ProductionRecord`** `@Model` — id (.unique), person (@Relationship, nullify), productTypeRawValue, statusRawValue, carrierName, annualPremium, submittedDate, resolvedDate?, policyNumber?, notes?, createdAt, updatedAt. @Transient computed `productType` and `status`. Inverse on `SamPerson.productionRecords`.
- **`WFGProductType`** enum (7 cases) — IUL, Term Life, Whole Life, Annuity, Retirement Plan, Education Plan, Other. Each has `displayName`, `icon`, `color`.
- **`ProductionStatus`** enum (4 cases) — Submitted, Approved, Declined, Issued. Each has `displayName`, `icon`, `color`, `next` (happy-path progression).

### Components
- **`ProductionRepository`** — Standard `@MainActor @Observable` singleton. CRUD: `createRecord()` (cross-context safe person resolution), `updateRecord()`, `advanceStatus()` (Submitted→Approved→Issued with auto resolvedDate), `deleteRecord()`. Fetch: `fetchRecords(forPerson:)`, `fetchAllRecords()`, `fetchRecords(since:)`. Metrics: `countByStatus()`, `countByProductType()`, `totalPremiumByStatus()`, `pendingWithAge()` (aging report sorted oldest first).
- **`PipelineTracker`** — Extended with production observable state: `productionByStatus`, `productionByType`, `productionTotalPremium`, `productionPendingCount`, `productionPendingAging`, `productionAllRecords`, `productionWindowDays`. New `refreshProduction()` method called from `refresh()`. New value types: `ProductionStatusSummary`, `ProductionTypeSummary`, `PendingAgingItem`, `ProductionRecordItem`.
- **`OutcomeEngine`** — New `scanCoverageGaps(people:)` scanner. For each Client with production records, checks against complete coverage baseline (life + retirement + education). Generates `.growth` outcomes with dedup for missing coverage categories. Called from `generateOutcomes()` alongside other scanners.

### Views
- **`ProductionDashboardView`** — Status overview (4 cards: Submitted/Approved/Declined/Issued with counts and premiums), product mix (list with icons, counts, premiums), window picker (30/60/90/180 days), pending aging (sorted by age, click-through via `.samNavigateToPerson`), all records list (full production record listing with status badges and person click-through).
- **`ProductionEntryForm`** — Sheet form: product type picker, carrier text field, annual premium currency field, submitted date picker, notes. Save/Cancel with validation.
- **`BusinessDashboardView`** — Updated from 2-tab to 3-tab segmented picker: Client Pipeline, Recruiting, Production.
- **`PersonDetailView`** — New production section (shown for Client/Applicant badge holders): record count + total premium summary, list of recent 5 records with product type icon, carrier, premium, status badge (tap to advance status), "Add Production" button opening `ProductionEntryForm` sheet.

### App Launch (SAMApp)
- `ProductionRepository.shared.configure(container:)` in `configureDataLayer()`

### Schema
- SAM_v19 → **SAM_v20** (lightweight migration, additive — 1 new model)

### Files
| File | Status |
|------|--------|
| `Models/SAMModels-Production.swift` | NEW — ProductionRecord, WFGProductType, ProductionStatus |
| `Models/SAMModels.swift` | MODIFIED — productionRecords inverse relationship on SamPerson |
| `Repositories/ProductionRepository.swift` | NEW — Full CRUD + metric queries |
| `Coordinators/PipelineTracker.swift` | MODIFIED — Production metrics + refreshProduction() + 4 value types |
| `Coordinators/OutcomeEngine.swift` | MODIFIED — scanCoverageGaps() cross-sell scanner |
| `Views/Business/ProductionDashboardView.swift` | NEW — Production dashboard |
| `Views/Business/ProductionEntryForm.swift` | NEW — Add/edit production record sheet |
| `Views/Business/BusinessDashboardView.swift` | MODIFIED — 3rd tab (Production) |
| `Views/People/PersonDetailView.swift` | MODIFIED — Production section + sheet for Client/Applicant |
| `App/SAMApp.swift` | MODIFIED — ProductionRepository config |
| `App/SAMModelContainer.swift` | MODIFIED — Schema v20, ProductionRecord registered |

### What did NOT change
- Existing pipeline views (Client Pipeline, Recruiting Pipeline) — untouched
- PipelineRepository — production has its own ProductionRepository
- StageTransition model — production records are separate from pipeline transitions
- Undo system — production records use standard CRUD (add undo support if needed later)
- No LLM usage in production tracking — all metrics are deterministic Swift computation
- Cross-sell scanner is deterministic coverage gap detection, not LLM-generated

---

## February 25, 2026 - Phase R: Pipeline Intelligence (Schema SAM_v19)

### Overview
Added immutable audit log of every role badge change (StageTransition), recruiting pipeline state tracking (RecruitingStage with 7 WFG stages), full Business dashboard with client and recruiting pipeline views, and a PipelineTracker coordinator computing all metrics deterministically in Swift (no LLM).

### Data Models
- **`StageTransition`** `@Model` — Immutable audit log entry: person (nullify on delete for historical metrics), fromStage, toStage, transitionDate, pipelineType (client/recruiting), notes. Inverse on `SamPerson.stageTransitions`.
- **`RecruitingStage`** `@Model` — Current recruiting state per person: stage (7-case enum), enteredDate, mentoringLastContact, notes. Repository enforces 1:1. Inverse on `SamPerson.recruitingStages`.
- **`PipelineType`** enum — `.client`, `.recruiting`
- **`RecruitingStageKind`** enum — 7 cases: Prospect → Presented → Signed Up → Studying → Licensed → First Sale → Producing. Each has `order`, `color`, `icon`, `next` properties.

### Components
- **`PipelineRepository`** — Standard `@MainActor @Observable` singleton. CRUD for StageTransition and RecruitingStage. Cross-context safe (re-resolves person in own context). `backfillInitialTransitions()` creates "" → badge transitions for all existing Lead/Applicant/Client/Agent badges on first launch. `advanceRecruitingStage()` updates stage + records transition atomically. `updateMentoringContact()` for cadence tracking.
- **`PipelineTracker`** — `@MainActor @Observable` singleton. All computation in Swift, no LLM. Observable state: `clientFunnel` (Lead/Applicant/Client counts), `clientConversionRates` (Lead→Applicant, Applicant→Client over configurable window), `clientTimeInStage` (avg days), `clientStuckPeople` (30d Lead / 14d Applicant thresholds), `clientVelocity` (transitions/week), `recentClientTransitions` (last 10), `recruitFunnel` (7-stage counts), `recruitLicensingRate` (% Licensed+), `recruitMentoringAlerts` (overdue by stage-specific thresholds: Studying 7d, Licensed 14d, Producing 30d). `configWindowDays` (30/60/90/180) for conversion rate window.

### Views
- **`BusinessDashboardView`** — Container with segmented picker (Client Pipeline / Recruiting Pipeline), toolbar refresh button, triggers `PipelineTracker.refresh()` on appear.
- **`ClientPipelineDashboardView`** — Funnel bars (proportional widths with counts), 2×2 metrics grid (conversion rates, avg days as Lead, velocity), window picker (30/60/90/180d), stuck callouts with click-through via `.samNavigateToPerson`, recent transitions timeline (last 10).
- **`RecruitingPipelineDashboardView`** — 7-stage funnel with stage-specific colors and counts, licensing rate hero metric card, mentoring cadence list with overdue alerts and "Log Contact" buttons, click-through navigation.

### Badge Edit Hook (PersonDetailView)
- When exiting badge edit mode, `recordPipelineTransitions()` records client pipeline transitions for any added/removed Lead/Applicant/Client badges.
- New recruiting stage section shown when person has "Agent" badge: horizontal 7-dot progress indicator, current stage badge, days since mentoring contact, "Log Contact" and "Advance" buttons.

### Sidebar Routing (AppShellView)
- New "Business" sidebar section with "Pipeline" navigation link (chart.bar.horizontal.page icon).
- Routes to `BusinessDashboardView` in the two-column layout branch.

### App Launch (SAMApp)
- `PipelineRepository.shared.configure(container:)` in `configureDataLayer()`
- One-time backfill gated by `pipelineBackfillComplete` UserDefaults key in `triggerImportsForEnabledSources()`

### Schema
- SAM_v18 → **SAM_v19** (lightweight migration, additive only — 2 new models)

### Files
| File | Status |
|------|--------|
| `Models/SAMModels-Pipeline.swift` | NEW — StageTransition, RecruitingStage, PipelineType, RecruitingStageKind |
| `Models/SAMModels.swift` | MODIFIED — stageTransitions + recruitingStages inverse relationships on SamPerson |
| `Repositories/PipelineRepository.swift` | NEW — Full CRUD + backfill |
| `Coordinators/PipelineTracker.swift` | NEW — Metric computation + observable state |
| `Views/Business/BusinessDashboardView.swift` | NEW — Segmented container |
| `Views/Business/ClientPipelineDashboardView.swift` | NEW — Client funnel + metrics |
| `Views/Business/RecruitingPipelineDashboardView.swift` | NEW — Recruiting funnel + mentoring |
| `Views/People/PersonDetailView.swift` | MODIFIED — Badge edit hook + recruiting stage section |
| `Views/AppShellView.swift` | MODIFIED — Business sidebar section |
| `App/SAMApp.swift` | MODIFIED — Repository config + backfill |
| `App/SAMModelContainer.swift` | MODIFIED — Schema v19, 2 new models registered |

### What did NOT change
- Existing `PipelineStageSection` in Awareness stays as compact summary
- `RoleBadgeStyle.swift` unchanged — recruiting stage colors live on `RecruitingStageKind` enum
- No LLM usage — all metrics are deterministic Swift computation
- Undo system not extended — stage transitions are immutable audit logs, not undoable

---

## February 25, 2026 - Import Watermark Optimization

### Overview
All three import coordinators (iMessage, Calls, Email) previously re-scanned their full lookback window on every app launch. While idempotent upserts prevented duplicates, this wasted time re-reading thousands of records and re-running LLM analysis on already-processed threads. Now each source persists a watermark (newest record timestamp) after successful import; subsequent imports only fetch records newer than that watermark. The lookback window is only used for the very first import. Watermarks auto-reset when the user changes lookback days in Settings. Calendar import is excluded — events can be created for any date, so a watermark wouldn't catch backdated entries.

### Changes
- **`CommunicationsImportCoordinator.swift`** — Added `lastMessageWatermark` / `lastCallWatermark` (persisted to UserDefaults). `performImport()` uses per-source watermarks when available, falls back to full lookback. Watermarks updated after each successful bulk upsert. `resetWatermarks()` clears both. `setLookbackDays()` resets watermarks on value change.
- **`MailImportCoordinator.swift`** — Added `lastMailWatermark` (persisted to UserDefaults). `performImport()` uses watermark as `since` date when available. Watermark set from all metadata dates (known + unknown senders) since the AppleScript metadata sweep is the expensive call. `resetMailWatermark()` clears it. `setLookbackDays()` resets watermark on value change.

### What did NOT change
- No schema or model changes
- No SQL query changes (services already accept `since:` parameter)
- No UI changes
- Calendar import unaffected
- Idempotent upsert safety preserved (sourceUID dedup still works as fallback)

---

## February 25, 2026 - Undo Restore UI Refresh Fix

### Overview
After restoring a deleted note via undo, the note didn't appear in PersonDetailView or ContextDetailView until navigating away and back. Root cause: both views use `@State` arrays with manual `loadNotes()` fetches rather than `@Query`, so SwiftData inserts from UndoRepository didn't trigger a re-render.

### Changes
- **`SAMModels.swift`** — Added `Notification.Name.samUndoDidRestore`
- **`UndoCoordinator.swift`** — Posts `.samUndoDidRestore` after successful restore
- **`PersonDetailView.swift`** — Added `.onReceive(.samUndoDidRestore)` → `loadNotes()`
- **`ContextDetailView.swift`** — Same listener

---

## February 25, 2026 - Phase Q: Time Tracking & Categorization (Schema SAM_v18)

### Overview
Added time tracking with automatic categorization of calendar events into 10 WFG-relevant categories based on attendee roles and title keywords. Manual override available in Awareness view.

### Data Model
- **`TimeEntry`** `@Model` — person, category, start/end, source (calendar/manual), override flag
- **`TimeCategory`** enum (10 cases): Prospecting, Client Meeting, Policy Review, Recruiting, Training/Mentoring, Admin, Deep Work, Personal Development, Travel, Other

### Components
- **`TimeTrackingRepository`** — Standard `@MainActor @Observable` singleton; CRUD, fetch by date range, category breakdown queries
- **`TimeCategorizationEngine`** — Heuristic auto-categorization: title keywords → role badges → solo event fallback
- **`TimeAllocationSection`** — 7-day breakdown in Review & Analytics section of AwarenessView
- **`TimeCategoryPicker`** — Inline override UI for manual category correction

### Schema
- SAM_v17 → **SAM_v18** (lightweight migration, additive)

---

## February 25, 2026 - Phase P: Universal Undo System (Schema SAM_v17)

### Overview
30-day undo history for all destructive operations. Captures full JSON snapshots before deletion/status changes, displays a dark bottom toast with 10-second auto-dismiss, and restores entities on tap.

### Data Model
- **`SamUndoEntry`** `@Model` — operation, entityType, entityID, entityDisplayName, snapshotData (JSON blob), capturedAt, expiresAt, isRestored, restoredAt
- **`UndoOperation`** enum: `.deleted`, `.statusChanged`
- **`UndoEntityType`** enum: `.note`, `.outcome`, `.context`, `.participation`, `.insight`
- **Snapshot structs** (Codable): `NoteSnapshot`, `OutcomeSnapshot`, `ContextSnapshot` (cascades participations), `ParticipationSnapshot`, `InsightSnapshot`

### Components
- **`UndoRepository`** — `@MainActor @Observable` singleton; `capture()` creates entry, `restore()` dispatches to entity-specific helpers, `pruneExpired()` at launch
- **`UndoCoordinator`** — `@MainActor @Observable` singleton; manages toast state, 10s auto-dismiss timer, `performUndo()` calls repository
- **`UndoToastView`** — Dark rounded banner pinned to bottom; slide-up animation; Undo button + dismiss X

### Undoable Actions
- Note deletion → full note snapshot restored (images excluded — too large)
- Outcome dismiss/complete → previous status reverted
- Context deletion → context + all participations cascade-restored
- Participant removal → participation restored with role data
- Insight dismissal → `dismissedAt` cleared

### Integration Points
- `NotesRepository.deleteNote()` — captures snapshot before delete
- `OutcomeRepository.markCompleted()` / `markDismissed()` — captures previous status
- `ContextsRepository.deleteContext()` / `removeParticipant()` — captures snapshot
- Insight dismiss handlers in AwarenessView — captures snapshot

### Schema
- SAM_v16 → **SAM_v17** (lightweight migration, additive)

---

## February 24, 2026 - App Intents / Siri Integration (#14)

### Overview
Verified and confirmed all 8 App Intents files compile cleanly with the current codebase (post Multi-Step Sequences, Intelligent Actions, etc.). No code changes needed — all API references (`PeopleRepository.search`, `OutcomeRepository.fetchActive`, `MeetingPrepCoordinator.briefings`, `DailyBriefingCoordinator`, `Notification.Name.samNavigateToPerson`) remain valid. This completes the Awareness UX Overhaul (#14).

### Files (all in `Intents/`)
- `PersonEntity.swift` — `AppEntity` + `PersonEntityQuery` (string search, suggested entities, ID lookup)
- `RoleFilter.swift` — `AppEnum` with 7 role cases
- `DailyBriefingIntent.swift` — Opens daily briefing sheet
- `FindPersonIntent.swift` — Navigates to person detail view
- `PrepForMeetingIntent.swift` — Rich meeting prep dialog result
- `WhoToReachOutIntent.swift` — Overdue contacts filtered by role
- `NextActionIntent.swift` — Top priority outcome
- `SAMShortcutsProvider.swift` — 5 `AppShortcut` registrations, auto-discovered by framework

---

## February 24, 2026 - Multi-Step Sequences (Schema SAM_v16)

### Overview
Added linked outcome sequences where completing one step can trigger the next after a delay + condition check. For example: "text Harvey about the partnership now" → (3 days, no response) → "email Harvey as follow-up." All done by extending `SamOutcome` with sequence fields, no new models.

### Data Model
- **`SequenceTriggerCondition`** enum in `SAMModels-Supporting.swift`: `.always` (activate unconditionally after delay), `.noResponse` (activate only if no communication from person). Display extensions: `displayName`, `displayIcon`.
- **5 new fields on `SamOutcome`**: `sequenceID: UUID?`, `sequenceIndex: Int`, `isAwaitingTrigger: Bool`, `triggerAfterDays: Int`, `triggerConditionRawValue: String?`. Plus `@Transient triggerCondition` computed property.
- Schema bumped from SAM_v15 → **SAM_v16** (lightweight migration, all fields have defaults).

### Repository Changes
- **`OutcomeRepository.fetchActive()`** — Now excludes outcomes where `isAwaitingTrigger == true`.
- **`OutcomeRepository.fetchAwaitingTrigger()`** — Returns outcomes with `isAwaitingTrigger == true` and status `.pending`.
- **`OutcomeRepository.fetchPreviousStep(for:)`** — Fetches step at `sequenceIndex - 1` in same sequence.
- **`OutcomeRepository.dismissRemainingSteps(sequenceID:fromIndex:)`** — Dismisses all steps at or after given index.
- **`OutcomeRepository.sequenceStepCount(sequenceID:)`** — Counts total steps in a sequence.
- **`OutcomeRepository.fetchNextAwaitingStep(sequenceID:afterIndex:)`** — Gets next hidden step for UI hint.
- **`OutcomeRepository.markDismissed()`** — Now auto-dismisses subsequent sequence steps on skip.
- **`EvidenceRepository.hasRecentCommunication(fromPersonID:since:)`** — Checks for iMessage/mail/phone/FaceTime evidence linked to person after given date. Used by trigger condition evaluation.

### Outcome Generation
- **`OutcomeEngine.maybeCreateSequenceSteps(for:)`** — Heuristics for creating follow-up steps:
  - "follow up" / "outreach" / "check in" / "reach out" → email follow-up in 3 days if no response
  - "send proposal" / "send recommendation" → follow-up text in 5 days if no response
  - `.outreach` kind + `.iMessage` channel → email escalation in 3 days if no response
- Each follow-up: same `linkedPerson`/`linkedContext`/kind, different channel (text↔email), `isAwaitingTrigger=true`.
- Wired into `generateOutcomes()` after action lane classification.

### Timer Logic
- **`DailyBriefingCoordinator.checkSequenceTriggers()`** — Added to the existing 5-minute timer:
  1. Fetch all awaiting-trigger outcomes
  2. Check if previous step is completed and enough time has passed
  3. Evaluate condition: `.always` → activate; `.noResponse` → check evidence → activate or auto-dismiss
  4. On activation: set `isAwaitingTrigger = false` → outcome appears in queue

### UI Changes
- **`OutcomeCardView`** — Sequence indicator between kind badge and title: "Step 1 of 2 · Then: email in 3d if no response". Activated follow-up steps show "(no response received)".
- **`OutcomeQueueView`** — Filters active outcomes to exclude `isAwaitingTrigger`. Passes `sequenceStepCount` and `nextAwaitingStep` to card view. Skip action auto-dismisses remaining sequence steps.

### Files Modified
| File | Change |
|------|--------|
| `Models/SAMModels-Supporting.swift` | New `SequenceTriggerCondition` enum with display extensions |
| `Models/SAMModels.swift` | 5 sequence fields + `@Transient triggerCondition` on `SamOutcome` |
| `App/SAMModelContainer.swift` | Schema bumped SAM_v15 → SAM_v16 |
| `Repositories/OutcomeRepository.swift` | `fetchActive()` filter, 5 new sequence methods, updated `markDismissed()` |
| `Repositories/EvidenceRepository.swift` | New `hasRecentCommunication(fromPersonID:since:)` |
| `Coordinators/OutcomeEngine.swift` | New `maybeCreateSequenceSteps()`, wired into generation loop |
| `Coordinators/DailyBriefingCoordinator.swift` | New `checkSequenceTriggers()` in 5-minute timer |
| `Views/Shared/OutcomeCardView.swift` | Sequence indicator + next-step hint |
| `Views/Awareness/OutcomeQueueView.swift` | Filter awaiting outcomes, sequence helpers, skip dismisses remaining |

---

## February 24, 2026 - Awareness UX Overhaul & Bug Fixes

### Overview
Major expansion of the Awareness dashboard with 6 new analytics sections, copy affordances throughout, cross-view navigation, and critical bug fixes for SwiftData cross-context errors and LLM JSON parsing.

### Tier 1 Fixes
- **"View Person" navigation** — Added `samNavigateToPerson` notification. InsightCard, OutcomeCardView (`.openPerson` action), and all Awareness sections can now navigate to PersonDetailView. AppShellView listens on both NavigationSplitView branches.
- **Copy buttons** — New shared `CopyButton` component with brief checkmark feedback. Added to OutcomeCardView (suggested next steps), FollowUpCoachSection (pending action items), MeetingPrepSection (open action items + signals).
- **Auto-link all meeting attendees** — `BriefingCard.createAndEditNote()` and `FollowUpCard.createAndEditNote()` now link ALL attendees to the new note instead of just the first.

### New Dashboard Sections (Tier 2/3)
- **`PipelineStageSection`** — Lead → Applicant → Client counts with "stuck" indicators (30d for Leads, 14d for Applicants). Click-to-navigate on stuck people.
- **`EngagementVelocitySection`** — Computes median evidence gap per person, surfaces overdue relationships (e.g., "2× longer than usual"). Top 8, sorted by overdue ratio.
- **`StreakTrackingSection`** — Meeting notes streak, weekly client touch streak, same-day follow-up streak. Flame indicator at 5+, positive reinforcement messaging.
- **`MeetingQualitySection`** — Scores meetings from last 14 days: note created (+40), timely (+20), action items (+20), attendees linked (+20). Surfaces low scorers with missing-item tags.
- **`CalendarPatternsSection`** — Back-to-back meeting warnings, client meeting ratio, meeting-free days, busiest day analysis, upcoming load comparison.
- **`ReferralTrackingSection`** — Top referrers + referral opportunities UI (stub data pending `referredBy` schema field).

### Batch 2 — Follow-up Drafts, Referral Schema, Life Events

- **Post-meeting follow-up draft generation (#7)** — New `SamNote.followUpDraft: String?` field. `NoteAnalysisService.generateFollowUpDraft()` generates a plain-text follow-up message from meeting notes. Triggered in `NoteAnalysisCoordinator` when note is linked to a calendar event within 24 hours. Draft displayed in `NotesJournalView` with Copy and Dismiss buttons.
- **Referral chain tracking (#12)** — Added `SamPerson.referredBy: SamPerson?` and `referrals: [SamPerson]` self-referential relationships (`@Relationship(deleteRule: .nullify)`). Schema bumped to SAM_v13. `ReferralTrackingSection` now uses real `@Query` data (top referrers, referral opportunities for established Clients). Referral assignment UI added to `PersonDetailView` with picker sheet filtering Client/Applicant/Lead roles.
- **Life event detection (#13)** — New `LifeEvent` Codable struct (personName, eventType, eventDescription, approximateDate, outreachSuggestion, status). `SamNote.lifeEvents: [LifeEvent]` field. LLM prompt extended with 11 event types (new_baby, marriage, retirement, job_change, etc.). `LifeEventsSection` in Awareness dashboard with event-type icons, outreach suggestion copy buttons, Done/Skip actions, person navigation. `InsightGenerator.generateLifeEventInsights()` scans notes for pending life events. Note analysis version bumped to 3 (triggers re-analysis of existing notes).

### Batch 2 Files Modified
| File | Change |
|------|--------|
| `Models/SAMModels.swift` | Added `referredBy` / `referrals` self-referential relationship on SamPerson |
| `Models/SAMModels-Notes.swift` | Added `followUpDraft: String?`, `lifeEvents: [LifeEvent]` on SamNote |
| `Models/SAMModels-Supporting.swift` | New `LifeEvent` Codable struct |
| `Models/DTOs/NoteAnalysisDTO.swift` | Added `LifeEventDTO`, `lifeEvents` on NoteAnalysisDTO |
| `App/SAMModelContainer.swift` | Schema bumped to SAM_v13 |
| `Services/NoteAnalysisService.swift` | Life events in LLM prompt, `generateFollowUpDraft()`, analysis version 3 |
| `Coordinators/NoteAnalysisCoordinator.swift` | Triggers follow-up draft after meeting detection, stores life events |
| `Coordinators/InsightGenerator.swift` | New `generateLifeEventInsights()` step |
| `Repositories/NotesRepository.swift` | Extended `storeAnalysis()` with life events, `updateLifeEvent()` method |
| `Views/Awareness/ReferralTrackingSection.swift` | Wired to real `@Query` data |
| `Views/Awareness/LifeEventsSection.swift` | **New** — Life event outreach cards |
| `Views/Awareness/AwarenessView.swift` | Added `LifeEventsSection` |
| `Views/Notes/NotesJournalView.swift` | Follow-up draft card with Copy/Dismiss |
| `Views/People/PersonDetailView.swift` | Referral assignment UI (picker sheet) |

### Bug Fixes
- **SwiftData cross-context insertion error** — InsightGenerator and OutcomeRepository were fetching `SamPerson` from PeopleRepository's ModelContext then inserting into their own context, causing "Illegal attempt to insert a model in to a different model context." Fixed InsightGenerator.persistInsights() to fetch person from its own context. Fixed OutcomeRepository.upsert() with `resolveInContext()` helpers that re-fetch linked objects from the repository's own ModelContext.
- **LLM echoing JSON template** — NoteAnalysisService prompt used ambiguous template-style placeholders (e.g., `"field": "birthday | anniversary | ..."`) that the LLM echoed back literally. Also contained en-dash characters (`–`) in `0.0–1.0` that broke JSON parsing. Rewrote prompt with concrete example values and separate field reference. Added Unicode sanitization to `extractJSON()` (en-dash, em-dash, curly quotes, ellipsis → ASCII equivalents).
- **ProgressView auto-layout warnings** — `ProcessingStatusView`'s `ProgressView().controlSize(.small)` caused AppKit constraint warnings (`min <= max` floating-point precision). Fixed with explicit `.frame(width: 16, height: 16)`.

### Files Modified
| File | Change |
|------|--------|
| `Models/SAMModels.swift` | Added `samNavigateToPerson` notification |
| `Views/AppShellView.swift` | `.onReceive` handlers for person navigation on both NavigationSplitView branches |
| `Views/Awareness/AwarenessView.swift` | Implemented `viewPerson()`, added 6 new section views |
| `Views/Awareness/OutcomeQueueView.swift` | Wired `.openPerson` action in `actClosure` |
| `Views/Shared/OutcomeCardView.swift` | Copy button on suggested next step |
| `Views/Shared/CopyButton.swift` | **New** — Reusable copy-to-clipboard button |
| `Views/Awareness/FollowUpCoachSection.swift` | Copy buttons on action items, all-attendee note linking |
| `Views/Awareness/MeetingPrepSection.swift` | Copy buttons on action items + signals, all-attendee note linking |
| `Views/Awareness/PipelineStageSection.swift` | **New** — Pipeline stage visualization |
| `Views/Awareness/EngagementVelocitySection.swift` | **New** — Personalized cadence tracking |
| `Views/Awareness/StreakTrackingSection.swift` | **New** — Behavior streak tracking |
| `Views/Awareness/MeetingQualitySection.swift` | **New** — Meeting follow-through scoring |
| `Views/Awareness/CalendarPatternsSection.swift` | **New** — Calendar pattern intelligence |
| `Views/Awareness/ReferralTrackingSection.swift` | **New** — Referral tracking (stub) |
| `Coordinators/InsightGenerator.swift` | Fixed cross-context person fetch in `persistInsights()` |
| `Repositories/OutcomeRepository.swift` | Added `resolveInContext()` helpers for cross-context safety |
| `Services/NoteAnalysisService.swift` | Rewrote note analysis prompt with concrete example |
| `Services/AIService.swift` | Added Unicode sanitization to `extractJSON()` |
| `Views/Components/ProcessingStatusView.swift` | Explicit frame on ProgressView |

---

## February 23, 2026 - Notes Editing UX Improvements

### Overview
Comprehensive improvements to note editing in NotesJournalView: fixed inline image rendering in edit mode, added double-click-to-edit gesture, dictation/attachment support in edit mode, keyboard shortcuts, and explicit save workflow with unsaved changes protection.

### Image Rendering Fix (RichNoteEditor)
- **`makeImageAttachment(data:nsImage:containerWidth:)`** — New static factory that creates `NSTextAttachmentCell(imageCell:)` with scaled display image. macOS NSTextView (TextKit 1) requires an explicit `attachmentCell` for inline image rendering; without it, images render as empty placeholders.
- **`lastSyncedText` tracking** — Coordinator tracks the last plainText value it pushed, so `updateNSView` can distinguish external changes (dictation, polish) from its own `textDidChange` syncs. Prevents newlines around images from triggering spurious attributed string rebuilds.

### Edit Mode Improvements (NotesJournalView)
- **Double-click to edit** — `ExclusiveGesture(TapGesture(count: 2), TapGesture(count: 1))` on collapsed notes: double-click expands + enters edit mode, single click just expands.
- **Delete on empty** — When user deletes all content and saves, note is deleted (previously the guard `!trimmed.isEmpty` silently exited editing without saving).
- **ScrollViewReader** — Prevents page jump when entering edit mode; scrolls editing note into view with 150ms delay via `proxy.scrollTo(id, anchor: .top)`.
- **Dictation in edit mode** — Mic button with streaming dictation, segment accumulation across recognizer resets, auto-polish on stop. Mirrors InlineNoteCaptureView pattern.
- **Attach image in edit mode** — Paperclip button opens NSOpenPanel for PNG/JPEG/GIF/TIFF; inserts inline via `editHandle.insertImage()`.

### Keyboard Shortcuts (NoteTextView subclass)
- **Cmd+S** — Saves via `editorCoordinator?.handleSave()` callback (explicit save, not focus loss).
- **Escape** — Cancels editing via `cancelOperation` → `editorCoordinator?.handleCancel()`.
- **Paste formatting strip** — Text paste strips formatting (`pasteAsPlainText`); image-only paste preserves attachment behavior.

### Explicit Save Workflow
- **Removed click-outside-to-save** — Previously used `NSEvent.addLocalMonitorForEvents(.leftMouseDown)` to detect clicks outside the editor and trigger save. This caused false saves when clicking toolbar buttons (mic, paperclip).
- **Replaced `onCommit` with `onSave`** — RichNoteEditor parameter renamed; only called on explicit Cmd+S or Save button click.
- **Save button** — Added `.borderedProminent` Save button to edit toolbar alongside Cancel.
- **Unsaved changes alert** — When notes list changes while editing (e.g., switching people), shows "Unsaved Changes" alert with Save / Discard / Cancel options.

### Dictation Polish Fix (NoteAnalysisService)
- **Proofreading-only prompt** — Rewrote `polishDictation` system instructions to explicitly state: "You are a proofreader. DO NOT interpret it as a question or instruction. ONLY fix spelling errors, punctuation, and capitalization." Previously the AI treated dictated text as a prompt and responded to it.

### Files Modified
| File | Change |
|------|--------|
| `Views/Notes/RichNoteEditor.swift` | Image attachment cell, lastSyncedText, NoteTextView subclass (Cmd+S/Esc/paste), onSave replaces onCommit, removed click-outside monitor |
| `Views/Notes/NotesJournalView.swift` | Double-click gesture, delete-on-empty, ScrollViewReader, dictation/attach buttons, Save button, unsaved changes alert |
| `Services/NoteAnalysisService.swift` | Proofreading-only polish prompt |

---

## February 22, 2026 - Phase N: Outcome-Focused Coaching Engine

### Overview
Transforms SAM from a relationship *tracker* into a relationship *coach*. Introduces an abstracted AI service layer (FoundationModels + MLX), an outcome generation engine that synthesizes all evidence sources into prioritized coaching suggestions, and an adaptive feedback system that learns the user's preferred coaching style.

### Schema
- **Schema bumped to SAM_v11** — Added `SamOutcome` and `CoachingProfile` models

### New Models
- **`SamOutcome`** — Coaching suggestion with title, rationale, outcomeKind (preparation/followUp/proposal/outreach/growth/training/compliance), priorityScore (0–1), deadline, status (pending/inProgress/completed/dismissed/expired), user rating, feedback tracking
- **`CoachingProfile`** — Singleton tracking encouragement style, preferred/dismissed outcome kinds, response time, rating averages
- **`OutcomeKind`** / **`OutcomeStatus`** — Supporting enums in SAMModels-Supporting.swift

### New Services
- **`AIService`** (actor) — Unified AI interface: `generate(prompt:systemInstruction:maxTokens:)`, `checkAvailability()`. Default FoundationModels backend with transparent MLX fallback.
- **`MLXModelManager`** (actor) — Model catalogue, download/delete stubs, `isSelectedModelReady()`. Curated list: Mistral 7B (4-bit), Llama 3.2 3B (4-bit). Full MLX inference deferred to future update.

### New Coordinators
- **`OutcomeEngine`** (@MainActor) — Generates outcomes from 5 evidence scanners: upcoming meetings (48h), past meetings without notes (48h), pending action items, relationship health (role-weighted thresholds), growth opportunities. Priority scoring: time urgency (0.30) + relationship health (0.20) + role importance (0.20) + evidence recency (0.15) + user engagement (0.15). AI enrichment adds suggested next steps to top 5 outcomes.
- **`CoachingAdvisor`** (@MainActor) — Analyzes completed/dismissed outcome patterns, generates style-specific encouragement (direct/supportive/achievement/analytical), adaptive rating frequency, priority weight adjustment.

### New Repository
- **`OutcomeRepository`** (@MainActor) — Standard singleton pattern. `fetchActive()`, `fetchCompleted()`, `fetchCompletedToday()`, `markCompleted()`, `markDismissed()`, `recordRating()`, `pruneExpired()`, `purgeOld()`, `hasSimilarOutcome()` (deduplication).

### New Views
- **`OutcomeQueueView`** — Top section of AwarenessView. Shows prioritized outcome cards with Done/Skip actions. "SAM Coach" header with outcome count. Completed-today collapsible section. Rating sheet (1–5 stars) shown occasionally after completion.
- **`OutcomeCardView`** — Reusable card: color-coded kind badge, priority dot (red/yellow/green), title, rationale, suggested next step, deadline countdown, Done/Skip buttons.
- **`CoachingSettingsView`** — New Settings tab (brain.head.profile icon). Sections: AI Backend (FoundationModels vs MLX), MLX Model management, Coaching Style (auto-learn or manual override), Outcome Generation (auto-generate toggle), Feedback stats + profile reset.

### App Wiring
- `OutcomeRepository.shared.configure()` and `CoachingAdvisor.shared.configure()` added to `configureDataLayer()`
- Outcome pruning + generation triggered in `triggerImportsForEnabledSources()` (gated by `outcomeAutoGenerate` UserDefaults key)
- `OutcomeQueueView` integrated as first section in `AwarenessView`
- `CoachingSettingsView` tab added to `SettingsView` after Intelligence

### Deferred
- MLX model download and inference (SPM dependency not yet added)
- Custom outcome templates
- Outcome analytics dashboard
- Progress reports to upline
- Team coaching patterns
- Universal Undo System (moved to Phase O)

---

## February 21, 2026 - Phase M: Communications Evidence

### Overview
Added iMessage, phone call, and FaceTime history as evidence sources for the relationship intelligence pipeline. Uses security-scoped bookmarks for sandbox-safe SQLite3 access to system databases. On-device LLM analyzes message threads; raw text is never stored.

### Schema
- **`SamPerson.phoneAliases: [String]`** — Canonicalized phone numbers (last 10 digits, digits only), populated during contacts import
- **Schema bumped to SAM_v9** — New `phoneAliases` field on SamPerson
- **`PeopleRepository.canonicalizePhone(_:)`** — Strip non-digits, take last 10, minimum 7 digits
- **`PeopleRepository.allKnownPhones()`** — O(1) lookup set mirroring `allKnownEmails()`
- Phone numbers populated in `upsert()`, `bulkUpsert()`, and `upsertMe()` from `ContactDTO.phoneNumbers`

### Database Access
- **`BookmarkManager`** — @MainActor @Observable singleton managing security-scoped bookmarks for chat.db and CallHistory.storedata
- NSOpenPanel pre-navigated to expected directories; bookmarks persisted in UserDefaults
- Stale bookmark auto-refresh; revoke methods for settings UI

### Services
- **`iMessageService`** (actor) — SQLite3 reader for `~/Library/Messages/chat.db`
  - `fetchMessages(since:dbURL:knownIdentifiers:)` — Joins message/handle/chat tables, nanosecond epoch conversion, attributedBody text extraction via NSUnarchiver (typedstream format) with manual binary fallback
  - Handle canonicalization: phone → last 10 digits, email → lowercased
- **`CallHistoryService`** (actor) — SQLite3 reader for `CallHistory.storedata`
  - `fetchCalls(since:dbURL:knownPhones:)` — ZCALLRECORD table, ZADDRESS cast from BLOB, call type mapping (1=phone, 8=FaceTime video, 16=FaceTime audio)
- **`MessageAnalysisService`** (actor) — On-device LLM (FoundationModels) for conversation thread analysis
  - Chronological `[MM/dd HH:mm] Me/Them: text` format
  - Returns `MessageAnalysisDTO` (summary, topics, temporal events, sentiment, action items)

### DTOs
- **`MessageDTO`** — id, guid, text, date, isFromMe, handleID, chatGUID, serviceName, hasAttachment
- **`CallRecordDTO`** — id, address, date, duration, callType (phone/faceTimeVideo/faceTimeAudio/unknown), isOutgoing, wasAnswered
- **`MessageAnalysisDTO`** — summary, topics, temporalEvents, sentiment (positive/neutral/negative/urgent), actionItems

### Evidence Repository
- **`EvidenceSource`** extended: `.iMessage`, `.phoneCall`, `.faceTime`
- **`resolvePeople(byPhones:)`** — Matches phone numbers against `SamPerson.phoneAliases`
- **`bulkUpsertMessages(_:)`** — sourceUID `imessage:<guid>`, bodyText always nil, snippet from AI summary
- **`bulkUpsertCallRecords(_:)`** — sourceUID `call:<id>:<timestamp>`, title includes direction/status, snippet shows duration or "Missed"
- **`refreshParticipantResolution()`** — Now includes iMessage/phoneCall/faceTime sources

### Coordinator
- **`CommunicationsImportCoordinator`** — @MainActor @Observable singleton
  - Settings: messagesEnabled, callsEnabled, lookbackDays (default 90), analyzeMessages (default true)
  - Pipeline: resolve bookmarks → build known identifiers → fetch → filter → group by (handle, day) → analyze threads → bulk upsert
  - Analysis only for threads with ≥2 messages with text; applied to last message in thread

### UI
- **`CommunicationsSettingsView`** — Database access grants, enable toggles, lookback picker, AI analysis toggle, import status
- **`SettingsView`** — New "Communications" tab with `message.fill` icon between Mail and Intelligence
- Inbox views updated: iMessage (teal/message icon), phoneCall (green/phone icon), faceTime (mint/video icon)

### App Wiring
- **`SAMApp.triggerImportsForEnabledSources()`** — Added communications import trigger when either commsMessagesEnabled or commsCallsEnabled

### Bug Fixes (Feb 21, 2026)
- **attributedBody text extraction** — Replaced NSKeyedUnarchiver with NSUnarchiver for typedstream format (fixes ~70% of messages showing "[No text]"); manual binary parser fallback for edge cases
- **Directory-level bookmarks** — BookmarkManager now selects directories (not files) to cover WAL/SHM companion files required by SQLite WAL mode
- **Toggle persistence** — Coordinator settings use stored properties with explicit setter methods (not @ObservationIgnored computed properties) for proper SwiftUI observation
- **Relationship summary integration** — `NoteAnalysisCoordinator.refreshRelationshipSummary()` now includes communications evidence (iMessage/call/FaceTime snippets) in the LLM prompt via `communicationsSummaries` parameter
- **Post-import summary refresh** — `CommunicationsImportCoordinator` triggers `refreshAffectedSummaries()` after successful import, refreshing relationship summaries for people with new communications evidence
- **`@Relationship` inverse fix (critical)** — Added `linkedEvidence: [SamEvidenceItem]` inverse on `SamPerson` and `SamContext`. Without explicit inverses, SwiftData treated the many-to-many as one-to-one, silently dropping links when the same person appeared in multiple evidence items. Schema bumped to SAM_v10.
- **`setLinkedPeople` helper** — All `@Relationship` array assignments in EvidenceRepository use explicit `removeAll()` + `append()` for reliable SwiftData change tracking

### Deferred
- Unknown sender discovery for messages/calls
- Group chat multi-person linking
- Real-time monitoring (currently poll-based)
- iMessage attachment processing

---

## February 20, 2026 - Role-Aware AI Analysis Pipeline

### Overview
Injected role context into every AI touchpoint so notes, insights, relationship summaries, and health indicators are all role-aware. Previously the AI treated all contacts identically.

### Part 1: Role-Aware Note Analysis Prompts
- **`NoteAnalysisService.RoleContext`** — Sendable struct carrying primary person name/role and other linked people
- **`analyzeNote(content:roleContext:)`** — Optional role context prepended to LLM prompt (e.g., "Context: This note is about Jane, who is a Client.")
- **`generateRelationshipSummary(personName:role:...)`** — Role injected into prompt; system instructions tailored per role (coverage gaps for Clients, training for Agents, service quality for Vendors)
- **Role enum updated** — Added `applicant | lead | vendor | agent | external_agent` to JSON schema
- **Analysis version bumped to 2** — Triggers re-analysis of existing notes with role context and discovered relationships

### Part 2: Role Context Wiring
- **`NoteAnalysisCoordinator.buildRoleContext(for:)`** — Extracts primary person (first non-Me linked person) and their role badge; passes to service
- **`refreshRelationshipSummary(for:)`** — Passes `person.roleBadges.first` as role parameter

### Part 3: Discovered Relationships
- **`DiscoveredRelationship`** (value type in SAMModels-Supporting.swift) — `personName`, `relationshipType` (spouse_of, parent_of, child_of, referral_by, referred_to, business_partner), `relatedTo`, `confidence`, `status` (pending/accepted/dismissed)
- **`DiscoveredRelationshipDTO`** (in NoteAnalysisDTO.swift) — Sendable DTO crossing actor boundary
- **`SamNote.discoveredRelationships: [DiscoveredRelationship]`** — New field (defaults to `[]`, no migration needed)
- **`NotesRepository.storeAnalysis()`** — Updated signature with `discoveredRelationships` parameter
- **LLM JSON schema** — New `discovered_relationships` array in prompt; parsed via `LLMDiscoveredRelationship` private struct
- **UI deferred** — Stored on model but not yet surfaced in views

### Part 4: Role-Weighted Insight Generation
- **`InsightGenerator.RoleThresholds`** — Per-role no-contact thresholds: Client=45d, Applicant=14d, Lead=30d, Agent=21d, External Agent=60d, Vendor=90d, Default=60d
- **Urgency boost** — Client, Applicant, Agent insights get medium→high urgency boost
- **`isMe` skip** — Relationship insights now skip the Me contact
- **`generateDiscoveredRelationshipInsights()`** — Scans notes for pending discovered relationships with confidence ≥ 0.7, generates `.informational` insights
- **Insight body includes role label** — e.g., "Last interaction was 50 days ago (Client threshold: 45 days)"

### Part 5: Role-Aware Relationship Health Colors
- **`RelationshipHealth.role: String?`** — New field passed through from `computeHealth(for:)`
- **`statusColor` thresholds per role** — Client/Applicant: green≤7d, yellow≤21d, orange≤45d; Agent: green≤7d, yellow≤14d, orange≤30d; Vendor: green≤30d, yellow≤60d, orange≤90d; Default: green≤14d, yellow≤30d, orange≤60d
- **Backward compatible** — All existing consumers of `statusColor` automatically get role-aware colors

### Deferred
- UI for discovered relationships (AwarenessView section with Accept/Dismiss)
- Role suggestion insights (LLM suggesting role badge changes)
- Email analysis role-awareness
- Per-role threshold settings (UserDefaults overrides)

---

## February 20, 2026 - Role Badges & Me Contact Visibility

### Role Badge System
- **Predefined roles updated** — `Client`, `Applicant`, `Lead`, `Vendor`, `Agent`, `External Agent` (replaces old set: Prospect, Referral Partner, Center of Influence, Staff)
- **RoleBadgeStyle** (new shared view) — Centralized color/icon mapping for role badges; every role gets a unique color and SF Symbol icon
- **RoleBadgeIconView** (new shared view) — Compact color-coded icon for People list rows with 600ms hover tooltip (popover); replaces full-text capsules that cluttered the sidebar
- **PersonDetailView badge editor** — Predefined + custom badge chips; each role shown in its assigned color; add/remove with animations
- **Notification-based refresh** — `Notification.Name.samPersonDidChange` posted on badge changes; PeopleListView listens and re-fetches immediately (fixes delay caused by separate ModelContext instances)
- **Role definitions documented** — Client (purchased product), Applicant (in purchase process), Lead (potential client), Vendor (underwriter/service company), Agent (user's WFG team member), External Agent (peer at WFG)

### Me Contact Visibility
- **People list** — Me contact shows subtle gray "Me" capsule next to name; distinct but not loud
- **PersonDetailView** — Non-interactive gray "Me" badge shown separately from editable role badges; cannot be added or removed through badge editor (set only via Apple Contacts Me card)
- **InboxDetailView** — Participants list filters out anyone whose email matches Me contact's email aliases
- **MeetingPrepCoordinator** — Briefing attendees and follow-up prompt attendees filter out `isMe` people at the data source; all downstream views (MeetingPrepSection, FollowUpCoachSection) automatically exclude Me

---

## February 20, 2026 - Bug Fixes: Dictation, Notes Journal, Contacts Capsule

### Dictation Fixes
- **Missing entitlement** — Added `com.apple.security.device.audio-input` to `SAM_crm.entitlements`; sandboxed app was receiving silent audio buffers without it
- **Microphone permission flow** — `DictationService.startRecognition()` now `async`; checks `AVCaptureDevice.authorizationStatus(for: .audio)` and requests permission if `.notDetermined`, throws if denied
- **`DictationService.requestAuthorization()`** — Now requests both speech recognition AND microphone permissions
- **Silence auto-stop** — Detects consecutive silent audio buffers and calls `endAudio()` after configurable timeout (default 2s, stored in `UserDefaults` key `sam.dictation.silenceTimeout`)
- **Buffer leak after auto-stop** — `didEndAudio` flag prevents continued buffer processing after `endAudio()` is called
- **Text accumulation across pauses** — On-device recognizer resets transcription context after silence; `InlineNoteCaptureView` now tracks `accumulatedSegments` and detects resets (text length drops sharply), preserving all spoken text
- **Buffer size** — Increased from 1024 to 4096 for more reliable speech detection
- **Mono format conversion** — Auto-converts stereo input to mono for SFSpeechRecognizer compatibility
- **Onboarding** — Added `microphonePermission` step to `OnboardingView` (after mail, before complete) requesting both speech recognition and microphone access

### Notes Journal View
- **NotesJournalView** (new) — Scrollable inline journal replacing tap-to-open-sheet pattern; all notes visible in one scrollable container with dividers, metadata headers, and inline editing
- **PersonDetailView** — Replaced `NoteRowView` + `editingNote` sheet with `NotesJournalView`; removed `NoteEditorView` sheet binding
- **ContextDetailView** — Same replacement: `NotesJournalView` replaces old note rows + sheet

### "Not in Contacts" Capsule
- **NotInContactsCapsule** (new shared view) — Orange capsule badge that acts as a button; tapping shows confirmation popover to create the person in Apple Contacts
- **Two init modes**: `init(person:)` for SamPerson with nil contactIdentifier, `init(name:email:)` for unmatched event participants
- **`ParticipantHint.Status`** — Added `matchedPerson: SamPerson?` so InboxDetailView can pass the matched person to the capsule
- **InboxDetailView** — Replaced static "Not in Contacts" text with `NotInContactsCapsule`
- **PeopleListView** — Replaced static orange `person.badge.plus` icon with `NotInContactsCapsule`

### Stale Contact Identifier Detection
- **`ContactsService.validateIdentifiers(_:)`** — Batch-checks which contact identifiers still exist in Apple Contacts
- **`PeopleRepository.clearStaleContactIdentifiers(validIdentifiers:)`** — Clears `contactIdentifier` on SamPerson records whose Apple Contact was deleted
- **`ContactsImportCoordinator.performImport()`** — Now runs stale identifier check after every contacts sync

### SAM Group Auto-Assignment
- **`ContactsService.addContactToSAMGroup(identifier:)`** — Automatically adds SAM-created contacts to the configured SAM group in Apple Contacts
- **`ContactsService.createContact()`** — Now calls `addContactToSAMGroup()` after creation, ensuring contacts created via triage, NotInContactsCapsule, or PersonDetailView all land in the SAM group

---

## February 20, 2026 - Phase L-2 Complete: Notes Redesign

**What Changed** — Simplified note model, inline capture, AI dictation polish, smart auto-linking, AI relationship summaries:

### Data Model
- **NoteEntry removed** — Multi-entry model replaced with single text block per note
- **SamNote.sourceTypeRawValue** — New field: "typed" or "dictated" (replaces NoteEntry.entryType)
- **SamNote.SourceType** — `@Transient` computed enum (`.typed` / `.dictated`)
- **SamNote init** — Removed `entries` param, added `sourceType` param
- **SamNote** — Removed `entries`, `rebuildContent()`, `migrateContentToEntriesIfNeeded()`
- **SamPerson** — Added `relationshipSummary: String?`, `relationshipKeyThemes: [String]`, `relationshipNextSteps: [String]`, `summaryUpdatedAt: Date?`
- **RelationshipSummaryDTO** — New Sendable DTO for AI-generated relationship summaries
- **SAMModelContainer** — Schema bumped `SAM_v7` → `SAM_v8`

### NotesRepository
- **Removed**: `addEntry()`, `deleteEntry()`, `migrateContentToEntriesIfNeeded()` calls
- **create()** — Simplified: no NoteEntry wrapping, accepts `sourceType` param
- **createFromImport()** — Simplified: no NoteEntry creation

### Views
- **InlineNoteCaptureView** (new) — Reusable inline text field + mic button + Save, used by PersonDetailView and ContextDetailView
- **NoteEditorView** — Simplified to edit-only (TextEditor + Cancel/Save), no entry stream or dictation
- **NoteEntryRowView** — Deleted (no longer needed)
- **PersonDetailView** — Inline capture replaces "Add Note" toolbar button, relationship summary section above notes, tap-to-edit note rows
- **ContextDetailView** — Inline capture replaces "Add Note" toolbar button, tap-to-edit note rows
- **InboxDetailView** — Create-then-edit pattern for note attachment
- **MeetingPrepSection / FollowUpCoachSection** — Create-then-edit pattern for meeting notes

### Services
- **NoteAnalysisService.polishDictation(rawText:)** — Cleans grammar/filler from dictated text using on-device LLM
- **NoteAnalysisService.generateRelationshipSummary()** — Generates overview, themes, and next steps for a person

### Repositories
- **EvidenceRepository.findRecentMeeting(forPersonID:maxWindow:)** — Finds most recent calendar event involving a person within 2h window

### Coordinators
- **NoteAnalysisCoordinator.analyzeNote()** — Removed `rebuildContent()` call, added relationship summary refresh
- **NoteAnalysisCoordinator.refreshRelationshipSummary(for:)** — Gathers notes/topics/actions, calls AI service, stores on SamPerson
- **EvernoteImportCoordinator** — Simplified: no NoteEntry creation in `confirmImport()`

---

## February 20, 2026 - Phase L Complete: Notes Pro

**What Changed** — Timestamped entry stream, voice dictation, and Evernote ENEX import:

### Data Model
- **NoteEntry** (new value type) — `id: UUID`, `timestamp: Date`, `content: String`, `entryTypeRawValue: String` (`.typed` / `.dictated`), optional `metadata: [String: String]?`
- **SamNote** — Added `entries: [NoteEntry]` embedded Codable array, `sourceImportUID: String?` for import dedup
- **SamNote.rebuildContent()** — Concatenates entries into `content` for LLM analysis backward compatibility
- **SamNote.migrateContentToEntriesIfNeeded()** — Lazy migration: wraps existing content into single entry
- **SAMModelContainer** — Schema bumped `SAM_v6` → `SAM_v7`

### NotesRepository
- **addEntry(to:content:entryType:metadata:)** — Appends entry, rebuilds content, marks unanalyzed
- **deleteEntry(from:entryID:)** — Removes entry, rebuilds content
- **createFromImport(sourceImportUID:content:createdAt:updatedAt:linkedPeopleIDs:)** — For ENEX import
- **fetchBySourceImportUID(_:)** — Dedup check for imported notes
- **create()** — Now wraps content into a NoteEntry
- **fetchAll()** — Calls `migrateContentToEntriesIfNeeded()` on each note (lazy migration)

### NoteEditorView (Major Rewrite)
- **Entry stream UI** — Bear/Craft-style distraction-free editor with timestamped entries
- **Progressive disclosure toolbar** — Link button (popover), mic button, more menu
- **Entry display** — Continuous document with subtle `.caption2` timestamps, mic icon for dictated entries, thin dividers
- **Input area** — Clean TextField pinned at bottom, Enter adds entry, auto-scrolls
- **Pending entries** — New notes use `@State pendingEntries` until Done (avoids orphans on Cancel)
- **Dictation integration** — Mic button toggles recording, partial results shown live, final result → `.dictated` entry

### DictationService (New)
- Actor wrapping `SFSpeechRecognizer` + `AVAudioEngine`
- `checkAvailability()` → `DictationAvailability`
- `requestAuthorization()` async → `Bool`
- `startRecognition()` async throws → `AsyncStream<DictationResult>` (on-device: `requiresOnDeviceRecognition = true`)
- `stopRecognition()` — Cleans up audio engine and recognition task

### ENEXParserService (New)
- Actor parsing `.enex` XML with Foundation `XMLParser` + delegate
- ENHTML → plain text via regex HTML tag stripping + entity decoding
- Handles `<note>`, `<title>`, `<content>` (CDATA), `<created>`, `<updated>`, `<guid>`, `<tag>`
- Date format: `yyyyMMdd'T'HHmmss'Z'` (UTC)

### EvernoteImportCoordinator (New)
- `@MainActor @Observable` singleton with two-phase flow
- `loadFile(url:)` — Parse ENEX, check dedup, populate preview counts
- `confirmImport()` — Create SamNotes, case-insensitive tag→person matching, fire background analysis
- `cancelImport()` — Reset state
- ImportStatus: `.idle`, `.parsing`, `.previewing`, `.importing`, `.success`, `.failed`

### Consumer Updates
- **PersonDetailView** — NoteRowView shows entry count + most recent timestamp
- **ContextDetailView** — Same NoteRowView update
- **NoteAnalysisCoordinator** — `rebuildContent()` guard before analysis
- **SettingsView** — Added Evernote tab with `EvernoteImportSettingsView`

### New Files
| File | Description |
|------|-------------|
| `Views/Notes/NoteEntryRowView.swift` | Clean timestamp + content row |
| `Services/DictationService.swift` | SFSpeechRecognizer actor |
| `Services/ENEXParserService.swift` | ENEX XML parser actor |
| `Models/DTOs/EvernoteNoteDTO.swift` | Evernote import DTO |
| `Coordinators/EvernoteImportCoordinator.swift` | Import coordinator |
| `Views/Settings/EvernoteImportSettingsView.swift` | Import settings UI |

### Modified Files
| File | Change |
|------|--------|
| `Models/SAMModels-Notes.swift` | NoteEntry struct, entries/sourceImportUID on SamNote |
| `App/SAMModelContainer.swift` | SAM_v6 → SAM_v7 |
| `Repositories/NotesRepository.swift` | Entry operations, import methods |
| `Views/Notes/NoteEditorView.swift` | Major rewrite — entry stream + dictation |
| `Views/Settings/SettingsView.swift` | Added Evernote tab |
| `Coordinators/NoteAnalysisCoordinator.swift` | rebuildContent() guard |
| `Views/People/PersonDetailView.swift` | Entry count in NoteRowView |
| `Views/Contexts/ContextDetailView.swift` | Entry count in NoteRowView |
| `Info.plist` | Speech recognition + microphone usage descriptions |

---

## February 20, 2026 - Phase J Part 3c Complete: Hardening & Bug Fixes

**What Changed** — Participant matching bug fix + insight persistence to SwiftData:

### Bug Fix: Participant Matching
- **Root cause**: `EKParticipant.isCurrentUser` unreliably returns `true` for organizer/all attendees in some calendar configurations, short-circuiting the `matched` check and making everyone appear verified
- **Fix**: Added `meEmailSet()` helper in `EvidenceRepository` that fetches Me contact's known emails from `PeopleRepository`; replaced `attendee.isCurrentUser` with `meEmails.contains(canonical)` in `buildParticipantHints()`

### Insight Persistence
- **SamInsight model** — Added `title: String`, `urgencyRawValue: String` + `@Transient urgency: InsightPriority`, `sourceTypeRawValue: String` + `@Transient sourceType: InsightSourceType`, `sourceID: UUID?`
- **InsightGenerator** — Added `configure(container:)` with `ModelContext`; `persistInsights()` creates `SamInsight` records with 24h dedup (same kind + personID + sourceID); prunes dismissed insights older than 30 days
- **AwarenessView** — Migrated from `@State [GeneratedInsight]` to `@Query SamInsight` (filtered by `dismissedAt == nil`); `markDone`/`dismiss` set `dismissedAt` on the SwiftData model
- **InsightCard** — Updated to accept `SamInsight` (uses `.title`, `.message`, `.urgency`, `.sourceType`, `.samPerson`)
- **SAMApp** — Wired `InsightGenerator.shared.configure(container:)` in `configureDataLayer()`
- **InsightPriority / InsightSourceType** — Made `public` for use in SamInsight's public init

---

## February 20, 2026 - Phase K Complete: Meeting Prep & Follow-Up

**What Changed** — Proactive meeting briefings, follow-up coaching, and relationship health indicators:

### Data Model
- **SamEvidenceItem** — Added `endedAt: Date?` property for calendar event end time
- **EvidenceRepository** — Set `endedAt = event.endDate` in both `upsert(event:)` and `bulkUpsert(events:)`

### MeetingPrepCoordinator (New)
- `@MainActor @Observable` singleton with `refresh() async` and `computeHealth(for:)`
- **MeetingBriefing** — Aggregates attendee profiles, recent interaction history, open action items, detected topics/signals, and shared contexts for meetings in the next 48 hours
- **FollowUpPrompt** — Identifies meetings ended in the past 48 hours with no linked note
- **RelationshipHealth** — Computed metrics: days since last interaction, 30d/90d counts, trend direction (increasing/stable/decreasing)
- Supporting types: `AttendeeProfile`, `InteractionRecord`, `ContactTrend`

### Awareness View
- **MeetingPrepSection** — Expandable briefing cards with attendee avatars, health dots, recent history, action items, topics, signals, shared contexts, and "Add Meeting Notes" button
- **FollowUpCoachSection** — Prompt cards with bold attendee names, relative time, pending action items, "Add Notes" / "Dismiss" actions
- **AwarenessView** — Both sections embedded after UnknownSenderTriageSection; refresh triggered on calendar sync completion

### PersonDetailView
- **RelationshipHealthView** — Shared view showing health dot, last interaction label, 30d/60d/90d frequency chips, and trend arrow
- Added as first section in `samDataSections`

### Files
- **New**: `MeetingPrepCoordinator.swift`, `MeetingPrepSection.swift`, `FollowUpCoachSection.swift`
- **Modified**: `SAMModels.swift`, `EvidenceRepository.swift`, `AwarenessView.swift`, `PersonDetailView.swift`

---

## February 17, 2026 - Phase J (Part 3b) Complete: Marketing Detection + Triage Fixes

**What Changed** — Marketing sender auto-detection, AppleScript header access fix, triage UI persistence fix, and triage section rendering fix:

### Marketing Detection (Headers Only — No Body Required)

- **MailService.swift** — Replaced broken `headers of msg` AppleScript call (returned a list of header objects, not a string) with direct per-header lookups using `content of header "HeaderName" of msg`. Checks three RFC-standard indicators:
  - `List-Unsubscribe` (RFC 2369) — present on virtually all commercial mailing lists
  - `List-ID` (RFC 2919) — mailing list manager identifier
  - `Precedence: bulk` or `Precedence: list` — bulk / automated sending indicator
- AppleScript now returns a 0/1 integer per message (`msgMarketing` list) instead of raw header strings. Swift side reads the integer directly — no string parsing needed.
- **MessageMeta** — Added `isLikelyMarketing: Bool` field, populated from marketing flag during Phase 1 sweep (before any body fetches).

### Data Layer

- **SAMModels-UnknownSender.swift** — Added `isLikelyMarketing: Bool` property (defaults to `false` for existing records on first migration).
- **UnknownSenderRepository.bulkRecordUnknownSenders()** — Updated signature to accept `isLikelyMarketing: Bool`. Sets on new records; upgrades existing records to `true` if any subsequent email has marketing headers (never clears once set).
- **MailImportCoordinator.swift** — Updated `senderData` mapping to include `meta.isLikelyMarketing`.
- **CalendarImportCoordinator.swift** — Updated call site with `isLikelyMarketing: false` (calendar attendees are never marketing senders).

### Triage UI

- **UnknownSenderTriageSection.swift** — Three fixes:
  1. **Marketing grouping**: Added `regularSenders` and `marketingSenders` computed properties. Marketing senders default to `.never`, personal/business senders default to `.notNow`. Two-section layout with "Mailing Lists & Marketing" subsection.
  2. **"Not Now" persistence**: Senders marked "Not Now" are now left as `.pending` in the database (previously marked `.dismissed` which removed them). They persist in the triage section across tab switches and app restarts until the user explicitly chooses "Add" or "Never".
  3. **Rendering fix**: Replaced `Group { content }` wrapper with always-present `VStack` container. The `Group` + `@ViewBuilder` + conditional content pattern failed to re-render when `@State` changed via `.task` after `NavigationSplitView` structural swap.

### Bug Fixes

- **AppleScript `headers of msg` bug**: Mail.app's `headers of msg` returns a list of header objects, not a raw string. The `try/end try` block silently caught the error, `theHeaders` stayed `""`, and `isMarketingEmail("")` always returned `false`. Fixed by checking specific headers individually via `content of header "List-Unsubscribe" of msg` etc.
- **Triage section disappearing on tab switch**: `NavigationSplitView` structural swap destroyed and recreated `AwarenessView`, but `Group`-wrapped conditional content didn't re-render when `@State` updated via `.task`. Fixed with always-present `VStack` container.
- **"Not Now" senders vanishing after Done**: Clicking Done dismissed all "Not Now" senders from the database, so they never reappeared. Now only "Add" and "Never" choices are persisted; "Not Now" senders remain `.pending`.

**Files Modified**:
| # | File | Action |
|---|------|--------|
| 1 | `Services/MailService.swift` | Fixed AppleScript header access (per-header lookup instead of `headers of msg`), returns 0/1 marketing flag |
| 2 | `Models/SAMModels-UnknownSender.swift` | Added `isLikelyMarketing: Bool` property + init param |
| 3 | `Repositories/UnknownSenderRepository.swift` | Updated `bulkRecordUnknownSenders` signature, sticky upgrade logic |
| 4 | `Coordinators/MailImportCoordinator.swift` | Pass `isLikelyMarketing` through senderData mapping |
| 5 | `Coordinators/CalendarImportCoordinator.swift` | Updated call site (`isLikelyMarketing: false`) |
| 6 | `Views/Awareness/UnknownSenderTriageSection.swift` | Two-group UI, "Not Now" persistence, Group→VStack rendering fix |

**Build & Test Status**:
- ✅ Build succeeds (0 errors)

---

## February 14, 2026 - Phase J (Part 3a) Complete: "Me" Contact + Email Integration UX

**What Changed** — Implemented "Me" contact identification and reworked email onboarding/settings UX:

### Me Contact Identification (Part A)
- **ContactsService.swift** — Replaced `fetchMeContact()` stub with real implementation using `CNContactStore.unifiedMeContactWithKeys(toFetch:)`
- **SAMModels.swift** — Added `isMe: Bool = false` to `SamPerson` model and updated initializer
- **PeopleRepository.swift** — Added `fetchMe()` (predicate query) and `upsertMe(contact:)` with uniqueness enforcement (clears existing `isMe` flags before setting new one)
- **ContactsImportCoordinator.swift** — After every group bulk upsert, fetches and upserts the Me contact (imported even if not in the SAM contacts group)

### Email Integration UX Tweaks (Part B)
- **MailSettingsView.swift** — Replaced free-text "Inbox Filters" section with toggle list driven by Me contact's `emailAliases`. Uses `PeopleRepository.shared.fetchMe()` loaded in `.task`. Shows explanatory messages when no Me card or no emails exist.
- **OnboardingView.swift** — Major rework of mail permission step:
  - Added `mailAddressSelection` step to `OnboardingStep` enum
  - Mail step footer now uses **Skip** + **Enable Email** button pair (replaces old inline Enable button + Next)
  - Enable button greyed out with explanatory note when no Me card exists in Contacts
  - After mail authorization succeeds, auto-advances to email address selection sub-step
  - All Me emails selected by default; user can toggle individual addresses
  - Selected addresses become `MailFilterRule` entries via `applyMailFilterRules()`
  - Back navigation from `.complete` goes to `.mailAddressSelection` (if mail enabled) or `.mailPermission` (if skipped)

### Bug Fix
- **MailSettingsView.swift** — Fixed `@Query(filter: #Predicate<SamPerson> { $0.isMe == true })` not filtering correctly (SwiftData Bool predicate returned all records). Replaced with explicit `PeopleRepository.shared.fetchMe()` call.

**Architecture Decision — Repository fetch over @Query for Me contact**:
- `@Query` with Bool predicates can silently return unfiltered results in SwiftData
- Explicit `PeopleRepository.fetchMe()` is reliable and consistent with onboarding approach
- `@Query` is still preferred for list views where reactive updates are needed

**Files Modified**:
| # | File | Action |
|---|------|--------|
| 1 | `Services/ContactsService.swift` | Implemented `fetchMeContact()` with `unifiedMeContactWithKeys` |
| 2 | `Models/SAMModels.swift` | Added `isMe: Bool = false` to SamPerson + init |
| 3 | `Repositories/PeopleRepository.swift` | Added `fetchMe()` and `upsertMe(contact:)` |
| 4 | `Coordinators/ContactsImportCoordinator.swift` | Import Me contact after group import |
| 5 | `Views/Settings/MailSettingsView.swift` | Replaced free-text filters with Me email toggles |
| 6 | `Models/DTOs/OnboardingView.swift` | Reworked mail step: Skip/Enable, Me prerequisite, address selection |

**Build & Test Status**:
- Build succeeds (0 errors)

---

## February 14, 2026 - Phase J (Part 2) Complete: Mail.app AppleScript Integration

**What Changed** — Replaced IMAP stubs with working Mail.app AppleScript bridge:
- ✅ **MailService.swift** (REWRITTEN) — NSAppleScript-based Mail.app bridge with `checkAccess()`, `fetchAccounts()`, `fetchEmails()`. Bulk metadata sweep + per-message body fetch. Performance-optimized parallel array access pattern.
- ✅ **MailImportCoordinator.swift** (REWRITTEN) — Removed IMAP config (host/port/username), KeychainHelper usage, testConnection/saveCredentials/removeCredentials. Added `selectedAccountIDs`, `availableAccounts`, `loadAccounts()`, `checkMailAccess()`. Fixed pruning safety (only prune if fetch returned results).
- ✅ **MailSettingsView.swift** (REWRITTEN) — Replaced IMAP credential fields with Mail.app account picker (toggle checkboxes per account). Shows access errors. Loads accounts on appear.
- ✅ **EmailAnalysisService.swift** (BUG FIXES) — Fixed EntityKind rawValue mapping ("financial_instrument" → `.financialInstrument` via explicit switch). Fixed Swift 6 Codable isolation warning (`nonisolated` on private LLM response structs).
- ✅ **SAM_crm.entitlements** — Added `com.apple.security.temporary-exception.apple-events` for `com.apple.mail`
- ✅ **Info.plist** — Added `NSAppleEventsUsageDescription`
- ✅ **KeychainHelper.swift** (DELETED) — No longer needed; Mail.app manages its own credentials
- ✅ **MailAccountDTO** — New lightweight struct for Settings UI account picker

**Architecture Decision — Mail.app over IMAP**:
- SAM's philosophy is "observe Apple apps, don't replace them" — Mail.app AppleScript aligns with Contacts/Calendar pattern
- Zero credential friction (Mail.app already has user's accounts)
- No SwiftNIO dependency or MIME parsing needed
- Sandbox workaround: `com.apple.security.temporary-exception.apple-events` entitlement (acceptable for non-App Store app)

**Build & Test Status**:
- ✅ Build succeeds (0 errors, 0 warnings)
- ✅ All tests pass

---

## February 13, 2026 - Phase J (Part 1) Complete: Email Integration

**What Changed**:
- ✅ **MailService.swift** (167 lines) - Actor-isolated IMAP client (placeholder stubs for SwiftNIO implementation)
- ✅ **EmailAnalysisService.swift** (165 lines) - Actor-isolated on-device LLM analysis via Apple Foundation Models
- ✅ **EmailDTO.swift** (32 lines) - Sendable email message wrapper
- ✅ **EmailAnalysisDTO.swift** (59 lines) - Sendable LLM analysis results (summary, entities, topics, temporal events, sentiment)
- ✅ **MailImportCoordinator.swift** (224 lines) - @MainActor @Observable coordinator (standard pattern)
- ✅ **KeychainHelper.swift** (59 lines) - Secure IMAP password storage using macOS Keychain API
- ✅ **MailFilterRule.swift** (31 lines) - Sender filtering rules (address/domain suffix matching)
- ✅ **MailSettingsView.swift** (208 lines) - SwiftUI IMAP configuration UI with connection testing
- ✅ **EvidenceRepository.swift** - Added `bulkUpsertEmails()` and `pruneMailOrphans()` methods
- ✅ **SettingsView.swift** - Added Mail tab to settings with MailSettingsView integration
- ✅ **SAMApp.swift** - Wired MailImportCoordinator into import triggers and Debug menu

**Architecture**:
- Email evidence items use `EvidenceSource.mail` with `sourceUID: "mail:<messageID>"`
- Raw email bodies never stored (CLAUDE.md policy) — only LLM summaries and analysis artifacts
- Participant resolution reuses existing email canonicalization and contact matching logic
- UserDefaults-backed settings with `@ObservationIgnored` computed properties (avoids @Observable conflict)
- On-device processing only (Foundation Models), no data leaves device

**API Pattern Established**:
- **Services**: MailService and EmailAnalysisService follow actor pattern with Sendable DTOs
- **Coordinator**: MailImportCoordinator follows standard ImportStatus pattern (consistent with CalendarImportCoordinator)
- **DTOs**: EmailDTO includes sourceUID, allParticipantEmails helpers; EmailAnalysisDTO captures LLM extraction results

**Files Modified**:
- `EvidenceRepository.swift` — Added bulk upsert and pruning for email evidence
- `SettingsView.swift` — Integrated Mail tab
- `SAMApp.swift` — Added mail import trigger and Debug menu reset

**Build & Test Status**:
- ✅ Build succeeds (0 errors, 6 warnings from pre-existing code)
- ✅ All 67 unit tests pass (no regressions)
- ✅ No compilation errors after fixing duplicate enum declarations and actor isolation issues

**Known Limitations**:
- MailService.testConnection() and .fetchEmails() use placeholder stubs (SwiftNIO IMAP implementation deferred)
- Requires manual SPM dependency addition: `swift-nio-imap` from Apple
- No onboarding integration yet (Phase J Part 2)

**Why It Matters**:
- Establishes third data source (after Calendar and Contacts)
- Proves on-device LLM analysis architecture works with Foundation Models
- Email is critical evidence for relationship management (communication history)
- Sets pattern for future integrations (iMessage, Teams, Zoom)

**Testing Outcome**:
- ✅ Coordinator properly wired in SAMApp
- ✅ Settings UI displays all IMAP configuration options
- ✅ Filter rules (sender address/domain) correctly implemented
- ✅ Keychain integration follows Security.framework best practices
- ✅ No permission dialogs (Keychain access is implicit)

---

## February 12, 2026 - Documentation Review & Reconciliation

**What Changed**:
- 📝 Reconciled `context.md` with actual codebase — phases E through I were all complete but context.md still listed them as "NOT STARTED"
- 📝 Updated project structure in context.md to reflect all actual files (SAMModels-Notes.swift, SAMModels-Supporting.swift, NoteAnalysisService.swift, NoteAnalysisCoordinator.swift, InsightGenerator.swift, DevLogStore.swift, NoteAnalysisDTO.swift, OnboardingView.swift, NoteEditorView.swift, NoteActionItemsView.swift, etc.)
- 📝 Added missing Phase E and Phase F changelog entries (below)
- 📝 Updated "Next Steps" to reflect actual current state: Phase J (polish, bug fixes, hardening)
- 📝 Documented known bugs: calendar participant matching, debug statement cleanup needed
- 📝 Updated coordinator API standards status (NoteAnalysisCoordinator, InsightGenerator now follow standard)
- 📝 Updated SamEvidenceItem model docs to match actual implementation (EvidenceSource enum, participantHints, signals)
- 📝 Updated document version to 4.0

**Known Bugs Documented**:
- Calendar participant matching: no participant is ever identified as "Not in Contacts" even when they should be
- Email matching recently adjusted to check all known addresses (emailCache + emailAliases) rather than just the first one, but participant identification issue persists

**Cleanup Identified**:
- ~200+ debug print statements across codebase (heaviest in SAMApp, ContactsService, EvidenceRepository, PeopleRepository)
- ContactsImportCoordinator still uses older API pattern (needs standardization)
- CalendarService uses print() while ContactsService uses Logger (inconsistent)
- Debug utilities (ContactsTestView, ContactValidationDebugView) should be excluded from production

---

## February 11, 2026 - Phase E Complete: Calendar & Evidence

**What Changed**:
- ✅ **CalendarService.swift** - Actor-isolated EKEventStore access, returns EventDTO
- ✅ **EventDTO.swift** - Sendable EKEvent wrapper with AttendeeDTO, participant resolution helpers
- ✅ **CalendarImportCoordinator.swift** - Standard coordinator pattern (ImportStatus enum, importNow async, debouncing)
- ✅ **EvidenceRepository.swift** - Full CRUD with bulk upsert, email resolution, orphan pruning, participant re-resolution
- ✅ **OnboardingView.swift** - First-run permission flow for Contacts + Calendar
- ✅ **Calendar permission flow** - Integrated into PermissionsManager and Settings

### Key Features

**CalendarService** provides:
- Fetch calendars, find by title/ID
- Fetch events in date range (default: 30 days back + 90 days forward)
- Single event fetch, calendar creation
- Change notification observation
- Auth checking before every operation

**EvidenceRepository** provides:
- Idempotent upsert by sourceUID (no duplicates)
- Bulk upsert with email-based participant resolution (matches attendee emails to SamPerson)
- Orphan pruning (removes evidence for deleted calendar events)
- Re-resolution of participants for previously unlinked evidence
- Triage state management (needsReview ↔ done)

**CalendarImportCoordinator** provides:
- Standard coordinator API (ImportStatus, importNow, lastImportedAt)
- Defers import while contacts import is in progress (ensures contacts imported first)
- Configurable debouncing interval
- Auto-triggers InsightGenerator after import
- Settings persistence (auto-import, calendar selection, import interval)

### Architecture Decisions
- Events become SamEvidenceItem with source = .calendar
- ParticipantHints store attendee info for deferred email resolution
- Calendar import waits for contacts to be imported first (sequential dependency)
- Orphan pruning removes evidence for events deleted from calendar

---

## February 11, 2026 - Phase F Complete: Inbox UI

**What Changed**:
- ✅ **InboxListView.swift** - Evidence triage list with filter/search
- ✅ **InboxDetailView.swift** - Evidence detail with triage actions, note attachment
- ✅ **AppShellView.swift** - Three-column layout for inbox (sidebar → list → detail)

### Key Features

**InboxListView** provides:
- Filter by triage state (Needs Review, Done, All)
- Search functionality
- Import status badge and "Import Now" button
- Context-aware empty states
- Selection binding for detail view

**InboxDetailView** provides:
- Evidence header (title, source badge, triage state, date)
- Content sections: snippet, participants, signals, linked people/contexts, metadata
- Triage toggle (needs review ↔ done)
- "Attach Note" button (opens NoteEditorView as sheet)
- Delete with confirmation dialog
- Source-specific icons and colors

### Architecture Patterns
- Three-column navigation: sidebar → InboxListView → InboxDetailView
- InboxDetailContainer uses @Query to fetch evidence by UUID (stable model access)
- UUID-based selection binding (not model references)
- Evidence triage is two-state: needsReview and done

---

## February 11, 2026 - Phase I Complete: Insights & Awareness

**What Changed**:
- ✅ **InsightGenerator** - Coordinator that generates insights from notes, relationships, calendar
- ✅ **AwarenessView** - Dashboard with filtering, triage, real-time generation
- ✅ **Real data wiring** - Replaced mock data with actual insight generation
- ✅ **Three insight sources** - Note action items, relationship patterns, calendar prep

**See**: `PHASE_I_COMPLETE.md` and `PHASE_I_WIRING_COMPLETE.md` for full details

### Key Features

**InsightGenerator** creates insights from:
1. Note action items (from Phase H LLM extraction)
2. Relationship patterns (people with no contact in 60+ days)
3. Upcoming calendar events (0-2 days away preparation reminders)

**AwarenessView** provides:
- Filter by category (All/High Priority/Follow-ups/Opportunities/Risks)
- Expandable insight cards with full details
- Triage actions (Mark Done, Dismiss, View Person)
- Quick stats dashboard (high priority count, follow-ups, opportunities)
- Empty state with friendly guidance
- Real-time generation button

### Architecture Decisions

- **In-memory insights**: Not persisted to SwiftData yet (Phase J+)
- **Deduplication**: Same person + same kind within 24 hours = duplicate
- **Priority sorting**: High → Medium → Low, then by creation date
- **Configurable thresholds**: Days-since-contact setting (default 60)

### What's Next

- Auto-generation triggers (after imports, on schedule)
- Person navigation (make "View Person" button work)
- Persistence (store in SamInsight model for history)

---

## February 11, 2026 - Phase H Complete: Notes & Note Intelligence

**What Changed**:
- ✅ **NotesRepository** - Full CRUD with analysis storage
- ✅ **NoteAnalysisService** - On-device LLM via Apple Foundation Models
- ✅ **NoteAnalysisCoordinator** - save → analyze → store pipeline
- ✅ **NoteEditorView** - Create/edit notes with entity linking
- ✅ **NoteActionItemsView** - Review extracted action items
- ✅ **Evidence pipeline** - Notes create evidence items (appear in Inbox)

**See**: `PHASE_H_COMPLETE.md` for full implementation details

### Key Features

**On-Device LLM Analysis** extracts:
- People mentioned with roles and relationships
- Contact field updates (birthdays, job titles, family members)
- Action items with urgency and suggested text
- Topics (financial products, life events)
- 1-2 sentence summaries

**User Experience**:
- Notes save instantly (sheet closes immediately)
- Analysis happens in background (3-4 seconds)
- Results appear automatically via SwiftData observation
- Notes show in PersonDetailView, ContextDetailView, and Inbox

### Bug Fixes During Implementation

1. **LLM JSON Parsing**: Fixed markdown code block stripping (backticks)
2. **SwiftData Context Violations**: Fixed NotesRepository creating multiple contexts
3. **ModelContext Boundaries**: Pass IDs between repositories, not objects
4. **NoteAnalysisCoordinator**: Fixed evidence creation context violations

### Files Created

- NotesRepository.swift (226 lines)
- NoteAnalysisService.swift (239 lines)
- NoteAnalysisCoordinator.swift (251 lines)
- NoteAnalysisDTO.swift (118 lines)
- NoteEditorView.swift (400 lines)
- NoteActionItemsView.swift (362 lines)

### Files Modified

- SAMApp.swift (added NotesRepository configuration)
- PersonDetailView.swift (added Notes section)
- ContextDetailView.swift (added Notes section)
- InboxDetailView.swift (added "Attach Note" button)

---

## February 11, 2026 - Phase G Complete: Contexts

**What Changed**:
- ✅ **ContextsRepository** - Full CRUD for SamContext with participant management
- ✅ **ContextListView** - List, filter (household/business), search, create contexts
- ✅ **ContextDetailView** - View/edit contexts, add participants with roles
- ✅ **Three-column layout** - Contexts integrated into AppShellView navigation
- ✅ **Feature complete** - Users can organize people into households and businesses

### Implementation Details

**New Files Created**:
1. **ContextsRepository.swift** (228 lines)
   - `fetchAll()`, `fetch(id:)`, `create()`, `update()`, `delete()`
   - `search(query:)`, `filter(by:)` for finding contexts
   - `addParticipant()`, `removeParticipant()` for managing membership
   - Follows same pattern as PeopleRepository and EvidenceRepository

2. **ContextListView.swift** (370 lines)
   - Filter picker (All / Household / Business)
   - Search functionality
   - Create context sheet with name and type selection
   - Empty state with call-to-action
   - ContextRowView showing icon, name, participant count, alerts

3. **ContextDetailView.swift** (520 lines)
   - Header with context icon, name, type, participant count
   - Participants section showing photo, name, roles, primary flag, notes
   - Edit context sheet (name and type)
   - Add participant sheet (select person, assign roles, mark as primary)
   - Delete confirmation dialog
   - Metadata section with context ID and type

**Files Modified**:
- `AppShellView.swift`:
  - Added `selectedContextID: UUID?` state
  - Updated `body` to include "contexts" in three-column layout condition
  - Added `ContextListView` to `threeColumnContent`
  - Added `contextsDetailView` to `threeColumnDetail`
  - Created `ContextsDetailContainer` helper view
  - Removed `ContextsPlaceholder` (no longer needed)

- `SAMApp.swift`:
  - Added `ContextsRepository.shared.configure(container:)` to `configureDataLayer()`

- `SettingsView.swift`:
  - Updated feature status: "Contexts" → `.complete`
  - Updated version string: "Phase G Complete"

- `context.md`:
  - Updated last modified date
  - Moved Phase G from "Next Up" to "Completed Phases"
  - Updated project structure to show ContextsRepository as complete
  - Updated Views section to show Context views as complete
  - Added Phase G completion details

### Architecture Patterns

**Followed Established Patterns**:
- ✅ Repository singleton with `configure(container:)` at app launch
- ✅ Three-column navigation (sidebar → list → detail)
- ✅ @Query in detail container views for stable model access
- ✅ UUID-based selection binding (not model references)
- ✅ Loading, empty, and error states in list view
- ✅ Filter and search with `@State` and `onChange`
- ✅ Sheet-based creation/editing flows
- ✅ Confirmation dialogs for destructive actions

**ContextKind Extensions**:
```swift
extension ContextKind {
    var displayName: String  // "Household", "Business"
    var icon: String         // "house.fill", "building.2.fill"
    var color: Color         // .blue, .purple
}
```

**Participant Management**:
- Participations link people to contexts with roles
- Roles are string arrays (e.g., ["Client", "Primary Insured"])
- Primary flag determines sort order and layout
- Optional notes field for context-specific annotations

### What This Enables

**Immediate Value**:
- Organize people into households (Smith Family, Johnson Household)
- Track business relationships (Acme Corp, local referral partners)
- Assign roles within contexts (Primary Insured, Spouse, Decision Maker)
- Mark primary participants for prioritized display
- Add context-specific notes (e.g., "Consent must be provided by guardian")

**Future Phases Unblocked**:
- **Phase H (Notes)**: Notes can link to contexts as well as people
- **Phase I (Insights)**: AI can generate household-level insights (e.g., "Smith family has coverage gap")
- **Phase K (Time Tracking)**: Track time spent on context-level activities
- **Products**: When product management is added, products can belong to contexts

### User Experience Flow

1. **Create Context**:
   - Click "+" in toolbar → "New Context" sheet
   - Enter name (e.g., "Smith Family")
   - Select type (Household or Business)
   - Click "Create"

2. **Add Participants**:
   - Open context detail
   - Click "Add Person" → select from available people
   - Assign roles (comma-separated, e.g., "Client, Primary Insured")
   - Toggle "Primary participant" if needed
   - Add optional note
   - Click "Add"

3. **View Participants**:
   - Each participant shows photo, name, roles, and primary badge
   - Notes appear in italic below name
   - Easy to scan who's in each context

4. **Filter & Search**:
   - Filter picker: All / Household / Business
   - Search bar finds contexts by name
   - Empty state when no results

### Testing Notes

**Previews Added**:
- `ContextListView`: "With Contexts" and "Empty" states
- `ContextDetailView`: "Household with Participants" and "Business Context"
- Both previews set up sample data for visual testing

**Manual Testing**:
1. ✅ Create household context
2. ✅ Create business context
3. ✅ Add participants to context
4. ✅ Edit context name/type
5. ✅ Remove participant
6. ✅ Delete context
7. ✅ Filter by kind
8. ✅ Search by name
9. ✅ Navigation between list and detail

### Next Steps

**Phase H: Notes & Note Intelligence**
- User-created notes (freeform text)
- Link notes to people, contexts, and evidence
- On-device LLM analysis with Foundation Models
- Extract people, topics, action items
- Generate summaries
- Suggest contact updates

**Phase H Will Enable**:
- "Met with John and Sarah Smith. New baby Emma born Jan 15..." → Extract Emma as new person, suggest adding to contacts
- "Bob's daughter graduating college in May. Send card." → Create action item
- "Annual review with the Garcias. Updated risk tolerance to conservative." → Generate insight

---

## February 10, 2026 - Critical Fixes: Notes Entitlement & Permission Race Condition

**What Changed**:
- 🔒 **Removed Contact Notes Access** (requires Apple entitlement approval)
- 🏁 **Fixed Permission Check Race Condition** at app startup
- 🎨 **Enhanced PersonDetailView** to show all contact fields

### Notes Entitlement Issue

**Problem**: Attempting to read `CNContactNoteKey` without the Notes entitlement causes Contacts framework to fail silently or return incomplete data.

**Files Modified**:
- `ContactDTO.swift`:
  - Commented out `note: String` property (line 27-28)
  - Removed `CNContactNoteKey` from `.detail` and `.full` key sets (lines 197, 217)
  - Added comments explaining Notes entitlement requirement
  
**Impact**: PersonDetailView can now successfully fetch and display all contact information except notes. Notes functionality will be implemented via `SamNote` (app's own notes) in Phase J.

**Log Evidence**: "Attempt to read notes by an unentitled app" error eliminated.

### Permission Race Condition

**Problem**: At app startup, the UI rendered immediately while permission checks ran asynchronously in the background. This caused:
1. User could click on people in the list
2. PersonDetailView would try to fetch contact details
3. Permission check hadn't completed yet → access denied error
4. Poor user experience with confusing error messages

**Sequence Before Fix**:
```
🚀 SAMApp init
📦 PeopleRepository initialized
📦 PeopleListView loads 6 people ← UI is interactive!
🔧 [Later] performInitialSetup checks permissions ← Too late!
⚠️ PersonDetailView: Not authorized ← User already clicked
```

**Files Modified**:
- `SAMApp.swift`:
  - Added `@State private var hasCheckedPermissions = false` to prevent re-runs
  - Renamed `performInitialSetup()` → `checkPermissionsAndSetup()`
  - Added guard to ensure check runs only once
  - Removed unnecessary `MainActor.run` and `Task` wrappers (already in async context)
  - Simplified permission check logic
  - Better logging with both enum names and raw values

**Sequence After Fix**:
```
🚀 SAMApp init
📦 Repositories initialized
🔧 checkPermissionsAndSetup() runs FIRST ← Before UI interaction
   ↓ If permissions missing → Shows onboarding sheet
   ↓ If permissions granted → Triggers imports
📦 PeopleListView loads (but user already went through onboarding if needed)
```

**Key Insight**: Even with `hasCompletedOnboarding = true`, permissions might not be granted (e.g., user manually set UserDefaults, permissions revoked in System Settings, app reinstalled). The fix detects this and automatically resets onboarding.

### PersonDetailView Enhancements

**Problem**: PersonDetailView was only showing basic fields (phone, email, organization) but not displaying all available contact data.

**Bug Fixed**:
- Email addresses only appeared if contact had **2 or more** emails (`count > 1` instead of `!isEmpty`)

**New Fields Added**:
- ✅ Postal addresses (with formatted display and copy button)
- ✅ URLs (with "open in browser" button)
- ✅ Social profiles (username, service, and link to profile)
- ✅ Instant message addresses (username and service)
- ✅ Contact relations (name and relationship label like "spouse", "manager", etc.)

**Enhanced Logging**:
```
✅ [PersonDetailView] Loaded contact: David Snyder
   - Phone numbers: 1
   - Email addresses: 1
   - Postal addresses: 1
   - URLs: 1
   - Social profiles: 0
   - Instant messages: 1
   - Relations: 3
   - Organization: 
   - Job title: Happily retired!
   - Birthday: No
```

**Why It Matters**:
- **Notes Issue**: Eliminates silent failures in contact fetching, ensuring reliable data display
- **Race Condition**: Prevents confusing "not authorized" errors when users interact with UI too quickly
- **Enhanced Details**: Provides complete contact information display, matching Apple Contacts app functionality
- **Better UX**: Smooth onboarding experience with no permission surprises

**Testing Outcome**:
- ✅ Onboarding sheet appears automatically when permissions missing
- ✅ No race condition errors in logs
- ✅ All contact fields display correctly
- ✅ No "attempt to read notes" errors
- ✅ Contact relations show properly with labels

---

## February 10, 2026 - Phase D Complete

**What Changed**:
- ✅ Created `PeopleListView.swift` - Full-featured list view for people
- ✅ Created `PersonDetailView.swift` - Comprehensive detail view with all relationships
- ✅ Updated `AppShellView.swift` - Replaced placeholder with real PeopleListView
- ✅ Fixed `ContactsImportCoordinator.swift` - Added `@ObservationIgnored` for computed UserDefaults properties
- ✅ First complete vertical slice from UI → Data Layer

**Bug Fixes**:
- Fixed ViewBuilder errors in Previews (removed explicit `return` statements)
- Fixed @Observable macro conflict with computed properties (added `@ObservationIgnored`)
  - Issue: @Observable tries to synthesize backing storage for computed properties
  - Solution: Mark UserDefaults-backed computed properties with `@ObservationIgnored`
- Fixed SamPerson initialization in PeopleRepository
  - Issue: SamPerson initializer requires `id`, `displayName`, and `roleBadges` parameters
  - Solution: Updated both `upsert()` and `bulkUpsert()` to provide all required parameters
  - New people get UUID auto-generated, empty roleBadges array by default
- Fixed Swift 6 predicate limitations in search
  - Issue: Swift predicates can't capture variables from outer scope in strict concurrency mode
  - Solution: Changed search to fetch all + in-memory filter (simpler and more maintainable)
- Fixed Preview model initializations
  - Issue: Previews used old initializer signatures for SamPerson, SamInsight, SamNote
  - Solution: Updated all previews to use correct model initializers with required parameters
  - Used proper InsightKind enum values (.followUpNeeded instead of non-existent .birthday)
- Fixed PersonDetailView to use correct SamInsight properties
  - Replaced deprecated `insight.title` → `insight.kind.rawValue`
  - Replaced deprecated `insight.body` → `insight.message`
  - Replaced deprecated `insight.insightType` → `insight.kind.rawValue`
  - Added confidence percentage display
- Fixed notes display
  - Temporarily hidden notes section until Phase J (SamPerson doesn't have inverse relationship to notes yet)
  - Notes link is via SamNote.linkedPeople, not person.notes

**UI Features Implemented**:
- **PeopleListView**:
  - NavigationSplitView with list/detail layout (macOS native pattern)
  - Search functionality (live search as you type)
  - Import status badge showing sync progress
  - "Import Now" manual refresh button
  - Empty state with call-to-action
  - Loading and error states
  - Person rows with photo thumbnails, badges, and alert counts
  
- **PersonDetailView**:
  - Full contact information display (phone, email, birthday, organization)
  - Role badges with Liquid Glass-style design
  - Alert counts for consent and review needs
  - Context participations (households/businesses)
  - Insurance coverages display
  - AI-generated insights display
  - User notes display
  - Sync metadata and archived contact warning
  - "Open in Contacts" button (opens Apple Contacts app)
  - Copy-to-clipboard for phone/email
  - FlowLayout for wrapping badges

**UX Patterns Applied** (per agent.md):
- ✅ Sidebar-based navigation
- ✅ Clean tags and badges for relationship types
- ✅ Non-modal interactions (no alerts, uses sheets)
- ✅ System-consistent design (SF Symbols, GroupBox, native controls)
- ✅ Keyboard navigation ready (NavigationSplitView)
- ✅ Dark Mode compatible

**Why It Matters**:
- First functional feature users can interact with
- Proves the architecture works end-to-end: ContactsService → ContactsImportCoordinator → PeopleRepository → SwiftData → Views
- Establishes UI patterns for all future features
- Shows proper separation of concerns (Views use DTOs, never raw CNContact)

**Testing Outcome**:
- Can view list of imported people
- Can search by name
- Can select person to see details
- Can manually trigger import
- No permission dialog surprises
- Previews work for both list and detail views

**Next Steps**:
- Phase E: Calendar & Evidence (implement CalendarService and evidence ingestion)

---

## February 10, 2026 - Documentation Restructure

**What Changed**:
- Moved all historical completion notes from `context.md` to this file
- Updated `context.md` to focus on current state and future roadmap
- Added new phases (J-M) for additional evidence sources and system features

**Why**:
- Keep `context.md` focused on "what's next" rather than "what happened"
- Provide stable historical reference for architectural decisions
- Separate concerns: changelog for history, context for current state

---

## February 9, 2026 - Phase C Complete

**What Changed**:
- ✅ Completed `PeopleRepository.swift` with full CRUD operations
- ✅ Rewrote `ContactsImportCoordinator.swift` following clean architecture
- ✅ Resolved `@Observable` + `@AppStorage` conflict using computed properties
- ✅ Wired up import coordinator in `SAMApp.swift`

**Why It Matters**:
- First complete vertical slice: ContactsService → ContactsImportCoordinator → PeopleRepository → SwiftData
- Proved the clean architecture pattern works end-to-end
- Established pattern for all future coordinators

**Migration Notes**:
- Old ContactsImportCoordinator used `@AppStorage` directly (caused synthesized storage collision)
- New version uses computed properties with manual `UserDefaults` access
- Pattern documented in `context.md` section 6.3

**Testing Outcome**:
- Contacts from "SAM" group successfully import into SwiftData
- No permission dialog surprises
- Import debouncing works correctly

---

## February 8-9, 2026 - Phase B Complete

**What Changed**:
- ✅ Created `ContactsService.swift` (actor-based, comprehensive CNContact API)
- ✅ Created `ContactDTO.swift` (Sendable wrapper for CNContact)
- ✅ Discovered and validated existing `PermissionsManager.swift` (already followed architecture)
- ✅ Migrated `ContactValidator` logic into `ContactsService`

**API Coverage**:
- Authorization checking (`authorizationStatus()`, never requests)
- Fetch operations (single contact, multiple contacts, group members)
- Search operations (by name)
- Validation (contact identifier existence)
- Group operations (list groups, fetch from group)

**Why It Matters**:
- Established the Services layer pattern for all external APIs
- Proved DTOs can safely cross actor boundaries
- Eliminated all direct CNContactStore access outside Services/
- No more permission dialog surprises

**Architecture Decisions**:
1. Services are `actor` (thread-safe)
2. Services return only Sendable DTOs
3. Services check authorization before every data access
4. Services never request authorization (Settings-only)
5. ContactDTO includes nested DTOs for all CNContact properties

**Testing Outcome**:
- Can fetch contacts and display photos without triggering permission dialogs
- ContactDTO successfully marshals all contact data across actor boundaries

---

## February 7, 2026 - Phase A Complete

**What Changed**:
- ✅ Created directory structure (App/, Services/, Coordinators/, Repositories/, Models/, Views/, Utilities/)
- ✅ Implemented `SAMModelContainer.swift` (singleton SwiftData container)
- ✅ Implemented `SAMApp.swift` (app entry point with proper initialization)
- ✅ Implemented `AppShellView.swift` (placeholder navigation shell)
- ✅ Defined all SwiftData models in `SAMModels.swift`:
  - `SamPerson` (contacts-anchored identity)
  - `SamContext` (households/businesses)
  - `SamEvidenceItem` (observations from Calendar/Contacts)
  - `SamInsight` (AI-generated insights)
  - `SamNote` (user notes)

**Why It Matters**:
- Established clean layered architecture from day one
- Prevented "spaghetti code" from old codebase
- Created foundation for strict separation of concerns

**Architecture Decisions**:
1. Apple Contacts = system of record for identity
2. SAM stores only `contactIdentifier` + cached display fields
3. Clean boundaries: Views → Coordinators → Services/Repositories → SwiftData/External APIs
4. DTOs for crossing actor boundaries (never raw CNContact/EKEvent)

**Testing Outcome**:
- App launches successfully
- Shows empty window with navigation structure
- SwiftData container initializes without errors

---

## February 6-7, 2026 - Old Code Archived

**What Changed**:
- Moved all previous code to `SAM_crm/SAM_crm/zzz_old_code/`
- Preserved old implementation as reference (DO NOT DELETE)
- Started clean rebuild from scratch

**Why**:
- Old codebase had architectural debt:
  - Views created CNContactStore instances (permission surprises)
  - Mixed concurrency patterns (Dispatch + async/await + Combine)
  - `nonisolated(unsafe)` escape hatches everywhere
  - No clear layer separation
- Faster to rebuild clean than refactor incrementally

**Migration Strategy**:
- Read old code to understand requirements
- Rewrite following clean architecture patterns
- Test new implementation thoroughly
- Keep old code as reference

---

## Pre-February 2026 - Original Implementation

**What Existed**:
- Working contact import from CNContactStore
- Basic SwiftUI views (PeopleListView, PersonDetailView)
- Settings UI with permission management
- ContactValidator utility for validation

**Why We Archived It**:
- Swift 6 strict concurrency violations
- Permission dialog surprises (views creating stores)
- Mixed architectural patterns
- Difficult to test and extend

**Lessons Learned**:
- Always check authorization before data access
- Use shared store instances (singleton pattern)
- Actor-isolate all external API access
- Never pass CNContact/EKEvent across actor boundaries
- `@Observable` + property wrappers = pain (use computed properties)

---

## Architecture Evolution

### Original Architecture (Pre-Rebuild)
```
Views → CNContactStore (DIRECT ACCESS ❌)
Views → ContactValidator → CNContactStore
Coordinators → Mixed patterns
```

**Problems**:
- Permission surprises
- Concurrency violations
- Hard to test
- Unclear responsibilities

### Clean Architecture (Current)
```
Views → Coordinators → Services → CNContactStore ✅
Views → Coordinators → Repositories → SwiftData ✅
      (DTOs only)   (DTOs only)
```

**Benefits**:
- No permission surprises (Services check auth)
- Swift 6 compliant (proper actor isolation)
- Testable (mock Services/Repositories)
- Clear responsibilities (each layer has one job)

---

## Key Architectural Decisions

### 1. Contacts-First Identity Strategy

**Decision**: Apple Contacts is the system of record for all identity data

**Rationale**:
- Users already manage contacts in Apple's app
- Family relationships, dates, contact info already stored
- SAM shouldn't duplicate what Apple does well
- Overlay CRM, not replacement

**Implementation**:
- `SamPerson.contactIdentifier` anchors to CNContact
- Cached display fields refreshed on sync
- SAM-owned data: roleBadges, alerts, participations, coverages, insights

### 2. Services Layer with DTOs

**Decision**: All external API access goes through actor-isolated Services that return Sendable DTOs

**Rationale**:
- Centralized authorization checking (no surprises)
- Thread-safe (actor isolation)
- Sendable DTOs cross actor boundaries safely
- Testable (mock service responses)

**Implementation**:
- `ContactsService` (actor) owns CNContactStore
- Returns `ContactDTO` (Sendable struct)
- Checks auth before every operation
- Never requests auth (Settings-only)

### 3. Coordinators for Business Logic

**Decision**: Coordinators orchestrate between Services and Repositories

**Rationale**:
- Views shouldn't contain business logic
- Services shouldn't know about SwiftData
- Repositories shouldn't call external APIs
- Coordinators bridge the gap

**Implementation**:
- `ContactsImportCoordinator` fetches from ContactsService, writes to PeopleRepository
- Manages debouncing, throttling, state machines
- Observable for SwiftUI binding

### 4. Repository Pattern for SwiftData

**Decision**: All SwiftData CRUD goes through `@MainActor` Repositories

**Rationale**:
- SwiftData requires MainActor
- Centralized data access patterns
- Easier to test (in-memory container)
- Clear separation from external APIs

**Implementation**:
- `PeopleRepository` manages SamPerson CRUD
- Accepts DTOs from coordinators
- Returns SwiftData models to views
- Singleton with container injection

### 5. Computed Properties for @Observable Settings

**Decision**: Never use `@AppStorage` with `@Observable` classes

**Rationale**:
- `@Observable` macro synthesizes backing storage (`_property`)
- `@AppStorage` also synthesizes backing storage (`_property`)
- Collision causes compile error

**Workaround**:
```swift
var setting: Bool {
    get { UserDefaults.standard.bool(forKey: "key") }
    set { UserDefaults.standard.set(newValue, forKey: "key") }
}
```

**Applies To**:
- ContactsImportCoordinator (autoImportEnabled, etc.)
- All future coordinators with persisted settings

---

## Testing Milestones

### Phase A Testing
- ✅ App launches without crashes
- ✅ SwiftData container initializes
- ✅ Navigation structure renders

### Phase B Testing
- ✅ ContactsService fetches contacts (with authorization)
- ✅ ContactDTO marshals all contact properties
- ✅ No permission dialogs during normal operation
- ✅ Validation correctly identifies invalid identifiers

### Phase C Testing
- ✅ PeopleRepository creates/updates SamPerson records
- ✅ Bulk upsert handles 100+ contacts efficiently
- ✅ Import coordinator triggers on system notifications
- ✅ Debouncing prevents redundant imports
- ✅ Settings persist across app launches

---

## Performance Benchmarks

### Phase C Import Performance
- **100 contacts**: < 2 seconds (bulk upsert)
- **1000 contacts**: ~15 seconds (bulk upsert)
- **Memory**: Stable, no leaks detected
- **CPU**: Peaks during import, returns to idle

**Optimization Notes**:
- Bulk upsert 10x faster than individual inserts
- Debouncing reduced redundant imports by 80%
- Lazy-loading contact photos improved UI responsiveness

---

## Known Issues (Resolved)

### Issue: Permission Dialog on First Launch
**Symptom**: App triggered permission dialog unexpectedly  
**Cause**: View created CNContactStore instance directly  
**Resolution**: Moved all CNContactStore access to ContactsService  
**Status**: ✅ Resolved in Phase B  

### Issue: @Observable + @AppStorage Compile Error
**Symptom**: "Declaration '_property' conflicts with previous declaration"  
**Cause**: Both macros synthesize backing storage  
**Resolution**: Use computed properties with manual UserDefaults  
**Status**: ✅ Resolved in Phase C  

### Issue: Slow Import Performance
**Symptom**: Importing 100 contacts took 20+ seconds  
**Cause**: Individual inserts instead of bulk upsert  
**Resolution**: Implemented `bulkUpsert` in PeopleRepository  
**Status**: ✅ Resolved in Phase C  

---

## Future Historical Entries

As phases complete, add entries here following this template:

```markdown
## [Date] - Phase X Complete

**What Changed**:
- ✅ List of completed tasks
- ✅ New files created
- ✅ Architecture patterns established

**Why It Matters**:
- Impact on overall architecture
- Problems solved
- Patterns established for future work

**Migration Notes**:
- Any breaking changes
- How old code was replaced
- Patterns to follow

**Testing Outcome**:
- What was verified
- Performance metrics
- Known limitations
```

---

---

## February 26, 2026 - Phase V: Business Intelligence — Strategic Coordinator (Schema SAM_v22)

### Overview
Implemented the RLM-inspired Strategic Coordinator: a Swift orchestrator that dispatches 4 specialist LLM analysts in parallel, synthesizes their outputs deterministically, and surfaces strategic recommendations via the Business Dashboard and Daily Briefings. All numerical computation stays in Swift; the LLM interprets and narrates. This is SAM's Layer 2 (Business Intelligence) — complementing the existing Layer 1 (Relationship Intelligence).

### New Models

**`StrategicDigest`** (@Model) — Persisted business intelligence output. Fields: `digestTypeRawValue` ("morning"/"evening"/"weekly"/"onDemand"), `pipelineSummary`, `timeSummary`, `patternInsights`, `contentSuggestions`, `strategicActions` (JSON array of StrategicRec), `rawJSON`, `feedbackJSON`. Transient `digestType: DigestType` computed property.

**`DigestType`** (enum) — `.morning`, `.evening`, `.weekly`, `.onDemand`.

### New DTOs

**`StrategicDigestDTO.swift`** — All specialist output types:
- `PipelineAnalysis` — healthSummary, recommendations, riskAlerts
- `TimeAnalysis` — balanceSummary, recommendations, imbalances
- `PatternAnalysis` — patterns (DiscoveredPattern), recommendations
- `ContentAnalysis` — topicSuggestions (ContentTopic)
- `StrategicRec` — title, rationale, priority (0-1), category, feedback
- `RecommendationFeedback` — .actedOn, .dismissed, .ignored
- `DiscoveredPattern` — description, confidence, dataPoints
- `ContentTopic` — topic, keyPoints, suggestedTone, complianceNotes
- Internal LLM response types for JSON parsing (LLMPipelineAnalysis, LLMTimeAnalysis, etc.)

### New Coordinator

**`StrategicCoordinator`** (`@MainActor @Observable`, singleton) — RLM orchestrator:
- `configure(container:)` — creates own ModelContext, loads latest digest
- `generateDigest(type:)` — gathers pre-aggregated data from PipelineTracker/TimeTrackingRepository/PeopleRepository/EvidenceRepository, dispatches 4 specialists via async/await, synthesizes results deterministically, persists StrategicDigest
- Data gathering: all deterministic Swift (<500 tokens per specialist). Pipeline data from PipelineTracker snapshot; time data from categoryBreakdown(7d/30d); pattern data from role distribution, interaction frequency, note quality, engagement gaps; content data from recent meeting topics + note analysis topics + seasonal context
- Synthesis: collects all StrategicRec from 4 specialists, applies feedback-based category weights (±10% based on 30-day acted/dismissed ratio), deduplicates by Jaccard title similarity (>0.6 threshold), caps at 7, sorts by priority descending
- Cache TTLs: pipeline=4h, time=12h, patterns=24h, content=24h
- `recordFeedback(recommendationID:feedback:)` — updates feedbackJSON on digest and strategicActions JSON
- `computeCategoryWeights()` — reads historical feedback from recent digests, adjusts per-category scoring weights
- `hasFreshDigest(maxAge:)` — cache freshness check for briefing integration

### New Services (4 Specialist Analysts)

All follow the same actor pattern: singleton, `checkAvailability()` guard, call `AIService.shared.generate()`, parse JSON via `extractJSON()` + `JSONDecoder`, fallback to plain text on parse failure.

**`PipelineAnalystService`** (actor) — System prompt: pipeline analyst for financial services practice. Analyzes funnel counts, conversion rates, velocity, stuck people, production metrics. Returns PipelineAnalysis (healthSummary, 2-3 recommendations, risk alerts).

**`TimeAnalystService`** (actor) — System prompt: time allocation analyst. Analyzes 7-day/30-day category breakdowns and role distribution. Returns TimeAnalysis (balanceSummary, 2-3 recommendations, imbalances). Benchmark: 40-60% client-facing time.

**`PatternDetectorService`** (actor) — System prompt: behavioral pattern detector. Analyzes interaction frequency by role, meeting note quality, engagement gaps, referral network. Returns PatternAnalysis (2-3 patterns with confidence/dataPoints, 1-2 recommendations).

**`ContentAdvisorService`** (actor) — System prompt: educational content advisor for WFG. Analyzes recent meeting/note topics and seasonal context. Returns ContentAnalysis (3-5 topic suggestions with key points, suggested tone, compliance notes).

### New Views

**`StrategicInsightsView`** — 4th tab in BusinessDashboardView:
- Status banner with relative time + Refresh button
- Strategic Actions section: recommendation cards with priority color dot, category badge, title/rationale, Act/Dismiss feedback buttons
- Pipeline Health / Time Balance / Patterns narrative sections with icons
- Content Ideas numbered list
- Empty state with lightbulb icon + instructions

### Modified Files

**`SAMModelContainer.swift`** — Added `StrategicDigest.self` to schema, bumped `SAM_v21` → `SAM_v22`.

**`SAMApp.swift`** — Added `StrategicCoordinator.shared.configure(container:)` in `configureDataLayer()`.

**`BusinessDashboardView.swift`** — Added "Strategic" as 4th segmented picker tab (tag 3), routes to `StrategicInsightsView(coordinator:)`. Toolbar refresh also triggers `strategic.generateDigest(type: .onDemand)` when on Strategic tab.

**`SAMModels-DailyBriefing.swift`** — Added `strategicHighlights: [BriefingAction]` field (default `[]`). Additive optional change — existing briefings remain valid.

**`DailyBriefingCoordinator.swift`** — Morning briefing: checks `strategicBriefingIntegration` UserDefaults toggle, triggers `StrategicCoordinator.generateDigest(type: .morning)` if no fresh digest (< 4h), pulls top 3 recommendations as `strategicHighlights` (BriefingAction with sourceKind "strategic"). Evening briefing: counts acted-on strategic recommendations, adds accomplishment if any.

**`CoachingSettingsView.swift`** — Added "Business Intelligence" section with two toggles: `strategicDigestEnabled` (default true, controls whether coordinator runs), `strategicBriefingIntegration` (default true, includes strategic highlights in daily briefing). Descriptive captions for each.

### Files Summary

| File | Action | Description |
|------|--------|-------------|
| `Models/SAMModels-Strategic.swift` | NEW | StrategicDigest @Model + DigestType enum |
| `Models/DTOs/StrategicDigestDTO.swift` | NEW | All specialist output DTOs + LLM response types |
| `Coordinators/StrategicCoordinator.swift` | NEW | RLM orchestrator |
| `Services/PipelineAnalystService.swift` | NEW | Pipeline health analyst |
| `Services/TimeAnalystService.swift` | NEW | Time allocation analyst |
| `Services/PatternDetectorService.swift` | NEW | Pattern detector |
| `Services/ContentAdvisorService.swift` | NEW | Content advisor |
| `Views/Business/StrategicInsightsView.swift` | NEW | Strategic dashboard tab |
| `App/SAMModelContainer.swift` | MODIFY | Schema v22, + StrategicDigest |
| `App/SAMApp.swift` | MODIFY | Configure StrategicCoordinator |
| `Views/Business/BusinessDashboardView.swift` | MODIFY | 4th "Strategic" tab |
| `Coordinators/DailyBriefingCoordinator.swift` | MODIFY | Briefing integration |
| `Models/SAMModels-DailyBriefing.swift` | MODIFY | + strategicHighlights field |
| `Views/Settings/CoachingSettingsView.swift` | MODIFY | Business Intelligence settings |

### Key Design Decisions
- **No new repository** — StrategicDigest is simple enough that StrategicCoordinator manages its own ModelContext (same pattern as DailyBriefingCoordinator with SamDailyBriefing)
- **Specialist prompts hardcoded initially** — Exposing prompts in Settings deferred to avoid UI complexity
- **Feedback is lightweight** — JSON field on StrategicDigest, not a separate model. Simple category-level weighting adjustment (±10%)
- **Cache TTLs** — Pipeline: 4h, Time: 12h, Patterns: 24h, Content: 24h. Stored as `lastAnalyzed` timestamps on coordinator

---

## February 26, 2026 - Phase X: Goal Setting & Decomposition (Schema SAM_v24)

### Overview
Phase X implements a business goal tracking system with 7 goal types that compute live progress from existing SAM data repositories — no redundant progress values stored. Goals are decomposed into adaptive pacing targets with pace indicators (ahead/on-track/behind/at-risk) and linear projected completion.

### New Models

**`BusinessGoal`** (@Model) — `id: UUID`, `goalTypeRawValue: String` (+ `@Transient goalType: GoalType`), `title: String`, `targetValue: Double`, `startDate: Date`, `endDate: Date`, `isActive: Bool`, `notes: String?`, `createdAt: Date`, `updatedAt: Date`. Progress computed live from existing repositories — no stored `currentValue`.

**`GoalType`** (enum, 7 cases) — `.newClients`, `.policiesSubmitted`, `.productionVolume`, `.recruiting`, `.meetingsHeld`, `.contentPosts`, `.deepWorkHours`. Each has `displayName`, `icon` (SF Symbol), `unit`, `isCurrency` (true only for `.productionVolume`).

**`GoalPace`** (enum, 4 cases) — `.ahead` (green), `.onTrack` (blue), `.behind` (orange), `.atRisk` (red). Each has `displayName` and `icon`.

### New Components

**`GoalRepository`** (@MainActor @Observable singleton) — `create(goalType:title:targetValue:startDate:endDate:notes:)`, `fetchActive()`, `fetchAll()`, `update(id:...)`, `archive(id:)`, `delete(id:)`.

**`GoalProgressEngine`** (@MainActor @Observable singleton) — Read-only; computes live progress from PipelineRepository (transitions), ProductionRepository (records + premium), EvidenceRepository (calendar events), ContentPostRepository (posts), TimeTrackingRepository (deep work hours). `GoalProgress` struct: `currentValue`, `targetValue`, `percentComplete`, `pace`, `dailyNeeded`, `weeklyNeeded`, `daysRemaining`, `projectedCompletion`. Pace thresholds: ratio-based (1.1+ ahead, 0.9–1.1 on-track, 0.5–0.9 behind, <0.5 at-risk).

**`GoalProgressView`** (SwiftUI) — 5th tab in BusinessDashboardView. Goal cards with progress bars, pace badges, pacing hints (adapts daily/weekly/monthly granularity), projected completion, edit/archive actions. Sheet for create/edit via GoalEntryForm.

**`GoalEntryForm`** (SwiftUI) — Type picker (dropdown with 7 GoalType icons), auto-title generation, target value field (currency prefix for production goals), date range pickers, optional notes. Frame: 450×520.

**`GoalPacingSection`** (SwiftUI) — Compact cards (up to 3) in AwarenessView Today's Focus group, prioritized by atRisk → behind → nearest deadline. Mini progress bars + pace badges.

### Components Modified

**`BusinessDashboardView.swift`** — Added 5th "Goals" tab (tag 4) rendering GoalProgressView.

**`AwarenessView.swift`** — Added GoalPacingSection to Today's Focus group.

**`DailyBriefingCoordinator.swift`** — `gatherWeeklyPriorities()` section 7: goal deadline warnings for goals ≤14 days remaining with behind/atRisk pace.

**`SAMModelContainer.swift`** — Schema bumped to SAM_v24, added `BusinessGoal.self` to allModels.

**`SAMApp.swift`** — Added `GoalRepository.shared.configure(container:)` in `configureDataLayer()`.

### Key Design Decisions
- **No stored progress** — current values computed live from existing repositories; avoids stale data
- **Soft archive** — `isActive` flag hides completed goals without data loss
- **Auto-title** — Pattern "[target] [type]" (e.g., "50 New Clients"), user-overridable
- **Linear pace calculation** — compares elapsed fraction vs. progress fraction; simple and transparent
- **7 goal types** — each maps to a specific repository query; covers all WFG business activities

---

## February 26, 2026 - Phase Y: Scenario Projections (No Schema Change)

### Overview
Phase Y adds deterministic linear projections based on trailing 90-day velocity across 5 business categories. Computes 3/6/12 month horizons with confidence bands (low/mid/high) and trend detection. Pure math — no AI calls, no data persistence.

### New Components

**`ScenarioProjectionEngine`** (@MainActor @Observable singleton) — `refresh()` computes all 5 projections from trailing 90 days, stores in `projections: [ScenarioProjection]`.

**Value types** (in ScenarioProjectionEngine.swift):
- `ProjectionCategory` enum (5 cases): `.clientPipeline` (green, person.badge.plus), `.recruiting` (teal, person.3.fill), `.revenue` (purple, dollarsign.circle.fill, isCurrency), `.meetings` (orange, calendar), `.content` (pink, text.bubble.fill).
- `ProjectionPoint` struct: `months` (3/6/12), `low`, `mid`, `high` confidence range.
- `ProjectionTrend` enum: `.accelerating`, `.steady`, `.decelerating`, `.insufficientData`.
- `ScenarioProjection` struct: `category`, `trailingMonthlyRate`, `points` (3 entries), `trend`, `hasEnoughData`.

**Computation**:
1. Bucket trailing 90 days into 3 monthly periods (0=oldest 60–90d, 1=30–60d, 2=recent 0–30d)
2. Per-category measurement: client transitions to "Client" stage, recruiting transitions to licensed/firstSale/producing, production annualPremium sum, calendar evidence count, content post count
3. Rate = mean of 3 buckets; stdev across buckets
4. Trend: compare bucket[2] vs avg(bucket[0], bucket[1]) — >1.15 accelerating, <0.85 decelerating, else steady
5. Confidence bands: mid = rate × months, band = max(stdev × sqrt(months), mid × 0.2), low = max(mid - band, 0)
6. `hasEnoughData` = true if ≥2 non-zero buckets

**`ScenarioProjectionsView`** (SwiftUI) — 2-column LazyVGrid of projection cards. Per card: category icon + name, trend badge (colored capsule with arrow + label), 3-column horizons (3mo/6mo/12mo with mid bold + low–high range), "Limited data" indicator. Currency formatting ($XK/$XM). Embedded at top of StrategicInsightsView.

### Components Modified

**`StrategicInsightsView.swift`** — Added `@State projectionEngine`, `ScenarioProjectionsView` as first section, `.task { projectionEngine.refresh() }`.

**`BusinessDashboardView.swift`** — Toolbar refresh calls `ScenarioProjectionEngine.shared.refresh()` when Strategic tab active.

**`DailyBriefingCoordinator.swift`** — `gatherWeeklyPriorities()` section 9: picks most notable projection (decelerating preferred, otherwise client pipeline), appends pace-check BriefingAction with `sourceKind: "projection"`. Only included if `hasEnoughData == true` and under priority cap.

### Key Design Decisions
- **90-day trailing only** — fixed window; simple and transparent
- **3 monthly buckets** — balances recency with data volume for trend detection
- **15% threshold** — captures meaningful trend changes without noise
- **Confidence as stdev-based bands** — wider for high variance; minimum 20% floor for small rates
- **No persistence** — computed on-demand; always fresh
- **Embedded in Strategic tab** — positioned before narrative summaries for immediate forward-looking context

### Files Summary

| File | Action |
|------|--------|
| `Coordinators/ScenarioProjectionEngine.swift` | NEW |
| `Views/Business/ScenarioProjectionsView.swift` | NEW |
| `Views/Business/StrategicInsightsView.swift` | MODIFY |
| `Views/Business/BusinessDashboardView.swift` | MODIFY |
| `Coordinators/DailyBriefingCoordinator.swift` | MODIFY |

---

## Role Deduction Engine + Graph Confirmation (March 4, 2026)

**Purpose**: Solve the cold-start problem where roles are 100% manual by auto-deducing roles from imported data and presenting suggestions for batch confirmation in the relationship graph.

**No schema change** — suggestions persisted to UserDefaults as JSON.

### New Files

**`Coordinators/RoleDeductionEngine.swift`** — `@MainActor @Observable` singleton. Deterministic scoring engine with 4 signal categories: calendar title keywords (max 40pts), calendar frequency patterns (max 25pts), communication volume (max 20pts), contact metadata (max 15pts). Threshold ≥40 to suggest. Batches suggestions by role in groups of 12. UserDefaults persistence. Public API: `deduceRoles()`, `confirmRole()`, `confirmBatch()`, `changeSuggestedRole()`, `dismissSuggestion()`, `dismissBatch()`, batch navigation.

**`Views/Business/RoleConfirmationBannerView.swift`** — Top-anchored `.regularMaterial` overlay on graph. Shows current role badge, people count, batch navigation chevrons, Confirm All / Skip Batch / Exit buttons, hint text.

### Modified Files

**`Coordinators/RelationshipGraphCoordinator.swift`** — Added `"roleConfirmation"` branch in `applyFilters()`: restricts visible nodes to current batch person IDs + Me node.

**`Views/Business/RelationshipGraphView.swift`** — `focusModeOverlay` branches on `"roleConfirmation"` vs `"deducedRelationships"`. Dashed ring in role color drawn around suggested nodes in `drawNodes()`. Tap handler intercepts node clicks in confirmation mode to show role picker popover (7 predefined roles + dismiss).

**`Coordinators/OutcomeEngine.swift`** — Scanner #12 `scanRoleSuggestions()`: creates `.outreach` outcome with `.reviewGraph` action lane when pending suggestions exist. Title-based dedup.

**`Views/Awareness/OutcomeQueueView.swift`** — `.reviewGraph` routing detects "suggested role" in title to use `"roleConfirmation"` focus mode instead of `"deducedRelationships"`.

**`Models/DTOs/OnboardingView.swift`** — New FeatureRow: "Identifying your clients, agents, and partners from your data". Post-import `triggerImports()` launches `RoleDeductionEngine.shared.deduceRoles()` after 5s delay.

### Scoring Heuristics Summary

| Category | Max Points | Signals |
|----------|-----------|---------|
| Calendar Title Keywords | 40 | Role-specific meeting title patterns |
| Calendar Frequency | 25 | Meeting cadence patterns (annual → Client, burst → Applicant, weekly → Agent) |
| Communication Volume | 20 | Interaction count and recency patterns |
| Contact Metadata | 15 | Job title, organization name, email domain |

Tiebreakers: Agent vs External Agent decided by training cadence (≤14d gap → Agent). Client vs Applicant decided by recency of process-titled meetings (all in last 60d → Applicant).

### Files Summary

| File | Action |
|------|--------|
| `Coordinators/RoleDeductionEngine.swift` | NEW |
| `Views/Business/RoleConfirmationBannerView.swift` | NEW |
| `Coordinators/RelationshipGraphCoordinator.swift` | MODIFY |
| `Views/Business/RelationshipGraphView.swift` | MODIFY |
| `Coordinators/OutcomeEngine.swift` | MODIFY |
| `Views/Awareness/OutcomeQueueView.swift` | MODIFY |
| `Models/DTOs/OnboardingView.swift` | MODIFY |

---

**Changelog Started**: February 10, 2026
**Maintained By**: Project team
**Related Docs**: See `context.md` for current state and roadmap
