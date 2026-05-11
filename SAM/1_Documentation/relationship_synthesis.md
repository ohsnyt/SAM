# SAM Model vs. Expert Frameworks — Synthesis

**Status:** Working draft, 2026-05-11. Compares the model defined in `relationship_model.md` against the cross-industry research in `relationship_research.md`. Identifies where our model is well-aligned, where it may be measuring the wrong things, and what to change before building.

---

## Executive summary

Three findings dominate:

1. **The vocabulary is mostly right** — Badge ≠ Stage, Sphere as life-context, Trajectory with Mode, cadence intent per (Person × Trajectory), and the Health/Stage-Progress split all hold up against six independent expert frameworks. Several would call this a more rigorous model than they have themselves.
2. **The Mode taxonomy is missing one distinction.** "Stewardship" silently conflates two operationally different things — *organism* (active tending, can decline) and *covenant* (abiding, persists through silence). The research treats these as fundamentally different ontologies, and they need different coaching mechanics.
3. **The Health metric is measuring the wrong things in three specific ways**: absolute decay instead of *relative drift*, no concept of *initiation asymmetry*, and no concept of *positive-to-negative balance*. Each is empirically the strongest signal in its respective domain. Fixing them is a measurement change, not a vocabulary change.

The rest of this document substantiates each finding and proposes concrete model changes.

---

## What the model gets right

The research broadly *validates* the model's core moves. The most important alignments:

| Model claim | Expert validation |
|---|---|
| Badge ≠ Stage; orthogonal axes | Donor cycle, real-estate SOI, and pastoral typologies all treat *what kind of person* separately from *where they are on any specific arc*. The conflation in SAM's current Lead/Applicant/Client model is unusual to the WFG funnel and doesn't generalize. |
| Sphere as user-defined life-context | Every non-funnel framework partitions relationships by life-context: donor portfolio, pastoral flock, real-estate SOI, marriage. SAM is correct to make this explicit. |
| Multi-trajectory people | Donor moves-management explicitly models the same donor as being on the *cultivation* arc and the *stewardship* arc simultaneously. Real-estate SOI segments overlap. Bob-as-Pastor-and-ED-candidate is a real case the research expects. |
| Two signals: Health (backward) + Stage Progress (forward) | Every domain distinguishes *neglect* from *progress*. Sales has "where in the funnel" and "communication latency." Donor work has "moves" and "lapsed." Pastoral has "name-known" and "back-door departures." SAM is right to track both. |
| Cadence intent as (Person × Trajectory), not (Person) | Buffini's A/B/C, Keller's 33 Touch / 12 Direct, and donor portfolio cadence are all *role-in-arc* cadences, not personal cadences. |

These validations are not unanimous, but the convergence across six independent traditions is unusually strong. The vocabulary is defensible.

---

## Where the model may be measuring the wrong things

### Finding 1: "Stewardship" mode conflates two distinct ontologies

The research surfaces three distinct ontologies of relationship:

- **Portfolio** — relationships are *managed*. Bounded capacity, named stages, cadence as schedule. (Sales, fundraising, real estate.)
- **Organism** — relationships are *tended*. Living things with health states; decline is pathology; cadence is metabolism. (Lencioni teams, Gottman couples, active pastoral care.)
- **Covenant** — relationships are *abided in*. They pre-exist any particular interaction and persist through silence. Cadence is fidelity, not maintenance. (Pastoral identity, marriage in its mature phase, lifelong friendships, family.)

SAM's Mode taxonomy maps cleanly to two of these:

- **Funnel** = Portfolio.
- **Campaign** = a time-bounded Portfolio mode that dissolves on completion.
- **Service** = a recency-driven Portfolio variant.

But "Stewardship" silently merges Organism and Covenant. Operationally this matters:

- **Organism** relationships should generate cadence-decay alerts. Fellow elders who haven't been engaged in a quarter genuinely *are* decaying.
- **Covenant** relationships should *not* generate calendar-driven nudges. Eugene Peterson would argue — and Henri Nouwen would say it more sharply — that a covenantal relationship that needs a 90-day reminder has already failed in some way. What covenant needs is *moments honored* (birthdays, life events, crises), not scheduled touches.

A wife, a long-time spiritual mentor, a 30-year client, a brother — these are not "due for outreach in 73 days." Treating them as such is a category error the user would feel as deeply wrong.

**Proposal:** Split Stewardship into two Modes — **Stewardship** (organism) and **Covenant** (abiding). Coaching for Covenant relationships is event-driven (life events, anniversaries, crises, traditions) rather than cadence-driven. The Health metric for Covenant relationships should be near-silent unless something specific has happened — but Stage Progress should be replaced with a different signal entirely: *presence-at-key-moments*.

Updated Mode taxonomy:

| Mode | Shape | Health signal | Forward signal |
|---|---|---|---|
| Funnel | One-way stage progression | Stall in stage; cycle-time drift | Next stage move |
| Stewardship | Active tending; cadence-bound | Cadence drift (relative); positive/negative balance | Suggested re-engagement |
| Campaign | Time-bounded, goal-driven | Cadence drift within the campaign window | Next campaign-specific move |
| Service | Recency-driven, non-stageful | Last-service recency | Reorder/re-engage prompt |
| **Covenant** | Abiding | *None by default; deviation only* | *Presence at moments* (life events, traditions, crises) |

### Finding 2: Health is measured absolutely; it should be measured as *drift*

This is the single highest-leverage measurement change. The research finding is unanimous: across sales, fundraising, real estate, pastoral care, and marriage, **the leading indicator of decline is a contact's pace slowing *relative to its own established baseline*, not against an absolute threshold.**

SAM today uses static role-based thresholds: Client = 45 days, Vendor = 90 days, etc. A Client who has historically been a once-a-month conversation, then drops to once-every-three-months, *isn't* "still healthy because under 45 days" — they've halved their pace, which is the actual decline signal.

The `MeetingPrepCoordinator.computeHealth` engine already has the inputs (`cadenceDays`, `effectiveCadenceDays`, `overdueRatio`, `velocityTrend`) — but the static `RoleVelocityConfig` thresholds dominate the score for any contact without enough interaction history. The fix:

- **Drift as the primary signal**: `(current gap) / (rolling baseline gap)`. Above 1.5 = warning; above 2.0 = at-risk.
- **Static thresholds become the floor**, used only when the contact's own baseline is too sparse to be reliable (fewer than ~5 prior interactions).
- **Trajectory-derived cadence overrides both** when the contact is on an active Trajectory with a specified cadence intent.

### Finding 3: Initiation asymmetry is not tracked

The research is unanimous a second time: when *only one party* is initiating, the relationship is already dying. This appears in sales ("every email seller-initiated"), real estate ("past clients don't reach in"), donor work ("donor never makes unsolicited contact"), and marriage ("no bids being made").

SAM stores `daysSinceLastOutbound` and `daysSinceLastInbound` separately but doesn't compute a *direction ratio* and doesn't surface initiation asymmetry as a distinct health signal.

**Proposal:** Add a per-contact `initiationRatio` over a rolling window (e.g., 90 days). Two flags:

- **User-driven**: ratio is heavily user-initiated → "you've been the sole driver of this relationship; their response patterns suggest waning interest."
- **Contact-driven, ignored**: ratio is heavily contact-initiated → "they've been reaching out; you've been slow to reciprocate." This is the Gottman "turning away from bids" signal — the most predictive negative in his entire dataset.

The second variant is especially important: SAM today is *neglect-blind* to a contact who keeps initiating but isn't being responded to. That's the most damaging failure mode for the kind of relationship the user actually cares about.

### Finding 4: Positive/negative interaction balance is not measured

Gottman's empirical finding — the **5:1 magic ratio** in conflict, **20:1** in everyday interaction — is the closest thing in this research to a universal law. The basic insight is broader than couples: relationships need a high ratio of positive moments to negative ones, and the ratio's drift downward is a stronger predictor than any single negative event.

SAM has sentiment data on notes and a `qualityScore30` derived from interactions, but doesn't compute a positive-to-negative ratio per relationship. Burk's parallel finding in donor work — "meaningful contacts, not raw touches" — points the same direction: count *texture*, not just volume.

**Proposal:** Compute a rolling positive-to-negative ratio per (Person, 90-day window). Flag drift below 5:1 as a coaching signal. Tune the threshold per Mode (Covenant relationships will run much higher in normal operation; sales relationships will run lower).

### Finding 5: Funnel terminus is wrong; it should exit into Stewardship

Sales, donor, and real-estate frameworks *all* loop. The strongest of them — Buffini (82% of real-estate transactions are referral/repeat), Burk (stewardship loops to cultivation), donor moves-management — explicitly model the post-conversion phase as the most valuable and most-neglected part of the relationship.

SAM's WFG funnel treats `Client` as a stable end-state. Once someone is a Client, there's no successor arc; they just sit there until someone manually checks in.

**Proposal:** Make explicit that completing a Funnel-mode Trajectory should *spawn* a Stewardship-mode Trajectory for the same person, inheriting the relationship and starting a stewardship cadence. A Client *without* an active Stewardship trajectory is a coaching warning ("this person is in your client list but you've defined no ongoing care plan").

This is exactly the structure that the donor cultivation cycle assumes, that Buffini bakes into "Work by Referral," and that pastoral retention assumes about church attenders.

### Finding 6: Trust has two currencies; the model doesn't represent them

The most interesting *divergence* across the research: half the frameworks build trust through warmth-and-presence (Sandler, Buffini, pastoral, Gottman), the other half through earned-authority-competence (Challenger, Lencioni's leadership, major-gift fundraising). They are not aliases — they describe genuinely different currencies of trust, and the *right* currency depends on what the contact needs.

This isn't a vocabulary gap so much as a *coaching* gap. SAM's coaching prompts assume one tone (mostly warmth). The same nudge — "check in with Bob this week" — should be coached differently if Bob's trust currency is competence (then: bring him an insight) vs. warmth (then: be present, not productive).

**Proposal:** Add an optional `trustCurrency` attribute per relationship, with values `warmth | competence | both`. Default inferred from the contact's primary Badge or active Trajectory's Mode. Used to steer the coaching prompt's tone, not as a structural change to the model.

### Finding 7: We have no concept of "what I owe the relationship next"

Multiple expert frameworks share an emphasis on *deposits before withdrawals*:

- Burk: prompt acknowledgment, specific impact, measurable reports.
- Buffini: "give it out in slices, it comes back in loaves."
- Nouwen: hospitality.
- Lencioni: leader vulnerability first.
- Gottman: emotional bank account.

SAM models cadence (how often) and stage (where on the funnel) but not the *texture* of what's owed next. The OutcomeEngine generates suggestions, but they're action prompts ("schedule a call"), not relational ledgers ("you've made three asks of Bob without a deposit").

**Proposal:** Track a coarse *ask/give ratio* per relationship over a recent window. When the ratio tips toward asking (especially within Funnel/Campaign modes where it naturally does), surface a Buffini-style "give before ask" prompt.

This is half-data-model, half-coaching-prompt. The model needs a per-interaction tag (`give` | `neutral` | `ask`); the engine uses the ratio.

---

## Specific operational borrowings

These are smaller, well-defined imports from the research that improve the model without changing its shape:

| Borrowing | Source | Where it lives |
|---|---|---|
| **A/B/C cadence ladder** as default Sphere cadences | Buffini, Keller | Each Sphere ships with default A/B/C cadences (monthly / quarterly / biannual). User overrides per-contact. |
| **33 Touch / 12 Direct** as empirical baselines for new Funnel Sphere | Keller | "Real Estate" and similar Funnel-mode Sphere templates can ship with these as starting cadences. |
| **48-hour acknowledgment rule** | Burk | Coaching nudge: any contact who reached out >48h ago without an acknowledgment surfaces in the briefing. |
| **Four Horsemen pattern flags** | Gottman | Optional advanced coaching feature: detect criticism/contempt patterns in user's outbound drafts and warn. (Defensive, not primary.) |
| **BRAVING checklist** | Brown | Surfaceable trust-diagnostic UI when a relationship is flagged as troubled. |
| **125–150 active prospects ceiling** | Major-gift convention | When a user's Funnel-mode Trajectory exceeds ~150 active people, coach toward triage. |
| **"Name the person" rule** | Peterson, Burk, Buffini convergence | Reinforces our existing AI-output quality standards. No model change. |

---

## Recommended model revisions

In priority order:

1. **Split Stewardship into Stewardship and Covenant.** New Mode in the taxonomy. Covenant relationships are silent by default; coaching is event-driven, not cadence-driven. *(Finding 1.)*
2. **Refactor Health to lead with drift, not absolute thresholds.** The contact's own baseline cadence dominates; role defaults become the fallback. *(Finding 2.)*
3. **Add `initiationRatio` and surface initiation asymmetry as a top-level coaching signal.** Especially the contact-initiated-but-ignored variant. *(Finding 3.)*
4. **Compute positive-to-negative ratio per (Person, window) and tune by Mode.** *(Finding 4.)*
5. **Make Funnel completion spawn a Stewardship Trajectory by default.** *(Finding 5.)*
6. **Add `trustCurrency` as an optional coaching-only attribute.** *(Finding 6.)*
7. **Tag interactions as give/neutral/ask and surface ratio drift.** *(Finding 7.)*

Items 1–5 are likely to matter for every user. Items 6–7 are coaching-quality refinements that depend on item 1–5 being right first.

---

## What's left open

- **Should "Covenant" Mode require explicit user opt-in per relationship**, or should the system infer it from relationship duration and depth? Both are defensible; inference risks miscategorizing a long-tenured Client (who is actually a Covenant relationship) as a stalled deal — exactly the category error we're trying to avoid.
- **How does the AI tone change per Mode?** The "two currencies of trust" insight implies different coaching voices, but the engineering of that is a separate design pass.
- **What does the Strategic Coordinator do when a user has 3+ Spheres of unequal weight?** The research is silent — no expert manages a portfolio of identity-spheres. This is a new design space.
- **Does the model survive the "casual friend" case?** Someone who is neither covenantal nor on any trajectory. The current fallback (Badge-derived cadence) probably works, but worth a walkthrough.

---

## Closing note

The most important takeaway is the second-order one: **a single relationship-health score, applied uniformly across a contact list, will commit category errors that the user will feel as wrong.** The same number ("Bob is at 67% health") means radically different things for a Lead (the deal is stalling), an active Elder relationship (you're due for a coffee), a 25-year mentor (probably nothing — covenant doesn't decay on a 90-day clock), and a recent referral source (your follow-through is overdue).

SAM's existing quality bar — "concrete, people-specific, copy-paste ready" — is exactly the right standard for outputs. The model changes above are about applying the same bar to *measurements*: making sure each number being computed actually corresponds to a relationship reality the user would recognize.
