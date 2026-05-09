# 08 · Social Platform Import (Auto-Detection)

Async-export platforms (LinkedIn, Substack, Facebook) all share a unified pipeline: user requests data → platform emails a download link → SAM detects, parses, matches, and presents for review.

## Sequence

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Sheet as {Platform}ImportSheet
    participant Coord as {Platform}ImportCoordinator
    participant Mail as MailDatabaseService
    participant Files as ~/Downloads watcher
    participant Parse as {Platform}Service (actor)
    participant Match as Contact matching
    participant Enrich as EnrichmentRepository
    participant Evid as EvidenceRepository
    participant UnK as UnknownSenderRepository

    User->>Sheet: File → Import → {Platform}…

    alt First-time setup
        Sheet->>Sheet: phase = .setup
        User->>Sheet: enter credentials / URL
    else Returning
        Sheet->>Sheet: phase = .scanning
        Sheet->>Coord: scanDownloadsFolder()
        alt ZIP found newer than last import
            Coord-->>Sheet: phase = .zipFound(info)
        else None found
            Coord-->>Sheet: phase = .noZipFound
        end
    end

    opt Watch for export email
        User->>Sheet: "Watch for Email"
        Sheet->>Coord: startEmailWatcher() (5-min poll, 2-day timeout)
        Coord->>Mail: pollForExportEmail()
        Mail-->>Coord: download URL
        Coord-->>Sheet: phase = .emailFound(url)
        Coord->>Coord: post macOS notification
        User->>Sheet: "Open Download Page"
        Sheet->>Coord: startFileWatcher() (30s poll, 2-day timeout)
        Coord->>Files: watch ~/Downloads
        Files-->>Coord: archive appeared
        Coord-->>Sheet: phase = .zipFound(info)
    end

    User->>Sheet: confirm
    Sheet->>Coord: processZip(url:)
    Sheet->>Sheet: phase = .processing
    Coord->>Parse: unzip + parse files
    Parse-->>Coord: Sendable DTOs (Track 1 + Track 2)

    Coord->>Coord: Track 1 → BusinessProfileService<br/>(user's own profile, voice analysis)
    Coord->>Match: priority match per contact:<br/>1. profile URL<br/>2. email<br/>3. phone<br/>4. fuzzy name
    Match-->>Coord: matched + unmatched

    par Persist
        Coord->>Enrich: PendingEnrichment for changed fields
        Coord->>Evid: SamEvidenceItem (dedup via sourceUID)
        Coord->>UnK: unmatched senders
    end

    Sheet->>Sheet: phase = .awaitingReview
    User->>Sheet: review matched/unmatched
    User->>Sheet: confirm
    Sheet->>Sheet: phase = .complete(stats)
    opt
        User->>Sheet: delete source ZIP
    end
```

## Phase state machine

```mermaid
stateDiagram-v2
    [*] --> setup: no prior config
    [*] --> scanning: has prior config
    setup --> noZipFound: no archive
    setup --> zipFound: archive found
    scanning --> noZipFound
    scanning --> zipFound
    noZipFound --> watchingEmail: "Watch for Email"
    watchingEmail --> emailFound: 5-min poll
    watchingEmail --> failed: 2-day timeout
    emailFound --> watchingFile: user clicks download
    watchingFile --> zipFound: new archive
    watchingFile --> failed: 2-day timeout
    zipFound --> processing: confirm
    processing --> awaitingReview
    processing --> failed
    awaitingReview --> complete: confirm
    failed --> scanning: retry
    complete --> [*]
```

## Two-track model

| Track | Source | Destination | Purpose |
|---|---|---|---|
| **Track 1 — about the user** | Profile, career, skills, posts | `UserSubstackProfileDTO` etc. → `BusinessProfileService.contextFragment()` | Injected into AI specialist prompts |
| **Track 2 — about contacts** | Connections, messages, endorsements | `PendingEnrichment` + `EvidenceRepository` (matched) / `UnknownSenderRepository` (unmatched) | Enriches CRM, drives touch scoring |

## Why a unified pipeline

Three platforms, one architecture: each platform only differs in (a) file/email patterns, (b) DTO parsing. The state machine, watchers, persistence, and notifications are shared. See [context.md §5.7](../context.md) for the full adaptation checklist.

## Voice analysis

Every platform that captures the user's own posts/articles runs voice analysis (3–5 samples → `writingVoiceSummary`). `ContentAdvisorService` injects platform-appropriate voice into draft generation. Cross-platform fallback order: Substack > LinkedIn > Facebook.

## Adding a new platform

1. Define file patterns + email sender filters.
2. Copy a sheet template (`SubstackImportSheet`, `LinkedInImportSheet`, or `FacebookImportSheet`).
3. Register `{PLATFORM}_EXPORT` notification category.
4. Wire `File → Import → {Platform}` menu item.
5. Add `sam.{platform}.*` watcher persistence keys.
6. Hook `cancelAll()` into `applicationShouldTerminate`.
