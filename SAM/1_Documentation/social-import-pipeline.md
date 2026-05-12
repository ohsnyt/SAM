# Social Platform Import Pipeline

Detailed reference for SAM's reusable async-export auto-detection pipeline. The lean overview lives in `context.md` §5.

## Two-Track Model

**Track 1 — Data About the User**: Profile, career, skills, certifications → feeds `BusinessProfileService.contextFragment()` → injected into all AI specialist prompts. Stored as JSON in UserDefaults (`sam.{platform}Profile`).

**Track 2 — Data About Contacts**: Connections, messages, endorsements, recommendations → enriches contacts via `PendingEnrichment` + creates evidence via `EvidenceRepository`. Unmatched contacts go to `UnknownSenderRepository`.

## Architecture Pattern

```
{Platform}Service (actor)           → Pure parsing, returns Sendable DTOs
{Platform}ImportCoordinator (@MainActor @Observable) → Matching, dedup, persistence
Existing repositories               → No changes needed
```

Coordinator follows the standard `ImportStatus` pattern: idle → parsing → preview → importing → success/error.

## Contact Matching Priority

1. **Platform profile URL** — exact match, highest confidence
2. **Email address** — match via ContactsService
3. **Phone number** — match via SamPerson.phoneAliases
4. **Fuzzy display name** — last resort, flag for user review

## Key Rules

- Social imports create **standalone SamPerson** records (`contactIdentifier: nil`)
- Evidence dedup key: `{platform}:{identifier}:{timestamp}` stored in `sourceUID`
- Watermark-based incremental import (`sam.{platform}.lastImportDate` in UserDefaults)
- User profile (Track 1) always replaced wholesale — no watermark needed
- Touch scoring via `IntentionalTouch` model + `TouchScoringEngine.computeScores()`
- Long-running import flows live in **standalone Window scenes**, not main-window sheets — so a background-coordinator sheet (post-call capture, life-event prompt) cannot dismiss them mid-review. See `context.md` §8.

## Adding a New Platform

1. Request and inspect a real data export — verify actual column headers and formats
2. Classify every file as Track 1, Track 2, or discard
3. Define DTOs, create `{Platform}Service` actor, create coordinator
4. Integrate with existing `EnrichmentRepository`, `EvidenceRepository`, `UnknownSenderRepository`
4b. If the platform export includes the user's own posts/articles, implement voice analysis and store `writingVoiceSummary` in the platform DTO
5. Add a `Window` scene in `SAMApp.swift` with id `import-{platform}` and a notification (`samShow{Platform}ImportWindow`) observed by `AppShellView`'s `SocialImportWindowObservers`. Wire the `File → Import → {Platform}` menu item to post that notification.
6. If the platform's export is async (user requests → platform emails a download link), implement the auto-detection pipeline (below)

## Voice Analysis (Standard for All Platforms)

Every social platform import that captures the user's own content (posts, articles, share comments) should include a voice analysis step:

1. Collect 3–5 recent content samples from the user's posts/articles
2. Run AI voice analysis: "Analyze the writing voice and style..."
3. Store `writingVoiceSummary` in the platform's profile DTO
4. Include the voice summary in `coachingContextFragment()`
5. `ContentAdvisorService.generateDraft()` uses `buildVoiceBlock(for:)` to inject platform-appropriate voice matching into draft generation prompts

Cross-platform fallback: if a platform has no voice data, the draft generator uses voice data from any connected platform (preferring Substack > LinkedIn > Facebook), adapted for the target platform's tone.

Currently implemented for: **Substack** (article excerpts), **LinkedIn** (share comments), **Facebook** (user posts).

## Auto-Detection Import Pipeline

Many social platforms use an **asynchronous export** model: the user requests their data, the platform prepares it (minutes to hours), emails a download link, and the user downloads a ZIP/archive. SAM provides a reusable auto-detection pipeline for this pattern.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│              Import Window (SwiftUI)                    │
│  State machine driven by {Platform}SheetPhase enum      │
│  Phases: setup → scanning → zipFound → processing →     │
│          awaitingReview → complete                      │
│  Fallback: noZipFound → watchingEmail → emailFound →    │
│            watchingFile → (loops back to scanning)      │
└──────────┬──────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────┐
│         {Platform}ImportCoordinator                     │
│  beginImportFlow()     — routes by config state         │
│  scanDownloadsFolder() — ~/Downloads pattern match      │
│  processZip(url:)      — unzip + parse + match          │
│  startEmailWatcher()   — 5-min Mail.app polling         │
│  startFileWatcher()    — 30s ~/Downloads polling        │
│  scheduleReminder()    — calendar-gap-aware reschedule  │
│  resumeWatchersIfNeeded() — persist across app restart  │
└──────────┬──────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────┐
│         SystemNotificationService                       │
│  {PLATFORM}_EXPORT notification category                │
│  "Open Export Page" action → opens URL + file watcher   │
│  "Remind Me Later" action → free-calendar-gap reschedule│
└─────────────────────────────────────────────────────────┘
```

### Phase State Machine

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

### Prerequisites

- **Entitlement**: `com.apple.security.files.downloads.read-write` — required for real ~/Downloads access (sandbox returns container otherwise). Already added; benefits all platforms.
- **Mail access**: Email watcher requires `MailImportCoordinator.shared.mailEnabled` and configured accounts. Graceful fallback when unavailable.

### Implemented Platforms

| Platform | File Pattern | Email Sender | Window | Coordinator |
|----------|-------------|--------------|--------|-------------|
| Substack | `substack-*.zip` | `substack.com` | `import-substack` | `SubstackImportCoordinator` |
| LinkedIn | `Complete_LinkedInDataExport_*.zip`, `Basic_LinkedInDataExport_*.zip` | `linkedin.com` | `import-linkedin` | `LinkedInImportCoordinator` |
| Facebook | `*facebook*.zip` (case-insensitive) | `facebook.com`, `facebookmail.com` | `import-facebook` | `FacebookImportCoordinator` |
| Evernote | folder picker (non-async) | n/a | `import-evernote` | `EvernoteImportCoordinator` |

### Adapting for a New Platform

1. **Define file patterns**: Each platform uses different export filenames. Add pattern matching to `scanDownloadsFolder()`.
2. **Define email patterns**: Each platform sends different export notification emails. Add sender/subject filters to `pollForExportEmail()`.
3. **Create the window content**: Copy one of the existing import sheets as a template. Replace platform-specific setup sections.
4. **Add notification category**: Register `{PLATFORM}_EXPORT` in `SystemNotificationService.configure()` with Open/Remind actions.
5. **Wire menu item**: `File → Import → {Platform}...` posts `samShow{Platform}ImportWindow`. The Window scene declared in `SAMApp.swift` handles the rest.
6. **Add watcher persistence**: Use `sam.{platform}.emailWatcherActive` / `fileWatcherActive` / `StartDate` keys. Call `resumeWatchersIfNeeded()` from `configure(container:)`.
7. **Add termination cleanup**: Call `{Platform}ImportCoordinator.shared.cancelAll()` from `SAMAppDelegate.applicationShouldTerminate`.

### UserDefaults Keys (per platform)

```
sam.{platform}.feedURL                    — platform config (if applicable)
sam.{platform}.lastSubscriberImportDate   — watermark for auto-scan
sam.{platform}.emailWatcherActive         — Bool, persists across restarts
sam.{platform}.emailWatcherStartDate      — Date, for timeout calculation
sam.{platform}.fileWatcherActive          — Bool
sam.{platform}.fileWatcherStartDate       — Date
sam.{platform}.extractedDownloadURL       — String, cached download URL
```
