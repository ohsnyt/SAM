# SAM Relationship Model — Implementation Plan

**Status:** Plan, 2026-05-11. Operationalizes the model in `relationship_model.md` and the recommendations in `relationship_synthesis.md`.

**Guiding rules:**

1. **Sarah's experience must not regress.** A user with a single Sphere and a single Funnel-mode Trajectory continues to see today's SAM. Every phase below has an explicit Sarah-regression check.
2. **Each phase ships independently.** Every phase leaves SAM in a working state, even if subsequent phases never land. No "half-built UI behind a flag" debt.
3. **Data first, UI last.** The model migration runs invisibly for several phases before any new surface is exposed.
4. **Migration is one-shot, idempotent, and reversible.** Existing users get auto-created defaults; the old fields stay populated as redundancy until at least one release after the new fields are battle-tested.

---

## Phase 0 — Pre-flight

**Goal:** establish baselines so we can detect regression.

**Scope:**

- Snapshot Sarah's current briefing, pipeline, person-detail view, and graph state. Save as fixtures to compare against post-migration.
- Capture current Health score distribution across the contact list (histogram). Phase 3 changes the math; we need to know what "today" looked like.
- Audit every consumer of `RelationshipHealth`, `roleBadges`, and pipeline stage in the codebase. Concrete list of files/lines that must be updated when each concept changes shape.

**Exit:** baseline document committed, audit list shared.

**No code changes.**

---

## Phase 1 — Foundation data model

**Goal:** introduce the new entities without changing any behavior.

**Scope:**

- New SwiftData models:
  - `Sphere` — id, name, purpose, accentColor, defaultMode, defaultCadenceDays, sortOrder, archived.
  - `Trajectory` — id, sphereID (optional), name, mode, archived, createdAt, completedAt.
  - `TrajectoryStage` — id, trajectoryID, name, sortOrder, isTerminal.
  - `PersonSphereMembership` — id, personID, sphereID, addedAt.
  - `PersonTrajectoryEntry` — id, personID, trajectoryID, currentStageID, cadenceDaysOverride, enteredAt, exitedAt, exitReason.
- New repositories: `SphereRepository`, `TrajectoryRepository`, `PersonTrajectoryRepository`.
- Default-Sphere bootstrap on first launch:
  - WFG users: auto-create `"My Practice"` Sphere with the existing Lead → Applicant → Client funnel as a Funnel-mode Trajectory. Every existing person inherits a `PersonTrajectoryEntry` derived from their current pipeline stage.
  - General users: auto-create `"My Practice"` Sphere with an empty Funnel-mode Trajectory, OR offer a one-screen Sphere setup at first launch (TBD by Phase 5).
- All existing systems (OutcomeEngine, MeetingPrepCoordinator, StrategicCoordinator, etc.) continue to read from existing fields. The new tables are *write-through* only at this point.

**Sarah regression check:** her briefing, pipeline view, and graph render identically. New tables are populated in the background.

**Files touched (estimate):**
- `Models/SAMModels-*.swift` — 5 new model files (or one consolidated)
- `Services/Repositories/` — 3 new repository files
- `Coordinators/AppLaunchCoordinator.swift` (or equivalent) — bootstrap step
- `1_Documentation/context.md` — schema update

**Risks:**
- SwiftData migration path — must be additive only. No existing schema mutated.
- First-launch bootstrap performance with 1000+ contacts. Run in background, show no UI hold.

**Exit criteria:**
- New tables created, indexes correct.
- Bootstrap runs idempotently (re-running doesn't duplicate).
- Sarah's UI is pixel-identical to Phase 0 baseline.
- All existing tests pass.

---

## Phase 2 — Mode taxonomy & Covenant

**Goal:** introduce the five-Mode taxonomy and the silence rule for Covenant relationships, without rewriting Health.

**Scope:**

- Add `Mode` enum: `funnel | stewardship | covenant | campaign | service`.
- Each `Trajectory` carries a Mode. Default Sphere ships with a Stewardship-mode "Ongoing" Trajectory.
- New: `PersonModeOverride` (optional per-Person mode hint, used when the person isn't on any explicit Trajectory). Defaults to the Sphere's defaultMode.
- Health engine respects Mode in one specific way only this phase: **Covenant-mode relationships never generate cadence-decay alerts**. They can still surface alerts from explicit life events (existing system) or user-set reminders.
- Coaching outputs gain a Mode-aware tone selector — same engine, different prompt-section.

**Sarah regression check:** her clients/applicants/leads all remain Funnel-mode. Mode is invisible to her UI.

**Files touched:**
- `Models/DTOs/Mode.swift` — new enum
- `Coordinators/MeetingPrepCoordinator.swift` — Mode-aware silence rule (small change)
- `Coordinators/OutcomeEngine.swift` — Mode passed to prompt assembly
- `Services/AICoordinator.swift` (or wherever prompts live) — Mode tone hints

**Risks:**
- Misclassifying a relationship as Covenant could silence genuinely-decaying contacts. **Mitigation:** Covenant is opt-in only this phase. Default never Covenant unless user explicitly tags.

**Exit criteria:**
- Tagging a relationship Covenant silences decay alerts for that person specifically.
- Sarah has zero Covenant tags by default. Her flow is unchanged.

---

## Phase 3 — Health metric refactor (the highest-leverage change)

**Goal:** make Health measure *drift* primarily, with role-defaults as fallback. Add initiation asymmetry and positive/negative balance.

**Scope:**

This is the core measurement change from `relationship_synthesis.md` Findings 2–4.

1. **Drift-as-primary in `MeetingPrepCoordinator.computeHealth`.**
   - Compute `personalBaselineCadence` from the contact's own history (median gap from ≥5 prior interactions). Already mostly computed today as `cadenceDays`; promote it to primary.
   - `driftRatio = currentGap / personalBaselineCadence`. New primary signal.
   - Role-based static thresholds become *floor only* — used when `personalBaselineCadence` is `nil` (insufficient history).
   - Trajectory-derived cadence (from active `PersonTrajectoryEntry.cadenceDaysOverride` or the Trajectory's default) **overrides both** when present.

2. **Initiation asymmetry.**
   - Compute `initiationRatio` over rolling 90 days: outbound count / total count. Already partially computed; surface as a first-class signal.
   - Two derived flags:
     - `userDrivenAsymmetry` — ratio > 0.85 with ≥5 interactions. ("You've been the sole driver.")
     - `contactDrivenIgnored` — ratio < 0.30 and `daysSinceLastOutbound` > `personalBaselineCadence`. ("They've been reaching out; you've been slow.") **This is the new neglect signal SAM doesn't have today.**

3. **Positive/negative balance.**
   - From sentiment-tagged notes/evidence over 90 days, compute `positiveCount / max(1, negativeCount)`. Default tuning: warn below 5:1 for Stewardship; 3:1 for Funnel; do not compute for Covenant.

4. **Health output is now a vector, not a scalar.**
   - `RelationshipHealth` gains: `driftRatio`, `initiationRatio`, `pnRatio`, `dominantSignal` (which of the three is the worst right now).
   - The existing scalar `HealthLevel` (healthy/cooling/atRisk/cold) is derived by combining the three, weighted by Mode.

**Sarah regression check:**
- Run the new engine over Sarah's contact list in shadow mode for a release. Compare HealthLevel against today's output for every person.
- Anyone whose category changes gets a manual review entry. The expected drift is small (the new math agrees with the old for most cases).
- Sarah's top-of-briefing "needs attention" list shouldn't shuffle wildly.

**Files touched:**
- `Coordinators/MeetingPrepCoordinator.swift` — core change.
- `Models/DTOs/RelationshipHealth.swift` (or wherever) — extended struct.
- Every view that reads `health.level` — verify no breakage; most should keep working.
- `Services/EvidenceRepository.swift` or equivalent — confirm interaction-direction data is reliably available.

**Risks:**
- Shadow-mode validation may surface unexpected discrepancies in Sarah's flow. Don't ship until the diff is reviewable and acceptable.
- `contactDrivenIgnored` is a brand-new alert kind. It may fire on contacts the user is intentionally not engaging (DNC-adjacent). Mitigation: respect existing lifecycle states (Archived, DNC, Deceased).

**Exit criteria:**
- Shadow-mode results reviewed and accepted.
- All three new signals visible in Person Detail (small disclosure section).
- Briefing surfaces `contactDrivenIgnored` cases as a new "Reaching for you" section.

---

## Phase 4 — Funnel completion spawns Stewardship

**Goal:** make explicit that a Funnel-mode Trajectory's terminal stage is the *beginning* of a Stewardship-mode arc, not an end.

**Scope:**

- When a `PersonTrajectoryEntry` reaches a Stage marked `isTerminal: true` in a Funnel-mode Trajectory, auto-create a new `PersonTrajectoryEntry` for the same person in a Stewardship-mode Trajectory belonging to the same Sphere.
  - If no such Stewardship Trajectory exists in that Sphere, auto-create one named `"<SphereName> — Ongoing Stewardship"`.
- Default cadence for the Stewardship arc: derived from the contact's `personalBaselineCadence`, with Sphere default as fallback.
- New coaching alert kind: `clientWithoutStewardship` — a contact at a Funnel terminus without an active Stewardship entry surfaces in the briefing.

**Sarah regression check:**
- For each of Sarah's current Clients, an Ongoing Stewardship entry is created at migration time.
- Her client-detail views gain a small "Stewardship: monthly" badge but otherwise look the same.
- Her briefing gains items like "When did you last connect with [Client] outside the application context?" — informed by Buffini and Burk research.

**Files touched:**
- `Coordinators/PipelineService.swift` (or wherever stage transitions live) — hook for spawn.
- `Coordinators/OutcomeEngine.swift` — new alert kind.

**Risks:**
- Over-alerting on clients who are recent (just closed last week — no need for stewardship nudges yet). Mitigation: 30-day grace period after entry creation before alerts fire.

**Exit criteria:**
- Closing a Lead → Client transition auto-creates a Stewardship entry.
- Reviewing the briefing the next morning shows the new "stewardship watch" section for any neglected Clients.

---

## Phase 5 — Spheres UI surface

**Goal:** expose Spheres as a first-class concept for users who have more than one. Single-Sphere users see no new UI.

**Scope:**

- New tab `Spheres` in `BusinessDashboardView`, visible only when user has 2+ Spheres.
- Each Sphere card shows: purpose, member count, active Trajectories, top open coaching items.
- New Sphere creation flow:
  - Name + purpose statement.
  - Choose default Mode for unattached members.
  - Choose Sphere accent color.
  - Optionally: import contacts via Apple Contacts group selection, or tag existing contacts.
- New Sphere setup templates (one-screen onboarding):
  - **Faith community leader** (Stewardship default, sub-groups for clergy/elders/members).
  - **Nonprofit board / chairman** (Stewardship default; Campaign-mode trajectory template available for searches like ED hiring).
  - **Personal advocate / promoter** (no default Trajectory; cadence is content-driven).
  - **Real estate / sales practice** (Funnel-mode primary Trajectory).
  - **Service business** (Service-mode primary, named "Customers").
  - **Blank** (start from nothing).
- PersonDetailView gains a "Spheres" section showing which Spheres this person belongs to and any active Trajectories.

**Sarah regression check:**
- Sarah has one Sphere. The Spheres tab is hidden. Her UI is unchanged.

**Files touched:**
- `Views/Business/BusinessDashboardView.swift` — conditional tab.
- New `Views/Business/SpheresOverviewView.swift`.
- New `Views/Business/SphereDetailView.swift`.
- New `Views/Business/NewSphereSheet.swift` with templates.
- `Views/People/PersonDetailView.swift` — Spheres section.
- `Views/Settings/SettingsView.swift` — Sphere management.

**Risks:**
- Template design: easy to over-engineer. Mitigation: ship Blank + Real-estate/Sales (already covers Sarah and the existing case) first, add others as templates iteratively.

**Exit criteria:**
- David can create three Spheres (Elder, Chairman, Promoter), tag contacts into each, see per-Sphere briefing sections.
- Sarah opens the app, sees nothing new.
- A new General-type user is offered the Sphere setup at first run.

---

## Phase 6 — Briefing & Strategic Coordinator restructure

**Goal:** the daily briefing and strategic digest become Sphere-aware. Single-Sphere users see today's structure; multi-Sphere users see per-Sphere sections.

**Scope:**

- `StrategicCoordinator` accepts a Sphere context. Each specialist analyst (Pipeline, Time, Pattern, Content) runs per-Sphere when there are 2+ Spheres.
- Briefing/digest structure for multi-Sphere users:
  - Per-Sphere section: 1–2 top actions, Health signals, Trajectory status.
  - Cross-Sphere section: patterns the coordinator detected (e.g., "your council contact Bob is also in your Real Estate Sphere — he asked about listings twice last month").
- For single-Sphere users, output structure is unchanged.

**Sarah regression check:**
- Single Sphere → identical briefing structure to today.

**Files touched:**
- `Coordinators/StrategicCoordinator.swift` — major refactor.
- `Coordinators/DailyBriefingCoordinator.swift` (or equivalent) — section assembly.
- Specialist analyst prompts — accept Sphere context as system message.

**Risks:**
- Token budget: per-Sphere analyst runs increase total inference. Mitigation: batched scheduling (one Sphere per session if budget is tight), and don't recompute Spheres whose contents haven't changed.
- Briefing quality: per-Sphere outputs must remain high-signal, not diluted.

**Exit criteria:**
- David's briefing reads as three coherent sections, one per Sphere, with a brief cross-Sphere insight when relevant.
- Sarah's briefing is unchanged.

---

## Phase 7 — Coaching refinements (trust currency, give/ask)

**Goal:** apply the smaller borrowings from the synthesis without further structural change.

**Scope:**

- `Trajectory` (and optionally `PersonModeOverride`) gains `trustCurrency: warmth | competence | both`.
- Default per Mode: Funnel/Campaign → competence; Stewardship → both; Covenant → warmth; Service → reliability.
- Coaching prompt-assembly uses `trustCurrency` to steer tone.
- Interaction tagging: on note save, classify the interaction as `give | neutral | ask` (cheap on-device classification). Surface a `give/ask` ratio per relationship over a window. Coaching prompt for the user when the ratio tips toward asking.
- Optional advanced: BRAVING decomposition surfaced in PersonDetailView when a relationship is at-risk, to help the user diagnose what specifically is broken.

**Sarah regression check:**
- All her Funnel Trajectories default to `competence` currency. Coaching tone may shift slightly toward insight-driven language. Acceptable.

**Files touched:**
- `Models/SAMModels-*.swift` — currency enum added to Trajectory.
- `Coordinators/NoteAnalysisCoordinator.swift` — interaction tagging.
- `Services/AICoordinator.swift` (or wherever prompts live) — currency-aware tone selection.

**Risks:**
- Give/ask classification accuracy. Mitigation: simple rule-based first (asks contain "could you", "would you mind", "I need", etc.); add classifier later if needed.

**Exit criteria:**
- Coaching nudges for a `warmth`-currency relationship sound different from a `competence`-currency one.
- Give/ask ratio is visible in PersonDetailView for any relationship with ≥5 recent interactions.

---

## Phase 8 — Migration cleanup & deprecation

**Goal:** retire the redundant old fields once new ones are battle-tested.

**Scope:**

- After two releases with the new model in production, audit reads of `roleBadges` for stage-implication usage. Migrate any that conflate badge with stage to use `PersonTrajectoryEntry` instead.
- Deprecate `pipelineStage` field on Person in favor of `PersonTrajectoryEntry.currentStageID`. Keep the field but mark deprecated.
- Remove shadow-mode comparison telemetry from Phase 3.

**Exit criteria:**
- Single canonical source for "where is this person on a Trajectory."

---

## Cross-cutting concerns

### Testing

- **Unit tests**: model bootstrap, drift calculation, initiation ratio, Mode-aware silence, terminal-stage spawn.
- **Shadow-mode validation**: Phase 3 health refactor runs in parallel with existing math for one release before cutover.
- **Persona walkthroughs**: scripted UI walkthroughs for Sarah, David (3 spheres), and a Real Estate Agent (1 Funnel + 1 Stewardship). Run on every release candidate.

### Performance

- Background bootstrap for Phase 1 must not block first launch.
- Per-Sphere specialist analyst calls in Phase 6 must batch or stagger to respect the existing TaskPriority discipline.
- Drift calculation in Phase 3 reads more history; ensure EvidenceRepository's cache strategy holds.

### AI prompt versioning

- Every specialist analyst prompt gets a version number. The Strategic Coordinator records which version produced which insight, so we can A/B compare quality between model versions.

### Documentation

- `context.md` updated at end of each phase with the new state.
- `changelog.md` entry per phase.
- `relationship_model_user_overview.md` (separate doc) updated when user-visible vocabulary changes.

### Rollback plan

- Phase 1–2: trivially reversible (drop new tables; remove enum case).
- Phase 3: keep the old health math behind a feature flag for one release. Toggle off if shadow-mode shows trouble in production.
- Phase 4: clients without auto-Stewardship still work via the old static cadence; revert is safe.
- Phase 5+: UI rollback only; data model stays.

---

## Sequencing summary

| Phase | Visible to user? | Sarah-safe? | Estimated effort | Dependency |
|---|---|---|---|---|
| 0 | No | — | 0.5 day | — |
| 1 | No | Yes | 3–5 days | Phase 0 |
| 2 | Minimal | Yes | 2–3 days | Phase 1 |
| 3 | Briefing changes | Yes (shadow-mode) | 5–8 days | Phase 1, 2 |
| 4 | Briefing items | Yes | 2–3 days | Phase 1, 2 |
| 5 | New tab (multi-Sphere users) | Yes | 5–8 days | Phase 1 |
| 6 | Briefing restructure (multi-Sphere) | Yes | 4–6 days | Phase 5 |
| 7 | Tone shift; new ratios | Yes | 3–5 days | Phase 3 |
| 8 | None | Yes | 2 days | All prior |

Total: roughly 4–6 weeks of focused engineering, depending on whether phases run sequentially or some are parallelized.

---

## Decision points before starting

The plan above is the recommended path. These are decisions to confirm before Phase 1:

1. **Single auto-Sphere for everyone, or first-run setup for General users?** Plan currently auto-creates "My Practice" for everyone. Alternative: General users hit a setup screen on first launch.
2. **Should `PersonModeOverride` exist** or should Mode always be derived from active Trajectory? Plan currently includes it as an escape hatch.
3. **Should Covenant default to `warmth` currency, or both?** Plan currently says `warmth`. Pastoral examples support both.
4. **Is the new "Reaching for you" briefing section worth a top-level surface, or just embedded in person cards?** Plan currently makes it top-level — it's the highest-leverage new signal.

If any of these warrant different choices, pause before Phase 1 and update the plan.
