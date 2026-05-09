# 07 · Daily Briefing Generation + Phone Sync

How the morning briefing is assembled on the Mac and synced to SAMField for read on the go.

## Sequence

```mermaid
sequenceDiagram
    autonumber
    participant Sched as Morning schedule
    participant DBC as DailyBriefingCoordinator
    participant SC as StrategicCoordinator
    participant Cal as CalendarService
    participant OE as OutcomeEngine
    participant DBS as DailyBriefingService
    participant Repo as Repositories
    participant CK as CloudKit private DB
    participant Field as SAMField

    Sched->>DBC: morning tick
    DBC->>SC: get latest StrategicDigest
    SC-->>DBC: top recommendations
    DBC->>Cal: today's events
    Cal-->>DBC: meetings + categorization
    DBC->>OE: visible outcomes (priority sorted)
    OE-->>DBC: outcomes + gap prompts

    DBC->>DBS: buildMorningDataBlock()
    Note over DBS: gapAnswersContext()<br/>+ goals + pacing<br/>+ knowledge gaps
    DBS-->>DBC: assembled briefing DTO

    DBC->>Repo: persist SamDailyBriefing
    DBC->>CK: write briefing snapshot
    CK-->>Field: subscription pushes

    Field->>Field: render Today tab
    actor User
    User->>Field: pull-to-refresh
    Field->>CK: fetch latest
    CK-->>Field: briefing JSON

    Note over DBC,Field: Live update:<br/>completed items + past events<br/>removed in real time
```

## What the briefing contains (all DTOs in coordinators, never in views)

- **Strategic highlights** — top 3–5 from the latest `StrategicDigest`.
- **Today's calendar** — categorized events with prep/follow-up cues.
- **Visible outcomes** — high-priority `SamOutcome` rows; suppressed for muted kinds; deduped against recent acts/dismisses.
- **Knowledge gaps** — at most one inline gap prompt.
- **Goals + pacing** — current `BusinessGoal` progress, pace, and any `GoalJournalEntry` learnings.
- **Crash-recovery banner** (if last session crashed) — `CrashReportService` data.

## Sync paths

| Path | What flows | When |
|---|---|---|
| **CloudKit private DB** | Briefing snapshot, trips, pairing token | Always available, even off-LAN |
| **TCP/HMAC same-LAN** | Bulk recordings, audio segments | When phone is on same Wi-Fi |

The briefing intentionally goes through CloudKit so the phone shows the latest morning briefing regardless of LAN status. See memory `project_briefing_sync.md`.

## Live update behavior

Per memory `feedback_briefing_live_update.md`: completed outcomes and past events must drop from the briefing in real time, not on next refresh. Coordinators observe repository changes and republish.

## Pairing

Same-iCloud-account device trust uses CloudKit private DB to distribute the pairing token — no PIN/QR UX. See memory `feedback_cloudkit_for_trust.md` and `project_cloudkit_pairing_migration.md`. The TCP/HMAC stream stays for performance once paired.
