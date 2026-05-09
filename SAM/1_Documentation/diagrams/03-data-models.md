# 03 · Data Models

SwiftData schema **SAM_v34**. Models grouped by domain. Mermaid ER syntax shows only the relationships and a few load-bearing fields — see `SAMModels-*.swift` for full definitions.

## People & evidence (the relationship core)

```mermaid
erDiagram
    SamPerson ||--o{ SamEvidenceItem : "linkedPeople"
    SamPerson ||--o{ SamNote : "subject"
    SamPerson ||--o{ SamInsight : "person"
    SamPerson ||--o{ SamOutcome : "person"
    SamPerson ||--o{ FamilyReference : "on person"
    SamPerson }o--o{ SamContext : "members"
    SamPerson ||--o{ DeducedRelation : "personA / personB"
    SamPerson ||--o{ PendingEnrichment : "candidate updates"
    SamNote ||--o{ FamilyReference : "sourceNote"
    SamPerson ||--o{ SamEvent : "auto-reply unknowns"
    SamEvent ||--o{ EventParticipation : "attendees"
    SamPerson ||--o{ EventParticipation : "person"

    SamPerson {
        UUID id
        string contactIdentifier
        string roleBadgesRaw
        string lifecycleStatusRaw
        int preferredCadenceDays
        string linkedInProfileURL
        string facebookProfileURL
        string substackURL
    }
    SamEvidenceItem {
        UUID id
        string sourceRaw
        string sourceUID
        string snippet
        date occurredAt
        bool isAllDay
    }
    SamNote {
        UUID id
        string content
        string actionItemsJSON
        string topicsJSON
        string lifeEventsJSON
        date createdAt
    }
    SamOutcome {
        UUID id
        string kindRaw
        int priority
        date deadline
        string actionLaneRaw
        string sequenceID
    }
```

## Pipeline, recruiting, production (the business core)

```mermaid
erDiagram
    SamPerson ||--o{ StageTransition : "audit log"
    SamPerson ||--|| RecruitingStage : "current stage"
    SamPerson ||--o{ ProductionRecord : "policies/products"
    SamPerson ||--o{ IntentionalTouch : "social touches"
    BusinessGoal ||--o{ GoalJournalEntry : "check-ins"
    RoleDefinition ||--o{ SamPerson : "fits role (computed)"

    StageTransition {
        UUID id
        UUID personID
        string fromStageRaw
        string toStageRaw
        date transitionedAt
        string note
    }
    RecruitingStage {
        UUID id
        UUID personID
        string stageRaw
        date enteredAt
    }
    ProductionRecord {
        UUID id
        UUID personID
        string typeRaw
        string statusRaw
        string carrier
        decimal premium
        date issuedAt
    }
    BusinessGoal {
        UUID id
        string typeRaw
        decimal target
        date startsAt
        date endsAt
    }
    GoalJournalEntry {
        UUID id
        UUID goalID
        string headline
        string adjustedStrategy
        decimal paceAtCheckIn
        int conversationTurnCount
    }
    IntentionalTouch {
        UUID id
        UUID personID
        string platformRaw
        string typeRaw
        string directionRaw
        double weight
        string dedupKey
    }
    RoleDefinition {
        UUID id
        string title
        string idealProfile
        string scoringCriteriaJSON
    }
```

## Time, content, compliance, events

```mermaid
erDiagram
    TimeEntry }o--o| SamEvidenceItem : "source event"
    ContentPost }o--|| SamPerson : "user's posts"
    ComplianceAuditEntry }o--o| SamOutcome : "from draft"
    SamEvent ||--|| SamPresentation : "uses"
    SamEvent ||--|| EventEvaluation : "post-event analysis"
    StrategicDigest ||--o{ SamOutcome : "synthesizes"

    TimeEntry {
        UUID id
        string categoryRaw
        date startsAt
        int durationMinutes
        UUID sourceEventID
    }
    ContentPost {
        UUID id
        string platformRaw
        string topic
        date postedAt
    }
    SamEvent {
        UUID id
        string title
        string formatRaw
        string statusRaw
        date startsAt
        bool autoReplyUnknownSenders
    }
    EventParticipation {
        UUID id
        UUID eventID
        UUID personID
        string rsvpStatusRaw
        string inviteStatusRaw
        date inviteSentAt
    }
    SamPresentation {
        UUID id
        string title
        string topicTagsJSON
        string keyTalkingPointsJSON
    }
    EventEvaluation {
        UUID id
        UUID eventID
        string overallSummary
        decimal averageOverallRating
        decimal conversionRate
    }
    ComplianceAuditEntry {
        UUID id
        string channelRaw
        string flagsJSON
        string originalDraft
        string finalDraft
    }
    StrategicDigest {
        UUID id
        string typeRaw
        string contentJSON
        date generatedAt
    }
```

## Imports & social

```mermaid
erDiagram
    LinkedInImport ||--o{ SamEvidenceItem : "produces"
    FacebookImport ||--o{ SamEvidenceItem : "produces"
    SubstackImport ||--o{ SamEvidenceItem : "produces"
    NotificationTypeTracker }o--|| SamPerson : "(none)"
    ProfileAnalysisRecord }o--|| SamPerson : "person"
    EngagementSnapshot }o--|| SamPerson : "person"
    SocialProfileSnapshot }o--|| SamPerson : "person"
    UnknownSender }o--o| SamEvidenceItem : "candidate"

    LinkedInImport {
        UUID id
        date importedAt
        int matchedCount
        int unmatchedCount
        string statusRaw
    }
    UnknownSender {
        UUID id
        string identifier
        string sourceRaw
        bool neverAdd
        date firstSeenAt
    }
    SocialProfileSnapshot {
        UUID id
        string platformRaw
        string identityKey
        string dataJSON
    }
```

## Mac↔phone sync, trips, undo

```mermaid
erDiagram
    SamTrip ||--o{ SamTripStop : "stops"
    PendingUpload }o--|| SamPerson : "(any model)"
    ProcessedSessionTombstone }o--o| SamPerson : "(none)"
    SamUndoEntry }o--o| SamPerson : "(any model)"

    SamTrip {
        UUID id
        date startedAt
        date endedAt
        decimal milesDriven
        string purposeRaw
    }
    SamTripStop {
        UUID id
        UUID tripID
        decimal latitude
        decimal longitude
        date arrivedAt
    }
    SamUndoEntry {
        UUID id
        string operationTypeRaw
        string snapshotJSON
        date createdAt
    }
    ProcessedSessionTombstone {
        UUID id
        string sessionUID
        date processedAt
    }
```

## Where things live (non-SwiftData)

| Storage | What's there |
|---|---|
| **UserDefaults** | `UserLinkedInProfileDTO`, `UserFacebookProfileDTO`, `UserSubstackProfileDTO`; per-platform watermarks (`sam.{platform}.lastImportDate`); gap answers (`sam.gap.*`); compliance prompt overrides; text scale; pairing flags |
| **Keychain** | Pairing secrets, mail account credentials |
| **Security-scoped bookmarks** | Mail Envelope Index directory, security-imported file paths |
| **Disk (sandbox)** | Audio segments (pre-retention sweep), backup archives (`SAMENC1` AES-256-GCM), ENEX export staging |
| **CloudKit private DB** | Daily briefing snapshot, trips, pairing token (see `project_cloudkit_pairing_migration.md`) |

## Core invariants

- **Apple Contacts is the system of record**. `SamPerson.contactIdentifier` links to it; standalone records (social-only) have `contactIdentifier == nil`.
- **Every model uses raw-string enum storage** with `@Transient` computed property (Swift 6 + SwiftData limitation).
- **Stage transitions are immutable** — never updated, only inserted. They power velocity and stall detection.
- **Evidence has a dedup key** in `sourceUID` (e.g. `linkedin:msg:12345:1709...`) — re-imports are idempotent.
- **`isArchived`** survives as a `@Transient` computed property; storage column is `isArchivedLegacy` (preserved for backward-compatible migration).

## Schema history

See [context.md §8](../context.md) for the v16 → v34 changelog. New schema versions require lightweight migration; never rename columns destructively.
