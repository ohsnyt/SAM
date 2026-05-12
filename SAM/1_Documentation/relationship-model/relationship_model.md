# SAM Relationship Model — Working Draft

**Status:** Design discussion in progress. Not yet implemented. Captures the vocabulary and conceptual model the user and the assistant have agreed on as of 2026-05-11.

**Purpose:** Provide a stable reference for the conceptual model so we can compare it against expert frameworks (see `relationship_research.md`) and decide what, if anything, to change before building.

---

## 1. Motivating context

SAM was originally shaped for a single WFG financial-advisor use-case: one user, one practice, one sales funnel (Lead → Applicant → Client) plus a recruiting funnel (Prospect → … → Producing Agent). Every relationship the user has fits inside that practice, and every coaching nudge is in service of it.

Real lives — including the lives of users SAM should be able to serve — don't fit that shape. The motivating example is the primary user (David), whose relationships split into three distinct contexts:

- **Elder at his church** — pastor, fellow elders, members
- **Chairman of Aramaic Bible Translation** (nonprofit) — board members, executive director, staff, interested public
- **Promoter of his daughter Sarah's financial-advisor practice** — wider audience reached via LinkedIn and Facebook

Each of these contexts has its own stakeholders, its own goals, and its own definition of "doing well." A single sales-funnel model is the wrong shape for any of them.

The follow-up consideration: the model must also remain a clean fit for users whose lives genuinely *are* funnel-shaped (Sarah; real-estate agents; B2B sellers), and for users with hybrid lives (a real-estate agent who is also a church member and a town-council member; an HVAC small-business owner with customers, crew, suppliers, and referral partners).

---

## 2. Vocabulary

The terms below are working definitions. Each was chosen to be non-overlapping; the abstraction is only useful if these stay distinct.

### Person
A contact. The entity in the address book. Backed by `SamPerson`.

### Relationship
The through-line between **Me** and a Person. The connection itself. Persists across time. Not a stage, not a label — the channel through which everything else (touches, badges, stages, cadence) flows.

### Badge
A *static label* on a Person describing **what kind of contact they are** in the user's world. Multi-valued. Doesn't change often. Examples: `Client`, `Lead`, `Pastor`, `Board Member`, `Donor`, `Friend`.

Badges describe *what a person is*, not *where they are in any sequence*.

### Sphere
A *hat the user wears* — a life-context they inhabit. The container for one of the user's responsibilities or callings. Examples for David: "Elder at Trinity," "Chair of ABT," "Promoting Sarah." For a real-estate agent: "Real Estate Practice," "Member of First Methodist," "Town Council Seat."

Spheres are user-defined. A user with a single Sphere (e.g., Sarah, who has only her practice) should see SAM exactly as it works today — Sphere is invisible overhead for single-Sphere users.

### Trajectory
A *named sequence of stages* a Person can travel through, in a specific context. Not every relationship sits on a trajectory; some are simply ongoing. Examples:

- *Sales Funnel*: Prospect → Qualified Lead → Applicant → Client → Repeat Customer
- *Donor Cultivation*: Identification → Cultivation → Solicitation → Stewardship
- *Recruiting Tree* (WFG): Initial Conversation → … → Producing Agent
- *ED Search Q2 2026*: Identified → Approached → Interviewed → Final Round → Hired/Declined

A trajectory belongs to a Sphere (or stands alone). A Person can be on multiple trajectories simultaneously, in different Spheres. The same Pastor can be:

- Badge: `Pastor`, `Friend`
- On the *ED Search* trajectory at stage `Final Round`
- Implicitly inside the *Elder Stewardship* of his church Sphere

When the trajectory ends, the stage record collapses; the badges and base relationship persist.

### Stage
The Person's *current position on a specific Trajectory*. Stage is a property of the **(Person × Trajectory)** pair, not of the Person globally. The same Person can be at different stages on different trajectories at the same time.

### Mode
The *shape* of a Trajectory. Distinct modes have distinct mechanics:

| Mode | Shape | When it ends | Examples |
|---|---|---|---|
| **Funnel** | One-way progression through stages, typically with conversion at the end. | When the person exits the funnel (closed-won, closed-lost, dropped). | Sales funnel; recruiting funnel |
| **Stewardship** | No progression. Ongoing cadence-intent for an established relationship. | When the underlying relationship ends. | Elder ↔ fellow elder; donor stewardship after gift |
| **Campaign** | Time-bounded effort to reach a defined outcome. People are placed onto the trajectory specifically for the campaign. | When the goal is achieved or abandoned (e.g., ED hired). Then the trajectory dissolves. | Hiring the next ED; running a capital campaign; promoting a new product launch |
| **Service** | Recency-driven, non-stageful. The relationship is healthy if the person has been served recently enough relative to expectation. | When the customer relationship ends. | HVAC customers; dentist patients; subscription services |

The same Person can be on a Funnel-mode trajectory and a Stewardship-mode trajectory simultaneously without conflict.

### Cadence intent
The expected frequency of touch between Me and a Person. **A property of the (Person × Trajectory) pair, not the Person alone.**

- Bob as an *ED-Search candidate*: weekly cadence (active Campaign).
- Bob as a *fellow elder*: quarterly cadence (Stewardship).
- Bob has no active trajectory: falls back to Sphere/Badge defaults.

When multiple trajectories apply to a Person, the **most active** cadence wins (typically: Campaign > Funnel > Stewardship > Service).

### Initiative / Goal
A user-defined, time-bounded outcome. May *spawn* a Campaign-mode trajectory and assign people to it. Examples: "Fill the ED role by August"; "Reach $X in production by Q4"; "Launch the new LinkedIn series and gather 500 subscribers by Sept."

Goals are distinct from Trajectories in that a goal is *about an outcome*; a trajectory is *about a sequence people travel through*. Most goals will produce one trajectory, but not all (a content-publishing goal has no trajectory; it has a cadence and a count).

---

## 3. The key conceptual unlock: Badge ≠ Stage

The current SAM model conflates these. A `Client` badge implies a position in the sales funnel. A `Lead` badge implies an earlier position. This conflation works only when *one funnel governs everyone*.

Once a user has more than one trajectory — or has people who are referral sources without ever being customers, or candidates for a campaign without being clients of anything — the conflation breaks:

- **Badge** says *what kind of person they are*.
- **Stage** says *where they are on a specific trajectory right now*.
- A person can have many Badges. A person can be on many Trajectories. The two axes are orthogonal.

This is the most important structural change. Everything else in this document follows from it.

---

## 4. The two signals: Health and Stage Progress

SAM today measures one thing per person: **Relationship Health** — a backward-looking, cadence-decay signal. ("Have I kept up with this relationship at its expected pace?")

The proposed model adds a second signal: **Stage Progress** — a forward-looking, action-oriented signal per (Person × Trajectory). ("Where is this person on this trajectory, and what's the next concrete move?")

| | Relationship Health | Stage Progress |
|---|---|---|
| **Scope** | Per Person, global | Per (Person × Trajectory) |
| **Direction** | Backward-looking (decay) | Forward-looking (next move) |
| **Answers** | "Have I been keeping up?" | "What do I do next with them?" |
| **Lives on** | The Person | A Trajectory entry |
| **Fades when** | Touches resume | Stage advances or trajectory ends |

Both signals matter, and they answer different questions. Today's SAM is silent on Stage Progress for everything outside the sales funnel.

---

## 5. Cadence intent rule

Today: cadence is a static default derived from the Badge (`Client` = 45 days, `Vendor` = 90 days, etc.). This is the right *fallback*, but it's the wrong *primary*.

Proposed rule:

1. If the Person is on one or more active Trajectories, the **most-active trajectory's cadence intent wins.**
2. Active priority: **Campaign > Funnel > Stewardship > Service**.
3. If no Trajectory is active, fall back to the **union of Sphere-default cadences** for the Spheres the Person belongs to (e.g., a fellow elder defaults to quarterly because the Elder Sphere defines that).
4. If still nothing applies, fall back to **Badge-derived cadence** (current behavior).
5. User can override at any of these levels.

When a Campaign ends — ED hired, capital campaign closed — its cadence intent dissolves cleanly. The person's expected cadence reverts to its baseline. No manual cleanup of "weekly nudges for Bob" required.

---

## 6. Interaction with existing systems

This is a checklist of what would need to change vs. stay the same.

### Stays as-is
- `SamPerson` and `roleBadges` (we just rename the *concept* — what the field stores is still badges).
- `RelationshipHealth` mechanics (cadence-decay math). The inputs change (cadence source); the engine doesn't.
- `GraphLens` system (Lenses become orthogonal filters; a Lens can run inside a Sphere or Trajectory).
- `PracticeType` (becomes a hint for *default Sphere + Trajectory bundle at first-run*, not a feature gate).

### Needs new model
- `Sphere` — user-defined, persistent.
- `Trajectory` — user-defined, with Mode and a stage list.
- `TrajectoryStage` — ordered list belonging to a Trajectory.
- `PersonTrajectoryEntry` — the (Person × Trajectory) join, holding current stage, cadence intent, and entry/exit dates. **This is where Stage Progress lives.**
- `PersonSphereMembership` — which Spheres a Person belongs to.

### Needs adaptation
- **`OutcomeEngine`** — every suggestion must carry a Sphere/Trajectory context, so feedback (dismiss, act, rate) is calibrated per-context. Dismissing an Elder-Sphere nudge shouldn't desensitize a Funnel nudge.
- **`CalibrationLedger`** — per-kind stats become per-(kind × Sphere) stats, with the existing per-kind aggregate as a roll-up.
- **`StrategicCoordinator`** — its specialist analysts (Pipeline Analyst, Time Analyst, etc.) gain a Sphere/Trajectory scope. The synthesizer produces a per-Sphere section when the user has 2+ Spheres; otherwise it renders today's shape.
- **`PipelineDashboardView`** — generalizes to "Trajectories" view; a Funnel-mode Trajectory still renders as today's pipeline.
- **Goals / `GoalType`** — Campaign-mode trajectories may be spawned by a Goal; the existing GoalType list needs a non-financial track.

### Specifically must NOT change
- **Sarah's existing experience**. A user with a single Sphere and a single Funnel-mode Trajectory must see the app she sees today. The new abstraction is invisible until she creates a second Sphere or Trajectory.
- **Pipeline analytics** (stage transitions, velocity, conversion). These remain first-class for Funnel-mode trajectories. Funnel mode is not a "specialization of Stewardship" — it has its own mechanics.

---

## 7. Open questions

These are unresolved as of 2026-05-11.

### Q1: Is Sphere a separate concept, or just a long-lived Stewardship Trajectory?

Collapsing them: drop `Sphere`, treat "Elder at Trinity" as a Stewardship-mode Trajectory with no end date. Pros: simpler model, fewer entities. Cons: loses the "which hat am I wearing" framing for the briefing and for goal-setting (a Goal feels Sphere-shaped: "as Chairman, I want to…").

Current lean: keep them separate. Sphere = identity context. Trajectory = a specific arc within (or across) a Sphere.

### Q2: Should Initiative/Goal be a first-class peer to Trajectory, or just a property of one?

Most goals will produce one Trajectory. But some goals (content-publishing cadence) produce no Trajectory at all. And some Trajectories aren't goal-driven (Elder Stewardship is just ongoing).

Current lean: keep `Goal` as a distinct concept that may *generate* a Trajectory; not every Goal does, and not every Trajectory has a Goal.

### Q3: Does a Person have a "primary Sphere," or are all memberships peer?

E.g., Pastor Bob is on the *ED Search* trajectory (a Chairman-Sphere campaign) but is also a *Pastor* in the Elder Sphere. When SAM coaches David about Bob, which framing wins?

Current lean: no primary Sphere. The active Trajectory's cadence and context win; if no trajectory is active, the briefing surfaces Bob under each Sphere he sits in (with light de-duplication).

### Q4: How should the model handle people who genuinely *don't* fit any Sphere?

Acquaintances, one-off contacts, casual relationships. Today they sit at the bottom of the contact list with no badges. They probably shouldn't be forced into a Sphere.

Current lean: Sphere membership is optional. People with no Sphere fall back to Badge-derived cadence (the current behavior).

### Q5: Do Trajectories interact across Spheres?

Cross-Sphere intelligence is one of the most interesting capabilities here: "your town-council contact might also be a real-estate referral source." Should Trajectories be able to declare cross-Sphere interactions, or is that purely an analytic overlay?

Current lean: keep Trajectories Sphere-scoped; cross-Sphere insight is a job for the Strategic Coordinator at synthesis time.

---

## 8. What this document does *not* yet decide

- UI shape. No tab structure, no sheet design, no navigation flow.
- Migration. No story yet for how existing users get from today's model to this one.
- AI prompt changes. The specialist analysts will need Sphere/Trajectory context; the wording isn't specified.
- Privacy implications of more granular per-Sphere coaching feedback.
- Performance: Stage Progress signals will multiply the number of per-Person computations roughly by the average trajectory count.

These are deliberately left open until the cross-industry research (see `relationship_research.md`) is in hand and we've decided whether the vocabulary above is the right one.

---

## Appendix: Glossary at a glance

| Term | One-line definition |
|---|---|
| Person | A contact. |
| Relationship | The persistent connection between Me and a Person. |
| Badge | A label saying what kind of contact they are. |
| Sphere | A hat I wear — a life-context I inhabit. |
| Trajectory | A named sequence of stages a Person can travel through. |
| Stage | Current position on a Trajectory. |
| Mode | The shape of a Trajectory: Funnel, Stewardship, Campaign, Service. |
| Cadence intent | Expected touch frequency, per (Person × Trajectory). |
| Initiative / Goal | A time-bounded outcome; may spawn a Campaign-mode Trajectory. |
| Relationship Health | Backward-looking cadence-decay signal. Per Person. |
| Stage Progress | Forward-looking next-move signal. Per (Person × Trajectory). |
