# Phase 0 — Consumer Impact Audit

**Date:** 2026-05-11
**Purpose:** Concrete file:line surface for the three concepts that Phase 3 (Health refactor) and Phase 8 (stage/badge deconflation) will touch. Built by grepping the codebase against the structural analysis from the relationship-model implementation plan.

This is a checklist, not a narrative. Trust the line numbers; verify before editing.

---

## 1. RelationshipHealth (Phase 3 surface)

The Health metric is centralized and clean. Phase 3 can refactor in place without restructuring callers.

### Definitions
- `SAM/Coordinators/MeetingPrepCoordinator.swift:58` — `enum DecayRisk` (none / low / moderate / high / critical)
- `SAM/Coordinators/MeetingPrepCoordinator.swift:80` — `struct RelationshipHealth` (~13 fields)
- `SAM/Models/DTOs/GraphNode.swift:32` — `enum HealthLevel` (healthy / cooling / atRisk / cold)
- `SAM/Coordinators/MeetingPrepCoordinator.swift:22` — `enum VelocityTrend` (decay acceleration detection)
- `SAM/Views/People/PersonDetailView.swift:2800` — `struct RelationshipHealthView` (presentation only)
- `SAMTests/ScenarioHarnessTests.swift:1192` — `struct RelationshipHealthQualityTests`

### Single write site
- `SAM/Coordinators/MeetingPrepCoordinator.swift:326` — `computeHealth(...)` is the only producer of `RelationshipHealth`. Phase 3 changes happen here.

### Read sites (~29 total — verify on edit)
Heaviest consumers:
- `SAM/Views/People/PersonDetailView.swift` — 9 reads across health sections
- `SAM/Views/Awareness/EngagementVelocitySection.swift` — 5 reads
- `SAM/Coordinators/DailyBriefingCoordinator.swift` — 6 reads
- `SAM/Coordinators/OutcomeEngine.swift` — 4 reads

All reads access fields on the returned struct (`.level`, `.daysSinceLastInteraction`, `.cadenceDays`, `.effectiveCadenceDays`, `.overdueRatio`, `.velocityTrend`, `.qualityScore30`, `.decayRisk`, `.statusColor`, `.statusLabel`). The struct stays the shape Phase 3 needs; we extend (add `driftRatio`, `initiationRatio`, `pnRatio`, `dominantSignal`), we do not break existing reads.

### Phase 3 risk assessment
**Low.** Centralized computation, immutable struct. Shadow-mode validation strategy (run new + old engines in parallel for one release) is straightforward because there's one producer.

---

## 2. roleBadges-as-stage conflation (Phase 8 surface)

This is the surprise. `roleBadges` is intended as a label collection ("what kind of person is this") but is used in 15+ places to answer "what pipeline stage is this person at" — which should come from `StageTransition` or `RecruitingStage`. Phase 8 must rewrite these sites to read from the stage repositories (or, post-Phase 1, from `PersonTrajectoryEntry`).

### Definition
- `SAM/Models/SAMModels.swift:211` — `roleBadges: [String]` on SamPerson. Strings, not enum. Custom badges supported.
- `SAM/Models/DTOs/RoleBadgeStyle.swift:12` — styling per badge name.

### Conflated reads (Phase 8 must rewrite these)

Pattern: `roleBadges.contains("Lead" | "Applicant" | "Client" | "Agent")` used to route behavior or filter populations.

**Coordinators:**
- `SAM/Coordinators/MeetingPrepCoordinator.swift:852` — extracts pipeline stage from roleBadges via Set lookup; pipe to `StageTransition` instead.
- `SAM/Coordinators/PipelineTracker.swift:68,69,70` — counts Lead/Applicant/Client populations from roleBadges. Should query `PipelineRepository` (or post-Phase 1, count `PersonTrajectoryEntry` by stage).
- `SAM/Coordinators/OutcomeEngine.swift:681` — leads filter
- `SAM/Coordinators/OutcomeEngine.swift:729` — Client routing
- `SAM/Coordinators/OutcomeEngine.swift:758` — clients filter
- `SAM/Coordinators/OutcomeEngine.swift:1367` — leads filter for gap analysis
- `SAM/Coordinators/OutcomeEngine.swift:1386` — applicants filter for gap analysis
- `SAM/Coordinators/OutcomeEngine.swift:2011` — `hasLeads` boolean
- `SAM/Coordinators/OutcomeEngine.swift:2038` — `allLeadsForGaps` collection
- `SAM/Coordinators/RoleRecruitingCoordinator.swift:242` — Agent gate
- `SAM/Coordinators/RelationshipGraphCoordinator+Lens.swift:592` — Client lens predicate
- `SAM/Repositories/PipelineRepository.swift:240` — Agent path inside the pipeline repo itself (ironic).

**Views:**
- `SAM/Views/People/PersonDetailView.swift:894` — recruiting-stage init gate ("if person isn't already Agent, can't set recruiting stage")
- `SAM/Views/People/PersonDetailView.swift:1487` — `recruitingStageSection` gated by `roleBadges.contains("Agent")` — should gate on `RecruitingStage` existence.
- `SAM/Views/People/PersonDetailView.swift:1492` — `productionSection` gated by Client/Applicant badge — should gate on `StageTransition` history.
- `SAM/Views/Business/RelationshipGraphView.swift:2642` — stage color picked by Agent badge.
- `SAM/Views/Awareness/PipelineStageSection.swift:21,25,29` — Lead/Applicant/Client groupings.
- `SAM/Views/Awareness/ReferralTrackingSection.swift:49` — Client filter for referrals.
- `SAM/Views/Awareness/CalendarPatternsSection.swift:171` — Client filter for calendar patterns.
- `SAM/Views/Awareness/StreakTrackingSection.swift:127` — Client filter for streaks.

### Pure-display reads (safe — keep)
The 60+ files containing `roleBadges` mostly read for display only (badge chip rendering, search row, contextual menus). Display-only reads stay untouched in Phase 8.

### Conflation count: 18+ confirmed sites
Significantly larger than the initial 5-site estimate. Phase 8 timeline should reflect this; consider splitting into 8a (coordinator rewrites) and 8b (view rewrites).

---

## 3. pipelineStage (already normalized — Phase 8 just needs the rewrites above)

### Definitions
- `SAM/Models/SAMModels-Pipeline.swift:86` — `StageTransition` (immutable audit log: fromStage, toStage, transitionDate, pipelineType).
- `SAM/Models/SAMModels-Pipeline.swift:137` — `RecruitingStage` (current recruiting state per person).
- `SAM/Models/SAMModels-Pipeline.swift:28` — `RecruitingStageKind` (7 cases: prospect → producing).
- `SAM/Models/SAMModels.swift:280` — `SamPerson` relationships: `stageTransitions`, `recruitingStages`.

### Writes (already centralized in PipelineRepository — good)
- `SAM/Repositories/PipelineRepository.swift` — `recordTransition`, `upsertRecruitingStage`, `advanceRecruitingStage`.
- `SAM/Views/People/PersonDetailView.swift` — user picker triggers PipelineRepository writes.
- `SAM/Coordinators/RoleRecruitingCoordinator.swift` — initializes Agent with prospect stage.
- `SAM/Coordinators/BackupCoordinator.swift` — restore path.
- `SAM/Repositories/PeopleRepository.swift` — merge re-points relationships.

### Reads via repository (correct pattern — Phase 1 PersonTrajectoryEntry should sit next to these)
- `SAM/Repositories/PipelineRepository.swift` — `fetchTransitions`, `fetchRecruitingStage`, `fetchAllRecruitingStages`.

### Phase 1 implication
The stage data model is normalized and clean. Phase 1's `PersonTrajectoryEntry` lives alongside `StageTransition`/`RecruitingStage`, not replacing them. The bootstrap can read `StageTransition.toStage` (most recent per person) to derive each person's initial `PersonTrajectoryEntry.currentStageID`.

---

## Summary table

| Concept | Definitions | Read sites | Write sites | Phase | Risk |
|---|---|---|---|---|---|
| RelationshipHealth | 6 | ~29 | 1 | 3 | Low |
| roleBadges (display) | 2 | ~45 (60-file file list, minus conflation/conflated sites) | 8 | — | None (no change) |
| roleBadges-as-stage conflation | — | **18+** | — | 8 | Medium — broader than initial estimate |
| pipelineStage / StageTransition / RecruitingStage | 4 | 18 via repos | 9 via PipelineRepository | 1 (bootstrap uses), 8 (becomes single source of truth) | Low |

---

## Pre-Phase-1 takeaways

1. **Phase 1 bootstrap reads from `StageTransition` (most recent per person) to seed `PersonTrajectoryEntry.currentStageID`.** Do not read `roleBadges` for stage — that's the bug we're inheriting away from.
2. **Phase 3 health refactor is structurally clean.** One producer, one struct, extend fields without breaking signatures.
3. **Phase 8 scope is larger than the plan estimated.** Update plan: split Phase 8 into 8a (coordinator/repo conflation rewrites — 12 sites) and 8b (view conflation rewrites — 6 sites). Bump total Phase 8 effort from 2 days → 4-5 days.
