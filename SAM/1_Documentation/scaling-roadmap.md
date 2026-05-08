# SAM — Scaling Roadmap

**Created**: 2026-05-07
**Status**: Phase 0 not yet started
**Owner**: David
**Related**: `context.md` §2 (Architecture), `changelog.md` (May 7, 2026 launch performance pass)

---

## Why This Document Exists

After Sarah's first ~2 months of real use, her dataset has grown to ~13.7K evidence rows / ~1.6K contacts. We just shipped a Phase-1 round of fixes (May 7, 2026 — see `changelog.md`) that eliminated the worst O(P × E) hot spots and several launch-time main-actor monopolizations. Those fixes were *algorithmic* — they did not change SAM's underlying architecture.

At Sarah's projected 1y / 3y / 5y scale, the same surfaces will fail again with *linear* scans instead of nested ones. Before we commit to bigger architectural changes (per-person rollup tables, `ModelActor` extraction, cold archival, possible escape to GRDB for hot paths) we need data:

1. **What does Sarah's growth actually look like?** — separate import-burst from steady-state.
2. **Which surfaces are slow in the wild?** — instrument production so hangs and slow paths self-report.
3. **How does SAM scale in the lab?** — synthetic load tests at 5×, 10×, 50× current size.

Only then do we decide *which* architectural changes are worth the cost.

---

## Scope

**In scope:** macOS (SAM) data layer, concurrency model, observability, and growth modeling.

**Out of scope (for now):**
- iPhone (SAM Field) data layer. Sarah's iPhone holds email metadata, contacts, recordings staged for upload, and trips — no evidence, no insights, no outcomes. Trivial growth even at 5y. Revisit only if the Field model set expands.
- Cloud sync of large data sets. Per `CLAUDE.md`, all processing stays on-device.

---

## Phase 0 — Dataset Audit (1–2 days, one-shot)

**Goal**: produce a quantitative model of Sarah's data growth that distinguishes the initial-import burst from steady-state ongoing usage. Use that model to project 1y / 3y / 5y per model.

**Deliverables**:

1. **Debug menu item** — `Settings → Diagnostics → Dataset Audit`. Walks every SwiftData model and emits a single JSON report:
   - Row count and approximate bytes per model.
   - Histogram by week of creation. Use `createdAt` where present; for models that lack it, fall back to `occurredAt` clustered by week as a rough proxy for the import cliff.
   - Per-source breakdown for `SamEvidenceItem` (mail, calendar, messages, recordings, notes, …).
   - Audio + transcript on-disk file sizes, separately from row counts.
   - Undo history and outcome history row counts (the silent growers).
   - Pending uploads, analysis artifacts, and other ancillary tables.

2. **Schema patch** — if any heavily-written model lacks `createdAt`, add it now. We can't reconstruct historical creation timestamps but we can stop the bleeding for Phase 0+ data.

3. **Run + analyze** — Sarah runs the audit on her Mac, emails us the JSON, we plot it.

**Exit criteria**: a single chart showing import-burst (first ~7 days post-onboarding) vs. trailing weekly steady-state, broken down by model. From that we extrapolate 1y / 3y / 5y per model and sum total expected DB size.

**Risk**: low. One-shot diagnostic, no production impact.

---

## Phase 1 — Watchdog + Signposts + Auto-Diagnostics (~1 week)

**Goal**: instrument production so Sarah's real-world hangs and slow paths self-report. This is where most of our future optimization budget will go, so getting it right is high-leverage.

**Deliverables**:

### 1a. MainActor hang watchdog

A detached `Task` on `.utility` priority pings `MainActor.run { }` every 250ms with a 1s timeout. On miss:
- Capture `Thread.callStackSymbols` for the main thread.
- Snapshot current state: active coordinator, last completed `os_signpost`, dataset sizes (rough counts), recent `os_log` tail.
- Write `hang-{ISO8601}.json` to `~/Library/Application Support/SAM/diagnostics/`.

### 1b. `os_signpost` instrumentation

Add signposts on the surfaces we already know are hot, plus the launch sequence:
- Launch phases (each — see `SAMApp.scheduleDeferredLaunchWork`).
- `OutcomeEngine` scanners (each scanner gets its own signpost).
- `MeetingPrepCoordinator.buildBriefings` and `buildFollowUpPrompts`.
- `InsightGenerator.generateRelationshipInsights`.
- `DailyBriefingCoordinator` gather methods.
- Import sweeps (calendar, mail, contacts, messages).

Signposts let Instruments visualize the timeline and the watchdog payload references the most recent active signpost so we know what was running when it hung.

### 1c. MetricKit subscriber

`MXMetricManager` gives us system-level CPU / memory / disk / hang rollups. Subscribe at app launch; dump daily payloads into the same diagnostics directory.

### 1d. Auto-delivery to `SAM@stillwaiting.org`

Gated behind a build-config flag `INTERNAL_TELEMETRY=1` so it's compiled out of public release builds. Sarah pre-approves automatic transmission once in Settings; for v1 internal builds we treat that approval as standing.

**Subject format**: `SAM Diag [{anomaly-type}] [{macHostnameHash}] [{YYYY-MM-DD-HHmm}]`

Anomaly types: `hang`, `slow-launch`, `metric-rollup`, `audit`.

**Mechanism (recommended)**: HTTP POST to a small webhook on a domain we control. A Cloudflare Worker or a 20-line script on `stillwaiting.org` is enough. Subject becomes a header or query param; payload is the JSON. This is more reliable than SMTP (no TLS / rate-limit / app-password fragility) and easier to triage than mailto: (which has no reliable attachment story across mail clients).

**Fallback**: SMTP from app, app-password in Keychain. Works, but fragile.

**Privacy posture**: per `CLAUDE.md` the public release will revert to opt-in per-send. The build flag enforces that.

**Exit criteria**: Sarah uses SAM normally for ~1 week. We receive ≥1 hang report, ≥7 daily metric rollups, and her Phase-0 audit JSON. We now have a list of *real* hot paths ranked by impact, not guesses.

---

## Phase 2 — Synthetic Load Harness (~3–5 days)

**Goal**: replicate what Phases 0 + 1 told us at 5×, 10×, 50× scale, so we can predict where SAM will hurt before users do.

**Deliverables**:

1. **"Synthetic Sarah" generator** — uses Phase 0's source/kind ratios to produce databases at configurable scale (50K, 100K, 500K evidence). Realistic distributions, not random uniform: same per-source ratios, same per-person evidence-count distribution, same date density.

2. **Benchmark suite** — over those databases:
   - Cold launch wall time + peak memory.
   - Briefing assembly wall time.
   - Search wall time across a fixed query set.
   - `MeetingPrepCoordinator.buildBriefings` and `buildFollowUpPrompts`.
   - Contact import sweep (importing on top of an existing populated DB).
   - `OutcomeEngine.generateOutcomes` full pass.
   Same `os_signpost` markers feed the same JSON shape, so Phase 1 dashboards work for synthetic runs too.

3. **Regression harness** — runnable under `xcodebuild test` so future changes get a regression check against (operation × dataset size → wall time, peak memory, hang count).

**Exit criteria**: a published table of (operation × dataset size → wall time, peak memory, hang count). This is where we decide if SwiftData holds at 100K, or if specific paths need to escape to GRDB.

---

## Phase 3 — Decision Point (review, no build)

With Phase 0 (real growth model), Phase 1 (real hot paths), and Phase 2 (scaling curves) in hand, decide:

- **Per-person rollup tables** — highest leverage if "for each person, scan evidence" patterns dominate Phase 1 hang reports. A `PersonInteractionSummary` model with `mostRecentEvidenceAt`, `evidenceCount`, `topicVector`, etc., maintained incrementally on insert/update.
- **`ModelActor` extraction** — if main-actor hangs cluster around large reads, move heavy repositories off MainActor. Coordinators stay `@MainActor`; services move to a custom `ModelActor` and return `Sendable` DTOs.
- **Indexed predicates** — cheap if SwiftData supports the index we need (`SamEvidence.occurredAt`, `source`, `kind`, FK to `SamPerson`). Audit every `#Predicate` against indexes.
- **Cold-archival flag** — `SamEvidence.archivedAt` plus default "active only" filter for evidence > N years old.
- **Undo history caps** — 30-day cap is unbounded by row count; add a row cap too.
- **GRDB / SQLite escape** — for any single hot path SwiftData can't handle.

**No code in Phase 3.** It's a review meeting with three datasets in hand.

---

## Phase 4+ — Implement Based on Data

Scoped by Phase 3. We don't pre-commit to ordering. Likely order based on what we expect Phase 1 to reveal:
1. Per-person rollup tables.
2. `ModelActor` extraction for heavy reads.
3. Indexed predicate audit.
4. Cold archival policy.
5. (Conditional) GRDB escape for one or two hot paths.

But the data may surprise us. We won't pretend to know until we see the reports.

---

## Recommended Kickoff

**Phase 0 first.** It's a few hours of work, gives us the growth model immediately, and the diagnostics dump format is reusable in Phase 1. Phase 1 lands right after. Phase 2 can run in parallel with Phase 1 if useful.

---

## Open Questions

1. **Webhook vs. SMTP** for Phase 1d auto-delivery. Recommended: small webhook on `stillwaiting.org` (more reliable, easier to triage). Confirm with David before building.
2. **`createdAt` schema patch** — which models lack it? Phase 0 starts with an audit of timestamps available; if too many models lack `createdAt`, the patch becomes a Phase 0 prerequisite rather than an aside.
3. **Build-flag plumbing** for `INTERNAL_TELEMETRY=1`. Confirm where to add the flag (xcconfig vs. scheme env var) so debug builds get auto-send and release builds don't.
4. **Trip data backup gap** (separate but related) — trips are not in the backup payload and not CloudKit-synced, so they're lost on reinstall. Out of scope for the scaling roadmap, but worth tracking as a related data-durability item.
