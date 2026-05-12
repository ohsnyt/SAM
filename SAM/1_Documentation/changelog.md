# SAM — Changelog

**Purpose**: This file tracks completed milestones, architectural decisions, and historical context. See `context.md` for current state and future plans.

---

## Documentation: lean `context.md` + satellite docs (2026-05-12)

**What**: Rewrote `context.md` from 568 lines to 364 lines, extracting eight self-contained subsystems into satellite docs under `1_Documentation/`:

- `architecture/social-import-pipeline.md` — Async export auto-detection pipeline (Substack / LinkedIn / Facebook), state machine, watcher persistence
- `architecture/app-lock-architecture.md` — Lock state, overlays, draft preservation, security primitives
- `architecture/crash-recovery.md` — Startup hardening, crash detection (incl. debugger-attached suppression), Safe Mode
- `architecture/compliance-architecture.md` — Practice-type compliance scanning maintenance rules
- `architecture/contact-photo-and-invitations.md` — Photo drop / paste → Apple Contacts; rich invitation + sent-mail detection
- `architecture/transcription-and-summary.md` — Recording contexts, auditable summary fields, lecture pipeline
- `architecture/text-scaling.md` — `samFont` / `samTextScale` rules
- `architecture/accepted-warnings.md` — Warnings we live with on purpose

Promoted two recently-validated architectural patterns to top-level sections in `context.md`:

- **§8 Modal Arbitration** — `ModalCoordinator` presentation arbiter with priority levels (`.opportunistic` < `.coaching` < `.userInitiated` < `.critical`) + `.managedSheet` modifier; standalone `Window` scenes for long-running social imports so they can't be dismissed by a coincident background coaching sheet.
- **§7 SwiftData Single-Context Rule** — `@MainActor` repositories whose models are bound by SwiftUI `@Query` must share `container.mainContext`. Documents both manifestations (cross-repo writes; repo-vs-mainContext deletes) and the `\SamPerson.roleBadges`-style crash that surfaces in the next render, not at the write site.

**Why**: The previous `context.md` was 568 lines and growing. The user's stated goal: future development should not "accidentally skip critical context because the context file is too large to retain the critical context." Lean main doc + satellite docs lets future AI/developer sessions load the critical material without burning context on subsystem details that are only needed when actively touching that subsystem.

---

## CrashReport: suppress false positives from debugger-stop (2026-05-12)

**What**: `CrashReportService` now tracks whether the previous session had Xcode/lldb attached (`sysctl` + `kinfo_proc.p_flag & P_TRACED`). On the next launch, if `sam.cleanShutdown` is `false` AND no `.ips` was written AND the previous session had a debugger attached, treat it as a clean dev termination and skip the crash banner. Also dropped the `buildMinimalReport()` fallback that produced empty noise emails.

**Why**: The crash banner fired on every "Stop" from the Xcode debugger because `applicationShouldTerminate` (which sets `sam.cleanShutdown = true`) is bypassed by debugger stops, and an empty `.ips` scan still flagged "previous session ended uncleanly." Real crashes from a debugged session still surface because a `.ips` is still written.

---

## PeopleRepository: share mainContext + delete by ID (2026-05-12)

**What**: Two fixes for the same root cause — cross-context SwiftData crashes.

1. `configure()` now binds to `container.mainContext` instead of constructing a private `ModelContext`. SwiftUI `@Query` reads the mainContext; when the repo deleted on a separate context, the mainContext kept live `SamPerson` references pointing at deleted rows, and the next render crashed on `"backing data was detached from a context without resolving attribute faults"` reading e.g. `SamPerson.roleBadges`.
2. `delete(person:)` → `delete(personID:)`. Passing a `SamPerson` from a different context (e.g. SwiftUI `@Query`) silently no-ops in SwiftData; re-fetching by ID guarantees the model is bound to the repo's context before mutation.

**Why**: Reproduced after a contacts import merged a duplicate while the People list was on screen. Latent for months — the same family of bug also showed up in `EvidenceRepository.refreshParticipantResolution()` once a 14K-item back-fill widened the detach window.

**Migration roadmap**: 24 other `@MainActor` repos still hold private `ModelContext` instances. Migrate proactively when next touching delete/merge logic in any of them.

---

## App architecture: presentation arbiter + OutcomeBundle redesign + comms backfill + shutdown extension (2026-05-12)

Four intertwined changes shipped together because their `SAMApp.swift` edits overlap.

### Presentation arbiter

**What**: `ModalCoordinator` promoted from a lock-arbitration utility to a real presentation arbiter. Replaces ~24 raw `.sheet` modifiers with `.managedSheet` across view files. Adds priority levels (`.opportunistic` < `.coaching` < `.userInitiated` < `.critical`) and conflict policies. Long-running social imports (LinkedIn / Facebook / Substack / Evernote) moved to their own `Window` scenes triggered via notifications observed by `AppShellView`'s `SocialImportWindowObservers`.

**Why**: macOS allows only one sheet per window. A post-call capture sheet (background-triggered) was dismissing an in-progress LinkedIn import sheet (user-initiated). The new arbiter rejects/queues lower-priority requests; standalone Windows make long-running flows immune to sheet collisions altogether.

### OutcomeBundle redesign

**What**: Per-person bundled outreach replaces per-topic `SamOutcome` for outreach-class kinds. New SwiftData models: `OutcomeBundle`, `OutcomeSubItem`, `OutcomeDismissalRecord`, `WeeklyBundleRating`. New `OutcomeBundleGenerator` coordinator, `OutcomeBundleRepository`, `WeeklyBundleRatingRepository`, `WeeklyBundleReviewView`, `OutcomeBundleCardView`.

One-time dismissal-preserving migration (`SAMModelContainer.runOutcomeBundleWipeIfNeeded`, guarded by `sam.migration.outcomeBundleWipeV1`): for every legacy outreach `SamOutcome` with status `.dismissed`, persist an `OutcomeDismissalRecord` so the new bundle generator doesn't re-fire it; then delete the legacy rows so the new generator starts clean. Non-person and non-outreach outcomes (preparation, training, compliance, content creation, setup, growth) are left untouched.

**Why**: The previous design generated five separate cards per person on a busy day — Sarah's queue was visually noisy. Bundling collapses multiple signals (life event, stale cadence, pending follow-up) into one card with sub-items that can be individually skipped or completed. Dismissal preservation honors the user's prior choices across the redesign.

### Comms hint backfill

**What**: One-time idempotent pass (`EvidenceRepository.backfillHandleHints`, guarded by `handleHintBackfillDone_v1`) to populate `rawPhone` hints on iMessage / call / WhatsApp evidence imported before phone hints were stored.

**Why**: Older evidence rows lacked the rawPhone metadata that newer outcome scoring uses for participant resolution.

### Shutdown extension

**What**: `ShutdownCoordinator.settle()`'s default timeout raised so MLX-aware coordinators (which can need 1+ minute to release their model context cleanly) have room to finish before teardown. Re-entrant `applicationShouldTerminate` guard prevents a second settle pass from racing the in-flight one if the user clicks Quit twice.

**Why**: A 15-second timeout was occasionally too short for the MLX bench coordinator to release its compute resources, leading to teardown crashes. The second-Quit race was a separate latent bug that would have surfaced eventually.

---

## Graph: dragged nodes' edges follow the cursor when bundling is on (May 10, 2026)

**What**: Fixed a regression where dragging a node in the relationship graph left its connected edges behind when edge bundling was enabled.

**Why**: `drawEdges` renders edges from `coordinator.bundledEdgePaths[edge.id]` — a cache of control points computed at layout time against the original node positions. Dragging mutates `coordinator.nodes[idx].position`, but the bundled-path cache never invalidated, so edges visually stayed put while the node moved.

**How**:
- In `drawEdges` (`RelationshipGraphView.swift`): collect the active drag set (`draggedNodeID` + group/cluster offset members) and skip the bundled-path branch for any edge touching one of those nodes — they fall back to a straight line that follows the live position.
- In `handleDragEnded`: if any node was dragged and bundling is on, call `coordinator.recomputeEdgeBundling()` so the cache catches up to the new positions and bundled curves resume.

Edges now follow the cursor during drag and re-bundle once the user releases.

---

## Graph layout: per-edge rest length in stress majorization + growth animation (May 10, 2026)

**What**: Two changes to the force-directed layout:

1. **Stress majorization is now hierarchy-aware.** Replaced `desiredDist = idealEdgeLength × hopCount` with a per-edge rest-length sum along Me's BFS tree. Each edge's rest length is sized from the parent's child count: `restLen(parent → child) = max(baseEdgeLen, K × leafArc / 2π)` where K = parent's child count. Distance from Me to any node = sum along the BFS tree path; pairwise desired distance = path through the LCA. Pairs not in Me's tree (orphans) fall back to the original hop-count formula.
2. **Growth animation toggle** in the Visibility menu. When enabled, the next graph build reveals nodes one at a time in BFS order from Me, with a small delay (default 50 ms) between each. Final positions are already computed before the animation starts — only visibility changes.

Cache key bumped to `graphLayoutCache_v7`.

### Why

User insight: "is it possible to calculate the distance of the hop of secondary nodes only based on the number of nodes to their parent node? Why do we calculate it as 2× the distance of the first node?"

The old formula came from textbook stress majorization, which is designed to preserve graph-theoretic distances in the embedding. For SAM's Me-centered view that's the wrong objective — it literally tells every two-hop node to sit twice as far as one-hop nodes regardless of local fan-out, producing the visible "second band" of L2 nodes that all look identical to the user but were placed at double radius by the algorithm.

Per-edge rest lengths fix this at the source: a parent with 50 children needs longer outgoing edges (so its children fan non-collidingly), but a parent with 2 children gets a short edge. L2 distance from Me becomes `L1distance + L2offset`, where the L2 offset can be much smaller than the L1 distance — eliminating the rigid 2× band.

The growth animation is for visual debugging: by watching nodes appear in BFS order, the user can see whether outliers settle far because of structural reasons (their parent has many siblings) or because of late-stage algorithmic drift.

### Implementation notes

- `applyStressMajorization` now takes `edges`, `nodeIndex`, `meID`. When `meID` is non-nil, it precomputes a `treeDist[i][j]` matrix using LCA over Me's BFS tree.
- Parent for each non-Me node = lower-layer neighbor with the strongest edge weight (deterministic across runs).
- LCA computation is per-pair via parent-chain walks, O(N² × depth). For N=400 and depth ~4 that's ~640K ops — done once per layout.
- `growthAnimationEnabled` and `growthAnimationDelayMs` are UserDefaults-backed under `sam.graph.growthAnimation*`.
- `progressiveRevealedIDs: Set<UUID>?` gates `applyFilters` during the reveal walk; cleared when the walk completes.
- Cached layouts skip the animation (positions are already finalized — toggle takes effect on the next fresh compute, e.g. via the toolbar Rebuild button).

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- User to verify visually: enable growth animation, hit Rebuild, watch L1 vs L2 distances.

---

## Graph layout: reverted both Hooke and radial back to original physics (May 10, 2026)

**What**: Restored `GraphBuilderService.swift` and `RelationshipGraphCoordinator.swift` to the state at commit `0c38ef9` — i.e. the original force-directed layout with linear-pull attraction (`force = strength * weight * dist`) and the full Phase 1–4 pipeline (initial placement → stress majorization → Fruchterman-Reingold → PrEd). Cache key bumped to `graphLayoutCache_v6` to invalidate cached positions from the v4 (Hooke) and v5 (radial) experiments.

### Why

Both the Hooke's-law spring (`152aa93`) and the deterministic radial layout (`2e97d53`) produced worse visuals than the original physics. The radial layout in particular pushed L2 nodes onto a hard concentric ring far from their parents, exposing the structural rigidity of fixed-radius layers.

User direction: "Can we revert back to the first physics model we had? Then let's examine what is pushing out that second band so far." The plan is to debug the band-gap pathology in-place on the original layout rather than keep replacing the algorithm.

### Next

Investigate what causes the visible "second ring" of nodes that sit roughly 2× the inner-ring distance under the original force-directed model. Candidates to inspect:
- Whether stress majorization's `idealEdgeLength = min(bounds) / max(1, n/3)` is producing inconsistent target distances for two-hop vs one-hop pairs.
- Whether `applyDirectRepulsion`'s O(N²) sum on dense central clusters dominates the single weak attraction pull for degree-1 dangling nodes (the original symptom that motivated the Hooke attempt).
- Whether `assignInitialPositions` golden-angle spiral leaves degree-1 nodes far enough out that the temperature schedule never pulls them back in.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.

---

## Graph layout: deterministic radial replaces force-directed physics (May 10, 2026)

**What**: Replaced the multi-phase force-directed layout (stress majorization → Fruchterman-Reingold → PrEd) with a deterministic radial layout. Me sits at center; BFS assigns every other node a layer; L1 (direct neighbors of Me) is grouped by primary role and placed clockwise from 12 o'clock with the smallest role bucket first; L2/L3 sub-trees fan outward from their parent.

- New `GraphBuilderService.layoutGraphRadial(nodes:edges:meID:bounds:)` runs in a single deterministic pass — no iterations, no physics, no random initialization.
- Per-leaf arc budget (50 px at L1 radius) plus a per-bucket gap (30 px) drives a recursive sub-tree-width calculation. L1 radius is computed from `max(140, requiredCircumference / 2π)` so the ring expands to fit all sub-trees without overlap, and contracts when the graph is small.
- Children sit at parent radius + 100 px and inherit their parent's angular slot, sub-divided proportional to each child's recursive sub-tree width. Useful depth is ~3 per the user's spec.
- Parent for each L2/L3 node = lower-layer neighbor with the strongest edge weight, tie-broken by `displayName` so the tree is reproducible run-to-run.
- Orphans (no path to Me) get an outer ring at `maxConnectedRadius + 100 px`.
- Cache key bumped to `graphLayoutCache_v5` to invalidate prior force-directed cached positions.
- Coordinator now fetches `meNodeID` *before* layout (was after) so it can be passed to the layout call.

### Why

The user reported repeated band-gap / starburst pathologies from the force-directed approach. Both attempts at fixing the physics — sqrt graph-distance scaling + 120 px repulsion cutoff (reverted in `0c38ef9`), and Hooke's-law attraction with rest length (`152aa93`) — produced worse layouts than before, including a degenerate vertical-spike pattern. The user proposed switching to a deterministic geometric model: "While the organic look of what we had tried before was nice, something about the math is just not working for us."

Concrete advantages over physics:
- **No layout drift.** Identical inputs always produce identical positions. The Les-vs-Stephan distance discrepancy (byte-identical data, different positions) cannot happen here — the algorithm has no notion of starting state.
- **No band gaps.** Each layer sits at a known radius; ring spacing is constant and explicit, not emergent from force balance.
- **Role clustering is structural, not emergent.** Sub-tree placement is decided by the algorithm, not by which random initial position a node happened to land near.
- **Predictable scaling.** With N L1 nodes the ring radius adjusts so they don't collide; deeper sub-trees naturally claim more arc.

### Limitations / known trade-offs

- L1 nodes with very large fan-outs (e.g., one client with 50 children) can dominate the L1 angular budget, leaving the rest of L1 cramped on the opposite side. Acceptable for V1; a cap or visual hierarchy adjustment can be added if it shows in practice.
- Context clusters (the old `contextClusters: [ContextGraphInput]` parameter) are no longer a layout influence. They can still drive filters/highlights elsewhere; placement is now strictly Me-centered.
- The old force-directed `layoutGraph` method remains in the file as dead code for now (in case we want to A/B compare). Will be removed once radial is confirmed good.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- User to verify visually that the All Contacts lens renders with role-grouped wedges and no band gaps.

---

## Graph layout: Hooke's-law attraction with rest length (May 9, 2026)

**What**: Replaced the unbounded linear attraction force in the force-directed layout with a Hooke's-law spring model that has a natural rest length.

- `applyAttraction` now computes `force = strength * weight * (dist - restLength)` instead of `force = strength * weight * dist`. The spring pulls in when an edge is stretched past `restLength` and pushes apart when compressed below it.
- Added `restLength` parameter to `applyAttraction`; both call sites (`layoutGraph` and `incrementalLayout`) compute it as `sqrt(bounds.width * bounds.height / max(1, n))` — roughly the spacing at which `n` evenly-distributed nodes would tile the canvas. For 200 nodes in 1200×800 that's ~70 px.
- Bumped `attractionStrength` from 0.01 → 0.05 to keep edges responsive against the existing repulsion budget.
- Cache key bumped to `graphLayoutCache_v4` so previously-cached bad layouts under v3 are invalidated.

### Why

User reported the All Contacts lens produced a wide band gap around the central cluster: degree-1 dangling nodes (people with only the implicit Me→person edge) sat roughly twice as far from the center as expected. Two specific Lead/Healthy contacts (Les Kline, Stephan Davis) with byte-identical data were placed at significantly different distances, confirming it was layout drift, not a data difference.

Root cause: the old attraction force scaled linearly with distance with **no equilibrium** — it was an unbounded inward pull. The final position of every node was determined purely by where outward repulsion happened to balance inward pull. For a degree-1 node next to a 200-node cluster, the cumulative O(N) outward repulsion from the cluster dominated the single weak inward pull, parking the node ~100 px out where forces balanced.

A previous attempt (sqrt graph-distance scaling + 120 px repulsion cutoff, commit `0c38ef9`-reverted) made the bands worse — sqrt over-compressed the stress targets and the cutoff removed long-range containment without fixing the underlying attraction/repulsion imbalance.

Hooke's law with a rest length fixes this at the physics level: every edge has a natural length, and the spring force vanishes at equilibrium. Nodes settle near `restLength` regardless of how dense the surrounding cluster is.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- User to verify visually that the band gap and radial-spike pattern from the All Contacts lens are resolved.

---

## Role filter: pre-check all roles + show counts (May 9, 2026)

**What**: Two changes to the Graph toolbar's role-filter menu so users can exclude individual roles instead of only including them.

1. **"Show All Roles" pre-checks every role.** Previously the button cleared `activeRoleFilters` to `[]` and relied on the "empty set = show all" sentinel. With nothing checked, the user had no way to exclude one role and keep the rest — they'd have to manually check every other role one by one. Now the button populates `activeRoleFilters` with every discovered role, so the user can immediately uncheck the one they don't want.
2. **All Contacts lens does the same on entry.** `loadAllContacts(bounds:)` now pre-populates `activeRoleFilters` after `buildGraph` returns. The lens summary line was updated to "uncheck a role in the toolbar to exclude it" so the affordance is discoverable.
3. **Per-role counts in the dropdown.** Each role label now reads "Client (47)" / "Vendor (3)" using node counts from the current `allNodes` snapshot. This makes it obvious which roles dominate the graph before the user unchecks anything.

### Why

User feedback: "When the new All Contacts lens is used, SAM should check on all the roles in the role picker on the window bar. Similarly, the top 'Show all roles' should check all roles on. The reason this would be helpful is when the user wants to exclude one role while showing all the rest." Plus: "A nice-to-have feature would be to have a count of the roles after each role in that dropdown menu. This would make it easy to see what role or roles will reduce larger numbers of nodes."

### Behavior change worth noting

If the user unchecks every role, the graph now shows nothing — instead of falling back to "show everything." This matches the pre-checked mental model and was confirmed with the user before implementation.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- `applyFilters` semantics unchanged — the only change is what populates `activeRoleFilters`. Curated lenses (Book of Business etc.) continue to leave the filter alone.

---

## All Contacts lens for the relationship graph (May 9, 2026)

**What**: Added a fifth lens — **All Contacts** — to the People → Graph picker. Unlike the four curated lenses (Book of Business, Referrer Productivity, Missed Nudges, Family Gaps), All Contacts shows the entire network with every connection SAM can see and hands control to the toolbar's existing role / edge-type / visibility filters.

- New `GraphLens.allContacts` case (icon `circle.grid.3x3.fill`, accent `.purple`, subtitle "Show me everything — let me filter.").
- Loader `RelationshipGraphCoordinator+Lens.loadAllContacts(bounds:)` delegates to the existing `buildGraph(bounds:)` path, so users get the full force-directed layout, edge bundling, and cached layout — but framed as a lens so the picker UI stays coherent.
- Lens summary line reads "N people · M connections · use toolbar filters to drill in" so the user knows the toolbar is the steering wheel.
- `LensPickerView` iterates `GraphLens.allCases`, so the new card appears automatically with no view-side changes.

### Why

The four curated lenses each answer one question. They're great for the questions they're built around, but they hide everything else. The user works across overlapping social groups (church, ABT, friends-of-friends, prospects-of-prospects), and those groups are exactly what the toolbar's role / edge / visibility filters were built to slice — but the toolbar had no top-level entry point unless you were already inside a curated lens. All Contacts is that entry point. It also helps the curated lenses feel valuable by contrast: switching from "Everything" → "Book of Business" makes obvious how much focus the curated lens is providing.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- New lens delegates to `buildGraph(bounds:)`, which already sets `meNodeID`, `allNodes`, `allEdges`, runs layout, calls `applyFilters()`, and sets `graphStatus = .ready` — so toolbar filters work the moment the lens renders.

---

## Briefing narrative: stop hallucinating meetings on empty calendars (May 9, 2026)

**What**: Three fixes to `DailyBriefingService.generateMorningNarrative` after a real-world hallucination where the briefing invented a 10 AM meeting with "Jane Martinez", a 2 PM with "Sarah" (the advisor's own first name), and a 7 PM with "Mike" — even though the calendar was empty.

1. **Removed example names from the prompt.** The pronoun-discipline rules previously used "Jane Martinez" and "Mike Chen" as illustrative attendees inside the system prompt. With an empty calendar, the model treated those names as schedule data and fabricated time slots around them. Replaced with generic `<attendee>` / `<person>` placeholders and added an explicit rule: "Treat any names that appear in these instructions as illustrative grammar examples, NOT as real schedule data."
2. **Explicit `(none)` markers for empty sections.** `buildMorningDataBlock` previously *omitted* empty sections entirely — `TODAY'S SCHEDULE`, `PRIORITY ACTIONS`, `FOLLOW-UPS NEEDED`, `LIFE EVENTS`. The model had no signal that the calendar was genuinely clear vs. that the data simply hadn't been included, so it filled the gap. Now each section emits `SECTION: (none)` when empty, and the prompt tells the model "Skip any section marked '(none)' or absent — do not invent content to fill it."
3. **Advisor identity rule.** The prompt now reads `AIService.userFullName` / `userFirstName` and tells the model: "The advisor's own name is "Sarah Snyder" or "Sarah". They are the person you are addressing. Never list them as a meeting attendee, follow-up subject, or life-event subject." Closes the third hallucination axis where "Sarah" appeared as an attendee.

### Why

Real-world report: morning briefing read "The day opens with your 10 AM meeting with Jane Martinez, followed by your 2 PM session with Sarah and your 7 PM call with Mike" — none of those people existed in the data. The user's calendar was empty, follow-ups + life events + goals were populated, so the sufficiency guard (line 49: `sectionCount >= 2 || totalItems >= 3`) correctly let the narrative through. The leak was the prompt itself: it contained literal example names, and the data block silently dropped the empty schedule section.

The guard is doing its job — the briefing should still cover follow-ups, life events, and goals when the calendar is clear. The fix is to let the model know the calendar is genuinely empty and to stop seeding it with names that don't belong in the data.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- `AIService.userFullName` / `userFirstName` are `nonisolated` static computed properties reading directly from UserDefaults, so the advisor identity rule has zero async cost in the briefing critical path.
- Behavior unchanged when the calendar has data: the empty-section markers only fire when a section is genuinely empty.

---

## Graceful quit + swap-not-overlay for blocking activity (May 9, 2026)

**What**: Two related fixes:

1. The blocking overlay shown during backup restore is now rendered **in place of** `AppShellView` (via an `if/else` in `mainContent`) rather than layered on top with `.overlay { ... }`. The shell's view tree — and every `@Query` observer inside it — fully tears down for the duration.
2. `applicationShouldTerminate` now consults a shared `BackgroundWorkProbe`. If any AI engine or import is mid-call, it sets `ShutdownCoordinator.isShuttingDown = true` (which routes the same `BlockingActivityOverlay` into the window via the same swap), returns `.terminateLater`, awaits `ShutdownCoordinator.settle(timeout: 15)`, runs `performShutdownTeardown()`, then replies via `sender.reply(toApplicationShouldTerminate: true)`.

### Why

A real-world re-import crashed with `SamEvidenceItem.source.getter at _PersistedProperty (fatalError)`. The `RestoreInProgressOverlay` was `.overlay { … }`-stacked on top of `AppShellView`, so although the overlay covered the screen the underlying `@Query`-driven views were still alive — and their observers fired during the wipe pass on the (now-deleted) models that triggered the SwiftData fatalError. Swapping the shell out for the overlay deletes the observers entirely.

The same kind of mid-call interruption was crashing on `Cmd+Q` while outcome generation or strategic digest was still running: macOS terminated the process, the LLM stream lost its actor context, and the next quit attempt was a forced one. The user wanted "Quit in progress, waiting for background AI agents to come back and report for duty" rather than a beachball or a force-kill.

### Architecture

- **`BackgroundWorkProbe`** (`Coordinators/BackgroundWorkProbe.swift`) — `@MainActor enum` that returns `[String]` blockers across the seven coordinators that touch SwiftData (comms / mail / calendar / contacts imports, outcome engine, strategic coordinator, role deduction). One source of truth — both `BackupCoordinator.waitForInFlightWorkToSettle` and `ShutdownCoordinator.settle` poll it, so adding a new coordinator means editing one file. `isAnyBusy` provides the boolean fast-path used by `applicationShouldTerminate`.
- **`ShutdownCoordinator`** (`Coordinators/ShutdownCoordinator.swift`) — `@MainActor @Observable` singleton mirroring `BackupCoordinator`'s public surface (`isShuttingDown`, `progress`, `blockedBy`). `settle(timeout:)` polls `BackgroundWorkProbe` every 250 ms with a 15 s ceiling and returns `Bool` (`true` = settled cleanly, `false` = timeout). On timeout the AppDelegate proceeds with teardown anyway — better than a deadlocked quit.
- **`SAMAppDelegate.performShutdownTeardown()`** — Extracted from the old inline body of `applicationShouldTerminate` so both the immediate quit path (no background work) and the deferred path (`.terminateLater` → settle → teardown) drain through identical cleanup: timer invalidation, every `cancelAll()`, scheduler stops, hotkey unregister, `mainContext.save()`, `AIService.prepareForTermination()`.
- **`BlockingActivityOverlay`** (renamed from `RestoreInProgressOverlay`) — Single overlay observing both `BackupCoordinator` and `ShutdownCoordinator`. Computes a private `Activity` struct (`title`, `subtitle`, `progress`, `blockedBy`) — shutdown takes precedence when both are active. Title swaps between "Restoring Backup" and "Quitting SAM"; the rest of the layout is shared.
- **`SAMApp.mainContent`** — Now an `if/else if/else` that renders `SafeModeView`, `BlockingActivityOverlay`, or `AppShellView`. The new computed `isBlockingActivity` returns `true` whenever the backup status is `.importing` OR `ShutdownCoordinator.isShuttingDown`. The shell — and all of its `@Query` observers — disappear from the view tree for the entire blocking window.
- **`BackupCoordinator.waitForInFlightWorkToSettle`** — Refactored to use `BackgroundWorkProbe.currentBlockers()` instead of an inline duplicate of the same checks.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- The shutdown path inherits the same 15 s ceiling pattern as the restore settle, so a stuck coordinator can't block quit forever — the overlay shows, the timeout fires, teardown runs, the process exits.
- AI inference (FoundationModels + MLX) doesn't expose a true cancellation handle — cooperative cancellation only happens at `Task.yield()` boundaries, which our engines already insert. The 15 s budget is sized for that worst-case checkpoint distance.

---

## Backup restore: cap AI enrichment + blocking overlay (May 9, 2026)

**What**: Two fixes for the post-restore window where the app appears hung for 5+ minutes:

1. `OutcomeEngine.enrichWithAI` now skips entirely on the first cycle after a restore (the cycle that has zero cached AI rationale and would otherwise burn through 5 outcomes × ~30 s × 2 LLM calls each), and is bounded by a 45 s wall-clock budget on every cycle. Outcomes past the budget enrich on the next scheduled run.
2. A new `RestoreInProgressOverlay` blocks all UI input from the moment `BackupCoordinator.status` enters `.importing` until the restore returns to `.idle`. The overlay shows the current phase string, and during the settle wait names the specific coordinators it's still waiting on.

### Why

A hang report audit traced a real-world 5-minute stall to `OutcomeEngine.enrichWithAI` running for 311 s right after a restore — the fresh post-restore batch had no cached `suggestedNextStep` or `draftMessageText` on any outcome, so the top-5 enrichment loop made the maximum number of AI calls (10) back-to-back, all on the main actor. The user (reasonably) thought the app had hung and force-quit it, which kicked off a fresh launch + a duplicate contacts import + another planned enrichment cycle. The whole sequence is non-cancellable once the user confirms the destructive restore alert, so the right answer is to make the post-restore window short and to make it clear what's happening.

### Architecture

- **`OutcomeEngine.skipEnrichmentNextRun`** — `@ObservationIgnored` one-shot bool. `BackupCoordinator.refreshAfterRestore` sets it to `true` immediately before calling `OutcomeEngine.shared.startGeneration()`. `enrichWithAI` checks the flag at entry, logs, clears it, and returns. The next scheduled cycle (idle-time, no restore pressure) populates AI rationale.
- **`OutcomeEngine.enrichmentBudgetSeconds = 45`** — Wall-clock budget tracked from the start of `enrichWithAI`. Before each per-outcome iteration, the elapsed time is compared against the budget; if exceeded, the loop logs `AI enrichment budget exceeded (Ns > 45s) after K/N outcomes — deferring rest` and returns. Independent of the restore guard added inside the same loop (`BackupCoordinator.isRestoring` short-circuit).
- **`BackupCoordinator.blockedBy: [String]`** — Observable list of human-readable coordinator names that are still busy during the settle phase. Updated each 250 ms poll in `waitForInFlightWorkToSettle`. Cleared when settled or on timeout.
- **`RestoreInProgressOverlay`** — `View` in `Views/Shared/`. Reads `BackupCoordinator.shared` directly via `@State`. Shows when `status == .importing`. Renders a Glass-material card with `ProgressView`, "Restoring Backup" title, the current `progress` string, and the `blockedBy` list when non-empty. The full-window backdrop is a 40 % black overlay with a `contentShape(Rectangle())` + empty `onTapGesture` that swallows clicks behind it. Wired into `SAMApp.mainContent` via `.overlay { RestoreInProgressOverlay() }`.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- The overlay is opacity-only — does not block the file importer, alerts, or onboarding sheets that exist outside `mainContent`. Restore is only invokable from Settings (post-onboarding) so the overlay covers the relevant paths.

---

## Backup restore: pause in-flight work to prevent SwiftData fatalError (May 9, 2026)

**What**: Restoring a backup now sets a process-wide `BackupCoordinator.isRestoring` flag for the duration of the wipe-and-reinsert pass, waits up to 30 s for in-flight imports/engines to drain before tearing down the store, and short-circuits any new background work (or in-progress yield-bounded loops) that runs while the flag is set.

### Why

A real-world restore crashed with `SamEvidenceItem.source.getter at _PersistedProperty (fatalError)` from `MeetingPrepCoordinator.computeHealth(for:)` ← `NoteAnalysisCoordinator.refreshRelationshipSummary` ← `CommunicationsImportCoordinator.refreshAffectedSummaries` ← `performImport`. Diagnosis: the comms import had already started its post-import refresh phase when the restore began deleting models. The wipe pass invalidates SwiftData objects the import was still iterating over, and the next property access on a deleted object trips SwiftData's `_PersistedProperty` fatalError. The previous restore flow had no coordination with running coordinators — it just called `deleteAll(SAMSchema.allModels)` and hoped nothing else was mid-flight.

### Architecture

- **`BackupCoordinator.isRestoring`** — `nonisolated` cross-actor flag backed by `OSAllocatedUnfairLock<Bool>`. Swift 6-friendly (no `nonisolated(unsafe)`). Set true in `performImport(from:passphrase:)` immediately after the safety backup, cleared via `defer`. Readable from any actor without `await`, so synchronous guard-checks inside `@MainActor` coordinator methods stay synchronous.
- **`BackupCoordinator.waitForInFlightWorkToSettle(timeout:)`** — Polls the seven coordinators that touch SwiftData on every cycle (`CommunicationsImportCoordinator`, `MailImportCoordinator`, `CalendarImportCoordinator`, `ContactsImportCoordinator`, `OutcomeEngine`, `StrategicCoordinator`, `RoleDeductionEngine`). Sleeps 250 ms between checks; logs which coordinator is blocking. Returns once all idle, or after 30 s timeout (logs warning, proceeds anyway — better than blocking the user indefinitely).
- **Re-entry guards** — Every coordinator's `performImport` / `generateOutcomes` / `generateDigest` / `deduceRoles` entry point checks `BackupCoordinator.isRestoring` and bails before claiming `importStatus = .importing`. New work scheduled during the restore window is inert.
- **In-flight bail points** — `OutcomeEngine._generateOutcomesBody` already had 18 `await Task.yield()` checkpoints between scanner phases; each one is now followed by `if BackupCoordinator.isRestoring { generationStatus = .idle; return }`. Long-running engines that started just before the wipe drop out cleanly at the next yield instead of touching deleted objects.
- **Defensive guards at the actual crash site** — `MeetingPrepCoordinator.computeHealth(for:)` returns a new `RelationshipHealth.empty` static if `BackupCoordinator.isRestoring || person.isDeleted`. `NoteAnalysisCoordinator.refreshRelationshipSummary` and `CommunicationsImportCoordinator.refreshAffectedSummaries` (plus inner loops) bail likewise. These cover the tight window between "wipe started" and "settle phase observed the import as idle" — if a `Task.utility` continuation reawakens during the wipe, it sees the flag and exits.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- Settle phase has a 30 s ceiling, so a hung coordinator can't deadlock the restore. Worst case the restore proceeds and per-method guards catch any straggler work.

---

## Backup restore: full state refresh + iCloud briefing replacement + watermark handling (May 9, 2026)

**What**: After restoring from a `.sambackup` file, SAM now resets stale in-memory state across the app, replaces the pre-restore briefing in CloudKit so the iPhone companion stops showing it, navigates the user to Today, re-runs the launch-time import + deferred work pipeline, and either resumes from the backup's import watermarks or — for legacy backups that pre-date this change — clears the local watermarks so the next import does a full lookback re-scan.

### Why

A restore wipes SwiftData and reinserts records from the backup, but leaves the rest of the running app frozen on pre-restore state: graph node/edge caches still reference deleted IDs, the Strategic Coordinator's last-loaded digest is gone from disk but still in memory, the iPhone companion keeps reading the pre-restore briefing JSON from CloudKit, and `mailLastWatermark` / the comms watermarks in UserDefaults still claim "last imported = today" — so the next import cycle skips messages newer than the backup, leaving a hole between backup-date and the stale watermark. The previous `refreshAfterRestore` only cleared the briefing date gate, pruned outcomes, restarted OutcomeEngine, and refreshed MeetingPrepCoordinator. Imports never re-ran, the graph never rebuilt, and CloudKit was untouched.

### Architecture

- **`BackupCoordinator.includedPreferenceKeys`** — Six watermark keys added to the export list: `mailLastWatermark`, `mailLastSentWatermark`, `commsLastMessageWatermark`, `commsLastCallWatermark`, `commsLastWhatsAppMessageWatermark`, `commsLastWhatsAppCallWatermark`. Forward-compat: a backup made on Mac A and restored on Mac B will resume imports from the same point Mac A left off.
- **`BackupCoordinator.refreshAfterRestore(importedPreferenceKeys:)`** — Now accepts the set of preference keys actually present in the backup. For each watermark key absent from that set, removes the local UserDefaults entry. Legacy backups (pre-May-9-2026) trigger a full reset; new backups carry their watermarks through.
- **`BackupCoordinator.writeRestorePlaceholderBriefing()`** — Deletes existing `SamDailyBriefing` rows (they reflect pre-restore state and are not exported) and inserts a single placeholder with `narrativeSummary = "SAM has just restored data from a backup. A fresh briefing will be available shortly."`. Then encodes the same payload using `DailyBriefingCoordinator.pushBriefingToCloud`'s schema (`date`, `meetingCount`, `narrativeSummary`, `sectionHeading="Restoring backup"`, plus empty `calendarItems` / `priorityActions` / `followUps` / `strategicHighlights`) and pushes to CloudKit so the iPhone replaces the cached briefing immediately.
- **`SAMApp.runPostRestoreStartup()`** — New static `@MainActor` entry point that re-runs the launch-time import sequence (Contacts → Calendar/Mail/Comms → role deduction → outcome engine → briefing first-open-of-day). `triggerImportsForEnabledSources` and `scheduleDeferredLaunchWork` were promoted from instance methods to `static @MainActor` so they can be invoked from `BackupCoordinator` without holding a reference to the running `SAMApp` instance. Onboarding/permission gating is intentionally skipped — a restore can only complete when the app is past onboarding.
- **`Notification.Name.samBackupDidRestore`** — New notification posted at the end of `refreshAfterRestore`. SwiftData `@Query`-bound views auto-repaint from the rewritten store, so the notification only targets `@Observable` coordinators that hold derived caches.
- **`RelationshipGraphCoordinator`** — Listens for `samBackupDidRestore` and resets `nodes`, `edges`, `lensHighlightedNodeIDs`, `lensAnnotations`, `lensClusterLabels`, sets `graphStatus = .idle`, then triggers a fresh `buildGraph()`.
- **`StrategicCoordinator`** — Listens for `samBackupDidRestore` and clears `latestDigest`, `strategicRecommendations`, calls `invalidateContentCache()`, then `loadLatestDigest()` from the new store.
- **Sidebar nav** — `refreshAfterRestore` writes `"today"` to `UserDefaults` key `sam.sidebar.selection` (the `@AppStorage` key bound by `AppShellView`) so the user lands on the Today screen, where the placeholder briefing immediately renders. Avoids stranding them on a stale People/Graph/Business view.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- All changes are additive: existing backups without watermark keys trigger the legacy reset path; existing call sites of `triggerImportsForEnabledSources` continue to work via `Self.` qualifier; the new notification is opt-in (only the two cache-holding coordinators listen).

---

## Three duplicate-work fixes from log audit: WhatsApp re-scan, summary regen, role deduction (May 9, 2026)

**What**: A log review surfaced three patterns of duplicate work running every comms-import cycle: WhatsApp unknown senders being re-recorded on every pass with `Date()` overwriting `latestEmailDate`, relationship summaries regenerating back-to-back when a note save and a comms import touched the same person within seconds, and role deduction walking the full candidate set even when no person's evidence had changed since the last run.

### Why

- "Recorded 18 unknown WhatsApp senders for triage" appeared 5× in a single import window, with "Unknown senders: 0 new, 18 updated" trailing each one. Investigation showed `discoverWhatsAppUnknownSenders` was passing `date: Date()` for every JID and `bulkRecordUnknownSenders` was unconditionally overwriting `latestEmailDate` and bumping `emailCount`. The "known to SAM" identifier set used to filter out triaged senders only contained SamPerson identifiers — UnknownSender rows were treated as fresh on every full-DB sweep.
- "Updated relationship summary for X" repeated for the same person within seconds. `refreshRelationshipSummary(for:)` is called from both note analysis (post-save) and comms import (post-import), neither of which checked when the last refresh happened. Two LLM calls for identical inputs.
- "Found 46 candidates for role deduction" repeated every 10 minutes (per the existing throttle) even when no role assignments had occurred and no new evidence had arrived for any candidate. The candidate-scoring loop ran in full each time and produced identical suggestions.

### Architecture

- **`UnknownSenderRepository.bulkRecordUnknownSenders`** — Now skips field updates when `sender.date <= record.latestEmailDate ?? .distantPast`. Display-name backfill and marketing-flag upgrade still happen (those are signal-additive). `emailCount` and `latestSubject` only increment on a strictly newer message. The "0 new, N updated" log line will now report 0 for repeated identical scans.
- **`UnknownSenderRepository.triagedIdentifiers()`** — New method returning every email/phone in the UnknownSender table regardless of status. Used during comms import to widen the "known to SAM" set so triaged-but-not-yet-added senders aren't re-recorded as fresh unknowns on every cycle. Pending senders are included because re-recording them inflates counters without adding signal.
- **`CommunicationsImportCoordinator.performImport`** — Builds two sets now: `knownIdentifiers` (people + triaged) for general filtering, and `knownPhonesUnion` (phones + triaged) specifically for the WhatsApp post-scan sweep. Logs the triaged count alongside email/phone counts.
- **`WhatsAppService.fetchAllJIDs`** — Tuple type extended to include `latestMessageDate: Date?`, computed via `MAX(m.ZMESSAGEDATE)` per-chat-session. Callers pass this through instead of `Date()`. JIDs with no messages (shouldn't happen given the JOIN, but defensively) get `.distantPast`.
- **`NoteAnalysisCoordinator.refreshRelationshipSummary(for:force:)`** — Added a 5-minute throttle keyed on `person.summaryUpdatedAt`. Skips silently with a debug log when called within the window. New `force: Bool = false` parameter for explicit user-driven refreshes.
- **`RoleDeductionEngine.deduceRoles(force:)`** — Added a candidate-set fingerprint check. After building the candidate list, hashes `sortedJoin(personID + ":" + linkedEvidence.count)` and compares to `lastCandidateHashKey` in UserDefaults. Match means every candidate's signals are unchanged → skip the LLM scoring loop entirely, log "candidate set unchanged," update `lastRunDateKey`, return `.complete`. Fingerprint persists alongside the date on every successful run.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- All four fixes are additive (new methods, new guards, new parameters with defaults). Existing call sites continue to work unchanged.

### Files

- `SAM/Services/WhatsAppService.swift` — `fetchAllJIDs` returns `latestMessageDate`.
- `SAM/Coordinators/CommunicationsImportCoordinator.swift` — Triaged-identifier union, real message-date passthrough, post-scan uses `knownPhonesUnion`.
- `SAM/Repositories/UnknownSenderRepository.swift` — `triagedIdentifiers()` method, `bulkRecordUnknownSenders` freshness guard.
- `SAM/Coordinators/NoteAnalysisCoordinator.swift` — 5-minute summary throttle, `force` parameter.
- `SAM/Coordinators/RoleDeductionEngine.swift` — Candidate fingerprint check, `lastCandidateHashKey` persistence.

### Not addressed (yet)

The "Building known identifier sets…" log appearing 5× per minute reflects 5× `performImport()` calls — file watchers + 60s legacy poll + 5-min fallback poll all firing independently. The unknown-sender fixes above eliminate most of the wasted work each pass does, so 5× imports now produces ~5× the cost of "fetch known identifiers" rather than ~5× the cost of "re-record every WhatsApp JID + regenerate every relationship summary." A consolidation pass on the trigger model is left for a future cleanup.

---

## Relationship Graph rebuilt around four lenses (May 9, 2026)

**What**: The Graph entry experience is now lens-based. Opening the Graph tab anchors `Me` at center and presents a 2×2 picker of four focused questions; selecting a lens streams in only the nodes that answer that question, in deterministic radial waves with no force layout. The previous "load all 264 nodes and force-simulate" path is gone — that's what was producing the 5–10 s beachball and the visually noisy hairball.

### Why

At Sarah's actual book size, the global graph was unreadable: every active client and every ghost contact and every co-attendee landed on the same canvas, with no signal about which connections mattered. The lens redesign starts from "what question are you trying to answer?" and only renders the subgraph that answers it — so a screen at any moment has ~10–50 nodes, all relevant, in a reading order driven by concentric rings.

### The four lenses

- **Book of Business** (green) — Active clients in the middle ring, deduced family ties in the outer ring on each client's radial, referrers in the inner ring on the radial of whoever they introduced. Singletons (clients with no family, no referrer chain) get the lens halo so the gaps are visible at a glance.
- **Referrer Productivity** (yellow) — Top referrers ranked and sized by clients introduced. Top three get a gold halo. Hovering a referrer node surfaces "N clients · $X premium" in the tooltip. Fan-out edges show every client each referrer brought in.
- **Missed Nudges** (orange) — All dismissed `SamOutcome`s grouped by `outcomeKind`. Each cluster gets a pill header above it on the canvas (e.g. "Stalled follow-ups · 7"). Each person node carries a tooltip annotation like "47d ago · Send check-in text" — what SAM nudged about, and how long ago it was dismissed.
- **Family Gaps** (blue) — Active clients with no `DeducedRelation` entries and no `familyReferences`. Single ring around Me, every node halo'd, so the action queue ("ask about family") reads off the screen.

### Architecture

- **`GraphLens` model** (`SAM/Models/GraphLens.swift`) — `enum GraphLens` with title/subtitle/description/systemImage/accentColor metadata, plus `LensLoadingPhase` (idle / anchoring / primary / secondary / tertiary / complete) for the progressive reveal banner.
- **`RelationshipGraphCoordinator+Lens.swift`** — All lens loading lives in this extension. Public entry points: `enterLensPicker()`, `loadLens(_:bounds:)`, `loadMeOnly(bounds:)`, `cancelInFlightLensLoad()`. Each lens loader runs as a wave-based async function that commits a snapshot, sleeps 120–140 ms, then commits the next wave — so the user sees Me anchor, then clients arrive, then family ties, then referrer chains. No `OutcomeEngine`-style scoring or force-directed simulation in the lens path; placement is deterministic radial (`ringRadius(for:level:)` returns base × 0.18 / 0.32 / 0.46, `ringAngle(index:total:)` distributes evenly).
- **Coordinator state additions** — `currentLens: GraphLens?`, `lensLoadingPhase`, `lensSummary`, `lensAnnotations: [UUID: String]`, `lensClusterLabels: [(center: CGPoint, label: String, count: Int)]`, `lensHighlightedNodeIDs: Set<UUID>`, `lensTaskBox: LensTaskBox` for cancellation. `allNodes` and `allEdges` were promoted from `private`/`private(set)` to `var` so the lens extension can write directly without going through `applyFilters`.
- **`LensPickerView`** (`SAM/Views/Business/LensPickerView.swift`) — Floating glass overlay shown when `coordinator.currentLens == nil`. 2×2 grid of `LensCard` buttons with hover scale + accent-tinted icon. Tapping calls `loadLens(lens, bounds:)`.
- **`RelationshipGraphView` rewiring** — Default `.task` now calls `loadMeOnly()` instead of building the full graph. Three new overlays in the main `ZStack`: `lensProgressBanner` (top-trailing, shows `lensLoadingPhase.progressLabel`), `lensPickerOverlay` (centered, shown when no lens active), and `lensSummaryChip` (top-leading, shows lens icon + title + summary, "Change lens" button calls `enterLensPicker()`).
- **Canvas visual hooks** — Two new draw passes in `drawCanvas`:
  - `drawLensHalos` (between nodes and bridge indicators) — soft accent-colored glow + ring around each `lensHighlightedNodeIDs` member, color-keyed to the lens.
  - `drawLensClusterLabels` (after labels) — pill-backgrounded headers for each `lensClusterLabels` entry, anchored in graph space and rendered with the lens accent border.
- **Tooltip integration** — `GraphTooltipView` now takes optional `lensAnnotation: String?` and `lensAccent: Color?`. The hover overlay in `RelationshipGraphView` looks up `coordinator.lensAnnotations[hoveredID]` and the active lens accent and passes both in. Annotation renders as a colored-dot + caption line above the divider, so the lens-specific signal sits prominently without disturbing the role-badge / health-circle / connection-count layout below.
- **`OutcomeRepository.fetchDismissed(limit:)`** — New repository method backing the Missed Nudges lens. Fetches `SamOutcome`s with `statusRawValue == OutcomeStatus.dismissed.rawValue`, sorted by `dismissedAt` descending, capped at 200.

### Performance

The lens path does no force simulation, no centrality scoring, and touches only the slice of `SamPerson` / `SamOutcome` / `DeducedRelation` each lens needs. Opening Graph now lands on the picker instantly; selecting a lens completes the multi-wave reveal in well under a second on a 264-node store. The previous "build everything, then filter" pattern is bypassed entirely (`commitLensSnapshot` writes through `allNodes` / `allEdges` / `nodes` / `edges` directly without going through `applyFilters`).

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- All four lenses load deterministically with progressive-reveal waves.
- Halos render with lens accent color; tooltip annotations surface for hovered nodes; cluster pills appear above grouped outcomes in Missed Nudges.

### Files

**New**:
- `SAM/Models/GraphLens.swift`
- `SAM/Coordinators/RelationshipGraphCoordinator+Lens.swift`
- `SAM/Views/Business/LensPickerView.swift`

**Modified**:
- `SAM/Coordinators/RelationshipGraphCoordinator.swift` — lens state additions, `LensTaskBox`, access-level changes on `allNodes` / `allEdges` / `mapHealthToLevel`.
- `SAM/Views/Business/RelationshipGraphView.swift` — `loadMeOnly()` default, three lens overlays, `drawLensHalos`, `drawLensClusterLabels`, tooltip annotation wiring.
- `SAM/Views/Business/GraphTooltipView.swift` — optional `lensAnnotation` / `lensAccent` parameters and rendering.
- `SAM/Repositories/OutcomeRepository.swift` — `fetchDismissed(limit:)`.

**Deferred to a future pass**: AI narration of "why this referrer is productive" (Referrer Productivity lens, design notes); per-lens coaching CTAs in the summary chip; lens-specific export to PDF for sharing with Sarah's team.

---

## App Lock redesign shipped: leak-proof modals, no-click unlock, post-unlock state preservation (May 8, 2026)

**What**: A 7-phase rebuild of the app lock system per `SAM-Lock-Redesign-Plan.md`. Three coupled goals: (1) zero sensitive content visible in any modal layer when locked, (2) Touch ID auto-prompts on lock-state transitions without requiring a click, (3) on unlock the user is back where they were — same windows, same sheets, same in-progress edit text.

### Why

The previous lock attached a SwiftUI `.lockGuarded()` modifier to each `WindowGroup` content root. Sheets, alerts, file pickers, and popovers present *above* that root in the window stack, so the blur sat underneath them and they leaked. Unlock required two clicks because `bringMainWindowToFront()` heuristically picked the wrong window. Aux windows were `close()`d on lock so they had to be reopened by hand on unlock, several seconds later. Sitting on SAM without interacting never triggered a lock at all — only `appDidBecomeActive` checked elapsed time.

### Architecture

- **`AppLockService`** — kept the `@Observable` state machine and the system-event observers, removed `closeAuxiliaryWindows()` / `bringMainWindowToFront()` / per-window `restoreWindowSharing()`. Added a foreground idle timer (10s tick + non-consuming NSEvent monitor for mouse/key/scroll) that fires `lock()` when `Date() - lastActivityAt >= timeout`. Added unlock-side observers (`com.apple.screenIsUnlocked`, `com.apple.screensaver.didstop`, `NSWorkspace.didWakeNotification`) plus a `LockOverlayWindow.didBecomeKey` failsafe — each invokes `tryAutoAuthenticateAfterSystemEvent(...)` which drops the `NSApp.isActive` guard since the system is mid-transition. One-shot 500ms retry in `authenticate()` handles the LAContext quirk where `evaluatePolicy` returns `userCancel`/`appCancel`/`systemCancel` within a few ms when the system isn't ready to host the prompt.
- **`LockOverlayCoordinator` + `LockOverlayWindow`** — a `LockOverlayWindow` (NSWindow at `.floating` level, `isLockOverlay = true`) is attached as a child window to every visible SAM window when locked, hosting `LockOverlayContent` (glass-block tile wall sampling refraction per tile, palette pulled from the SAM logo). Hide-don't-close: aux windows `orderOut(nil)` on lock and `orderFront(nil)` on unlock — instant restore, SwiftUI state preserved.
- **`ModalCoordinator`** — singleton tracking three kinds of registrations: `dismissOnly` (alerts, confirmations), `restorable` (sheets — dismissed on lock, re-presented on unlock), and `panel` (NSOpenPanel/NSSavePanel — `cancel(nil)` on lock). Bound via two `ViewModifier`s: `DismissOnLock(isPresented:)` and `RestoreOnUnlock(item:)` / `RestoreOnUnlock(isPresented:)` in `LockModifiers.swift`. Wired across ~75 sheet sites and ~11 file importer/exporter sites.
- **`DraftStore`** — in-memory `[kind: [id: [field: value]]]` keyed by sheet kind + entity ID. Forms load drafts on `init`/`.onAppear`, save on `.onChange` of every text field, and clear on commit-success or explicit Discard. Plain dismiss/lock-dismiss does NOT clear — that's how unlock recovers in-progress edits. v1 is in-memory only; disk persistence deferred (would require encryption work). Wired into 8 forms: `NoteEditorView`, `ComposeWindowView`, `ContentDraftSheet`, `EventFormView`, `GoalEntryForm`, `ProductionEntryForm`, `ManualTaskSheet`, `CorrectionSheetView`. Passphrase forms (`BackupPassphraseSheet`, `ImportPassphraseSheet`) intentionally excluded — security boundary.
- **String rewrite pass** — ~25 alert/confirmation sites switched from interpolated names ("Archive John Smith?", "Delete '{name}'?") to generic phrasing ("Archive this contact?", "Delete this context?"). Reduces sensitive content visible in modals before lock-time dismiss can catch them.

### Verified

- `xcodebuild -scheme SAM -destination 'platform=macOS' build` — `BUILD SUCCEEDED` after every phase.
- Foreground idle timer: confirmed locking after timeout while user is in-app.
- Auto-prompt: confirmed Touch ID prompts without first click after screen-lock, screensaver, and system-sleep cycles.

### Files

**New**: `SAM/Services/ModalCoordinator.swift`, `SAM/Services/DraftStore.swift`, `SAM/Views/Shared/LockModifiers.swift`, `SAM/Views/Shared/LockOverlayWindow.swift` (lock overlay NSWindow class — created in Phase 3).

**Modified**: `SAM/Services/AppLockService.swift` (rework), `SAM/Views/Shared/AppLockView.swift` (glass-block overlay rewrite), `SAM/App/SAMApp.swift` (window observer wiring + 4 modifier sites), plus ~30 view files for `.dismissOnLock` / `.restoreOnUnlock` modifiers, ~25 view files for the string rewrite pass, and 8 edit-form views for `DraftStore` integration.

**Deferred to v2** (per plan §8): disk-persistent encrypted drafts, popover restoration, multi-display overlay positioning on hot-plug.

---

## Phase 1c shipped: instrumentation expansion driven by first-day hang reports (May 8, 2026)

**What**: A second pass of `PerformanceMonitor` wraps targeting the gaps the Phase 1a/1b reports surfaced. The 23 hang JSON files captured on the first day showed two recurring blind spots: `OutcomeEngine.generateOutcomes` taking up to 66.93 s while its 18 instrumented scanners only summed to ~3.7 s (i.e. ~63 s in *uninstrumented* pre/post-scanner work), and `ContactsImport.performImport` running back-to-back twice in the same launch (6.36 s + 7.20 s) with no record of who triggered each call.

### Why

The watchdog was reporting beach-balls but pointing at empty stacks — the operation had already finished by the time the heartbeat returned, so the active-stack snapshot was blank and only the ring buffer hinted at the cause. To turn those "post-stack" reports into actionable signal, every phase that runs on the main actor in `OutcomeEngine`, `ContactsImportCoordinator`, and the launch sequence now has its own measured frame.

### What got wrapped

- **`OutcomeEngine` pre-scanner phases** — `pruneExpired`, `wakeExpiredSnoozes`, `autoResolveWoken`, `fetchAllPeople`, `fetchAllNotes`. These run on the main actor before any scanner fires and weren't visible in the existing 18-scanner breakdown.
- **`OutcomeEngine` post-scanner phases** — `classifyActionLanes`, `buildSequenceSteps`, `buildCompanions`, `scorePriorities`, `filterMutedKinds`, `softSuppress`, `persistOutcomes`, `detectKnowledgeGaps`, `enrichWithAI`, `reprioritize`. These walk every generated outcome (often 80+) on the main actor and were the prime suspect for the missing ~63 s.
- **`scanRelationshipHealth` aggregate timing** — instead of a per-person frame (would have spammed the ring buffer with hundreds of entries), the loop logs total elapsed time, `MeetingPrepCoordinator.computeHealth` cumulative time, and the percentage of the loop spent inside `computeHealth`. This pinpoints whether the hot loop is in the health computation or in the surrounding outcome-construction code.
- **`ContactsImportCoordinator.performImport`** now takes a `triggeredBy reason: String` parameter logged via `Logger.notice` and signposted via the wrapped frame. Three callers updated: `importNow` → `"importNow"`, `importIfConditionsMet` → `"configChange:<reason>"`, `importIfNeeded` → `"scheduled:<reason>"`. The next hang report will name *which* code path triggered the duplicate import.
- **`ContactsImportCoordinator` inner phases** — `fetchContacts`, `bulkUpsert`, `meContact`, `mergeDuplicates`, `clearStaleIDs`, `unlinkNonGroup`, `reresolveParticipants`, `deduceRelationships`. Each phase is independently measured so we can tell whether the duplicate run is wasting time on the same expensive sub-step (likely `bulkUpsert` or `mergeDuplicates`) or short-circuiting most of it.
- **`SAMApp` launch sequence** — `Launch.openSAMModelContainer` (first SwiftData touch), `Launch.runMigrationV32IfNeeded`, `Launch.runDirectionBackfillIfNeeded`, the post-`configureDataLayer` background pass (`Launch.eventRepairIntegrity`, `Launch.backfillPersonNameCache`, `Launch.pruneComplianceAudits`), the `.task` block (`Launch.task.configureLockService`, `Launch.task.checkPermissionsAndSetup`, `Launch.task.briefingFirstOpenOfDay`, `Launch.task.devicePairingBootstrap`, `Launch.task.transcriptionConfigure`, `Launch.task.transcriptionStartListening`), and `scheduleDeferredLaunchWork` (`Launch.deferred.pruneExpiredOutcomes`, `Launch.deferred.purgeOldOutcomes`, `Launch.deferred.pruneExpiredUndo`, `Launch.deferred.startOutcomeGeneration`, `Launch.deferred.pipelineBackfill`, `Launch.deferred.briefingFirstOpenOfDay`).

### Why aggregate timing for `scanRelationshipHealth` instead of per-person frames

A 256-person store with per-person `measureSync` would push 256 frames onto the active stack and through the ring buffer in a single scanner run, evicting every other useful frame in the buffer. The `os.signpost` channel would also become unreadable in Instruments. Aggregate cumulative timing keeps the cost bounded and makes the question "is the loop body or `computeHealth` the bottleneck?" answerable from the log line alone.

### Verified

- `xcodebuild -project SAM.xcodeproj -scheme SAM -configuration Debug -destination 'platform=macOS' build` — `BUILD SUCCEEDED`.
- All wraps are mechanical begin/end pairs around existing call sites; underlying logic unchanged.
- Existing scanner instrumentation from 1b is preserved — the new pre/post wraps surround it without altering its frames.

### Files

- `SAM/Coordinators/OutcomeEngine.swift` — pre-scanner, post-scanner, `scanRelationshipHealth` aggregate timing.
- `SAM/Coordinators/ContactsImportCoordinator.swift` — `triggeredBy` parameter + 8 inner-phase wraps.
- `SAM/App/SAMApp.swift` — `configureDataLayer` open + migrations + maintenance wraps; `.task` block wraps; `scheduleDeferredLaunchWork` wraps.

---

## Phase 1a + 1b shipped: MainActor hang watchdog and signpost instrumentation (May 8, 2026)

**What**: SAM now self-reports when its main thread freezes for more than a second. Each hang produces a JSON file in `~/Library/Application Support/SAM/diagnostics/` naming the operation that was running, how long it had been running, and a ring buffer of recent completions. Recent hangs surface in Settings → Diagnostics → Performance Watchdog.

### Why

Sarah reports beachballs, especially in the first ~15 minutes after launch and around screen unlock. We've patched several O(P × E) hot spots already (May 7 changelog entry), but more remain. Phase 1's purpose is to stop guessing: instrument production so the next round of optimization targets *measured* hot paths, not hypothesized ones.

### 1a — Hang Watchdog (`SAM/Services/HangWatchdog.swift`)

Two `DispatchSourceTimer`s on a private `.utility` background queue:

- **Pinger** — every 250 ms, schedules a tiny block on `DispatchQueue.main` that records a heartbeat into the lock-protected `HeartbeatStore`. The block only runs when the main queue is free; if the main thread is blocked, heartbeats stop landing.
- **Watcher** — every 250 ms on the background queue, checks heartbeat age. If > 1.0 s and we are not already in a hang, captures a snapshot (active operation beacon, 32-entry recent-completed history, hang count) and writes `hang-{ISO8601}.json`. When the next heartbeat lands, transitions out of the hang state and logs the recovery.

`DispatchSourceTimer` over `Task.sleep` for deterministic 250 ms cadence and to guarantee the watcher runs off-main. Started in `SAMAppDelegate.applicationDidFinishLaunching` so the launch window is covered; stopped in `applicationShouldTerminate`. Skipped in Safe Mode.

Cross-thread main-thread call-stack capture (Mach `task_threads` + `thread_get_state`) is **deferred**. The active-operation beacon plus recent-completed history covers most "what was running?" questions without bookkeeping overhead. Add later if real reports show the beacon is blank too often.

### 1b — Signpost instrumentation (`SAM/Services/PerformanceMonitor.swift`)

`PerformanceMonitor.measure(_:perform:)` and `measureSync(_:perform:)` wrap an operation in a begin/end pair: pushes a frame onto the lock-protected active-operation stack (read by the watchdog when a hang fires), emits an `OSSignposter` interval (visible in Instruments timeline), and pops on exit regardless of throw or cancellation.

Wrapped surfaces in this round:

- `OutcomeEngine.generateOutcomes` and all 18 scanners individually (`upcomingMeetings`, `pastMeetingsWithoutNotes`, `pendingActionItems`, `relationshipHealth`, `growthOpportunities`, `coverageGaps`, `contentSuggestions`, `contentCadence`, `goalPacing`, `deducedRelationships`, `notificationSetupGuidance`, `roleSuggestions`, `staleContacts`, `featureAdoption`, `substackAutoDetection`, `whatsAppAutoDetection`, `roleRecruiting`, `openCommitments`).
- `DailyBriefingCoordinator` — `gatherCalendarItems`, `gatherPriorityActions`, `gatherFollowUps`, `gatherLifeEvents`, `gatherTomorrowPreview`.
- `MeetingPrepCoordinator.buildBriefings` and `buildFollowUpPrompts`.
- `ContactsImportCoordinator.performImport`.

### Concurrency notes

- `HeartbeatStore` is `nonisolated final class` guarded by `OSAllocatedUnfairLock<State>`. Both the main thread (writers) and the watcher (reader) touch it — every access goes through the lock. No `nonisolated(unsafe)` (forbidden by `CLAUDE.md`).
- The store is a module-level `nonisolated let _samPerformanceStore` so `HangWatchdog` (nonisolated) can reach it without hopping through `@MainActor`. `PerformanceMonitor.shared.store` returns the same instance.
- `PerformanceMonitor` itself is `@MainActor` because every `measure(...)` call site is already on the main actor — zero hop cost wrapping fast operations.

### UI

`SAM/Views/Settings/DiagnosticsSettingsPane.swift` gained a Performance Watchdog block: a table of the 10 most recent hangs (timestamp, active operation, stalled seconds), a Refresh button, and an "Open Diagnostics Folder" button that reveals the JSON files in Finder.

### Verified

- `xcodebuild` clean.
- Heartbeat / hang transition logic reviewed by inspection: watcher only writes on the *transition* into hang; recovery logs once when heartbeat returns; pruning keeps at most 50 reports.
- The 18-scanner instrumentation is a mechanical wrap of existing call sites; the underlying scanners are unchanged.

### Out of scope (deferred to 1c / 1d)

- MetricKit subscription (`MXMetricManager` daily payloads).
- Auto-delivery webhook to `SAM@stillwaiting.org` behind `INTERNAL_TELEMETRY=1` build flag. Manual transfer of hang JSON files via the existing diagnostics folder is fine for now.
- Cross-thread main-thread call-stack capture.

### Files

`SAM/Services/PerformanceMonitor.swift` (new), `SAM/Services/HangWatchdog.swift` (new), `SAM/App/SAMApp.swift`, `SAM/Coordinators/OutcomeEngine.swift`, `SAM/Coordinators/DailyBriefingCoordinator.swift`, `SAM/Coordinators/MeetingPrepCoordinator.swift`, `SAM/Coordinators/ContactsImportCoordinator.swift`, `SAM/Views/Settings/DiagnosticsSettingsPane.swift`, `SAM/1_Documentation/roadmap/scaling-roadmap.md`.

---

## Phase 0 shipped: Dataset Audit, Trip Durability, pre-approved diagnostics auto-send (May 7, 2026)

**What**: First two scaling-roadmap deliverables. Sarah's Mac can now produce a quantitative audit of her dataset growth and (with pre-approval) auto-email the JSON back so we can plot it offline. Trips also became durable across phone reinstalls — the Mac is now a system-of-record mirror for `SamTrip`/`SamTripStop`/`SamSavedAddress`, with backup coverage and first-launch resync.

### Why

Sarah is ~2 months in at ~13.7K evidence rows / ~1.6K contacts. We need real numbers to extrapolate 1y / 3y / 5y growth before we commit to bigger architectural changes (per-person rollup tables, ModelActor extraction, GRDB escape on hot paths). Phase 0 was scoped explicitly to gather data, not to optimize. Trip durability rode along because it's a one-session deliverable and trips were silently single-device-only on the phone — a SAMField reinstall wiped them.

### 0a — Dataset Audit (commits `377a0dc`, `33c2d2f`)

- **`SAM/Services/DatasetAuditService.swift`** — new `@MainActor` service. Walks every one of the 52 `@Model` classes registered in `SAMModelContainer.SAMSchema.allModels`, counts rows, and builds an ISO-week histogram keyed `YYYY-Www` against the most semantically appropriate timestamp per model (e.g., `SamPerson.lifecycleChangedAt`, `SamEvidenceItem.occurredAt`, most `createdAt`, `TimeEntry.startedAt`, `StageTransition.transitionDate`, `RecruitingStage.enteredDate`, `SamTrip.date`, etc.). For models with no creation-time field, the histogram is omitted with a `"(none)"`/`"(offset only)"` source label. Also emits per-source `SamEvidenceItem` breakdown and on-disk file sizes (SQLite + WAL/SHM, audio directory, pre-open backups, total Application Support).
- **`SAM/Views/Settings/DiagnosticsSettingsPane.swift`** — new pane. Header with Run / Save JSON / Copy JSON; in-pane summary card (sizes, model table, evidence-by-source breakdown).
- **`SAM/Views/Settings/SettingsView.swift`** — added a new `Advanced` group with `case diagnostics` (icon `stethoscope`).

### 0a addendum — pre-approved auto-send (commit `33c2d2f`)

Sarah doesn't need to hand-attach the JSON. Toggle once in Settings → Diagnostics → "Automatically email diagnostic reports"; macOS prompts for Mail.app Automation permission once via an immediate test send; thereafter every audit silently posts to `sam@stillwaiting.org`.

- **`SAM/Services/DiagnosticsMailService.swift`** — new `@MainActor @Observable` singleton. Drives Mail.app via `NSAppleScript` (same pattern already used in `ComposeService.swift`). `sendTestEmail()` and `sendDatasetAudit(Data)`; the audit attachment is written to `/tmp/sam-dataset-audit-<ISO8601>.json`, sent, and cleaned up 30s later in a detached task. Recipient is hard-coded; `UserDefaults` keys persist `isEnabled`, `lastSentAt`, `lastError`.
- **Entitlements / Info.plist** — already in place: `com.apple.security.automation.apple-events` true, `com.apple.mail` in the temporary-exception list, `NSAppleEventsUsageDescription` already authored. No new permission surface.

**Private-beta scope (must un-ship before public release)**: the recipient is hard-coded to the developer's inbox. Memory `project_diagnostics_auto_send.md` documents the three viable gating strategies (remove pane / `#if SAM_INTERNAL` gate / make recipient configurable) and the triggers that should surface this reminder (App Store submission, beta-test expansion, marketing, copyright/LLC setup, "ship v1 publicly").

### 0b — Trip Durability (commit `43baefe`)

- **Wire protocol** (`SAMModels-AudioStreaming.swift`) — four new message types at `0x11`–`0x14`: `tripUpsert`, `tripDelete`, `tripSyncRequest`, `tripSyncBundle`. Length-prefixed JSON over the existing TCP/HMAC stream; no framing changes.
- **DTOs** — `TripUpsertDTO`, `TripDeleteDTO`, `TripSyncRequestDTO`, `TripSyncBundleDTO`. All `Sendable`. Round-trip carries the trip, ordered stops, and any referenced saved addresses.
- **Mac side** — new `TripIngestCoordinator` upserts via `TripRepository` (resolve-by-UUID, last-write-wins). New `TripRestoreService` handles `tripSyncRequest` by gathering everything from `TripRepository.fetchAll()` + saved addresses and replying with `tripSyncBundle`. `AudioReceivingService.swift` dispatches the four new opcodes.
- **Phone side** — `TripPushService` pushes on trip close / edit / confirm / delete; queues to a `PendingTripUpload` outbox table (mirroring the existing `PendingUpload` recording pattern) when offline, drains on reconnect. First-launch resync: if local trip count is 0 and `tripsRestoreAttempted` is false, the phone sends `tripSyncRequest` after the Mac handshake and ingests the bundle.
- **Backup coverage** — `BackupCoordinator.swift` + `BackupDocument.swift` now encode/decode `SamTrip`, `SamTripStop`, and `SamSavedAddress` so Mac→Mac restore preserves trips.

**Out of scope on purpose**: conflict resolution beyond last-write-wins (Sarah is the only writer); Mac-originated trip writes pushing back to the phone (phone remains system of record for *new* trips, Mac is the durable mirror); recovery of *historical* lost trips (gone — the fix prevents future loss).

### Verified

- Run Audit → JSON saves and copies cleanly; row counts match a manual `sqlite3 .count` spot-check on five models.
- Toggle Auto-send → macOS Automation prompt fires once → test email arrives at `sam@stillwaiting.org`. Subsequent runs silent.
- Closing a trip on the phone shows up in `MacTripsView` within seconds. SAMField reinstall + pair → trips restored from Mac. Mac→Mac backup restore preserves trips.

### Files

`SAM/Services/DatasetAuditService.swift`, `SAM/Services/DiagnosticsMailService.swift`, `SAM/Views/Settings/DiagnosticsSettingsPane.swift`, `SAM/Views/Settings/SettingsView.swift`, `SAM/Coordinators/TripIngestCoordinator.swift`, `SAM/Services/TripRestoreService.swift`, `SAM/Services/AudioReceivingService.swift`, `SAM/Services/BackupCoordinator.swift`, `SAM/Services/BackupDocument.swift`, `SAMModels-AudioStreaming.swift`, `SAMField/Services/TripPushService.swift`, `SAMField/Coordinators/TripCoordinator.swift`.

---

## Launch-time performance pass: O(P × E) hotspots and main-actor yields (May 7, 2026)

**What**: At Sarah's scale (~1.4K people, ~13.7K evidence rows) the app was monopolizing the MainActor for several minutes after launch. The post-meeting capture sheet appeared but couldn't accept keystrokes; lock screen presentation lagged; multiple multi-second beachballs sat between log lines during the import sequence. This pass eliminates the worst hot spots with a mix of date-windowed predicate fetches, single-pass dictionary builds replacing nested filters, and deferring non-critical pruning past first paint.

### Why

Several launch-path coordinators were calling `EvidenceRepository.fetchAll()` and then filtering in memory — fine at hundreds of rows, pathological at tens of thousands. Worse, several callers had an inner per-person loop over the full evidence set, producing O(people × evidence) comparisons synchronously on the main actor (~19M comparisons in Sarah's case). Pruning was also running inline before the first paint completed.

### Changes

- **`SAMApp.scheduleDeferredLaunchWork`** (`cc48a7e`, `044d1e9`) — `OutcomeEngine.startGeneration`, pipeline backfill, `DailyBriefingCoordinator.checkFirstOpenOfDay`, and the `OutcomeRepository`/`UndoRepository` pruners now all run from a `Task(priority: .utility)` behind a 3s sleep so first paint completes before they touch the store. Yesterday's expired outcomes do not need to be marked the instant the window opens.
- **`OutcomeEngine.generateOutcomes`** (`cc48a7e`) — `await Task.yield()` between fetches and after each of the 18 scanners so the MainActor releases for UI work during the scan pass.
- **`OutcomeEngine` scanners** (`0dc00ec`) — `scanUpcomingMeetings`, `scanPastMeetingsWithoutNotes`, and `shouldAutoResolve` switched from global `fetchAll` to `EvidenceRepository.fetchOccurringBetween(start, end)` (new helper) so SwiftData pushes the date predicate into the query.
- **`InsightGenerator.generateRelationshipInsights`** (`0dc00ec`) — replaced the per-person `allEvidence.filter { evidence.linkedPeople.contains(...) }` with a single upfront pass that builds `[UUID: Date]` of most-recent evidence per person, then per-person becomes O(1). At Sarah's scale this drops ~19M comparisons to ~14K. Yields every 500 evidence rows during the build and every 50 people during the predictive-decay loop.
- **`DailyBriefingCoordinator.gatherCalendarItems` / `gatherTomorrowPreview`** (`197f0b4`) — replaced fetchAll-then-filter with `fetchOccurringBetween` over the day window and the tomorrow window respectively.
- **`DailyBriefingCoordinator.gatherFollowUps`** (`197f0b4`) — converted to async and yields every 50 people so the 1.4K-person sweep through `computeHealth` no longer monopolizes the main actor before the morning briefing call into MLX.
- **`EvidenceRepository.refreshParticipantResolution`** (`04e4ca4`) — built a `[canonicalEmail: SamPerson]` dictionary in one upfront pass instead of filtering all people once per evidence row. This was the visible pause between the WhatsApp JID enumeration and the `Deduced N relationship(s) from contact relations` log line during contact import. Total work is now O(people + evidence) instead of O(people × evidence).
- **`MeetingPrepCoordinator.buildBriefings` / `buildFollowUpPrompts`** (`5f31155`) — replaced `fetchAll()` with `fetchOccurringBetween` over a 30-day window (matching the helpers' lookback) and a 56-hour window respectively.

### New repository surface

`EvidenceRepository.fetchOccurringBetween(_ start: Date, _ end: Date)` — date-bounded predicate fetch. Push this into the database whenever a caller only needs evidence inside a known window; reserve `fetchAll()` for true full-table operations (compaction, full re-index, etc.).

### Verified

Importing Sarah's 13,666-evidence DB, the meeting-capture sheet now accepts keystrokes within ~1s of appearing instead of hanging. The previously-reported beachballs (pre-MLX-load, pre-contacts-import, between WhatsApp JID enumeration and contact-relation deduction) are all gone.

### Phase 2 candidates (deferred)

Not all `fetchAll()` callers got the windowed-fetch treatment in this pass. Lower-priority sites still in `DailyBriefingCoordinator` and `EvidenceRepository.findRecentMeeting`/`hasRecentCommunication` are O(E) but only fire once per launch or per user action — fine for now. Architectural follow-ups under consideration: indexed predicates on hot columns, per-person rollup tables for "most recent evidence per person", and paged backfill for the initial migration of an existing database. Pause for a design conversation before implementing.

---

## Crash fix: cross-context relationship write in pending-reviews refresh (April 27, 2026)

**What**: 1.0(1) crashed with `EXC_BREAKPOINT` (SwiftData `_assertionFailure` from `ObservationRegistrar.withMutation`) when the 5-minute briefing timer fired and a pending meeting review was waiting. Crash signature: `SamOutcome.linkedPerson.setter` ← `DailyBriefingCoordinator.refreshPendingReviewsOutcome()` ← `createMeetingNoteTemplate(...)` (line 961) ← `checkRecentlyEndedMeetings()` ← timer closure inside `configure(container:)` (line 169).

### Why

`DailyBriefingCoordinator`, `OutcomeRepository.shared`, and `EvidenceRepository.shared` each create their own `ModelContext`. `refreshPendingReviewsOutcome` was assigning a `SamPerson` from the evidence repo's context to `existing.linkedPerson` on a `SamOutcome` from the outcome repo's context. SwiftData traps inside `withMutation` on cross-context relationship writes. The same path also called `try context.save()` (the briefing coordinator's context) on mutations that lived in the outcome repo's context — so `existing.status = .completed` was never persisted when the queue drained.

`OutcomeRepository.upsert(...)` already handled this for the insert path via a private `resolveInContext(_:)`, but the in-place update branch in `refreshPendingReviewsOutcome` bypassed it and wrote directly.

### Fix

- `SAM/Repositories/OutcomeRepository.swift`: `resolveInContext(_ person: SamPerson?)` flipped from `private` to internal so other `@MainActor` callers can re-fetch a `SamPerson` into the outcome repo's context before assigning it to a `SamOutcome` relationship.
- `SAM/Coordinators/DailyBriefingCoordinator.swift` `refreshPendingReviewsOutcome()`: route the candidate `linkedPerson` through `outcomeRepo.resolveInContext(...)` before the assignment, and replace both `try context.save()` calls with `try outcomeRepo.save()` so saves land in the context that owns `existing`. Drop the now-unused `guard let context` at the top of the method.

### Diagnosis trail

Symbolicated 1.0(1) (UUID `A8DE1ECA-9B54-3F39-B092-B0543613C1AA`, archive `SAM 4-23-26, 3.02 PM.xcarchive`) with `atos`. Stack named the property setter and the calling coordinator method directly, which made the cross-context source obvious by inspection (three different repos, three different contexts, one shared `SamPerson`).

### Risk

Any user with an outstanding pending-review outcome and a still-pending calendar event would have hit the trap within 5 minutes of launch. Warrants a 1.0(2) rebuild.

---

## Recording Reclassification (April 25, 2026)

**What**: Sarah can now reclassify a recording's `RecordingContext` (e.g., from `clientMeeting` to `trainingLecture`) on either the Mac or SAM Field. Reclassifying triggers a full resummarize against the new context-specific prompt and pushes the regenerated summary to whichever device didn't initiate the change.

### Why

It is easy to forget to set the right type before hitting record — especially impromptu captures that turn out to be a training session, or vice versa. Without reclassification the summary produced by the wrong prompt was permanent and a lot of useful structure (lecture review notes, board minutes, prospecting next-step compliance, etc.) was lost.

### Gating

Reclassification is only offered while the audio + verbatim transcript still exist on the Mac, because regenerating the summary requires re-running `MeetingSummaryService.summarize` against the original transcript:

- **Mac** (`TranscriptionReviewView`): visible while `session.signedOffAt == nil && session.audioFilePath != nil && session.audioPurgedAt == nil`. Once Sarah taps "Looks Good" or `RetentionService` purges the audio, the menu disappears.
- **Phone** (`MeetingCaptureView` completedView): visible while `coordinator.sessionID != nil && coordinator.lastSummary != nil && coordinator.isMacConnected`. Once Done or Delete is tapped the local sessionID clears and the menu disappears.

Confirmation dialog on both sides — resummarizing is destructive (the prior summary is gone) and takes 10–30 seconds.

### Wire protocol

- `MessageType.recordingContextChanged = 0x10` (frees the old `pinPairingRequest` slot).
- `RecordingContextChangedDTO { sessionID: UUID, recordingContextRaw: String }` JSON payload, bidirectional.
- Phone-initiated: phone sends → Mac updates session, runs `TranscriptionSessionCoordinator.reclassifyAndResummarize`, pushes new summary via existing `summaryPush`.
- Mac-initiated: Mac runs the same coordinator path, then sends `recordingContextChanged` so the phone clears its stale summary card and shows a "regenerating" state until the new `summaryPush` lands.

### Files touched

- `SAM/Models/SAMModels-AudioStreaming.swift`: new `MessageType.recordingContextChanged` case + `RecordingContextChangedDTO`.
- `SAM/Services/AudioReceivingService.swift`: `onRecordingContextChanged` callback, inbound handler, `sendRecordingContextChanged` outbound sender.
- `SAM/Coordinators/TranscriptionSessionCoordinator.swift`: wires the callback to the new public `reclassifyAndResummarize(sessionID:to:)`, which gates on retention, updates the model, and reuses `generateMeetingSummary` for the resummarize + phone push.
- `SAM/Views/Transcription/TranscriptionReviewView.swift`: header menu "Change Recording Type", confirmation dialog, `canReclassifyRecording` gate; existing `generateSummaryFromTranscript()` regenerate path now also pushes the regenerated summary to the phone (previously a missing hook).
- `SAMField/Services/AudioStreamingService.swift`: `onRecordingContextChanged` callback, inbound handler, `sendRecordingContextChanged` outbound sender.
- `SAMField/Coordinators/MeetingCaptureCoordinator.swift`: tracks `currentRecordingContext` and `isReclassifying`; new `reclassifyCurrentRecording(to:)`; `onMeetingSummary` clears `isReclassifying` when the regenerated summary lands; `onRecordingContextChanged` mirrors a Mac-initiated change locally and shows the regenerating state.
- `SAMField/Views/Capture/MeetingCaptureView.swift`: completedView "Change Recording Type" menu, confirmation dialog, `canReclassifyRecording` gate.

### Side effects on existing flows

`CommitmentExtractionService.extract` already de-duplicates by session + normalized text, so resummarizing an already-extracted session creates only the *new* commitments produced by the new prompt — old commitments stay attached.

---

## CloudKit-Distributed Pairing (April 24, 2026)

**What**: Replaced the 6-digit PIN pairing handshake (which itself replaced QR and the "oort cloud" experiment) with implicit pairing via CloudKit private DB. Every SAM device belongs to the same iCloud account, so the private DB is itself the trust boundary — a Mac writes its 32-byte HMAC token to its private CloudKit zone on first launch, and any phone signed into the same iCloud account fetches it automatically. No PIN, no QR, no sheet. The TCP/Bonjour audio stream and the existing `SAM-AUTH-v1|phoneDeviceID|challengeB64` HMAC handshake stay exactly as they were — only the *source of the shared secret* changed.

### Why

The PIN approach worked but was wasted effort: the trust boundary it manually re-created (does this iPhone belong to the same user as this Mac?) was already enforced for free by CloudKit's per-account access control. Phones from different iCloud accounts can't read the token, so HMAC fails for them automatically. Removing the entire pairing UX is a meaningful UX win — first-launch on the phone now Just Works.

### Architecture

- **CloudKit record type** `SAMPairingToken` in the existing `iCloud.sam.SAM` private DB. One record per Mac, recordID `pairingToken-{macDeviceID}`. Fields: `macDeviceID` (String), `macDisplayName` (String), `tokenB64` (String, 32 raw bytes base64), `updatedAt` (Date).
- **Mac on bootstrap** (`SAM/Services/DevicePairingService.swift`): generates token + macDeviceID into Keychain on first launch (unchanged), then calls `CloudSyncService.pushPairingToken(...)` to publish. Idempotent — subsequent launches re-push the same token.
- **Phone on bootstrap** (`SAMField/Services/DevicePairingService.swift`): hydrates `trustedMacs` from Keychain first (so we work offline), then calls `CloudSyncService.fetchPairingTokens()` and merges any new/updated tokens. New entries are persisted to Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) so we don't re-hit CloudKit on every cold start. The new `refreshFromCloudKit()` is also exposed for pull-to-refresh in Settings and is called automatically when the Bonjour browser sees an unrecognized SAM Mac.
- **Auth path on the Mac** (`SAM/Services/AudioReceivingService.swift`): unknown phones with valid HMACs are now auto-trusted (added to `pairedDevices`). The CloudKit boundary already vouched for them — only the iCloud user could have read the token to produce a valid HMAC.
- **Reset Pairing Token** (Mac Settings): regenerates the token, evicts every paired phone, and republishes to CloudKit. Phones pick up the new token on their next launch / refresh.

### Files removed

- `SAMField/Views/Settings/PinEntryView.swift` — entire 6-digit keypad sheet.
- `SAMModels-AudioStreaming.swift`: `pinPairingRequest = 0x10`, `pinPairingResult = 0x11`, `PinPairingRequest`, `PinPairingResult`.
- `SAM/Services/DevicePairingService.swift`: `currentPIN`, `currentPINExpiresAt`, `isPINActive`, `pinExpiryTask`, `startPINPairing`, `stopPINPairing`, `verifyPIN`, `generatePIN`.
- `SAM/Services/AudioReceivingService.swift`: `handlePinPairingRequest`, `sendPinPairingResult`, the `.pinPairingRequest`/`.pinPairingResult` switch cases, and the PIN exception in the pre-auth gate.
- `SAMField/Services/AudioStreamingService.swift`: `PinPairingState`, `pinPairingState`, `pendingPin`, `pinDiscoveryTimeoutSeconds`, `pinDiscoveryTimeoutTask`, `armPinDiscoveryTimeout`, `pairWithPIN`, `sendPinPairingRequest`, `handlePinPairingResult`, `.sendingPinRequest` from `PhoneAuthState`, the PIN branch in `handleAuthChallenge`, and the PIN-mode connect-to-anything branch in the browse handler.
- `SAMField/Services/DevicePairingService.swift`: `acceptPinPairingResult`.
- `SAM/Views/Settings/CompanionPhoneSettingsPane.swift`: `PairingExperienceSheet` (PIN-display sheet with countdown), the "Pair New iPhone" button, and `showingPairingSheet`.
- `SAMField/Views/Settings/SettingsView.swift`: `showingPINEntry`, the "Pair with Mac" button, the PinEntryView sheet.
- `SAMField/Coordinators/MeetingCaptureCoordinator.swift`: `restartBrowsingAfterPairing` (only PinEntryView called it).

### Files added / modified

- `SAM/Services/CloudSyncService.swift` — added `pairingTokenRecordType`, `pushPairingToken(macDeviceID:macDisplayName:tokenData:)`, `deletePairingToken(macDeviceID:)`, `fetchPairingTokens() -> [(UUID, String, Data)]` following the same `database.save(record)` / `serverRecordChanged`-fallback pattern used for briefings and workspace settings.
- `SAM/Views/Settings/CompanionPhoneSettingsPane.swift` — explanatory copy ("Any iPhone signed into the same iCloud account picks up this Mac's pairing token automatically — no PIN required."); paired-iPhones list and Reset Pairing Token kept.
- `SAMField/Views/Settings/SettingsView.swift` — replaced the "Pair with Mac" button with a "Refresh from iCloud" action that calls `DevicePairingService.refreshFromCloudKit()`. Updated copy explains the iCloud-account boundary.

### Migration

Existing PIN-paired devices are preserved: the Mac keeps its previously generated token in Keychain and just publishes it to CloudKit on the next launch. Already-paired phones keep their cached tokens in Keychain and continue to authenticate normally. No forced re-pairing.

### Notes

- The lesson — when two devices belong to the same iCloud account, prefer CloudKit-distributed trust over inventing custom pairing UX — is captured in `feedback_cloudkit_for_trust.md`.
- Real-time TCP/Bonjour audio streaming is retained; CloudKit is *only* the secret-distribution channel, not the live transport.
- `iCloud.sam.SAM` was already enabled in both target entitlements and the `CloudSyncService` shared via Xcode 16 synchronized folders, so no project-file changes were needed to ship this.

---

## Trips: address autocomplete, map / contact pickers, round-trip close, Year/All views (April 24, 2026)

**What**: Sarah-driven feature pass on the SAM Field manual-trip and active-trip flows. Eight related improvements ship together because they share the same data plumbing (Saved Addresses + autocomplete model).

### Capabilities

- **Saved Addresses** — new `SamSavedAddress` SwiftData model with three kinds (`home`, `favorite`, `recent`). Home is unique; favorites are user-labeled; recents auto-populate as addresses are used and prune to 15 entries. Schema stays at `SAM_v34` (additive). Registered in both `SAMModelContainer` and `SAMFieldModelContainer`.
- **Address autocomplete** — `AddressSuggestField` wraps `MKLocalSearchCompleter` with a `MKLocalSearch`-resolving picker. The dropdown surfaces Home → Favorites → Recents (when no live results) → live suggestions. Replaced every plain address `TextField` in `ManualTripEntryView`. Picks call `SavedAddressService.recordUse` so frequent destinations float to the top.
- **Map pin picker** — `AddressPickerMapView`: long-press to drop a pin, continue holding and drag to refine. Reverse-geocoded via iOS 26 `MKReverseGeocodingRequest` (replacing deprecated `CLGeocoder`). Wired into both the trip-start and per-stop rows.
- **Contact picker** — `ContactAddressPickerView`: ranks SAM contacts by today's calendar attendees → nearby (configurable radius, default 75 mi) → alphabetical, with `.searchable` override. Pulls postal addresses via `CNContactStore.unifiedContact` and forward-geocodes via `MKGeocodingRequest`.
- **Round-trip / Return-to-Home** — two convenience buttons in the manual-stops section: "Return to Start (Round Trip)" appends a final stop at the start coordinate; "Return to Home" appends a final stop at the saved Home address. Active trips also get a "Close at Home" button on the live-tracking panel that calls `TripCoordinator.closeAtHome` and ends the trip with a Home stop even if GPS dwell hasn't fired.
- **Year + All filters** — `TripsView` extends `TripPeriod` with `.year` (calendar year) and `.all`. Both group rows by month for readable scrolling.
- **Configurable contact radius** — `TripSettingsKeys.contactRadiusMiles` (`@AppStorage`, default 75, range 5–150). Lives in a new "Trips" Settings section that also exposes Home, Favorites (add/swipe-delete), and recent-history clearing.
- **Delete-reappear bug fix** — swipe-deleting a 0-mile trip no longer briefly reappears. `TripCoordinator.deleteTrip` now removes the row optimistically and reuses the deletion `ModelContext` for `refreshStats`, avoiding a stale fetch from a fresh context.

### Files added

- `SAM/Models/SAMModels-Trip.swift` — `SamSavedAddress` model + `SavedAddressKind` enum (additive).
- `SAMField/Services/SavedAddressService.swift` — `@MainActor @Observable` singleton: `home/favorites/recents` reads, `setHome/clearHome/addFavorite/promoteToFavorite/delete/clearRecents/recordUse`. Coordinate-proximity match (~30 m / 0.0003 deg) prevents recent duplicates.
- `SAMField/Views/Trips/AddressSuggestField.swift` — autocomplete field + `AddressCompleterModel` wrapping `MKLocalSearchCompleter`. Defines the shared `PickedAddress` struct.
- `SAMField/Views/Trips/AddressPickerMapView.swift` — long-press + drag map picker.
- `SAMField/Views/Trips/ContactAddressPickerView.swift` — ranked contact-address fill.
- `SAMField/Views/Settings/TripSettingsView.swift` — Trips settings section.

### Files modified

- `SAMField/Coordinators/TripCoordinator.swift` — delete-reappear fix; `hasHomeAddress`, `closeAtHome`.
- `SAMField/Views/Trips/ManualTripEntryView.swift` — autocomplete in start + stop rows; Current Location / Map / Contact buttons; Return-to-Start / Return-to-Home; `MKReverseGeocodingRequest` migration.
- `SAMField/Views/Trips/TripsView.swift` — `.year` / `.all` filters with month grouping; "Close at Home" on the active-trip panel.
- `SAMField/App/SAMFieldApp.swift` — bootstraps `SavedAddressService.configure(container:)`.
- `SAMField/App/SAMFieldModelContainer.swift`, `SAM/App/SAMModelContainer.swift` — register `SamSavedAddress`.
- `SAMField/Views/Settings/SettingsView.swift` — Trips Settings entry.

### Notes

- The `#Predicate { $0.id == address.id }` form crashes the Swift macro expander; bound `targetID = address.id` to a local before the predicate to keep the comparison `KeyPath<Variable<SamSavedAddress>, UUID> == UUID` rather than two keypath operands.
- Default contact radius is 75 mi for rural users (Sarah's territory). Larger urban-agent practices can dial it down in Settings.
- All long-form coaching/business reasoning still runs in Swift; this pass is pure data-entry plumbing — no LLM in the picker paths.

---

## PIN Pairing Between Mac and iPhone (April 23, 2026)

**What**: Replaced the previous (non-functional) "oort cloud" pairing experiment with a simple 6-digit PIN handshake for the iPhone ↔ Mac audio streaming link. The Mac displays a PIN, the phone enters it, and the two devices exchange a 32-byte HMAC token that keys every subsequent authentication.

### Architecture

- **New services**: `SAM/Services/DevicePairingService.swift` (Mac) and `SAMField/Services/DevicePairingService.swift` (iPhone). Each holds its own identity (`macDeviceID` / `phoneDeviceID`) and the shared pairing token(s). Mac can accept many phones; phone can be paired with multiple Macs. Tokens live in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **New wire messages** in `SAMModels-AudioStreaming.swift`: `pinPairingRequest` (phone → Mac, carries PIN + phone identity), `pinPairingResult` (Mac → phone, carries token + Mac identity on success).
- **Bonjour TXT record** (`_samtranscript._tcp`) now carries `devid` and `name` keys so paired phones can recognize which Mac is theirs on the reconnect path.
- **Handshake**: every new TCP connection from a phone triggers an `authChallenge`. A paired phone answers with an HMAC-SHA256 `authResponse` (message = `SAM-AUTH-v1|phoneDeviceID|challengeB64`, key = pairing token). An unpaired phone that's in PIN-entry mode answers the same `authChallenge` with a `pinPairingRequest` — the Mac verifies the PIN, replies with `pinPairingResult` carrying the token, and the same TCP connection transitions to authenticated without a reconnect.
- **Mac pairing UI**: `SAM/Views/Settings/CompanionPhoneSettingsPane.swift` — dedicated "Companion Phone" section in Settings. Shows a PIN card (90 s countdown), paired-iPhone list with per-device unpair, and a "Reset Pairing Token" destructive action that evicts every paired phone.
- **iPhone pairing UI**: `SAMField/Views/Settings/PinEntryView.swift` — 6-digit keypad sheet with live status banner driven by `AudioStreamingService.pinPairingState`.

### TXT-record fallback (the bug that shipped and was fixed)

The first runtime test revealed the phone's `NWBrowser` discovering the Mac but not receiving the TXT record (`"Skipping browse result with no SAM TXT record: ..."`). iOS's Bonjour browser doesn't always resolve the TXT on the first browse event, and the original implementation bailed out silently when `metadata` was `.none`, leaving the UI stuck in "searching" until a 30 s discovery timeout fired.

Fix: in PIN-entry mode the phone no longer requires a TXT record — it connects to the first `_samtranscript._tcp` endpoint it sees, sends the PIN, and picks up the Mac's real `macDeviceID` / `macDisplayName` from `PinPairingResult`. The TXT record is still read on the normal post-pairing reconnect path to route HMAC responses to the correct stored token. Helper `endpointName(_:)` decodes `\032` → space so endpoint names render cleanly when used as a provisional label.

### Safety rails

- **Discovery timeout**: `pairWithPIN` arms a 30-second task that flips `pinPairingState` to a user-visible failure (with a concrete hint about Local Network permission / Wi-Fi) if no SAM Mac appears.
- **Auth handshake timeout**: 15 seconds from TCP-ready to authenticated, otherwise the connection is torn down.
- **Pre-auth packet gate**: the Mac drops every message except `authResponse` and `pinPairingRequest` until the connection is authenticated.
- **Browser state logging**: `.waiting(error)` is now logged so permission / network-path issues surface in Console instead of silently stalling.
- **Tokens never leave Keychain** except inside a successful `pinPairingResult` (gated by the PIN itself).

### Files added

- `SAM/Services/DevicePairingService.swift` — Mac-side pairing service (PIN generation + verification, token management, paired-device list, HMAC verification).
- `SAM/Views/Settings/CompanionPhoneSettingsPane.swift` — Mac settings pane with PIN display sheet.
- `SAMField/Services/DevicePairingService.swift` — iPhone-side trust store (multi-Mac).
- `SAMField/Services/KeychainService.swift` — thin iOS Keychain wrapper.
- `SAMField/Views/Settings/PinEntryView.swift` — iPhone PIN entry sheet.

### Files modified

- `SAM/App/SAMApp.swift`, `SAMField/App/SAMFieldApp.swift` — await `DevicePairingService.bootstrap()` before anything touches the network.
- `SAM/Models/SAMModels-AudioStreaming.swift` — `PinPairingRequest`, `PinPairingResult`, `AuthChallenge`, `AuthResponse`, `AuthResult`, TXT-record keys, new `MessageType` cases.
- `SAM/Services/AudioReceivingService.swift` — pre-auth gate, `handlePinPairingRequest`, TXT record on the listener, idempotent `startAdvertising`.
- `SAM/Coordinators/TranscriptionSessionCoordinator.swift`, `SAMField/Coordinators/MeetingCaptureCoordinator.swift` — reuse the new shared `AudioReceivingService.shared` / `AudioStreamingService.shared` singletons.
- `SAMField/Services/AudioStreamingService.swift` — `pairWithPIN`, PIN-mode browse branch, `pinDiscoveryTimeoutTask`, TXT fallback, surfaced `.waiting` / `.failed` browser states.
- `SAMField/Views/Settings/SettingsView.swift` — Mac Connection section with pair list + PIN entry sheet.
- `SAM/Views/Settings/SettingsView.swift` — new "Companion Phone" settings section in the General group.
- `SAMField/Info.plist` — `NSLocalNetworkUsageDescription` + `NSBonjourServices`.

### Why this replaces QR / "oort cloud"

The prior QR-based flow required camera access and perfect scan conditions; the oort-cloud variant added a multi-step ack/confirm handshake that never reliably closed. PIN is one screen on each device, no camera, no extra round-trips — and the same HMAC token ends up persisted, so the steady-state reconnect path is unchanged from what audio streaming already expected.

### Known follow-up

The iOS TXT-record delivery issue is worked around, not root-caused. Normal post-pairing reconnects still depend on the TXT being present to route HMAC against the right stored token. Worth a closer look if users report reconnect failures with multiple paired Macs.

---

## Morning Briefing Prompt v3 — Pronoun Discipline (April 22, 2026)

**What**: Replaced the morning-briefing prompt in `DailyBriefingService.generateMorningNarrative` and `PromptLabCoordinator.defaultMorningBriefingPrompt` with a third-generation variant that enforces pronoun discipline, date fidelity, and required-section coverage. The previous prompt ("150 words or less", 3-part structure) had been in production since the briefing system shipped.

- **Pronoun discipline**: the advisor is "you" / "your" throughout. "I" / "my" is reserved for SAM (the assistant). "we" is banned entirely — the advisor is not attending their own meetings with SAM.
- **Meeting-attendee rewrite pattern**: "You meet with Jane Martinez" instead of "Jane Martinez and I". Prevents a specific failure mode where the model would fill the "I" slot with a duplicate of the other attendee's name ("Jane Martinez and Jane Martinez").
- **Date fidelity**: explicit instruction that if the data says a birthday is today, it is today — do not shift it to yesterday or tomorrow.
- **Required-section checklist**: today's schedule, priority actions, follow-ups, life events, business goals, tomorrow preview. Prior prompt let the model silently skip sections.
- **Word-count floor**: 110–160 words (was "150 words or less"). Shorter than 110 means sections got skipped.
- **Voice softening**: command-voice openers ("Please ensure", "Prioritize sending") discouraged; "Worth a quick note to [name]", "The day opens with…", "Looking ahead…" preferred.

### Why
Original prompt allowed outputs like "Jane Martinez and I will meet to review life insurance coverage" — SAM was speaking as Sarah rather than to her. The briefing is a coaching artifact, not a diary entry; the pronoun register matters for how the user experiences the surface.

### Bench validation (sam-bench narrative track, briefing-morning-001, n=5)
Measured on FoundationModels backend, full bake-off documented in `sam-bench/FINDINGS.md`.

| Metric | v2 (prior default) | v3 (new default) | Δ |
|--------|-------------------|------------------|---|
| First-person-for-advisor errors | ~every run | 0 / 10 runs | eliminated |
| Subject accuracy (judge) | 4.67 | 5.00 | +0.33 (perfect) |
| Repetition (higher = less) | 1.67 | 3.20 | +1.53 |
| Structure (judge) | 4.00 | 4.20 | +0.20 |
| Tone (judge) | 3.67 | 3.80 | +0.13 |
| Overall usefulness (judge) | 4.67 | 4.60 | ≈ |
| Deterministic groundedness | 0.90 | 0.99 | +0.09 |
| Length in-range (target 80–180) | 1.00 | 0.80 | −0.20 (one run just under floor) |

### Compatibility
Users with a custom prompt deployed via Prompt Lab (`UserDefaults` key `sam.promptLab.morningBriefing`) keep their deployed version. The v3 prompt is only applied when no Prompt Lab override is active.

---

## Briefing v3 Extended — Evening + Morning/Evening TTS (April 22, 2026)

**What**: Extended the v3 pronoun-discipline rules from the morning visual briefing to the three remaining briefing surfaces — morning TTS, evening visual, evening TTS — in both `DailyBriefingService` inline prompts and `PromptLabCoordinator.defaultEveningBriefingPrompt`.

- Morning TTS: explicit pronoun discipline line ("your 10 AM", not "our meeting" or "I'll meet with…"), date fidelity.
- Evening visual: full pronoun-discipline block ("your day", "what you closed today", "we" banned), tightened word budget to 60–120, date fidelity, dropped redundant "Respond with ONLY…" line since that lives in the system instruction.
- Evening TTS: short pronoun-discipline line, date fidelity.

### Why
Even though the v3 morning-visual win was measured, the other three surfaces still routed through v1 prompts — mismatched register within the same briefing session (morning visual = "your 10 AM", evening TTS = "we had a good week"). This aligns the whole briefing family on the same pronoun register.

### Bench validation
Prompt bodies are identical to the `NarrativePrompts.v3` variants already in sam-bench; no separate bench sweep was run for these surfaces. Production deployment is the validation.

### Compatibility
Evening Prompt Lab override (`sam.promptLab.eveningBriefing`) still wins when deployed. Morning/evening TTS have no Prompt Lab override path.

---

## Morning Briefing Prompt v3 — Pronoun Discipline Bake-off (Qwen3-8B, April 22, 2026)

**What**: Re-benched the MLX Qwen3-8B-4bit narrator against the v3 prompt (prior measurement was v1 only).

### Results (briefing-morning-001, n=5)

| Metric | v1 (n=3) | v3 (n=5) | Δ |
|--------|----------|----------|---|
| First-person-for-advisor errors | present | 0 / 5 | eliminated |
| Length in-range (110–160 words) | 0.67 | 1.00 | +0.33 |
| Word count | 79 (chronically short) | 93 | +14 |
| Deterministic groundedness | 0.75 | 0.96 | +0.21 |
| Subject accuracy (judge) | 5.00 | 4.40 | −0.60 |
| Grounding (judge) | 5.00 | 4.20 | −0.80 |
| Structure (judge) | 4.67 | 4.20 | −0.47 |
| Tone (judge) | 4.67 | 4.00 | −0.67 |
| Usefulness (judge) | 5.00 | 4.40 | −0.60 |
| Latency | 42.3s | 58.4s | +16s |

Judge dips likely reflect variance on the v1 n=3 sample (where a single run sets the per-dimension mean). Det-groundedness and length compliance are the structural wins. Pronoun discipline lands cleanly on Qwen3-8B.

### Recommendation
Qwen3-8B-4bit v3 is the recommended MLX-upgrade variant. Too slow (~60s) for foreground use; suitable for the "stronger coaching narrative" tier.

---

## Summary Prompt v10 — Recruiting Date Discipline (April 22, 2026)

**What**: Appended a DATE DISCIPLINE directive block to the recruiting-interview prompt only. All other contexts fall through to v9 unchanged.

- Rule 1: if the transcript did not state a date or relative phrase for a task, OMIT `dueDate` entirely. Empty is correct; inventing one is a bug.
- Rule 2: NEVER infer a month from a day-of-month reference. "Thursday the twelfth" stays as-is — do not silently attach "October" or "December."
- Rule 3: WRONG/RIGHT pairs bundled into the prompt to make the failure mode concrete for the model (e.g., `WRONG dueDate: "10/15"   RIGHT: (omit) or "by Monday"`).

### Why
v9 recruiting runs emitted isolated date fabrications — absolute `MM/DD` dueDates the transcript never stated, plus "december" inferred from "Thursday the twelfth." Recruiting transcripts are unusually date-dense (licensing deadlines, BPM invites, "by Monday"), steering the model toward emitting dates for every `actionItem` even when the transcript never dated them. Other contexts never surfaced the pattern.

### Bench validation (n=10 recruiting runs, v9 vs v10)
- Total hallucinations: 11 → 3
- Max in a single run: 7 → 1
- Mean per run: 1.1 → 0.3
- Overall recall: 87% → 89%
- Preserved dimensions held or improved (`skepticism` 80 → 97, `life_event` 40 → 60)

### Deferred
- Residual "december" false-positives (3/10 runs, 1 hallucination each) — baseline scoring artifact going back to v4. Likely needs a stronger negative example in the prompt or a scorer-side allowance when the transcript contains a lone day-of-month reference.

---

## Summary Prompt v9 Fixes (April 22, 2026)

**What**: Four targeted directive blocks appended to SAM's specialized prompts, each closing a specific recall gap the bench flagged after the v8 rollout.

- **Prospecting — HOUSEHOLD PROFILE**: forces spouse name + profession, children names + ages, and employer + plan type into tldr and topics verbatim. Bench `prospect_profile` recall 8% → 44%.
- **Recruiting — CANDIDATE PROFILE**: forces current employer + title + tenure into tldr and topics verbatim; optional compensation + spouse situation as topic tags. Bench `candidate_profile` recall 33% → 100%; `financial_risk` lifted 33% → 100% as an incidental bonus.
- **Annual review — YEAR-IN-REVIEW RECAP**: requires every prior-year position as a topic tag, every specific change as its own decisions/openQuestions entry, and tldr to name the single most consequential year-over-year change. Bench `year_review` recall 22% → 67%, reversing the v8 regression.
- **Board — FINANCIAL FIGURES**: routes treasurer-report numbers into `agendaItems.notes` verbatim, budget line-items into their agenda-item notes, and top-line quarter figures into topics as short tags. Bench `financial` recall 0% → 67%.

Each scenario's `_overall` moved up ~5pp with zero regressions on preserved dimensions. Temporal hallucination stayed at 0.0 across all 12 v9 bench runs. See `sam-bench/FINDINGS.md` for the full v8-vs-v9 table.

### Why
The April 22 context expansion landed the v8 specialized prompts. Bench runs after that exposed three specific misses — board financial capture, annual year-review recap, prospect/candidate profile detail — and this entry ships the narrowly-scoped fixes for each, validated end-to-end in the bench before porting to SAM.

---

## Summary Prompt Port + Context Expansion (April 22, 2026)

**What**: Three new `RecordingContext` cases (`prospectingCall`, `recruitingInterview`, `annualReview`) plus three new auditable `MeetingSummary` fields (`retentionSignals`, `numericalReframing`, `complianceStrengths`), all validated against the `sam-bench` keyword-recall rubric before porting.

### New Recording Contexts
- `RecordingContext` expanded from 3 → 6 cases. `.prospectingCall` and `.recruitingInterview` get compliance tracking (sales conversations); `.annualReview` is a client meeting with a year-over-year lens; `.trainingLecture` and `.boardMeeting` remain non-compliance. `supportsPersonLinking` unchanged — trainingLecture still the lone exception.
- `MeetingSummaryService.systemInstruction(for:)` now dispatches to six specialized prompt methods, each with a UserDefaults override hook: `sam.ai.prospectingSummaryPrompt`, `sam.ai.recruitingSummaryPrompt`, `sam.ai.annualReviewSummaryPrompt` (plus existing meeting / training / board).
- Prospecting/recruiting prompts push the model to capture referral chain, household/employer profile, objections-with-responses, licensing content, and income hedging — bench showed +32.9pp recall on prospecting and +20.0pp on recruiting vs. the generic client-meeting prompt.
- `MeetingSummaryPrinter` and `TranscriptionSessionCoordinator` updated with appropriate titles for the new contexts ("Prospecting Call", "Recruiting Interview", "Annual Review").

### Auditable MeetingSummary Fields
- `retentionSignals`, `numericalReframing`, `complianceStrengths` added to `MeetingSummary` as `@Guide`-annotated `[String]` fields with empty-array defaults. Backward-compatible: existing JSON decodes fine; `hasContent` updated to include them; printer renders dedicated sections for each.
- `clientMeetingInstruction()` prompt extended with field guidance for all three plus the worked reframe example ("if the advisor said 2022 messaging suggested 8-10% but realistic long-term is 5-6%, emit one entry containing both figures exactly as stated"). Bench validated this restoration as the fix for v6's reframe regression (25% → 100% on cm-007).

### Why
SAM's summary prompt had been stable since the initial phases but lacked the sales-specific context types (prospecting, recruiting, annual review) that Sarah uses alongside regular client meetings. The bench revealed two problems: (1) the generic client-meeting prompt was losing referral chains, prospect profiles, and candidate objections when those were the whole point of the call; (2) three auditable dimensions (retention risk, numerical reframes, compliance-positive posture) weren't being captured at all. The bench authored scenarios, scored the gaps, iterated prompts (v1 → v8), and this release ships the validated v7/v8-equivalent prompts to SAM.

### Schema
No migration required — all three new `MeetingSummary` fields decode as `[]` when absent from historical JSON. `RecordingContext` is string-backed with forward-compat defaults (`.clientMeeting` fallback on unknown raw values).

### Deferred
- `v8` prompt tuning for prospecting/recruiting profile fields (11% / 33% miss rate on planted facts).
- Annual-review year_review dimension regression (specialized prompt over-steers toward decisions/reframes; needs explicit year-in-review guidance).
- Board-meeting financial-figures capture (MeetingSummary lacks a dedicated financial field; prompt needs to route dollar amounts into topics/decisions).

---

## Commitments, Meeting-Occurrence Review, Impromptu Capture, Lock Hardening (April 21, 2026)

**What**: Four tightly-coupled blocks landed together: commitment tracking with per-person follow-through (Block 3), meeting-occurrence review after an event ends (consolidated queue + "did this happen?" decision), lightweight review sheet for calendar-less recordings (Block 4), and app-lock hardening that now engages on screen lock / screensaver / sleep with an artistic glass-block overlay (Block 5).

### Block 3 — Commitment Tracking
- **`SamCommitment` model** (`SAMModels-Commitment.swift`): direction (`fromUser` / `toUser`), status (`pending` / `fulfilled` / `missed` / `dismissed`), `dueDate`, linkedPerson, linkedSession.
- **`CommitmentRepository`**: CRUD + `sweepMissed()` (grace period past due → `.missed`) + `fetchOpenFromSarah(dueWithin:)` + per-person `followThroughRate` (tiered: reliable / mixed / flaky).
- **`CommitmentExtractionService`**: converts `MeetingSummary.actionItems` into durable commitments at summary time, so follow-through survives transcript cleanup. Sarah-owned items → `.fromUser` + best non-self attendee; attendee-owned → `.toUser` + matched attendee; unassigned items skipped.
- **`OutcomeEngine.scanOpenCommitments()`** (new `OutcomeKind.commitment`): aggregates Sarah's overdue/due-soon commitments per counterparty into a single actionable outcome per person.
- **`MeetingPrepCoordinator.AttendeeProfile.followThrough`**: attaches a `FollowThroughSummary` DTO with display-ready headline and coaching hint ("4 of 5 kept — Reliable: commitments here usually land. Move at their pace.") so pre-briefs name the person's track record before the meeting.

### Block 4 — Impromptu Recording Review
- `TranscriptSession` gained `calendarEventID`, `impromptuReviewShownAt/OutcomeRawValue/ReviewedAt`, usage signals (`summaryOpenedCount`, `producedNote`), and computed `isImpromptu` / `needsImpromptuReview`.
- `ImpromptuReviewPayload` (Sendable/Identifiable, UUID id = sessionID) is posted on `.samOpenImpromptuReview` right after Block 3 commitment extraction.
- `ImpromptuRecordingReviewView`: compact sheet with TLDR, `RecordingContext` segmented picker (clientMeeting/trainingLecture/boardMeeting), person picker, Approve/Skip/Discard row. Approve sets context + links person + calls `RetentionService.signOff`. Discard mirrors `TranscriptionReviewView.performDelete` (audio file + note + evidence + tombstone + session).
- `TranscriptionReviewView` now bumps `summaryOpenedCount` on load and flips `producedNote = true` when a note is saved.

### Meeting-Occurrence Review
- New `EvidenceReviewStatus` on `SamEvidenceItem`: `pending` (surfaced for review) / `confirmed` / `cancelled` / `didNotHappen` / `rescheduled`. `countsAsOccurred` is false for the last three — `OutcomeEngine` stale-contact scan and `MeetingPrepCoordinator` interaction counts now skip non-occurrences so a calendar full of no-shows doesn't mask a truly stale relationship.
- `DailyBriefingCoordinator.lastMeetingCheckTime` is now UserDefaults-persisted (first-launch seed = 24h back) so meetings that ended while SAM was closed still get surfaced. Surfaced events are marked `.pending`; multiple pending reviews roll up into a **single** consolidated "Meetings awaiting your review" outcome (sentinel key `sam.pendingMeetingReviews`) that updates in place and auto-completes when the queue drains.
- `PostMeetingCaptureView` gained an **OccurrenceDecision** (happened / rescheduled / cancelled / didNotHappen) as the first question. Non-"happened" choices short-circuit the capture flow — evidence gets the status, sheet closes, no note created. Primary button label changes to match ("Save" / "Mark rescheduled" / "Mark cancelled" / "Mark no-show"). Supports a queue-walk mode with a "N remaining" badge.

### Block 5 — App Lock Hardening
- `AppLockService` now installs screen-lock observers in `configureOnLaunch()`: `com.apple.screenIsLocked` (distributed), `com.apple.screensaver.didstart` (distributed), `NSWorkspace.willSleepNotification`. Any of these triggers `lock()` if not already locked, closing auxiliary windows, dismissing sheets, and installing the key-event monitor.
- On lock, `applyWindowSharingRestriction()` sets `NSWindow.sharingType = .none` on every app window — legacy `CGWindowList`-based recorders capture black instead of content. Restored to `.readOnly` on successful auth.
- `LockGuardModifier` rewritten: the old `.ultraThinMaterial` blur was visually indistinct, so it's now a **glass-block wall** — a 96pt grid of independently-materialized `.regularMaterial` tiles with 2pt "grout" seams, SAM-logo palette (iceBlue `rgb(.88,.94,1)` / skyBlue `rgb(.62,.78,.96)`), deterministic per-tile pseudo-random tints, and gradient stroke borders (white → black) that read as glass edges. Because each tile samples its own patch of the content behind it, text crossing a seam refracts differently in each tile — unreadable but alive, like looking at SAM through a glass-block shower wall. Center card: app icon + "SAM is Locked" + "Click to unlock" on a `.thinMaterial` rounded card.
- `PrivacyCurtainCoordinator` (briefly prototyped as a `.screenSaver`-level NSPanel curtain) was removed after testing — it added a second mechanism for no incremental value; folding the screen-lock observers directly into `AppLockService` covers the gap more simply.

### Schema
- `SAMSchema.models` now includes `SamCommitment.self`. `CommitmentRepository.shared.configure(container:)` is wired up in `SAMApp.task`. No migration required (purely additive — new model + new optional fields on existing models).

---

## Lecture Summary Pipeline + Backfill (April 20, 2026)

**What**: Ported the map-then-synthesize pipeline from `tools/summary-bench` into the main app and added a backfill path for sessions without a cached summary.

**Why**: Training-lecture summaries were chunk-summarizing into one shape (`MeetingSummary`) and then passing merged `reviewNotes` through a second refine call. That pipeline lost the speaker's explicit outline — "Six Pillars," the Road to Emmaus scaffold — because the refine call saw only an abstracted prose blob, not the structure that the extracts had captured. The bench harness replaced it with a five-stage pipeline (extract → deterministic scaffold → reasoner → core → details) plus Swift-side enforcement that keeps the speaker's ordered points visible against LLM paraphrase drift. Median anchor score stabilized at 88% on the Aspects-of-Exhaustion and Military-Transition transcripts.

### Pipeline Port (`SAM/Services/LectureSummaryPipeline.swift`)
- New actor `LectureSummaryPipeline` replacing `refineLectureSummary()` for `.trainingLecture` recordings.
- Stages:
  1. **Chunk** — 2,800-char ceiling keeps each extract prompt well under the 4,096-token budget.
  2. **Extract** — per-chunk `@Generable` DTO capturing thesis, entities, structure markers, anecdotes, data points, claims, questions, citations. Overflow recovery recursively halves chunks up to depth 3.
  3. **Deterministic scaffold** — Swift-side aggregation: recurring entities (2+ chunks), primary anecdote, ordered theses, repeated-thesis-stem detection, outline-cue sentences scanned from the raw chunks.
  4. **Reasoner pass** — LLM sees the scaffold + outline cues and emits `narrativeFrame`, `centralThesis`, `orderedPoints`, `primaryIllustration`.
  5. **Ordered-point enforcement** — For each outline cue, if its distinctive stems are absent from the reasoner's orderedPoints, append the cue phrase so synthesis has an anchor. Frame-stem detection excludes subject-name stems (e.g. "jesu" across every point in a Jesus-themed sermon) from the coverage check so a speaker's outline still drives augmentation.
  6. **Core synthesis (LLM)** — title, opening, reviewNotes grounded in scaffold + extracts. HARD LIMIT on reviewNotes (<1200 chars) to keep the prompt for pass 6 bounded.
  7. **Details synthesis (LLM)** — topics, learningObjectives, keyPoints, openQuestions. Surfaces a KEY CLAIMS section so named assertions (e.g. "Transamerica pays 125%") anchor keyPoints. Entity variant resolution prefers the clean alphabetic form ("Aegon" over "A-Gon").
  8. **Post-synthesis keyPoint enforcement** — same frame-stem-aware coverage check, appends any ordered point missing from keyPoints + reviewNotes.
- Integrated at the top of `MeetingSummaryService.summarize()`: training-lecture recordings run through the new pipeline; failures fall through to the legacy path so the user still gets a summary.

### Backfill (`TranscriptionSessionCoordinator.regenerateMissingSummaries()`)
- Fetches every `TranscriptSession` where `meetingSummaryJSON` is nil or empty and segments exist, then runs them sequentially through `generateMeetingSummary(for:)` at `.utility` priority.
- Progress surfaced via `backfillProgress: (done: Int, total: Int)?`.
- UI: **Settings → Prompt Lab → Transcript Maintenance → Regenerate missing summaries** (new section with a single "Run now" button and a progress line). Because the backfill routes through the normal generate path, training-lecture sessions automatically pick up the new pipeline without a dedicated migration.

### Result
`.trainingLecture` sessions now produce outputs that reliably name the speaker's organizing frame, preserve numeric data points (distances, percentages, dates) verbatim, and cover every explicit outline point. Existing sessions that never finished summarizing can be backfilled from Settings.

---

## Swift 6 Concurrency + iOS 26 API Cleanup (April 18, 2026)

**What**: Swept both SAM and SAMField to zero build warnings under Swift 6 strict concurrency and the iOS 26 SDK. Also addressed a runtime priority-inversion warning in `ContactsService`.

**Why**: The project has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which implicitly isolates every declaration to `@MainActor` unless marked `nonisolated`. This caused a backlog of isolation warnings — most flagged as "this is an error in the Swift 6 language mode" — that would block the eventual move to Swift 6 mode. SAMField additionally had deprecated MapKit/CLGeocoder and AVAudioSession symbols.

### Swift 6 Isolation Fixes
- Marked DTOs, value types, and their inits `nonisolated` where they cross actor boundaries: `DiarizationVoiceSegment`, `DiarizationResultDTO`, `MeetingSummary` + static `empty` + custom `init(from:)`, `RecordingContext` and its computed properties (`displayName`, `systemIcon`, etc.), `FeedbackResponse`, `LLMCandidateScore`, `AudioPreprocessingService.preprocess(...)`, `WhisperTranscriptionEngine.defaultModelID`.
- `SpeakerEmbeddingProvider` protocol requirements marked `nonisolated`; `SpeakerEmbeddingService.provider` / `init` / `embeddingDimension` made `nonisolated`; `MFCCSpeakerEmbeddingProvider.init` marked `nonisolated`.
- Moved file-scope `private let logger` into the owning types across services (AppLockService, FieldContactLookupService, etc.) to satisfy strict-concurrency file-level global rules.
- `[weak self]` added to nested `Task { }` closures in AudioStreamingService, MeetingCaptureCoordinator, PendingUploadService, VoiceRecordingService, AudioReceivingService; extracted non-`Sendable` `Notification.userInfo` values before capture in `MeetingCaptureCoordinator.handleAudioInterruption`.
- Replaced `DispatchQueue.main.asyncAfter` with `Task.sleep` in `CopyButton`.
- `StageCache.enabled` converted from plain static var to `Mutex<Bool>`-backed accessor (avoids `nonisolated(unsafe)` per CLAUDE.md).

### iOS 26 Deprecations (SAMField)
- `CLGeocoder` → `MKReverseGeocodingRequest` / `MKGeocodingRequest` in `LocationService` and `ManualTripEntryView`.
- `MKPlacemark` initializers → `MKMapItem(location:address:)`; `CLPlacemark.formatted()` → `MKMapItem.address?.fullAddress`.
- `AVAudioSession.CategoryOptions.allowBluetooth` → `.allowBluetoothHFP` (MeetingRecordingService, VoiceRecordingService).
- `EKAuthorizationStatus.authorized` comparisons simplified to `.fullAccess` only (FieldCalendarService).

### ContactsService Priority-Inversion Fix
Pinned the `ContactsService` actor to a `DispatchSerialQueue` at `.userInitiated` QoS via a custom `unownedExecutor`, so mixed-priority callers don't trigger inversion when a background-QoS task is already holding the actor during a synchronous CN read.

**Residual Hang-Risk warnings at `store.unifiedContacts(...)` and `store.unifiedMeContactWithKeys(...)` are accepted**. The inversions the OS reports happen inside Apple's `contactsd` XPC response path (Background-QoS internal thread on the daemon side) and cannot be suppressed per-line. macOS priority inheritance typically resolves the wait within milliseconds. Documented in `context.md` §7 "Accepted Hang Risk Warnings" so a future audit knows these are intentional.

### Result
Both SAM and SAMField targets now build clean (zero warnings, zero errors) under the current Swift 5 language mode with strict-concurrency diagnostics enabled. The fixes should translate directly to Swift 6 mode when the project migrates.

---

## SAMField: Recording Sync Handshake Fixes + Polish Pipeline Guards (April 17, 2026)

**What**: Fixed three compounding bugs that caused pending recordings to get stuck permanently in the upload queue ("Mac is processing" with no resolution), and added guards in the Stage 5 polish pipeline to skip polish on silence/noise recordings and cap any polish operation at 30 seconds.

**Why**: Sarah had 3 recordings stuck in the sync queue that she could not clear without deleting them. Root cause analysis found the handshake had three independent failure modes that could each independently orphan a session. The polish fix was discovered while debugging: a 5.5-second silence recording spent 60 seconds in Stage 5 before failing with "Exceeded model context window" — caused by Whisper hallucinating text on silence which was then sent to FoundationModels.

### Sync Handshake Fixes

**Bug 1 — `awaitingAck` records never retried** (`PendingUploadService.swift`)

Records stuck in `.awaitingAck` or `.uploading` at app launch (from crashes, force-quits, or connection loss during a previous session) were invisible to `attemptNextUpload`, which only queried `.pending` and `.failed`. Added `resetOrphanedInProgressRecords()` called from `configure()` that resets any orphaned in-progress records to `.pending` on startup.

**Bug 2 — Ack silently dropped when iPhone disconnects during reprocess** (`AudioReceivingService.swift`)

`sendSessionProcessed()` returned silently when `activeConnection` was nil. For a 60-second reprocess, the phone's connection frequently drops before the Mac finishes. Fixed by queuing pending acks in `pendingAcks: [PendingAck]` and draining them in the `.ready` state handler when the iPhone reconnects (same pattern as the existing `pendingSummary` flush). The ack now survives connection drops across the reprocess window.

**Bug 3 — Late acks discarded (timing gap between uploadStart and continuation setup)** (`PendingUploadService.swift`)

`handleSessionProcessedAck()` did nothing when `ackContinuation` was nil. An ack that arrives in the window between the phone sending `uploadStart` and setting up the `withCheckedContinuation` (after `uploadEnd`) was silently lost. Fixed by adding a SwiftData fallback path: if no continuation is active, the ack is applied directly to the `PendingUpload` record, deleting the file and record on success or marking `.failed` on failure.

**Bonus — Processed session ledger prevents re-processing** (`AudioReceivingService.swift`)

Added `processedSessionIDs: Set<String>` backed by UserDefaults (max 500 entries, evicts oldest). When the Mac receives `uploadStart` for a session already in the ledger, it sends an immediate `sessionProcessed` ack and ignores all subsequent chunks and `uploadEnd` for that session — no reprocessing, no duplicate `TranscriptSession`. This makes re-uploads (which happen after the phone resets an orphaned record) nearly instantaneous.

**Auto-chain** (`PendingUploadService.swift`)

After each upload completes (success or failure), `attemptNextUpload(isRecording: false)` is called automatically. Previously the queue only advanced on tab appearance or Mac reconnect; now it drains in sequence without user interaction.

**Pending uploads management UI** (`PendingUploadsManagementView.swift`, `MeetingCaptureView.swift`)

The "N recordings waiting to sync" banner is now tappable and opens a sheet listing each pending recording with status (Waiting/Uploading/Processing/Failed), duration, size, attempt count, and error message. Swipe-left deletes the WAV file and SwiftData record.

### Stage 5 Polish Pipeline Guards

**Guard 1 — Skip polish when diarization finds 0 voice segments** (`PendingReprocessService.polishSession`)

If SpeakerKit/MFCC diarization returns 0 voice segments, polish is skipped entirely before any model call. Zero voice segments means the recording is silence or noise; Whisper's output is almost certainly a hallucination and not worth polishing. Saves the entire Stage 5 cost (~60s) for silence recordings.

**Guard 2 — 30-second hard timeout on FoundationModels calls** (`AIService.generateWithFoundationModels`)

`withThrowingTaskGroup` races the `session.respond(to:)` call against a 30-second sleep. If the model doesn't respond in time, `AIError.timeout` is thrown and polish fails gracefully. Previously a hanging model call could block the pipeline for 60+ seconds before returning an error. The pipeline continues to Stage 6 regardless.

### Architecture Notes

- No schema version bump — all changes are in-memory or UserDefaults
- `processedSessionIDs` UserDefaults key: `sam.processedUploadSessions` (max 500 UUIDs as string array)
- The pending ack queue is in-memory only; Mac app restarts clear it. For acks lost across restarts, the phone's startup reset + re-upload + immediate ledger ack path covers recovery.

---

## SAMField: IRS Mileage Tracking — Full Feature Set (April 17, 2026)

**What**: Completed the SAMField mileage tracking feature with IRS-compliant export (CSV + PDF), manual trip entry, vehicle management, trip confirmation flow, commuting exclusion, Mac-side trips view, and related settings.

**Why**: Sarah needed a way to export her business driving records for tax purposes. The feature already captured GPS-tracked trips; this work added all the structure and export capability the IRS requires for mileage deductions plus UI to manage and review trips from both phone and Mac.

### Key Design Decisions

- **IRS rate stored per-device via `@AppStorage`**, not per-trip — the rate changes annually and is only needed at filing time, not per-trip. Sarah updates it once in Settings when the IRS publishes the new rate.
- **Commuting exclusion as a manual toggle** (`isCommuting: Bool` on `SamTrip`) rather than auto-detection from office address — reduces false positives, keeps user in control of what's deductible.
- **Manual trip entry uses Expensify-style route computation** — forward-geocodes addresses via `CLGeocoder`, computes driving distances via `MKDirections` per segment, shows a live map with route polylines. Produces IRS-defensible derived miles without requiring odometer readings.
- **PDF export via `WKWebView.pdf()`** — cross-platform (iOS + macOS); HTML rendered with 800ms sleep for load completion. Landscape US Letter (792×612).

### New Files (8)

- `SAMField/Services/VehicleStore.swift` — UserDefaults-backed vehicle picklist ("Personal Vehicle", "Rental" as protected defaults; user-addable)
- `SAMField/Services/MileageExportService.swift` — CSV (UTF-8 BOM for Excel) + PDF (WKWebView HTML) generation with commuting exclusion, confirmed column, IRS rate
- `SAMField/Views/Trips/MileageExportView.swift` — Export sheet: year/custom range picker, IRS rate field, format toggle (CSV/PDF), progress indicator for PDF
- `SAMField/Views/Trips/ManualTripEntryView.swift` — Form-based manual entry with geocoding, MKDirections routing, live map, vehicle picker
- `SAM/Services/MacMileageExportService.swift` — Mac-side mirror of MileageExportService (SAMField target not available to Mac)
- `SAM/Views/Business/MacTripsView.swift` — Mac trips view with year filter, stats header, trip table, NSSavePanel export, MacTripDetailView sheet
- `SAM/Views/Settings/TripsAndMileageSettingsPane.swift` — Mac settings: IRS rate, regular office address, vehicle list management
- `SAMField/Views/Capture/PendingUploadsManagementView.swift` — Pending upload management (see sync fixes above)

### Modified Models

- `SAMModels-Trip.swift` — Added: `startAddress: String?`, `vehicle: String`, `tripPurposeRawValue: String?` + `@Transient tripPurpose`, `confirmedAt: Date?`, `isCommuting: Bool`. Removed: `irsRatePerMile` (was per-trip; now applied at export time only). All new properties have safe defaults for backward compatibility.

### Architecture Notes

- No schema version bump — new `SamTrip` properties have defaults; existing records load cleanly
- `VehicleStore` is in SAMField target; Mac reimplements inline using `UserDefaults.standard.stringArray(forKey: "sam.vehicles")`
- `TripCoordinator.unconfirmedCount` drives the Trips tab badge and a TodayView banner prompting review
- The IRS "contemporaneous record" requirement is satisfied by `confirmedAt: Date?` — the timestamp records when the user verified the trip log

---

## Streaming Stability + Speaker Turn Chunking (April 15, 2026)

### Overview
Fixed long recording failures (40+ min), context window overflow on summary/polish, and refactored the transcript pipeline to use speaker turns as natural chunk boundaries for AI processing.

### Streaming Stability
- `TranscriptionSessionCoordinator.swift` — Auto-finalize session when phone disconnects mid-recording. Connection watch task detects drop within 500ms and calls `handleSessionEnd()`. Previously the Mac stayed stuck on "Recording" forever.
- `CommunicationsImportCoordinator.swift`, `MailImportCoordinator.swift`, `PostImportOrchestrator.swift` — Defer background imports (comms, mail, role deduction, insight generation) while `isSessionActive`. These were competing with the streaming pipeline and likely causing connection drops on long recordings. Confirmed: 40-minute podcast recorded successfully after this fix.

### Speaker Turn Architecture
- `TranscriptionSessionCoordinator.buildSpeakerTurns()` — New static method builds transcript as speaker turns (one turn = consecutive same-speaker segments, max ~2000 chars with sentence-boundary safety). Replaces the old `buildSummaryInput()` that joined all segments into giant paragraphs.
- Each speaker turn is a natural chunk boundary (~200-2000 chars) that fits well within the 4096-token AI context window.
- `TranscriptPolishService.maxChunkChars` lowered from 10,000 to 6,000 to account for Apple Intelligence tokenizing at ~3 chars/token.
- `chunkTranscript()` — Added sentence-boundary fallback for oversized paragraphs.

### Live Path Improvements
- `TranscriptionPipelineService.swift` — Live streaming now uses SpeakerKit (neural, 16kHz resampled) for diarization instead of MFCC-only. Falls back to MFCC if SpeakerKit fails. Gives live recordings the same speaker separation quality as batch reprocessing.

### UI
- `TranscriptionReviewView.swift` — Added "Generate Summary" button for sessions with transcript but no summary (e.g., after context window failure). Always uses raw segments with turn formatting for reliable chunking.

### Confirmed Results
- 40-minute podcast: connection survived full duration (previously failed at ~30 min)
- 46,848 chars split into 10 chunks, all summarized successfully
- Summary correctly captured podcast's thematic arc across chunks

---

## Diarization Fix: 16kHz Resampling + SpeakerKit Tuning (April 15, 2026)

### Overview
Fixed a critical sample rate mismatch that caused SpeakerKit (Pyannote) to see garbled audio, collapsing all speakers into one cluster. SpeakerKit expects 16kHz input but SAM was passing 48kHz samples without resampling. Added tunable parameters for speaker count and clustering threshold.

### Root Cause
SpeakerKit uses `WhisperKit.sampleRate = 16000` internally for all frame-to-timestamp conversions. Passing 48kHz samples caused: (1) every 3rd sample treated as consecutive, producing garbled audio that couldn't distinguish speakers; (2) all timestamps inflated by 3x (120s clip produced 360s timestamps); (3) speaker embeddings computed from wrong-rate audio.

### Changes
- `DiarizationService.swift` — Added 16kHz linear interpolation resampling before calling `kit.diarize()`. Added `expectedSpeakerCount` and `neuralClusterDistanceThreshold` (0.50, down from SpeakerKit default 0.60) as tunables. Now passes `PyannoteDiarizationOptions` with `numberOfSpeakers`, `clusterDistanceThreshold`, and `useExclusiveReconciliation: false` (allows overlap detection).
- `PendingReprocessService.swift` — Added neural diarization parameters (`neuralThresh`, `speakers`, `neural`) to stage cache key so threshold changes invalidate cached results.
- `StageCache.swift` — Bumped diarization version to "2".

### Results (2-minute 3-speaker phone call test clip)
- **Before fix**: 1 speaker, 52 segments, max timestamp 359s, 65s voiced
- **After fix (auto-detect)**: 2 speakers (male vs female separated), 33 segments, max 120s, 110s voiced
- **After fix (numberOfSpeakers: 3)**: 4 speakers (3 real + 1 fragment), correct turn transitions

### Architecture Notes
- `expectedSpeakerCount` defaults to nil (auto-detect). Should be set per-session from calendar event attendee count or user input for best results — Grok's recommendation confirmed.
- The resampling uses linear interpolation which is adequate for speech. A polyphase filter would be higher quality but the improvement is marginal for diarization embeddings.
- Overlap detection (`useExclusiveReconciliation: false`) captures backchannel responses ("yeah, yeah") as separate speaker segments.

---

## Phone Done + Delete for Recordings (April 14, 2026)

### Overview
Added two new iPhone→Mac protocol messages so Sarah can mark a recording as "Done" or delete it directly from the phone without returning to the Mac. "Done" ensures the note is saved and analysis runs but does NOT sign off — the session stays available for review/editing on Mac. "Delete" permanently removes the recording, transcript, note, and evidence.

### Changes
- `SAMModels-AudioStreaming.swift` — Added `sessionDone` (0x0A) and `sessionDeleted` (0x0B) message types to the TCP protocol.
- `AudioReceivingService.swift` — Added `onSessionDone` and `onSessionDeleted` callbacks, dispatch in `handleMessage()`.
- `TranscriptionSessionCoordinator.swift` — Added `handleSessionDone(sessionID:)` (idempotent ensure-saved) and `handleSessionDeleted(sessionID:)` (full delete path mirroring TranscriptionReviewView.performDelete). Wired callbacks in `startListening()`.
- `AudioStreamingService.swift` (SAMField) — Added `sendSessionDone(sessionID:)` and `sendSessionDeleted(sessionID:)` methods.
- `MeetingCaptureCoordinator.swift` (SAMField) — Added `markSessionDone()` with double-send prevention and checkmark confirmation, `deleteSession()` with local state cleanup.
- `MeetingCaptureView.swift` (SAMField) — Added "Done" button (green, sends sessionDone) and "Delete" button (destructive, with confirmation dialog) to the completed session view. Done shows a brief checkmark animation.

### Architecture Notes
- Both messages are fire-and-forget (no Mac→iPhone ack). If the connection drops mid-message, the session still exists on Mac for manual action. The `send*` methods return `Bool` so future UI can detect "not connected" if needed.
- "Done" is intentionally lighter than "Looks Good" on Mac — it does not start the retention timer or sign off. Sarah can still review and edit on Mac before final approval.
- Delete handler is idempotent: if the session was already deleted, it logs a warning and returns.

---

## Transcript Editing Overhaul + Post-Edit Re-Analysis (April 14, 2026)

### Overview
Replaced the broken NSTextView/NSScrollView-based transcript editor with a single native SwiftUI `TextEditor` backed by `AttributedString` (macOS 26). Diff highlights (blue for AI-changed words, green for insertions) are now rendered as `backgroundColor` attributes inline in the editable text. Added automatic re-generation of meeting summary and note analysis after user edits.

### Changes
- `TranscriptionReviewView.swift` — Removed the per-paragraph editing system (pencil icon, mode switching, DiffHighlightEditor NSViewRepresentable, AutoSizingScrollView, WrappingHFlow layout). Replaced with a single `TextEditor(text: $polishedAttrText)` using `AttributedString`. Speaker labels are inline bold colored text. Save button appears only when text differs from original. On save, polished text is committed, diff highlights regenerate, and summary + note analysis re-run in the background.
- `TranscriptionReviewView.swift` — Added `commitPolishedAttributedEdit()` which triggers `MeetingSummaryService.summarize()` and `NoteAnalysisCoordinator.analyzeNote()` against the edited polished text (not raw segments). Shows "Updating summary…" spinner during regeneration.
- `MeetingSummaryService.swift` — Improved JSON decode fallback. When full `MeetingSummary` decode fails, now uses `JSONSerialization` to salvage individual fields (tldr, topics, decisions, etc.) before falling back to plain text. Strips markdown fences and JSON artifacts so users never see raw JSON in the summary display.
- `TestInboxWatcher.swift` — Removed auto-run of RSVP test harness on every launch (11 AI inference calls competing with foreground UI). Available manually via `RSVPTestHarness.runAll()`.

### Architecture Notes
- The macOS 26 `TextEditor` with `AttributedString` eliminates all NSViewRepresentable complexity — no height calculation, no nested scroll views, no focus management. Speaker labels are part of the attributed string rather than separate SwiftUI views.
- Post-edit re-analysis uses the polished text (what the user sees and edited) rather than raw Whisper segments, so the summary reflects the user's corrections.
- Summary regeneration runs at `.utility` priority on a background `ModelContext` to avoid blocking the UI.

---

## Post-Event Evaluation (April 7, 2026)

### Overview
Automated post-workshop analysis pipeline. After a workshop completes, Sarah can import the Zoom chat transcript and Google Forms feedback CSV. SAM parses participants, matches them to contacts, runs AI engagement analysis, identifies content gaps, and auto-generates follow-up outcomes for warm leads.

### New Models
- **EventEvaluation** (@Model) — linked 1:1 to SamEvent via cascade relationship. Stores chat analysis, feedback data, AI summaries, and aggregate metrics (attendance, average rating, conversion rate). No schema version bump required (additive change).
- **ChatParticipantAnalysis** (Codable struct) — per-participant engagement data stored as JSON array on EventEvaluation: display name, matched person ID, message/reaction counts, engagement level, questions asked, topic interests, sentiment, conversion signals, inferred role (host/cohost/attendee).
- **FeedbackResponse** (Codable struct) — per-respondent feedback stored as JSON array: name, email, areas to strengthen, overall rating, follow-up interest, current situation.
- **FeedbackColumnMapping** (Codable struct) — maps CSV column headers to known fields. Auto-detected from header text, saved per-presentation for reuse.
- New enums: `EvaluationStatus`, `EngagementLevel`, `InferredEventRole`, `FeedbackRating`, `FollowUpInterest`.
- New `EvidenceSource.zoomChat` case with all exhaustive switches updated.

### New Services (actors)
- **ZoomChatParserService** — parses Zoom chat .txt export format (`HH:MM:SS From Name : message`). Cleans host markers (`!`), strips trailing URLs from display names, handles multi-line messages, detects reactions vs replies, aggregates per-participant stats (message count, reaction count, question detection).
- **FeedbackFormParserService** — parses Google Forms CSV exports with proper quote/comma handling. Fuzzy-matches free-text ratings and follow-up interest to enums. Supports semicolon-separated multi-select fields.
- **EventEvaluationAnalysisService** — LLM analysis via AIService: deterministic engagement scoring (heuristic thresholds), LLM enrichment for active participants (topic interests, sentiment, conversion signals, role inference), cross-reference analysis (chat questions vs presentation content → content gaps + effective sections), overall event summary generation.

### New Coordinator
- **PostEventEvaluationCoordinator** (@MainActor @Observable) — orchestrates the full pipeline: chat import with name matching (event participants first, then all contacts, fuzzy first+last name matching), feedback CSV import with column mapping UI, participant review workflow for unmatched names, cross-reference analysis, overall summary, and outcome generation. Outcomes created: warm leads (explicit follow-up requests), thank-yous (high-engagement attendees), info sends (maybe responses), content improvements.

### New Views
- **EventEvaluationImportSheet** — file import UI with pickers for chat .txt, feedback .csv, transcript .vtt. Shows import progress and status.
- **FeedbackColumnMappingSheet** — maps CSV columns to feedback fields with auto-detection from header text. Saved per-presentation.
- **ParticipantMatchReviewSheet** — review unmatched chat participants: match to existing contact, create new, or skip.
- **PostEventEvaluationView** — analytics dashboard: summary cards (participants, rating, conversion, response rate), engagement bar chart, content gap/effectiveness analysis, feedback area aggregation, follow-up interest breakdown, top questions list, per-participant cards with topic tags and conversion signals. Shown in EventDetailView right pane when event is completed and no participant is selected.

### Modified Files
- `SAMModels-Event.swift`: added `evaluation: EventEvaluation?` relationship on SamEvent
- `SAMModelContainer.swift`: registered EventEvaluation.self
- `EventDetailView.swift`: "Evaluate" button in action bar for completed events, PostEventEvaluationView in right pane, import sheet
- `SAMModels-Supporting.swift`, `MeetingPrepSection.swift`, `MeetingPrepCoordinator.swift`, `PersonDetailView.swift`, `SearchResultRow.swift`, `InboxDetailView.swift`, `InboxListView.swift`: added `zoomChat` to exhaustive EvidenceSource switches

### Tests
- 28 tests across 5 suites: ZoomChatParserTests (8), FeedbackFormParserTests (6), EventEvaluationModelTests (5), EvaluationEnumTests (6), EventEvaluationAnalysisTests (4). All pass.

---

## Crash Recovery: Safe Mode, Auto-Detection & OutcomeEngine Fix (March 31, 2026)

### SwiftData Crash Fix
- **Root cause**: `OutcomeEngine.reprioritize()` crashed (SIGTRAP) when setting `outcome.priorityScore` on models with stale `linkedPerson` relationship references. During `enrichWithAI()` (~15s of AI inference), contacts import could delete/modify people in a separate `ModelContext`. SwiftData asserted when validating the outcome object during property mutation.
- **Fix**: `reprioritize()` now flushes the context before re-fetching and re-fetches each outcome individually by ID before mutation (matching the defensive pattern in `enrichWithAI()`). Added `OutcomeRepository.save()` method. Added `isDeleted` guards on all `linkedPeople` accesses in scanner functions.
- **Also hardened**: `enrichWithAI()` and `generateDraftMessage()` now accept outcome IDs instead of model references, with re-fetch-after-await guards at every suspension point.

### Safe Mode (Option Key at Launch)
- **Activation**: Hold Option key during app launch. Skips all normal startup — no SwiftData container, no coordinators, no imports, no AI.
- **SafeModeService**: Runs 7 categories of deep SQLite integrity checks directly on the store file: WAL checkpoint, `PRAGMA integrity_check`, table row counts, full FK repair (12 known mappings + heuristic auto-detection), many-to-many join table cleanup, duplicate UUID scan, schema metadata.
- **SafeModeView**: Full-window UI with streaming monospaced log, color-coded severity icons (green/yellow/orange/red), and summary bar.
- **Email Report**: Composes email to `sam@stillwaiting.org` with `[DATABASE REBUILD] <datetime>` subject containing the full plain-text report (version, schema, hardware, all check results).
- **Restart**: Relaunches SAM in normal mode via `NSWorkspace.openApplication`. Uses `sam.safeMode.justCompleted` UserDefaults flag to prevent re-entry if Option is still held.
- **AppDelegate guards**: `applicationDidFinishLaunching` and `applicationShouldTerminate` skip data layer access when in safe mode.

### Automatic Crash Report Detection
- **Mechanism**: `CrashReportService` sets `sam.cleanShutdown = false` at launch and `true` in `applicationShouldTerminate`. On next launch, if the flag is `false`, the previous session crashed.
- **Report discovery**: Scans `~/Library/Logs/DiagnosticReports/` (and `Retired/` subfolder) for `SAM_*.ips` or `sam.SAM*.ips` files created after the previous session's launch timestamp. Wraps the Apple crash report with SAM context headers (version, schema, hardware). Falls back to a minimal report with manual attachment instructions if `.ips` not yet written.
- **UX**: Red `CrashReportBanner` at the top of the Today view. "Send Report" composes email to `sam@stillwaiting.org` with `[CRASH REPORT] <datetime>` subject. Dismiss button records the crash timestamp to prevent re-showing.
- **First-launch safe**: `sam.lastLaunchTimestamp` defaults to 0, so crash detection is skipped on first ever launch.

### Files
- **New**: `SafeModeService.swift`, `SafeModeView.swift`, `CrashReportService.swift`
- **Modified**: `SAMApp.swift` (Option key detection, safe mode guards, crash detection hooks), `OutcomeEngine.swift` (reprioritize + enrichWithAI hardening), `OutcomeRepository.swift` (save method), `AwarenessView.swift` (crash report banner)

---

## Sent Recipient Discovery (March 24, 2026)

- **Feature**: When SAM imports sent emails, unknown recipients are collected as triage candidates. They appear at the top of the Unknown Senders triage list so the user can quickly add them as contacts.
- **Two-tier display**: Recipients with display names or emailed 2+ times default to "Add" (Recommended). Single-send bare addresses default to "Later" (Review).
- **Watermark reset on approval**: When a sent recipient is approved, SAM rewinds the inbox watermark to 1 day before the earliest sent email to that address. This ensures any replies that arrived before the contact was added get picked up on the next import.
- **Noise filtering**: Skips noreply/marketing addresses, mailing list infrastructure domains, and role addresses (admin@, billing@, etc.) using shared `MailService.marketingLocalParts` and `marketingDomains`.
- **Model changes**: Added `EvidenceSource.sentMail` enum case. Added `sentEmailCount` and `earliestSentDate` fields to `UnknownSender`.
- **Repository**: `UnknownSenderRepository.bulkRecordSentRecipients()` handles upsert, dedup, and source upgrade (inbound `.mail` → `.sentMail` when user also sends to that address).
- **Settings**: Toggle in Settings → Mail: "Suggest adding unknown sent recipients" (default on).
- **Collection hook**: Runs in `MailImportCoordinator` after sent mail upsert, filtering against known contacts, neverInclude list, user's own addresses, and noise addresses.

---

## Dead code cleanup — Settings sidebar refactor remnants (March 24, 2026)

- **Removed ~750 lines** of dead code left over from the Settings sidebar navigation refactor.
- **SettingsView.swift**: Removed `ImportStatusDashboard`, `DataSourcesSettingsView`, `AISettingsView`, `BusinessSettingsView`, `_RemovedPermissionsView`, `ContactsSettingsView`, `CalendarSettingsView`, `IntelligenceSettingsView` — all replaced by private pane structs in the sidebar layout.
- **7 settings files**: Removed unused standalone `*SettingsView` wrapper structs from `CommunicationsSettingsView.swift`, `MailSettingsView.swift`, `CoachingSettingsView.swift`, `BriefingSettingsView.swift`, `LinkedInImportSettingsView.swift`, `FacebookImportSettingsView.swift`, `EvernoteImportSettingsView.swift`. The `*Content` views they contained remain in use.
- Removed orphaned `#Preview` blocks that referenced deleted wrappers.

---

## Import troubleshooting, clickable people, About build date, and email fixes (March 24, 2026)

### Watermark Reset & Re-scan
- **Problem**: When SAM ran with test data, import watermarks advanced past real emails, causing them to be permanently skipped.
- **Debug menu**: Added "Re-scan Mail" and "Re-scan iMessage & Calls" to the Debug menu (resets watermarks + triggers import).
- **Settings UI**: Added Troubleshooting sections to Settings → Mail and Settings → Communications with Re-scan buttons for normal (non-debug) builds. Each button shows the exact lookback start date (e.g., "Re-imports mail starting from Jan 23, 2026").
- **MailImportCoordinator**: Added `resetWatermark()` method that clears `lastMailWatermark` and `lastSentMailWatermark`.

### Clickable Person Names on Outcome Cards
- **Feature**: Every outcome card that references a specific person now shows a clickable person name link (person.circle icon + name in blue). Clicking navigates to that contact in the People view via `samNavigateToPerson` notification.
- **Motivation**: Outcomes like "Consider archiving…" previously had no quick way to navigate to the contact.

### About SAM Build Date
- **Feature**: Custom About panel shows build timestamp derived from the executable's modification date (e.g., "Built: Mar 24, 2026, 3:47 PM"). Updates with every build, giving users a reliable way to identify exactly which build they're running.

### Email Body Truncation
- **Problem**: Long emails caused `exceededContextWindowSize` errors (4819 tokens vs 4096 limit) during on-device LLM analysis.
- **Fix**: Email bodies truncated to ~2500 characters before LLM analysis. System instruction + subject/from use ~800–1000 tokens; body gets the rest.

### LinkedIn Notification Guidance
- **Clarified**: Updated the "Set up LinkedIn email notifications" outcome to make clear this is a linkedin.com setting, not a SAM setting. Added instruction to ensure LinkedIn sends to the SAM-monitored email account.

### Build & Distribution
- **DMG installer script**: `scripts/build-dmg.sh` archives SAM, opens Organizer for signing/notarization, then packages the exported .app into a drag-to-Applications DMG via `create-dmg`.
- **`.gitignore`**: Added `build/`, `DerivedData/`, `*.xcuserstate`, `xcuserdata/`, `*.dmg`.

---

## Outcome Snooze & Outgoing Event Matcher (March 23, 2026)

### Outcome Snooze
- **Feature**: Users can defer coaching outcomes to a future date ("I'll handle this, but not yet"). Snooze button between Done and Skip with quick-pick popover (Tomorrow, 3 Days, Monday, 1 Week, or custom date).
- **Model changes**: Added `snoozedAt`, `snoozeUntil`, `snoozeCount` to `SamOutcome`; added `case snoozed` to `OutcomeStatus`; extended `OutcomeSnapshot` with snooze fields for undo support.
- **Auto-resolve**: When a snoozed outcome wakes (reaches its `snoozeUntil` date), `OutcomeEngine.shouldAutoResolve()` checks for outbound evidence to the linked person since the snooze date. If found, the outcome is auto-completed — the user already took action.
- **Repository**: `OutcomeRepository.markSnoozed(id:until:)` sets status + captures undo snapshot with toast. `wakeExpiredSnoozes()` returns outcomes past their wake date and resets them to pending. `hasSimilarOutcome` dedup includes `.snoozed` status.
- **Calibration**: `CalibrationService.recordSnooze()` tracks snooze as a soft signal (counted as partial dismissal in the calibration ledger).
- **UI**: New `SnoozePickerView` popover. `OutcomeCardView` wired with `onSnooze` callback. `OutcomeQueueView` calls repository + calibration on snooze.

### Outgoing Event Matcher
- **Feature**: After mail/comms imports, SAM scans recent outgoing messages for references to upcoming events. If a recipient is not yet a participant, SAM generates a coaching outcome suggesting they be added.
- **Matching heuristics**: Event title keywords (2+ significant words), venue name, formatted date (both "March 28" and "3/28" patterns).
- **Dedup**: Checks active outcomes for existing person+event suggestions before creating new ones.
- **Integration**: `OutgoingEventMatcher.shared.scanRecentOutgoing()` called from `PostImportOrchestrator.runPostImportWork()` after role deduction and insight generation.
- **Scan state**: `lastScanDate` persisted in UserDefaults; minimum 30-second debounce between scans.
- **Outcomes**: Generated as `.preparation` kind with `.schedule` action lane, linked to the person, deadline set to event start date.

---

## Rich Email Handoff, Image Resize Slider, Invitation Resend (March 23, 2026)

### Mail.app Rich Email Handoff
- **Problem**: Getting formatted text, links, and inline images from SAM's editor into Mail.app proved surprisingly difficult. Multiple approaches were tried and failed:
  - AppleScript `html content` property silently fails on modern macOS — message body always empty
  - AppleScript with temp file reads (`read POSIX file`, `do shell script "cat"`) — same silent failure
  - Base64 data URI images in AppleScript — string too large for AppleScript runtime
  - `NSAttributedString(data:options:.html)` roundtrip — Apple's HTML parser reorders images to end
  - Clipboard + System Events `keystroke "v"` — requires Accessibility permissions SAM doesn't have
- **Solution**: `NSSharingService(named: .composeEmail)` with a clean `NSAttributedString` built by `ComposeService.buildMailAttributedString()`. Images are re-rendered at the user's chosen display size (baked into PNG pixel data) so Mail shows them crisp at the correct dimensions. NSSharingService places images at the bottom as attachments — they're sharp and the user can drag them inline in Mail if needed.
- **Architecture insight** (via ChatGPT): "Do not treat your NSTextView content format as your email transport format." The editor's internal `NSAttributedString` with `NSTextAttachment` objects is NOT what Mail wants. The transport layer must rebuild a clean attributed string with images at final dimensions.

### Image Resize Slider
- Replaced S/M/L/Full preset buttons with a **logarithmic slider** (5%–100%) in the formatting toolbar
- Log mapping: `0.05 * pow(20, x)` — small sizes get proportionally more slider range, making fine adjustments at small scales easy
- Slider appears when cursor is on an image attachment; percentage label shows current value
- Slider initializes to the selected image's current scale via inverse mapping
- Selection tracking via `textViewDidChangeSelection` delegate → `onSelectionChanged` callback
- **QR codes are now resizable** — removed `min(1.0, ...)` cap that prevented small images from scaling up; resize now uses container-width-relative sizing with aspect ratio preservation

### Invitation Resend
- Added `.handedOff` to the resend-eligible states in `EventDetailView` quick actions
- Previously only `.invited` and `.reminderSent` showed the resend button — `.handedOff` (Mail opened but send not confirmed) was stuck with no action
- Button label: "Reinvite" for `.handedOff`, "Resend Invitation" for `.invited`/`.reminderSent`
- Opens `InvitationDraftSheet` with the single participant, generating a fresh AI draft

### Actor Isolation Fix
- `RichInvitationEditor.Coordinator` marked `@MainActor` to resolve Swift 6 strict concurrency errors when calling `@MainActor`-isolated handle methods (`toggleBold`, `toggleItalic`, `onInsertLink`)

---

## Rich Invitation Editor, Sent Mail Detection, Multi-Recipient Intelligence (March 23, 2026)

### Rich Text Invitation Editor
- **`RichInvitationEditor`** — NSViewRepresentable wrapping NSTextView with Cmd+B (bold), Cmd+I (italic), Cmd+K (insert link) keyboard shortcuts
- **`LinkInsertionPopover`** — Low-friction link insertion with presets: event join URL, user website, custom URL. Optional QR code inline insertion via `QRCodeGenerator`
- **`QRCodeGenerator`** — CIFilter-based QR code generation (NSImage + PNG data) for embedding shareable links
- **`InvitationDraftSheet` rewritten** — Rich text editor for email channel with formatting toolbar (Bold/Italic/Link/QR/Image); plain TextEditor preserved for iMessage. "Send" becomes "Open in Mail" for email channel. NSOpenPanel for inline image insertion

### HTML Email Handoff to Mail.app
- **`AttributedStringToHTML`** — Converts NSAttributedString to HTML with bold, italic, links, and inline images (CID references)
- **`ComposeService.composeHTMLEmail()`** — AppleScript automation using Mail.app's `html content` property for rich email compose windows. Temp files for image attachments
- **`EventCoordinator.sendRichInvitation()`** — Orchestrates the flow: stores message metadata, marks participation as `.handedOff`, converts to HTML, opens Mail.app, registers for sent mail detection

### Sent Mail Detection & Multi-Recipient Intelligence
- **`SentMailDetectionService`** — @MainActor @Observable singleton observing NSWorkspace.didActivateApplicationNotification
- When SAM regains focus after Mail.app, scans Envelope Index for recently sent messages matching pending watch subjects
- Retry pattern: checks at 1s, 3s, 8s, 15s, 30s after focus return; watches expire after 1 hour
- **Role-aware recipient classification**:
  - TO recipients → invitees (auto-mark as invited)
  - BCC recipients → always informational
  - CC with Agent/Vendor/Referral Partner/Strategic Alliance roles → informational
  - CC with Client/Lead/Applicant roles → ambiguous (prompts user)
  - Unknown email addresses → new contact (prompts user)
- **`InvitationRecipientReviewSheet`** — Review UI for ambiguous/new recipients with Add as Invitee / Informational / Ignore decisions
- Auto-updates matched participations from `.handedOff` → `.invited` when sent mail confirmed

### Supporting Changes
- **`InviteStatus.handedOff`** — New lifecycle state between draftReady and invited, representing "Mail.app opened but not yet confirmed sent"
- **`BusinessProfileDTO.website`** — User website field for link presets (backwards-compatible decoder)
- **`EmailDTO.bccEmails`** — BCC recipient support throughout mail pipeline
- **`MailDatabaseService.queryRecipients`** — Returns 3-tuple (to, cc, bcc) instead of 2-tuple
- Settings: website text field in Business Profile section

---

## Event Invitation UX, Outcome Dedup Fix (March 23, 2026)

### Event Invitation Picker — "Show More Suggestions"
- `AddParticipantsSheet` now tracks an `excludedFromSuggestions` set of person IDs already shown
- After adding selected people, they're removed from the visible suggestions list immediately
- **"Show More Suggestions"** button at the bottom of the list fetches the next batch from the AI, excluding all previously suggested and already-added people
- `EventCoordinator.suggestInvitationList()` accepts new `excludingIDs` parameter to filter candidates before sending to the AI
- Button hides when no more candidates remain

### Remove Participant from Event
- **"Remove from Event"** destructive button added to `ParticipantDetailView` quick actions
- Confirmation alert explains removal clears all invitation and RSVP data
- Calls `EventRepository.removeParticipant()` to delete the `EventParticipation` record entirely — no residual accepted/declined status remains
- Parent view (`EventDetailView`) clears selection and refreshes participant list via `onRemoved` callback

### Outcome Dedup Respects Skip/Done Choices
**Bug**: `hasSimilarOutcome()` only checked `.pending`/`.inProgress` outcomes. After a user marked an outcome as Skip (dismissed) or Done (completed), it became invisible to the dedup check and was regenerated on every OutcomeEngine cycle — causing duplicate "Reconnect with…" items and lost user choices across app restarts.

**Fix**:
- Added `OutcomeRepository.hasRecentlyActedOutcome(kind:personID:withinDays:)` — checks dismissed/completed outcomes within a **7-day suppression window**, anchored to `dismissedAt`/`completedAt` timestamps
- Both persist paths in `OutcomeEngine` (main generation loop + role transition outcomes) now check `hasRecentlyActedOutcome` alongside existing `hasSimilarOutcome`
- After 7 days, SAM will re-suggest if the relationship health scanner still detects an issue — balancing respect for user choices with ongoing coaching value

### Migration Notes
- No schema changes — uses existing `dismissedAt`/`completedAt` fields on `SamOutcome`
- Existing dismissed/completed outcomes immediately participate in the 7-day suppression window

---

## Settings Restructure + AI Simplification (March 21, 2026)

### Settings Sidebar Navigation
Replaced 5-tab TabView with Xcode-style NavigationSplitView sidebar. 15 sidebar items organized into four groups (General, Data, AI, Business). Window frame widened to 880×580.

**Sidebar sections**:
- **General**: Personalization, Appearance, Security
- **Data**: Contacts, Calendar, Mail, Communications, Clipboard Capture
- **AI**: Coaching, Briefings, Dictation & Voice, Prompt Lab
- **Business**: Business Type, Compliance, Roles

**New pane files**: `PersonalizationSettingsPane.swift` (identity + signature + emoji), `AppearanceSettingsPane.swift` (text size, tips, notifications), `DictationVoiceSettingsPane.swift` (mic/speech permissions, silence timeout), `RolesSettingsPane.swift` (role definitions with seed roles for Financial Advisor).

### AI Backend Simplification
- `AIService.activeBackend()` locked to `.hybrid` — structured queries via Apple FoundationModels, narrative via MLX
- `MLXModelManager.selectedModelID` locked to `mlx-community/Qwen3-8B-4bit`
- Removed backend picker, model list/download/delete UI from Coaching settings
- Onboarding AI step updated to reference Qwen 3 8B (was Mistral 7B)
- `aiBackend` removed from backup preference keys
- Strategic coordinator logging simplified to fixed `"hybrid/Qwen3-8B"` label

### Settings Simplification
- **Removed always-on toggles**: morning briefing, strategic digest, strategic briefing integration, outcome auto-generate — these features now always run (UserDefaults keys still default to true for existing users)
- **Removed "SAM is my CRM" toggle** — CRM constraint always injected into AI system instructions and blocklist
- **Removed Social Platforms UI** — platforms auto-detected from Me card's CNContact social profiles via `BusinessProfileService.socialPlatformsFromMeCard()` (maps service names to user-friendly labels, cached per-launch)
- **Removed "Auto-detect permission loss" toggle** — feature always active (was a developer convenience, not user-facing)
- **Renamed**: "Profile & Identity" → "Personalization", "Practice Profile" → "Business Type"
- **Moved**: emoji toggle to Personalization, Clipboard Capture to its own sidebar item under Data
- **Mail import**: added 1-minute interval option (feasible with direct SQLite reads), wording changed to "Automatically import email" for consistency
- **Inbox filters**: added +/- mechanism for custom email addresses beyond Me card

### Role Recruiting Improvements
- **Seed roles for Financial Advisor**: "Referral Partner", "WFG Agent Recruit", "Client Advocate", "Strategic Alliance" — pre-populated descriptions, criteria, and exclusions. Button appears in Roles pane when practice type is Financial Advisor.
- **RoleDefinitionEditorSheet** widened from 450×600 to 560×640, added rounded border text fields, improved section headers and footer descriptions
- Role definitions management moved from Business dashboard to Settings > Roles

### Migration Notes
- Same UserDefaults keys — no data migration needed
- Old container views (`DataSourcesSettingsView`, `AISettingsView`, `BusinessSettingsView`) kept as private dead code for reference
- `BusinessProfile.samIsCRM` and `activeSocialPlatforms` fields retained in the DTO for backwards-compatible JSON decoding, but no longer exposed in UI

---

## Qwen JSON Sanitizer Hardening, Practice-Aware Compliance, Anti-Hallucination (March 20, 2026)

### Qwen JSON Sanitizer Hardening
`sanitizeMLXJSON()` rewritten from line-based filtering to a whitelist approach. Lines must contain at least one JSON structural character (`"`, `{`, `}`, `[`, `]`, digit) or be a JSON literal (`true`/`false`/`null`) to survive. This catches all observed Qwen hallucination patterns:
- Bare words on their own line (e.g., `compact`)
- Half-quoted keys with missing opening quote (e.g., `comlpliance_notes":`)
- Fully unquoted keys (e.g., `clam: "reflective"`)
- Trailing commas before `]` or `}`

Enhanced JSON parse error debugging: full JSON logged in 800-char chunks, error byte position with surrounding context, line-level inspection.

### Practice-Aware Topic Compliance
Content topic JSON schema now conditional on practice type. General practice shows `"compliance_notes": null` in the schema example and instructs Qwen to always return null. Financial Advisor practice preserves the original compliance notes behavior. Also changed example `suggested_tone` from "educational" to "personal" to reduce Qwen's tendency to default every topic to educational.

### Anti-Hallucination Prompt Rule
Explicit instruction added to content topic prompt: never invent statistics, percentages, study citations, or research findings. Use only facts from the provided context data.

### Role Candidate Scoring Skipped on User-Triggered Digests
`RoleRecruitingCoordinator.refreshIfStale()` no longer runs during on-demand (user-triggered) strategic digests, only during scheduled runs (morning briefing). Prevents AI resource contention when the user clicks Generate Ideas.

---

## Role-Based Content Seeding, MLX Topic Suggestions, Content Topic Model Comparison (March 20, 2026)

### Role-Based Content Generation Seeding
Users can now flag specific roles for content topic generation. When editing a role definition, a new "Content Generation" section lets the user toggle content seeding on and provide a brief describing why the world should know about this group. The content advisor then generates at least one topic per content-enabled role, grounded in the role's brief and recent interactions with people in that role.

- **RoleDefinition** — New fields: `contentGenerationEnabled` (Bool), `contentBrief` (String)
- **RoleDefinitionEditorSheet** — Content Generation section with toggle and multi-line text field
- **StrategicCoordinator.gatherContentData()** — New `CONTENT-ENABLED ROLES` section includes role name, brief, and up to 5 recent candidate interactions
- **ContentAdvisorService** — Prompt updated to generate at least one topic per content-enabled role

### MLX-First Topic Suggestions
Content topic suggestions (`ContentAdvisorService.analyze()`) now route through `generateNarrative()` (MLX/Qwen) instead of FoundationModels. Apple's model ignores style instructions and produces generic "Title: Subtitle" patterns. Qwen follows hook-style, first-person voice, and tone variety prompts faithfully.

- **ContentAdvisorService** — Topic suggestion prompt rewritten for hook-style titles, first-person key points, tone variety
- **sanitizeMLXJSON()** — Strips Qwen hallucinated unquoted keys (e.g., `clam: "reflective"`) and trailing commas
- **PromptLabCoordinator** — Default content topics prompt updated to match runtime prompt style

### Content Topic Model Comparison (Debug)
New debug utility that runs the same content topic prompt through both FoundationModels and MLX, logging timing and parsed output for side-by-side quality comparison.

- **ContentTopicModelComparison** (new) — Actor-isolated debug tool, accessible via Debug > Compare Content Topic Models
- **SAMApp** — Debug menu entry added

### Prompt Lab Filtering
Prompt Lab now only shows MLX-routed prompt sites. FoundationModels prompts produce internal structured JSON not useful for user experimentation.

- **PromptSite** — Added `isPromptLabVisible`, `promptLabCases` filter
- **PromptLabView** — Default selection changed to `.contentDraft`, picker filtered to MLX-only sites
- **PromptLabCoordinator** — Test runner uses `generateNarrative()` to match runtime behavior

### NotebookLM Documentation Refresh
Updated onboarding showcase and overview documents with expanded detail on the eleven-step onboarding flow, security lock screen, tooltip examples, guide sections, and adaptive learning.

---

## Custom Topic, MLX Content Drafting, Practice-Aware Compliance (March 20, 2026)

### Custom Topic Sheet
New "Custom Topic" button in Grow > Content lets users seed their own topic and key points for social media draft generation, beyond SAM's AI-suggested topics.

- **CustomTopicSheet** (new) — Topic + key points entry, submits as `ContentTopic` for draft generation
- **GrowDashboardView** — Custom Topic button in content ideas header and empty state

### MLX-First Content Generation
Content draft generation now routes through `generateNarrative()` (prefers MLX/Qwen) instead of `generate()` (FoundationModels). Apple's on-device model was refusing legitimate nonprofit/ministry topics as "controversial." Qwen produces better prose and has no overly cautious safety filters.

- **ContentAdvisorService** — Switched to `generateNarrative()`, added refusal detection with auto-retry, moved key points from system instruction to user prompt for stronger adherence, improved plain text fallback JSON artifact cleanup
- **Refusal detection** — `isRefusal()` detects common LLM refusal phrases and retries with softened framing

### Practice-Aware Compliance
Financial compliance rules in content prompts are now conditional on `practiceType`. General practice users get clean prompts without financial compliance noise. Compliance settings section in Settings is now visible for all practice types.

- **ContentAdvisorService** — Financial compliance block only injected when `isFinancial`, removed forced "educational" framing for General practice
- **ComplianceSettingsContent** — Accepts `isFinancial` parameter; financial category toggles shown only for Financial Advisor; custom keywords always available
- **SettingsView** — Compliance section visible for all practice types

### Content Draft Sheet UX
Larger sheet dimensions for both topic entry and draft viewing.

- **CustomTopicSheet** — 560×520 (was 500×400)
- **ContentDraftSheet** — Width 560 (was 480), draft area 160–400px (was 80–200px read / 120–200px edit)

---

## RSVP Calibration, Event Detail UX, Graph Legend, New Person, LinkedIn PDF Safety, Tips & Guides (March 18, 2026)

### RSVP Intelligence Calibration
AI-detected RSVPs now learn from user feedback. When a user confirms or dismisses a detected RSVP, the outcome is logged via `CalibrationService.recordRSVPFeedback()`. Historical accuracy drives an adaptive auto-confirm threshold (`EventCoordinator.computeRSVPThreshold()`): high accuracy lowers the bar, low accuracy raises it. Stats visible in Settings > Coaching > RSVP Detection Accuracy.

- **CalibrationDTO** — Added `rsvpAccuracyStats` property (confirmed/dismissed/accuracy%)
- **CalibrationService** — `recordRSVPFeedback(detectedStatus:wasCorrect:)`, `rsvpAutoConfirmThreshold()`
- **CoachingSettingsView** — RSVP accuracy stats section with reset button

### Event Detail UX Overhaul
EventDetailView replaced simple dropdown participant filter with a three-tier layout: Confirmed → Inferred (AI-detected) → Dismissed. Collapsible sections reduce clutter. Added bulk review sheet for inferred RSVPs.

- **EventDetailView** — Cached participations, `reloadEvent()`, collapsible inferred/dismissed sections, bulk review sheet
- **EventCoordinator** — `dismissDetectedRSVP()`, calibration feedback on confirm/correct
- **EventRepository** — `dismissRSVP()`, `undoDismissRSVP()`, `bulkDismissRSVPs()`
- **SAMModels-Event** — New fields: `rsvpDismissed`, `rsvpDismissedAt`, `rsvpOriginalDetectedStatusRawValue`

### Relationship Graph Legend
New visual legend overlay (⌘L toggle) showing edge types (business, referral, recruiting, communication, co-attendee, mentioned together, family) with colors/line styles, plus node health color key.

- **GraphLegendView** (new) — Compact overlay with edge and node legends
- **GraphToolbarView** — Legend toggle button (⌘L)
- **RelationshipGraphView** — Legend overlay, keyboard shortcut

### New Person Sheet
Users can now create SAM contacts directly without Apple Contacts. Accessible via ⌘N in People list or empty state.

- **NewPersonSheet** (new) — Simple form (name, optional email/phone), calls `PeopleRepository.insertStandalone()`
- **PeopleListView** — ⌘N button, updated empty state with "New Person" option

### LinkedIn PDF Name Mismatch Warning
Drag-and-drop LinkedIn PDF import now checks whether the PDF profile name matches the target contact. On mismatch, a confirmation dialog warns: *"This PDF is for 'X' but you're viewing 'Y'. Import anyway?"*

- **ContactPhotoCoordinator** — `PendingLinkedInImport`, `namesMatch()` (accent-insensitive first+last comparison), `confirmPendingLinkedInImport()`, `cancelPendingLinkedInImport()`, extracted `performLinkedInImport()`
- **InlineNoteCaptureView** — `.confirmationDialog` for mismatch confirmation

### TipKit Expansion & Guide Articles
8 new contextual tips added across views (post-meeting capture, content drafts, life event coaching, goal check-ins, deep work scheduling, enrichment review). 5 new guide articles covering text size, life events, deep work, goal check-ins, and command palette.

- **SAMTips** — New tip types with guide article mappings
- **GuideManifest.json** — 5 new entries
- **GuideScreenshotRunner** — Updated screenshot list
- Multiple views — Added `TipView()` with `SAMTipViewStyle()`

### Infrastructure & Fixes
- **EnrichmentRepository** — Dedup skips enrichments in any status, not just pending
- **LinkedInImportCoordinator** — Phone enrichment skips duplicates
- **RoleRecruitingCoordinator** — Fixed retain cycle with `weak` capture
- **RoleRecruitingRepository** — Prevents duplicate candidate inserts
- **RoleCandidateDetailView** — Auto-save notes on disappear/submit
- **MailDatabaseService** — Guards against nil SQLite pointer
- **GoalJournalRepository** — Fixed actor isolation in `summarizeSession()`
- **RoleCandidateAnalystService** — `LLMCandidateScore` Sendable conformance
- **GoalCheckInSessionView** — Changed `.onAppear` to `.task` for async init

---

## App-Wide Text Size Setting (March 18, 2026)

**What**: Added a user-configurable text size preference (Settings > General) that scales all semantic fonts throughout SAM. Addresses readability concerns on high-resolution displays.

**Why**: macOS does not meaningfully respond to SwiftUI's `DynamicTypeSize` for semantic fonts — `.body`, `.caption`, `.headline` etc. are fixed point sizes regardless of the dynamic type environment. A custom scaling system was needed.

**How it works**:
- `SAMTextSize` enum defines four levels: Small (0.88×), Standard (1.0×), Large (1.15×), Extra Large (1.30×)
- Custom `EnvironmentKey` (`\.samTextScale`) propagates a `CGFloat` multiplier from the app root
- `Font.sam(_:scale:weight:)` returns system fonts at macOS default point sizes × the multiplier
- `.samFont(_:weight:)` `ViewModifier` reads the environment and applies the scaled font
- Settings UI uses a segmented picker with a live preview sentence

**Scope**: ~1,870 `.font(.caption)` / `.font(.headline)` / etc. calls across 109 view files converted to `.samFont()`. Hardcoded `.font(.system(size:))` calls for decorative elements left as-is.

**Convention**: All new views must use `.samFont()` instead of `.font()` for semantic text styles.

---

## Goal Journal — Conversational Refinement (March 17, 2026)

**What**: Added goal-scoped coaching check-in sessions that produce persistent, structured learnings. Users can check in on any business goal via a chat UI; when done, SAM distills the conversation into a `GoalJournalEntry` capturing what's working, what's not, barriers, adjusted strategy, key insight, and commitment actions. Journal data feeds forward into all AI specialists.

### New Files
- **`SAMModels-GoalJournal.swift`** — `GoalJournalEntry` SwiftData model with JSON-encoded array pattern
- **`GoalJournalDTO.swift`** — `GoalJournalEntryDTO` (Sendable, Codable, team-export-ready) + `GoalCheckInContext` context DTO
- **`GoalJournalRepository.swift`** — `@MainActor @Observable` singleton with CRUD, export, and background `summarizeAndSave()` with observable `isSummarizing` status
- **`GoalCheckInService.swift`** — Actor singleton: goal-scoped coaching responses (conversation rules enforce ONE question per turn, conversation-ending detection) + post-session AI summarization into structured JSON
- **`GoalCheckInSessionView.swift`** — Chat UI with goal header (progress, pace badge, days remaining), multi-line TextEditor input, action buttons, immediate close on "Done" with background distillation

### Forward-Feeding Injection Points (6+)
- **BusinessProfileService** — `goalJournalFragment()` in `fullContextBlock()` propagates to all AI specialists
- **StrategicCoordinator** — `gatherContentData()` includes whatsWorking/whatsNotWorking/insights; `gatherPipelineData()` includes barriers and adjusted strategies
- **OutcomeEngine** — Journal-informed pacing (references adjustedStrategy/commitmentActions); check-in nudge when behind/atRisk goal hasn't been checked in for 14+ days
- **RoleCandidateAnalystService** — Journal context from roleFilling goals injected into candidate scoring prompts
- **DailyBriefingService** — Recent journal entries (7 days) included in briefing prompt

### Modified Files
- **GoalProgressView** — "Check In" button per goal, collapsible journal history section
- **MinionsView** — "Distilling" minion row during background summarization
- **SAMModelContainer** — Registered `GoalJournalEntry.self`
- **SAMApp** — `GoalJournalRepository.shared.configure(container:)`
- **BackupDocument** — `GoalJournalEntryBackup` struct (optional for backward compat)
- **BackupCoordinator** — Export/import for journal entries

### UX Refinements (from testing)
- System instruction rewritten: one question per turn, 2–4 sentences, conversation arc guide instead of probing checklist
- Multi-line TextEditor (72pt min / 120pt max) replaces single-line TextField
- Thinking indicator scrolls into view via `onChange(of: isGenerating)`
- Conversation-ending detection: SAM closes warmly when user signals wrap-up
- "Done" closes window immediately; summarization runs in background with Minion status indicator

---

## Content Advisor Robustness & Encodable Fix (March 17, 2026)

**What**: Fixed `LLMContentTopic` Encodable conformance, hardened content advisor JSON parsing, added diagnostic logging across the content pipeline, and pinned architecture to arm64.

### LLMContentTopic Encodable Fix
- `LLMContentTopic` had extra `CodingKeys` cases (`platform`, `angle`, `relevance`) for tolerant decoding of alternate LLM field names, but these broke the compiler's auto-synthesized `Encodable` conformance
- Added explicit `encode(to:)` that encodes only the four canonical properties (`topic`, `keyPoints`, `suggestedTone`, `complianceNotes`)

### Content Advisor Parsing Hardening
- Added bare-array fallback: if the LLM returns `[{...}]` instead of `{"topic_suggestions": [{...}]}`, the parser now handles it via a `DecodingError.typeMismatch` retry
- Extracted JSON format instructions into a shared `jsonFormat` constant so both custom-prompt and default-prompt paths include the same schema specification

### Diagnostic Logging
- Added debug logging throughout the content pipeline: `StrategicCoordinator` cache status, content result counts, digest persistence, and `ContentAdvisorService` raw response / parse results
- Added debug prints in `GrowDashboardView` content tab for tracing rendering decisions
- Commented out verbose per-fetch logging in `ContactsService` to reduce noise

### Build Configuration
- Pinned `ARCHS = arm64` across all build configurations (Debug, Release, target-level) for Apple Silicon-only builds

---

## Parallelize Briefing Generation, Improve Progress UX, Remove Duplicated Sections (March 17, 2026)

**What**: Parallelized AI narrative and strategic analysis in daily briefing generation, replaced numeric progress bar with descriptive stage labels and indeterminate progress, moved refresh button inline, removed duplicated follow-up/life-event sections from the briefing card (already shown as outcome cards in Zone 2), and removed overzealous hallucination-detection filter that was discarding valid narratives.

### Parallel Briefing Generation
- AI narrative (visual + TTS) and strategic digest now run concurrently via `async let` / `Task`, cutting briefing generation wall-clock time roughly in half
- `StrategicCoordinator.generateDigest` accepts an `onProgress` callback so callers receive per-specialist stage updates in real time

### Progress UX Overhaul
- Replaced deterministic `ProgressView(value:)` with indeterminate `ProgressView()` — the old numeric progress was misleading because AI inference time is unpredictable
- Stage labels now describe what SAM is doing in human-readable terms ("Reviewing priority actions...", "Running AI specialists...", etc.) instead of silent percentage jumps
- Added `Task.yield()` between data-gathering stages so SwiftUI renders label updates promptly
- Stage label transitions use a subtle ease-in-out animation

### Refresh Button Relocated
- Removed toolbar "Refresh" button from `AwarenessView`; replaced with an inline `arrow.clockwise` button next to the greeting in `PersistentBriefingSection`
- Button spins continuously while generating (via `rotationEffect` + `repeatForever` animation)

### Briefing Card Cleanup
- Removed "Follow-ups" and "Life Events" subsections from the briefing card — these were duplicating content already rendered as outcome cards in Zone 2
- Simplified view state logic: generating → briefing content → generate CTA (previously had overlapping conditions)

### Hallucination Filter Removed
- Removed `detectHallucinatedNames` from `DailyBriefingService` — it used a brittle heuristic (mid-sentence capitalized words not in input) that frequently rejected valid narratives containing proper nouns the filter didn't anticipate (place names, organization names, product names)
- The anti-hallucination prompt fix from earlier today is more effective and doesn't discard valid output

---

## Mail Import Overhaul, Prompt Lab Wiring, Briefing Fixes (March 17, 2026)

**What**: Complete overhaul of sent mail import pipeline, wired all 11 Prompt Lab sites to production, fixed briefing hallucination, added periodic mail import.

### Sent Mail Import — Full Direct DB Pipeline
- **Root cause**: `.skipsPackageDescendants` in the file enumerator prevented descending into `.mbox` packages, so `.emlx` files in `Data/{0-9}/Messages/` sharded directories were never found
- Fixed `discoverMessageDirs` to remove `.skipsPackageDescendants` — now finds 500+ `Messages/` directories vs 9 before
- Added recursive `.emlx` fallback search with self-healing cache for undiscovered directory structures
- Added DB-only recipient query from `recipients` table when `.emlx` isn't available (covers IMAP edge cases)
- Watermark now only advances on successful body fetch (not metadata-found) to prevent permanently skipping messages
- Added 1-second watermark buffer to prevent `>` comparison from skipping same-timestamp messages
- One-time migration resets sent watermark to recover previously skipped emails
- Descriptive "Sent to ..." fallback snippet when body unavailable (with recipient list)

### Periodic Mail Import
- Mail import now runs on a recurring timer (default 600s), matching communications importer behavior
- Previously only ran once at app launch — new emails required restart or manual Debug menu trigger

### Prompt Lab → Production Wiring
- All 11 Prompt Lab sites now connected: "Deploy as Active" variants are used by actual services
- Morning/evening briefing services read deployed variants from UserDefaults
- Content Draft (`ContentAdvisorService.generateDraft`) was the last unwired site — now reads custom prompt

### Morning Briefing Anti-Hallucination
- Fixed prompt that caused AI to fabricate meetings when calendar was empty
- "overview of the day (meetings, key people)" → "If TODAY'S CALENDAR is empty, say the calendar is open — NEVER invent meetings"
- Applied to both `DailyBriefingService` and `PromptLabCoordinator` default prompts

---

## Archive Build Fixes, Warning Cleanup, UX Polish, Mail Onboarding Fix (March 17, 2026)

**What**: Fixed archive (Release) build failure, eliminated ~60 compiler warnings, improved last-name sorting, removed redundant UI, fixed Mail onboarding to use direct database access, fixed OutcomeEngine crash, and migrated EventFormView to MapKit geocoding.

### Archive Build Fix
- `defaultStoreURL` was inside `#if DEBUG` but referenced by `checkpointStoreIfNeeded()` and `cleanupOrphanedReferences()` which run in all configurations — moved it above the `#if DEBUG` block

### Compiler Warning Cleanup (~60 warnings eliminated)
- Added `nonisolated` to ~25 pure-data DTO structs/enums to opt out of project-wide `@MainActor` default (`UserLinkedInProfileDTO`, `UserFacebookProfileDTO`, `ProfileAnalysisDTO`, `RSVPDetectionDTO`, Facebook/Substack DTOs, `GoalType`, `GoalPace`, `GoalProgress`, `ImageResizeUtility`, etc.)
- Removed unused variables (`hasExisting`, `role`, `summary`), unnecessary `await`, redundant `?? ""` on non-optional strings, unused `try?` results
- Fixed `SamPerson` capture in `@Sendable` closures (`ContactPhotoCoordinator`) and mutable-after-capture (`EventCoordinator.autoReplied`)
- Added `nonisolated(unsafe)` to file-scope Logger constants where needed for cross-actor access
- Added `nonisolated` to `SAMModelContainer.schemaVersion` for access from `nonisolated static` functions

### Mail Onboarding Fix
- Onboarding "Enable Email" now requests a folder bookmark for `~/Library/Mail` (direct DB access) instead of triggering AppleScript automation — eliminates the "privilege violation (-10004)" error
- `MailImportCoordinator.checkMailAccess()` returns success immediately when direct DB access bookmark exists, only falling back to AppleScript when no bookmark is available
- SAMApp launch permission check skips AppleScript when `hasMailDirAccess` is true

### UX Polish
- Last-name sorting now strips generational suffixes (Jr, Sr, II–V) and professional credentials (MBA, RN, LCSW, CPA, CFP, etc.) before identifying the sort key
- Removed redundant "Add Note" button from Person Detail top section (Notes section below has its own input)

### Bug Fixes
- Fixed `OutcomeEngine.generateOutcomes()` crash: `Dictionary(uniqueKeysWithValues:)` fatal assertion when multiple `SamPerson` instances shared the same `.id` — switched to `uniquingKeysWith` merge

### API Migration
- `EventFormView` address validation: replaced deprecated `CLGeocoder` with `MKGeocodingRequest` and `MKAddressRepresentations.fullAddress(includingRegion:singleLine:)` (macOS 26)

---

## Log Level Cleanup, LinkedIn PDF Import, Clipboard Capture, Note Context Menu (March 16, 2026)

**What**: Massive log noise reduction, LinkedIn profile PDF drag-and-drop import with deterministic parsing, clipboard capture intelligence improvements, and right-click edit/delete on notes.

### Log Level Cleanup (~560 calls across 70+ files)
- Downgraded ~560 `logger.info()` calls to `logger.debug()` across 70+ files
- Only ~47 `.info` calls remain, limited to: final completion summaries, permission results, security events, significant state changes, and one-time setup events
- Dramatically reduces log noise in Console.app during normal operation while preserving all diagnostic detail at debug level

### LinkedIn Profile PDF Import
- Drag a LinkedIn-generated profile PDF onto the "Add a note..." bar in PersonDetailView
- `LinkedInPDFParserService` performs deterministic PDF parsing (no AI) — extracts structured sections: summary, experience, education, skills, honors, languages, contact info
- Creates `PendingEnrichment` records (`.linkedInProfilePDF` source) for email, phone, company, job title, and LinkedIn URL
- Generates a concise note combining summary, current position, education highlights, top skills, honors, and languages
- The created note triggers standard AI analysis, enabling family/relationship discovery from the profile content
- `EnrichmentSource.linkedInProfilePDF` added to distinguish PDF-sourced enrichment from CSV import enrichment
- `PeopleRepository.findByLinkedInSlug()` added for matching contacts by LinkedIn URL slug
- `PersonDetailView` photo drop target reverted to image-only; PDF drops route to the note capture bar instead

### Clipboard Capture Improvements
- **Source URL detection**: `ClipboardParsingService` now reads the pasteboard source URL to determine content origin
- **LinkedIn profile page detection**: When clipboard content comes from a LinkedIn profile URL, routes to a profile review phase instead of conversation parsing — prevents misinterpreting profile page content as a conversation
- **Auto-matching by LinkedIn slug**: Profile review phase automatically matches the profile to existing contacts by extracting the LinkedIn slug from the source URL
- **UI noise filtering**: Strips web page chrome (navigation elements, sidebars, footers) from pasted web content before analysis
- **Anti-hallucination improvements**: `MessageAnalysisService` adds grounding rules to prevent fabricating conversation participants or message content from ambiguous clipboard input

### Note Context Menu
- Right-click on any note in `NotesJournalView` now shows Edit and Delete options
- Delete includes a confirmation dialog before removal
- Deletion uses existing undo history infrastructure (30-day undo)

### New Files
| File | Purpose |
|------|---------|
| `Services/LinkedInPDFParserService.swift` | Deterministic LinkedIn profile PDF parser — extracts structured data without AI |

### Modified Files (10 + 70 log cleanup)
- `Coordinators/ContactPhotoCoordinator.swift` — LinkedIn PDF import handler: enrichment creation + note generation
- `Services/ClipboardParsingService.swift` — Source URL detection, LinkedIn profile vs conversation routing, UI noise filtering
- `Views/Communication/ClipboardCaptureWindowView.swift` — Profile review phase, auto-matching by LinkedIn slug
- `Views/Notes/InlineNoteCaptureView.swift` — PDF drop target on "Add a note..." bar
- `Views/Notes/NotesJournalView.swift` — Context menu with Edit and Delete on notes
- `Views/People/PersonDetailView.swift` — Photo drop reverted to image-only (PDFs route to note bar)
- `Models/SAMModels-Enrichment.swift` — Added `EnrichmentSource.linkedInProfilePDF`
- `Repositories/PeopleRepository.swift` — Added `findByLinkedInSlug()` method
- `Services/MessageAnalysisService.swift` — Anti-hallucination grounding rule for clipboard content
- 70+ files — `logger.info` → `logger.debug` downgrade

---

## Contact Photo Drag-and-Drop, LinkedIn Enrichment, Facebook Import Fix (March 15–16, 2026)

**What**: Drag-and-drop / paste photo onto contact avatars with one-click Safari profile opener for LinkedIn and Facebook, plus fix for Facebook folder import hang.

### Contact Photo Management
- Drag an image from Safari or any source onto a contact's photo area in PersonDetailView — image is center-cropped to square, resized to 600×600 max, compressed to JPEG (0.85 quality), and written to Apple Contacts via `CNContactStore`
- Paste an image via right-click context menu when clipboard has an image
- One-click profile opener: clicking an empty photo placeholder opens the person's LinkedIn/Facebook profile in a compact 500×500 Safari window positioned next to the drop target for easy dragging
- Safari windows tracked by ID and auto-closed after successful photo drop; login sessions preserved
- LinkedIn photos can be dragged directly from the profile page; Facebook requires clicking the friend's photo to enlarge it first, then dragging
- For confirmed Facebook friends without a stored profile URL, falls back to a Facebook people search by name
- Visual feedback: frosted glass overlay with icon on drag hover, progress spinner during save, auto-dismissing inline error capsule

### Profile URL Resolution
- Checks all sources: `SamPerson.linkedInProfileURL` / `facebookProfileURL`, Apple Contacts `socialProfiles`, Apple Contacts `urlAddresses`
- `sanitizeProfileURL()` strips service-name prefixes (`linkedin:`, `facebook:`, etc.) that Apple Contacts sometimes stores in the username field
- Constructs profile URLs from usernames when `urlString` is nil (e.g., `linkedin` service with username `jsmith` → `https://www.linkedin.com/in/jsmith`)

### Facebook Import Fix
- **Bug**: `processZip()` set `importStatus = .parsing` before calling `loadFolder()`, which then hit its own re-entry guard (`guard importStatus != .parsing`) and returned immediately — silently doing nothing
- **Fix**: Removed the premature status set from `processZip()`; `loadFolder()` manages its own status transitions

### LinkedIn Import: Company & Position Enrichment
- `Connections.csv` Company, Position, and Email columns were parsed but never written to contacts during import
- `enrichPeopleFromConnections` now passes `company` and `position` to `updateLinkedInData`
- `updateLinkedInData` / `applyLinkedIn` now create `PendingEnrichment` records for company (`.company`) and job title (`.jobTitle`) from LinkedIn data
- `upsertFromSocialImport` accepts new `linkedInCompany` / `linkedInPosition` parameters and queues enrichment records for both existing and new standalone contacts
- `createContactsForAddCandidates` now passes `candidate.company` and `candidate.position` through to the upsert
- Enrichment records appear as the blue "contact update(s) available" banner on PersonDetailView for user review

### Photo Sync Protection
- After writing a photo via drag-and-drop, the `CNContactStoreDidChange` notification triggers a background sync that would overwrite `photoThumbnailCache` with stale/nil data (Apple Contacts hasn't generated the thumbnail yet)
- `ContactPhotoCoordinator.recentPhotoWrites` tracks contact IDs with recent photo writes
- `PeopleRepository` incremental sync skips thumbnail overwrite for 30 seconds after a photo write, giving Apple Contacts time to generate the thumbnail

### Detail View Refresh After Enrichment
- `PersonDetailView` enrichment sheet `onDismiss` now calls `loadFullContact()` to re-fetch updated company/job title from Apple Contacts immediately

### Entitlement Update
- Added `com.apple.Safari` to `temporary-exception.apple-events` in both entitlement files for AppleScript Safari control

### New Files
| File | Purpose |
|------|---------|
| `Utilities/ImageResizeUtility.swift` | Center-crop, resize, JPEG compression for contact photos |
| `Utilities/SafariBrowserHelper.swift` | AppleScript: open/close/position Safari windows by ID |
| `Services/ContactPhotoService.swift` | Actor: write processed JPEG to CNContactStore |
| `Coordinators/ContactPhotoCoordinator.swift` | Orchestrates drop/paste/Safari-open flow, photo write protection |

### Modified Files (7)
- `Views/People/PersonDetailView.swift` — Photo drop target, paste handler, click-to-open, profile URL resolution from all sources, enrichment refresh
- `Coordinators/FacebookImportCoordinator.swift` — Fixed re-entry guard bug in `processZip()`
- `Coordinators/LinkedInImportCoordinator.swift` — Pass company/position through enrichment and add-candidate paths
- `Repositories/PeopleRepository.swift` — LinkedIn data enrichment with company/position, photo sync protection grace period
- `Resources/Guide/people/02-Person-Detail.md` — Photo drag-and-drop usage guide
- `SAM/SAM_crm.entitlements` — Added Safari to Apple Events exceptions
- `SAM_crm.entitlements` (project root copy) — Same entitlement update

---

## Practice Type System, Social Notifications, Performance Optimizations (March 14, 2026)

**What**: Multi-purpose SAM (PracticeType on BusinessProfile), Facebook/LinkedIn email notification processing, relationship graph custom roles, copy-to-clipboard across coaching UI, Facebook import folder support, profile analyst prompt compression, and call-flow optimization.

### Practice Type System
- `PracticeType` enum (`.financialAdvisor`, `.general`) on `BusinessProfileDTO` with backwards-compatible JSON decoding
- Settings picker controls feature visibility: Production tab, Recruiting pipeline, compliance scanning, financial goal types all hide for general practice
- `personaFragment()` / `complianceNote()` on `BusinessProfileService` replace 40+ hardcoded "financial strategist" strings across all AI service prompts
- `ComplianceScanner.scanWithSettings()` returns empty for non-financial practice types

### Social Platform Email Notifications
- `FacebookEmailParser` — subject-only parser (11 event types) for `@facebookmail.com` notifications; no MIME fetch needed
- `MailImportCoordinator` intercepts Facebook emails alongside LinkedIn before known/unknown partitioning
- `FacebookImportCoordinator.handleNotificationEvent()` records IntentionalTouch and evidence for Facebook engagement
- LinkedIn `notifications-digest` re-enabled for engagement data processing

### Relationship Graph Custom Roles
- `GraphToolbarView` role filter menu now dynamically discovers roles from graph data (predefined first, then custom alphabetically)
- Role picker in graph review popover includes custom roles
- `GraphNode.primaryRole` gives custom roles reasonable priority (50 vs 99)
- Peer edges between people sharing the same custom role create visible clusters

### Copy-to-Clipboard
- Right-click context menu on outcome cards: "Copy" (full text) and "Copy Draft Message"
- Daily briefing: "Copy Briefing" button + right-click on narrative
- Text selection enabled on briefing narrative in Today view and overlay

### Facebook Import Folder Support
- "Select Folder..." button alongside ZIP picker on import sheet (setup, no-ZIP-found, and failed phases)
- `processZip()` detects folders vs files, routes accordingly
- `loadFolder()` searches one level down for expected structure
- ZIP extraction filters `__MACOSX` metadata folders

### Profile Analyst Prompt Compression & Context Budget
- System instructions compressed ~65% across LinkedIn, Facebook, Substack, CrossPlatform analysts
- `compactContextBlock()` on BusinessProfileService — business profile + blocklist only (no redundant social fragments)
- `contextBudgetChars()` on AIService — 10K for FoundationModels, 60K for MLX
- Previous analysis JSON budget reduced to 800 chars on FoundationModels (2000 on MLX)

### File System Watchers for Communications
- `DispatchSource.makeFileSystemObjectSource` watches iMessage `chat.db`, WhatsApp `ChatStorage.sqlite`, and `CallHistory.storedata` for instant change detection
- 1.5-second debounce coalesces rapid SQLite writes into single import
- Replaces 60-second polling loop; ~2 second latency for new message detection
- 5-minute fallback poll as safety net

### Call-Flow Optimization
- `PostImportOrchestrator` — 3-second debounce across all 7 import coordinators; role deduction and insight generation run once instead of N times
- `RoleDeductionEngine.deduceRoles()` throttled to 10-minute minimum between runs
- `InsightGenerator.startAutoGeneration()` throttled to 10-minute minimum
- `computeHealth(for:)` cached in PersonDetailView (was called 3x), pre-computed as healthMap in OutcomeEngine sort/filter paths
- `fullContextBlock()` cached for 5 minutes in CoachingPlannerService session lifetime
- WhatsApp JID log downgraded from `.info` to `.debug`; TODO log replaced with actual InsightGenerator call

### Bug Fixes
- SETUP outcomes no longer misclassified as `.communicate` (preserved `.openURL` action lane)
- Facebook import "Done" button added to complete phase body (not just toolbar)
- LinkedIn error messages now include platform name
- Cross-platform analysis loads Facebook profile from persisted storage (not just in-memory import state)
- `samProfileAnalysisDidUpdate` notification posted on `@MainActor`

### New Files
| File | Description |
|------|-------------|
| `Services/FacebookEmailParser.swift` | Subject-only parser for Facebook notification emails |
| `Coordinators/PostImportOrchestrator.swift` | Debounced post-import work orchestrator |

### Modified Files (30+)
Key files: `BusinessProfileDTO.swift`, `BusinessProfileService.swift`, `AIService.swift`, `ComplianceScanner.swift`, `SettingsView.swift`, `BusinessDashboardView.swift`, `PipelineDashboardView.swift`, `GoalEntryForm.swift`, `SAMModels-Goal.swift`, `GraphToolbarView.swift`, `GraphBuilderService.swift`, `RelationshipGraphView.swift`, `GraphNode.swift`, `OutcomeCardView.swift`, `DailyBriefingOverlay.swift`, `PersistentBriefingSection.swift`, `OutcomeEngine.swift`, `MailImportCoordinator.swift`, `FacebookImportCoordinator.swift`, `FacebookImportSheet.swift`, `CommunicationsImportCoordinator.swift`, `ProfileAnalystService.swift`, `FacebookProfileAnalystService.swift`, `SubstackProfileAnalystService.swift`, `CrossPlatformConsistencyService.swift`, `CoachingPlannerService.swift`, `PersonDetailView.swift`, `InsightGenerator.swift`, `ContactsImportCoordinator.swift`, `CalendarImportCoordinator.swift`, `LinkedInImportCoordinator.swift`, `GrowDashboardView.swift`, `RoleDeductionEngine.swift`, `WhatsAppService.swift`, plus 20+ service files for persona string replacement

---

## Security Hardening (March 13, 2026)

**What**: Mandatory authentication on every launch, mandatory backup encryption, clipboard auto-clear, log privacy audit, and keychain service.

**Why**: SAM stores sensitive relationship and business data. Security should be enforced by default with no opt-out, minimizing friction while ensuring data protection at rest, in transit (backups), and in logs.

### New Files (3)

- `Services/AppLockService.swift` — `@MainActor @Observable` singleton. Always-on Touch ID + system password authentication via `LocalAuthentication` framework. Locks on launch, locks after idle timeout (configurable 1–60 min, default 5). Lifecycle-based idle detection via `willResignActiveNotification` / `didBecomeActiveNotification` (not polling). Separate `authenticateForExport()` gate for backup operations.
- `Utilities/KeychainService.swift` — `actor` wrapping Security framework (`SecItemAdd/CopyMatching/Update/Delete`). Stores sensitive data with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Service name `com.matthewsessions.SAM`.
- `Utilities/ClipboardSecurity.swift` — `@MainActor enum` with `copy(_:clearAfter:)` (60s auto-clear, smart: only clears if user hasn't copied something else since) and `copyPersistent(_:)` for non-sensitive data.

### New Files (1) — UI

- `Views/Shared/AppLockView.swift` — Full-screen `.ultraThinMaterial` overlay with app icon, "SAM is Locked" title, unlock button. Auto-authenticates on appear.

### Modified Files (15)

#### Lock Integration

- `App/SAMApp.swift` — Lock overlay in ZStack (shows whenever `isLocked` is true, no opt-out). `configureOnLaunch()` in `.task`. Lifecycle observers for resign/become active. Backup export always passes passphrase (no nil path).
- `Views/Settings/SettingsView.swift` — `SecuritySettingsContent` simplified: removed enable/disable toggles and export auth toggle. Shows only idle timeout picker, Lock Now button, and Touch ID availability info.

#### Backup Encryption (Mandatory)

- `Coordinators/BackupCoordinator.swift` — Added AES-256-GCM encryption/decryption with HKDF-SHA256 key derivation. `SAMENC1` header for encrypted format detection. `BackupError` enum with `.encryptionFailed`, `.decryptionFailed`, `.authenticationRequired`. Auth gate via `authenticateForExport()`.
- `Views/Shared/BackupPassphraseSheet.swift` — Passphrase now required for export (no "Export Without Encryption" option). Button disabled until passphrase entered.

#### Clipboard Security (12 callsites across 9 files)

- `Coordinators/ComposeService.swift`, `Views/Shared/CopyButton.swift`, `Views/Awareness/OutcomeCardView.swift`, `Views/Awareness/ContentDraftSheet.swift`, `Views/Awareness/SocialPromotionSheet.swift`, `Views/Events/EventDetailView.swift`, `Views/People/PersonDetailView.swift` — `ClipboardSecurity.copy(_, clearAfter: 60)`
- `Views/Settings/PromptLabView.swift`, `Views/Awareness/GrowDashboardView.swift`, `Views/Social/ProfileAnalysisSheet.swift` — `ClipboardSecurity.copyPersistent(_:)`

#### Log Privacy (73 fixes across 14 files)

- All PII (names, emails, phones, social URLs, contact IDs) changed from `privacy: .public` to `privacy: .private` in: ComposeService, ContactsService, UnknownSenderTriageSection, NoteAnalysisCoordinator, NoteAnalysisService, DailyBriefingCoordinator, ContactEnrichmentCoordinator, MailService, MailImportCoordinator, LinkedInImportCoordinator, PeopleRepository, PersonDetailView, NotInContactsCapsule, FacebookImportCoordinator.

### Architecture Notes

- **No database encryption needed** — macOS FileVault provides full-disk encryption; app sandbox isolates data. `FileProtectionType.complete` was tested and removed — it causes `SQLITE_IOERR_AUTH` (error 6922) on macOS when SQLite tries to access WAL/SHM files.
- **Idle detection uses lifecycle events, not polling** — A polling timer caused the app to lock during active use. The lifecycle pattern (`willResignActive` → record timestamp, `didBecomeActive` → check elapsed time) only locks when the user actually switches away.
- **No schema version bump** — all changes are service/UI layer; no SwiftData model changes.
- Authentication uses `.deviceOwnerAuthentication` (Touch ID with system password fallback), not `.deviceOwnerAuthenticationWithBiometrics` (which would fail if Touch ID is unavailable).

---

## March 13, 2026 — Post-Meeting Capture for Unknown Attendees

### Bug Fix: Meetings with unknown participants now trigger note capture

Previously, the post-meeting capture prompt only fired for calendar events where at least one attendee was already a known SAM contact. Meetings with new prospects or leads — arguably the most important ones to capture — were silently skipped.

**Root cause:** `CalendarImportCoordinator` filtered out events without known-contact attendees at import time, so they never became evidence items and could never trigger the post-meeting check in `DailyBriefingCoordinator`.

**Changes:**

- **SamEvidenceItem** — Added `isAllDay: Bool` and `calendarAvailability: String` fields (additive, no schema version bump needed)
- **EventDTO** — Added `hasNonSelfAttendees` and `looksLikeRealMeeting` computed helpers for filtering
- **CalendarImportCoordinator** — Import filter now also includes events that look like real meetings (have non-self attendees, not free, not all-day) even when no attendee is a known contact
- **DailyBriefingCoordinator.checkRecentlyEndedMeetings()** — Three guards prevent false positives:
  - Skip `isAllDay` events (conferences, holidays)
  - Skip `calendarAvailability == "free"` events (deep work blocks like "Research IUL options for Joey")
  - Require at least one non-self participant (unverified hint or linked non-Me person)
- **CapturePayload** — Added `unknownAttendeeNames: [String]` field
- **PostMeetingCaptureView** — Pre-populates `extraAttendeeNames` with unknown attendee names on appear, so the user sees them in the attendance step ready to confirm or edit
- **DailyBriefingCoordinator.createMeetingNoteTemplate()** — No longer force-unwraps first attendee; handles events with only unknown attendees gracefully

**Guard logic for solo blocks:** Events marked as "free" availability (common for deep work, prep, research blocks) are excluded. All-day events are excluded. Events with zero non-self attendees are excluded. This means personal calendar blocks like "Take an hour to research IUL options for Joey" won't trigger prompts as long as they're marked free or have no invitees.

---

## March 13, 2026 — FamilyReference System: Note-Discovered Relationships on Graph

### New Feature: FamilyReference Pipeline

Family and personal relationships discovered during note analysis now flow through to the relationship graph and person detail view. Previously, the AI extracted `discovered_relationships` from notes but they were only stored on `SamNote` — never surfacing on the graph or the person's profile.

**Architecture:**
- **FamilyReference** (`SAMModels-Supporting.swift`) — Codable struct on `SamPerson` with freeform relationship label, optional `linkedPersonID` (for graph linking), and `sourceNoteID`
- **AI category field** — The LLM now returns `relationship_category` ("family" or "business") alongside a freeform `relationship_type` label, eliminating brittle enum normalization
- **DiscoveredRelationshipDTO.relationshipCategory** — New field passed through the DTO pipeline from `NoteAnalysisService` → `NoteAnalysisCoordinator`
- **NoteAnalysisCoordinator.createFamilyReferences()** — Filters family-category DTOs, resolves owner/referenced person orientation (AI can put the note owner on either side), deduplicates, creates reciprocal references when both people exist, and generates "Review in Graph" outcomes
- **formatRelationshipLabel()** — Simple string formatter that strips `_of` suffixes and normalizes underscores/hyphens for display
- **GraphBuilderService** — New `familyReferenceLinks` parameter; creates `.familyReference` edges and ghost nodes for referenced people without contact records
- **RelationshipGraphCoordinator.gatherFamilyReferenceLinks()** — Collects all family references across people for graph building

**UI:**
- **Relationship Graph** — `.familyReference` edges render as pink dashed lines; ghost nodes shown for unmatched people
- **PersonDetailView** — "Family & Relationships" section shows each reference with linked/ghost status indicator
- **GraphToolbarView** — "Family (Notes)" filter option in edge type menu
- **Outcomes** — "Review in Graph" outcome created for each new family discovery with `.reviewGraph` action lane

**Bug fixes:**
- Self-reference prevention (AI returning "Albert is brother of Albert")
- Owner orientation handling (AI can put the note owner in `personName` or `relatedTo`)
- Hyphenated relationship types (e.g., "brother-in-law") now handled correctly

---

## March 12, 2026 — Sidebar Toggle Fix & Graph Deduced Relationship Improvements

### Fix: Sidebar Toggle Pinned Next to Traffic Lights

SwiftUI's built-in `NavigationSplitView` sidebar toggle migrates to the toolbar overflow menu when the sidebar collapses. Replaced with an AppKit `NSTitlebarAccessoryViewController` (`SidebarToggleConfigurator.swift`) that pins the toggle button in a fixed leading position next to the traffic lights, matching the behavior of Apple's own apps (Xcode, Mail, Finder). This is an intentional hybrid AppKit/SwiftUI pattern documented in `context.md` §2.1.

### Fix: Deduced Relationship Graph Interactions

- **Reject from double-click alert**: The confirmation alert now shows three options — Confirm, Incorrect (reject), and Cancel. Previously only Confirm/Cancel were available, requiring the context menu to reject.
- **Edge hit testing for parallel edges**: When multiple edges exist between two people, hit testing now accounts for the Bézier curve offsets used during rendering. Previously it tested against straight lines, making it impossible to reliably click the deduced edge.

---

## March 12, 2026 — Unknown Sender Auto-Reply, Confirmation Flow & Reminder Scheduler

### New Feature: Auto-Reply to Unknown Sender Event RSVPs

When an unknown sender texts about an upcoming event, SAM can now auto-send a holding reply and post an OS notification.

**Architecture:**
- `SamEvent.autoReplyUnknownSenders: Bool` — per-event toggle (independent of `autoAcknowledgeEnabled`)
- `EventCoordinator.autoReplyToUnknownEventRSVPs(messages:)` — scans incoming unknown messages for event title keyword overlap + attendance-intent keywords; sends holding reply via `ComposeService.sendDirectIMessage` if both `autoReplyUnknownSenders` and `directSendEnabled` are on; always posts OS notification via `SystemNotificationService.postUnknownSenderRSVP`
- `CommunicationsImportCoordinator` — hooks auto-reply call after `bulkRecordUnknownSenders` during iMessage import
- `EventFormView` — "Auto-reply to unknown senders" toggle in Auto-Acknowledgment section

### Enhancement: Two-Phase Unknown Sender Confirmation (UnknownSenderQuickAddSheet)

Reworked from single-phase (add + dismiss) to two-phase flow:

- **Phase 1**: Name + "Add to Event" (existing). On success → transitions to Phase 2 (no dismiss).
- **Phase 2**: Editable TextEditor with AI-generated confirmation message draft.
  - `EventCoordinator.generateConfirmationMessage(for:event:)` resolves `{name}`/`{date}` from `ackAcceptTemplate`
  - Nameless contacts (friendlyFirstName = "there") get appended name-request line
  - **Send** → sends via ComposeService, logs `.acknowledgment` message, calls `onAdded`, auto-dismisses
  - **Cancel** → `.confirmationDialog` with 3 options: "Unconfirm and Remove" (reverts participation + person), "Keep Confirmed, Skip Message", "Write a Different Message"

**Bug fix**: `onAdded?()` callback deferred until sheet truly exits (send/skip/revert), preventing parent view from dismissing sheet before Phase 2 renders.

### New Feature: Event Reminder Scheduler

Background 5-minute polling loop that checks upcoming events for reminder windows.

**Architecture:**
- `EventCoordinator.startReminderScheduler()` / `stopReminderScheduler()` — `TaskPriority.utility` loop
- `checkAndSendReminders()` — checks two windows per event:
  - **1 day before** (1440 min): all accepted attendees → AI reminder via `generateReminderDrafts`
  - **10 min before** (virtual/hybrid only): short message with join link
- If `directSendEnabled` → auto-send + OS notification "Reminders sent". Otherwise → drafts + OS notification "Reminders ready to review"
- Dedup: skips if a reminder was already sent/drafted in the last hour
- `SAMApp.applicationDidFinishLaunching` starts scheduler; `applicationShouldTerminate` stops it

**SystemNotificationService additions:**
- `postUnknownSenderRSVP(senderHandle:eventTitle:eventID:autoReplied:)` — unknown sender RSVP notification with tap → navigate to event
- `postEventReminder(eventTitle:eventID:attendeeCount:autoSent:)` — reminder status notification with tap → navigate to event
- Two new UNNotificationCategory registrations: `UNKNOWN_SENDER_RSVP`, `EVENT_REMINDER`

### Bug Fix: generateReminder Name Resolution

`EventCoordinator.generateReminder` now uses `friendlyFirstName(for:)` instead of raw `displayNameCache`, preventing phone-number-as-name in reminder messages.

### Bug Fix: EventFormView Address Verification

Fixed double-click required for address verification: `onChange(of: address)` was resetting `addressValidationMessage` to nil when geocoding updated the address field. Now skips the reset when `isValidatingAddress` is true.

No schema version bump — `autoReplyUnknownSenders` uses SwiftData lightweight migration with `Bool` default.

---

## March 11, 2026 — Event Management, Presentation Library & RSVP Intelligence

### New Feature: Event/Workshop Management

Complete event lifecycle system for planning, inviting, and tracking attendance at workshops and client events.

**Architecture:**
- `SamEvent` model — title, format (workshop/seminar/webinar/social/oneOnOne), status (draft→inviting→confirmed→inProgress→completed→cancelled), date/time, venue, RSVP tracking with accepted/tentative/declined counts, optional presentation link
- `EventParticipation` model — join table linking events to people with RSVP state, invitation tracking, attendance confirmation
- `EventCoordinator.swift` — `@MainActor @Observable` singleton orchestrating event CRUD, participant management, AI-powered invitation generation, topic suggestions
- `EventRepository.swift` — SwiftData CRUD with fetch-upcoming/past/all, participant queries
- `EventTopicAdvisorService.swift` — AI-driven event topic and format suggestions based on client portfolio

**Views:**
- `EventManagerView.swift` — Segmented picker switching between Events (HSplitView list+detail) and Presentations tabs
- `EventDetailView.swift` — Full event detail with header, action buttons (Add People, Promote, Draft Invitations), participant list with role-colored badges, RSVP filter, per-participant quick actions
- `EventFormView.swift` — Create/edit event form
- `InvitationDraftSheet.swift` — AI-generated personalized invitation popup with edit-before-send, signature learning
- `AddParticipantsSheet.swift` — Search and add participants from contacts
- `SocialPromotionSheet.swift` — Social media promotion drafts

**Undo support:** Event deletion is undoable via the universal undo system. `.samUndoDidRestore` notification refreshes the event list.

### New Feature: Presentation Library

Reusable presentation management with drag-and-drop PDF import and AI content digestion.

**Architecture:**
- `SamPresentation` model — title, description, topicTags, estimatedDurationMinutes, targetAudience, fileAttachments (security-scoped bookmarks), contentSummary, keyTalkingPoints, contentAnalyzedAt, linked events
- `PresentationFile` — embedded Codable struct storing fileName, fileType, bookmarkData, fileSizeBytes
- `PresentationAnalysisCoordinator.swift` — `@MainActor @Observable` singleton with `AnalysisStatus` enum (idle/extracting/analyzing/success/failed). PDFKit text extraction from security-scoped bookmarks, AI summary generation returning summary + talking points + topic tags. Status auto-resets after 5s.

**Drag-and-drop flow:**
1. User drags PDF onto Presentations tab → blue dashed drop overlay appears
2. `.onDrop(of: [.fileURL])` handler creates security-scoped bookmark, derives title from filename
3. `SamPresentation` inserted into SwiftData with `PresentationFile` attachment
4. `PresentationAnalysisCoordinator.analyze()` kicks off automatically
5. MinionsView shows "Extracting" → "Analyzing" row with presentation title tooltip
6. On completion, presentation detail shows AI-generated summary and talking points

**PresentationFormSheet** includes Files section with "Add PDF" button; auto-fills title from first file; auto-triggers analysis on create.

### New Feature: RSVP Auto-Detection & Third-Party Flows

**RSVP Detection pipeline:**
- `RSVPDetectionDTO` — extended with `additionalGuestCount`, `additionalGuestNames`, `eventReference` fields
- `MessageAnalysisService` / `EmailAnalysisService` — extended LLM prompts with RSVP detection rules including guest detection and event references
- `RSVPMatchingService.swift` — `tryAutoAddToEvent()` finds best matching event via title word overlap, substring, day-of-week, and date scoring; auto-adds participant with user confirmation flag; posts `.samRSVPAutoAdded` notification
- Guest handling: named guests searched in contacts and auto-added; unnamed guests logged
- Multi-event matching: scores candidates and picks highest confidence match

### Enhancement: Sender Identity & Signature Learning

**Identity settings:**
- `SettingsView` — "Your Identity" section with first/last name fields, default closing field, "Auto-fill from Me Contact" button
- Auto-populates from Me contact on first launch

**AI integration:**
- `AIService` — `senderName(forWarmRelationship:)` returns first name for warm relationships (3+ evidence items in 90 days), full name for formal
- `AIService.closing(forMessageKind:isWarm:)` — checks learned preferences, falls back to user default
- Signature learning: `InvitationDraftSheet` compares original draft closing to edited version on send, stores preferences by message kind × warmth in UserDefaults (`sam.closing.<kind>.<warm|formal>`)
- `EventCoordinator.generatePersonalizedInvitation` prompt includes `SENDER` field and sign-off instruction

### Enhancement: Morning Briefing — Past Event Filtering

`DailyBriefingCoordinator` now filters out past events from the morning briefing calendar section, showing only today's remaining and future events.

No schema version bump — all new models handled by SwiftData lightweight migration.

---

## March 9, 2026 — Prompt Lab: Side-by-Side Prompt Comparison Tool

### New Feature: Prompt Lab

A dedicated window for testing, comparing, and refining SAM's AI prompts against sample data.

**Architecture:**
- `PromptLabTypes.swift` — `PromptSite` enum (10 AI prompt sites), `PromptVariant`, `PromptTestRun`, `VariantRating` types, rich sample input data per site
- `PromptLabCoordinator.swift` — `@MainActor @Observable` singleton, JSON-persisted store (`~/Library/Application Support/SAM/PromptLabStore.json`), variant CRUD, test run execution, deploy/revert, default prompt registry
- `PromptLabView.swift` — Split-view UI: left panel (site picker + sample input editor), right panel (horizontally scrollable columns for side-by-side comparison)
- `PromptLabColumnView.swift` — Per-variant column: collapsible prompt editor, output display, rating controls (winner/good/neutral/poor/rejected), deploy/duplicate/delete actions

**Supported prompt sites** (10 initial):
Note Analysis, Email Analysis, Message Analysis, Pipeline Analyst, Time Analyst, Pattern Detector, Content Topics, Content Draft, Morning Briefing, Evening Briefing

**Prompt override integration:**
- PipelineAnalystService, TimeAnalystService, PatternDetectorService — refactored to check `UserDefaults` for custom prompt overrides (new `buildSystemInstructions()` method pattern)
- ContentAdvisorService `analyze()` — added custom prompt override check
- Backward-compatible with existing `sam.ai.notePrompt`/`emailPrompt`/`messagePrompt` keys

**Access:**
- Settings → AI & Coaching → "Open Prompt Lab" button
- Debug menu → "Open Prompt Lab" (⇧⌘P)
- `.samOpenPromptLab` notification + AppShellView listener

**Workflow:**
1. Select a prompt site from the dropdown
2. Edit or use the provided sample input
3. Create variants (clone from default or blank)
4. Click "Run All" (⌘↩) to test all variants against the same input
5. Compare outputs side-by-side, rate each variant
6. Deploy winning variant as the active prompt via the column menu

No schema change.

---

## March 9, 2026 — Generative Reasoning Quality Test Suite

### Test Fixes

1. **Calendar evidence contaminating stale client tests** (`ScenarioHarnessTests.swift`): `buildCalendarEvents()` was cycling through all clients/agents for meeting attendees, including stale clients and the silent recruiting prospect. Upcoming future meetings (next 3 days) explicitly used `clients[0..2]` — the exact indices marked as stale — giving them `daysSince` values of 0, -1, -2 instead of 50+. Fixed by filtering out `staleClients` and `silentRecruitingProspect` from calendar event attendee selection.

2. **Missing `.linkedIn` in CommunicationChannel validation** (`ScenarioHarnessTests.swift`): `actionLaneClassification` test had a hardcoded `validChannels` set missing the `.linkedIn` case. Replaced with `Set(CommunicationChannel.allCases)` for future-proof validation.

### New Test Suite: Generative Reasoning Quality (16 tests)

Evaluates SAM's AI-powered recommendation and briefing pipelines using the existing `ScenarioDataGenerator` (~950 synthetic contacts, 5 years of evidence). Tests are structural quality evals — they verify output properties rather than exact text.

**Performance optimization**: Shared `GenerativeTestContext` singleton builds the scenario and runs outcome generation once (~3 min), then all 16 tests reuse the cached results (0s each). Total suite time: ~4.5 min (vs. ~45 min if rebuilt per-test).

**Outcome Engine tests (10)**:
- Engine completes successfully without errors
- All linked people exist in the scenario dataset (no hallucinated references)
- Scanner category coverage (preparation + outreach/followUp kinds present)
- Priority scores non-zero and in valid range [0, 1.5]
- Upcoming meetings generate preparation outcomes with linked people
- Archived/DNC/deceased contacts never receive outcomes
- Zero-engagement social imports (LinkedIn/Facebook noise) never receive outcomes
- Stale clients get outreach outcomes; recently active clients don't
- Double-generation doesn't create duplicate outcomes
- Outcome count reasonable (3–50) with no single kind >80%

**Briefing tests (4)**:
- Calendar items have valid titles and chronological dates
- Follow-up urgencies are from the valid set
- Recently active clients excluded from briefing follow-ups
- AI narrative length within bounds (visual: 100–2000 chars, TTS: 50–1000 chars)

**AI Narrative tests (1)**:
- Morning narrative references only names from input data (hallucination detection via capitalized word-pair extraction with common-phrase skip list)

**Classification tests (1)**:
- All outcomes have valid `ActionLane` and `CommunicationChannel` enum values

---

## March 7, 2026 — UI Polish, Backup Improvements & Role Suggestion UX

### Bug Fixes

1. **Onboarding stuck at Contact Access** (`OnboardingView.swift`): `advanceToNextActiveStep()` failed when the current step was marked ready (via `stepReadiness`) before advancing — the step was removed from `activeSteps`, so `firstIndex(of:)` returned nil. Added fallback logic using canonical step ordering. Same fix applied to `retreatToPreviousActiveStep()`.

2. **File > Restore Data blocked during onboarding** (`SAMApp.swift`): `.fileImporter` was only on `AppShellView`, blocked by the modal onboarding sheet. Added duplicate `.fileImporter` + confirmation alert on the onboarding sheet. Successful restore auto-dismisses onboarding.

3. **No refresh after backup restore** (`BackupCoordinator.swift`): Added `refreshAfterRestore()` — clears briefing/weekly date gates, prunes expired outcomes/undo entries, triggers OutcomeEngine generation, regenerates morning briefing, refreshes MeetingPrepCoordinator.

4. **Business profile not included in backup** (`BackupCoordinator.swift`): Added 7 missing UserDefaults keys to `includedPreferenceKeys`: `sam.businessProfile`, `sam.userLinkedInProfile`, `sam.userFacebookProfile`, `sam.userSubstackProfile`, `sam.profileAnalyses`, `sam.profileAnalysisSnapshot`, `sam.facebookAnalysisSnapshot`.

### People List View Improvements

5. **Navigation title shows filter ratio** (`PeopleListView.swift`): Title bar now shows "36 / 219 Selected" when filtering, "219 People" when unfiltered. Removed redundant "36 of 219" from inline filter chip row.

6. **Sort/filter moved inline** (`PeopleListView.swift`): Sort and Filter menus repositioned from window toolbar to inline controls above the list (`.menuStyle(.borderlessButton)`), keeping them near the content they control.

7. **Toolbar divider** (`PersonDetailView.swift`): Added `Divider()` toolbar item before detail view buttons to visually separate list and detail toolbar areas.

### Shared Role Filters (People List + Graph)

8. **Unified role filters** (`PeopleListView.swift`, `RelationshipGraphCoordinator.swift`): Role filters are now shared between People list and Graph via `RelationshipGraphCoordinator.shared.activeRoleFilters`. Filtering to "Clients" in the list and switching to Graph shows only clients, and vice versa.

9. **Special filters lifted to AppShellView** (`AppShellView.swift`, `PeopleListView.swift`): `activeSpecialFilters` moved from `@State` to `@Binding` owned by AppShellView, so filter state persists when switching between Contacts and Graph modes. Filters clear when navigating away from People via sidebar.

### Graph Toolbar Role Filter Display

10. **Colored role icons in graph toolbar** (`GraphToolbarView.swift`): Replaced generic blue number badge with up to 3 colored role icons (e.g., green dollar for Client, orange target for Lead) plus "+N" overflow. Dropdown items now show colored `checkmark.circle.fill` when active.

### Role Suggestion UX Overhaul

11. **Batch size reduced to 10** (`RoleDeductionEngine.swift`): Down from 12 for clearer review. Each batch remains single-role grouped.

12. **"Pending Role Suggestions" filter** (`PeopleListView.swift`): New special filter (sparkles icon) shows only people with pending role suggestions. Syncs to graph via `pendingSuggestionPersonIDs` on `RelationshipGraphCoordinator`.

13. **Role suggestion badge in PersonDetailView** (`PersonDetailView.swift`): Pulsing dashed-border badge appears in the role area for people with pending suggestions. Shows suggested role with inline Confirm (checkmark) and Dismiss (xmark) buttons.

14. **Remaining count on graph banner** (`RoleConfirmationBannerView.swift`): Shows "(N more to review)" after current batch.

15. **Filter menu logical grouping** (`PeopleListView.swift`): Three groups separated by dividers — Roles, Needs Attention (Pending Role Suggestions / Needs Contact Update / Not in Contacts), Excluded (Archived / DNC / Deceased). Attention and Excluded groups are mutually exclusive — selecting one auto-clears the other.

### Helper Methods

- `RoleDeductionEngine`: Added `suggestion(for:)`, `pendingPersonIDs`, `remainingAfterCurrentBatch`
- `RelationshipGraphCoordinator`: Added `pendingSuggestionPersonIDs` filter field
- `PeopleSpecialFilter`: Added `.attentionGroup` and `.excludedGroup` static sets

### Modified Files (10)

- `SAMApp.swift` — Onboarding fileImporter, restore during onboarding
- `BackupCoordinator.swift` — Post-restore refresh, business profile backup keys
- `OnboardingView.swift` — Step advancement fix with canonical ordering
- `AppShellView.swift` — Lifted `peopleSpecialFilters`, sidebar clear, PeopleListView binding
- `PeopleListView.swift` — Inline sort/filter, shared role filters, special filter groups, pending suggestions filter
- `PersonDetailView.swift` — Toolbar divider, RoleSuggestionBadge
- `RelationshipGraphCoordinator.swift` — `pendingSuggestionPersonIDs` filter
- `RoleDeductionEngine.swift` — Batch size 10, helper methods
- `GraphToolbarView.swift` — Colored role icons label, highlighted menu items
- `RoleConfirmationBannerView.swift` — Remaining count display

---

## March 6, 2026 — Priority 7: Onboarding, Helps & Tooltips Remediation

### Overview
Fixed bugs and gaps in onboarding, feature adoption coaching, and permission loss detection. Role confirmation walkthrough was already complete.

### Fixes
1. **Feature adoption dedup bug** (`OutcomeEngine.swift`): `scanFeatureAdoption()` used `hasSimilarOutcome(kind: .setup, personID: nil)` which blocked ALL feature coaching if ANY `.setup` outcome existed. Changed to title-based dedup via new `hasSimilarOutcome(title:)` overload.
2. **Missing coaching entries** (`FeatureAdoptionTracker.swift`): Added 3 `CoachingEntry` items for `postMeetingCapture` (day 2), `contentDraft` (day 3), and `deepWorkSchedule` (day 4) — these features had usage tracking but no coaching prompts.
3. **Communications state not persisted** (`OnboardingView.swift`): `saveSelections()` now sets `sam.comms.enabled` in UserDefaults when user grants iMessage/phone access during onboarding.
4. **Mail permission loss undetected** (`SAMApp.swift`): `checkIfPermissionsLost()` now checks mail automation permission (via `MailService.checkAccess()`) in addition to contacts and calendar.

### Files Changed
- `Repositories/OutcomeRepository.swift` — Added `hasSimilarOutcome(title:withinHours:)` overload
- `Coordinators/OutcomeEngine.swift` — Changed dedup from kind-based to title-based in `scanFeatureAdoption()`
- `Coordinators/FeatureAdoptionTracker.swift` — Added 3 coaching timeline entries
- `Models/DTOs/OnboardingView.swift` — Persist `sam.comms.enabled` in `saveSelections()`
- `App/SAMApp.swift` — Added mail to `checkIfPermissionsLost()`, included in early-return guard

---

## March 6, 2026 — Legacy Role Extraction via SQLite3

### Overview
When full SwiftData lightweight migration fails (schema too old), SAM can now extract role assignments directly from legacy stores using raw SQLite3 reads. This recovers the most valuable manually-entered data — contact role badges (Client, Lead, Agent, etc.) — even when the overall schema is incompatible. Contacts are matched by Apple Contacts identifier (primary) or display name (fallback).

### Files Changed
- `Services/LegacyStoreMigrationService.swift` — Added `import SQLite3`, `RoleExtractionResult` struct, `migrateRolesOnly()` public method, `extractAndApplyRoles(from:)` private method. Opens legacy `.store` file read-only via `sqlite3_open_v2`, queries `ZSAMPERSON` table for `ZCONTACTIDENTIFIER`, `ZROLEBADGES` (binary plist blob decoded via `NSKeyedUnarchiver` with `PropertyListSerialization` fallback), and `ZDISPLAYNAMECACHE`. Matches against current store by contactIdentifier then display name. Applies missing role badges and saves.
- `Views/Settings/SettingsView.swift` — Added "Import Roles Only..." button to Legacy Data section. When full migration fails with "schemas too old", shows hint text suggesting role-only import. Renamed "Migrate Data..." to "Migrate All Data..." for clarity.

---

## March 6, 2026 — Legacy Data Migration in Settings

### Overview
Added the missing "Legacy Data" section to Settings → General. The Today view banner directed users to this location when orphaned stores from previous SAM versions were detected, but the section had never been implemented (migration was only available via the Debug menu).

### Files Changed
- `Views/Settings/SettingsView.swift` — Added `legacyDataSection` to `GeneralSettingsView`, shown only when `LegacyStoreMigrationService` discovers orphaned stores. Displays store count, total size, most recent version. "Migrate Data..." button runs the backup round-trip migration. "Clean Up Old Files..." button with destructive confirmation alert. Progress/success/error status inline. Discovery runs on appear.

---

## March 6, 2026 — Intro Video Replacement

### Overview
Replaced the 6-slide narrated intro sequence with a single 2:39 intro video (`SAM_intro_video_hb.mp4`, 1260x720). The video provides a more polished and motivational first-launch experience while also giving SAM additional time to process initial data imports and compile the first briefing and recommendations in the background.

### Files Changed
- `Coordinators/IntroSequenceCoordinator.swift` — Removed slide system (6-case enum, NarrationService integration, fallback timers, slide progression, inter-slide delays). Simplified to video lifecycle: `showIntroSequence`, `videoFinished`, `checkAndShow()`, `videoDidFinish()`, `skip()`, `markComplete()`.
- `Views/Awareness/IntroSequenceOverlay.swift` — Replaced slide-based UI with AVPlayer video playback. `.AVPlayerItemDidPlayToEndTime` observer triggers "Get Started" button on completion. Skip button during playback. Window sized at 7:4 aspect ratio (882x504 ideal) matching the video.
- `Resources/SAM_intro.mp4` — Removed (superseded by the new video).
- `Resources/SAM_intro_video_hb.mp4` — New intro video (already present from prior commit).

---

## March 6, 2026 — File Menu Cleanup

### Overview
Reorganized the File menu to follow macOS Human Interface Guidelines and remove clutter. Removed non-functional "New" menu items for auxiliary windows (Quick Note, Clipboard Capture, Compose) that require programmatic context to function. Moved automatic import triggers (Contacts, Calendar, Mail, iMessage & Calls) to the Debug menu since SAM runs these automatically. Flattened the Import submenu into top-level items. Close remains in its standard HIG position between New and Import.

### File Menu (Before → After)
**Before:** New submenu (New Window, New Quick Note Window, New Clipboard Capture Window, New Compose Window), Close, Import submenu (7 items including auto-imports), Backup/Restore.

**After:** New Window (⌘N), Close (⌘W), Import Substack.../LinkedIn.../Facebook.../Evernote Notes..., Backup Data.../Restore Data...

### Files Changed
- `App/SAMApp.swift` — Added `.commandsRemoved()` to Quick Note, Clipboard Capture, and Compose WindowGroups. Flattened Import submenu to 4 top-level items (Substack, LinkedIn, Facebook, Evernote). Moved auto-import commands (Contacts, Calendar, Mail, iMessage & Calls) to Debug menu.

---

## March 6, 2026 — Intro Sequence Video + Narration Delay

### Overview
Added a short intro video (`SAM_intro.mp4`) to the welcome slide of the first-launch intro sequence. The video plays muted while SAM's speech narration plays simultaneously. Added a 1.5-second delay before narration begins on the welcome slide to let the video establish visually.

### Files Changed
- `Views/Awareness/IntroSequenceOverlay.swift` — Added `AVKit.VideoPlayer` for welcome slide (muted, auto-play, lifecycle-managed). Falls back to app icon if video not found.
- `Coordinators/IntroSequenceCoordinator.swift` — Extracted `beginNarration(for:)` method. Added 1.5s async delay before narration on welcome slide only, with pause/skip guards.
- `Resources/SAM_intro.mp4` — Bundled intro video (auto-included by Xcode).

---

## March 6, 2026 — Facebook Smart Auto-Detection Import Flow

### Overview
Applied the reusable auto-detection pipeline (§5.7) — third platform after Substack and LinkedIn — to Facebook imports. The old `File → Import → Import Facebook Archive...` menu item opened a raw NSOpenPanel with no guidance. The new `File → Import → Facebook...` opens a unified import sheet that handles the full lifecycle: scanning ~/Downloads for ZIP files, requesting a data export, watching for the export email, detecting the downloaded ZIP, parsing JSON files, reviewing matches, and importing.

### Sheet State Machine
`FacebookSheetPhase` enum with 12 cases: `.setup`, `.scanning`, `.zipFound(info)`, `.processing`, `.awaitingReview`, `.importing`, `.noZipFound`, `.watchingEmail`, `.emailFound(url)`, `.watchingFile`, `.complete(stats)`, `.failed(message)`.

### Files Changed

#### New File
- `Views/Settings/FacebookImportSheet.swift` — Full phase-driven import sheet (580px wide). Renders all 12 phases with appropriate UI: ZIP preview with confirm/decline, progress indicators, inline review content (reuses `FacebookReviewContent`), email/file watcher status, completion summary with delete-ZIP toggle. Uses `.fileImporter` for manual ZIP selection as fallback.

#### Coordinator
- `Coordinators/FacebookImportCoordinator.swift` — Added `FacebookSheetPhase` enum, `FacebookZipInfo` struct, `FacebookImportStats` struct. New observable state (`sheetPhase`, `importedZipURL`). Watcher infrastructure: `emailPollingTimer`/`filePollingTimer`, UserDefaults-backed persistence (`sam.facebook.emailWatcherActive`, `emailWatcherStartDate`, `fileWatcherActive`, `fileWatcherStartDate`, `extractedDownloadURL`). New methods: `beginImportFlow()`, `scanDownloadsFolder()`, `processZip()`, `openFacebookExportPage()`, email/file watcher start/stop/poll, `scheduleReminder()`, `resumeWatchersIfNeeded()`, `deleteSourceZip()`, `cancelWatchers()`, `cancelAll()`, `completeImportFromSheet()`, `isMailAvailableForWatching`. Added `configure(container:)` method. Added sheetPhase transitions to `importFromZip()`, `loadFolder()`, and `confirmImport()`.

#### Review Refactor
- `Views/Settings/FacebookImportReviewSheet.swift` — Extracted three-section review UI (probable matches, recommended to add, no interaction) into reusable `FacebookReviewContent` view. Made `FacebookProbableMatchRow`, `FacebookCandidateRow` internal (was private) for cross-file reuse. `FacebookImportReviewSheet` simplified to wrapper.

#### System Notifications
- `Services/SystemNotificationService.swift` — Added `FACEBOOK_EXPORT` notification category with "Open Download Page" (foreground, opens URL + starts file watcher) and "Remind Me Later" (triggers calendar-gap-aware rescheduling) actions. New `postFacebookExportReady(downloadURL:triggerDate:)` method. Delegate handling for both action buttons and default tap.

#### App Integration
- `App/SAMApp.swift` — Renamed menu "Import Facebook Archive..." → "Import Facebook...". Replaced `importFacebookArchive()` file picker with `showFacebookImportSheet` state + `.sheet` presenter. Added `.samFacebookZipDetected` notification listener to auto-present sheet. Changed `.samFacebookAwaitingReview` to route to new sheet. Added `FacebookImportCoordinator.shared.configure(container:)` to `configureDataLayer()`, `cancelAll()` to termination handler, watcher UserDefaults keys to `clearAllData()`.

#### Settings Cleanup
- `Views/Settings/FacebookImportSettingsView.swift` — Removed step-by-step import instructions, folder picker, preview/status sections, stale import warning, and unused state. Kept: profile analysis section, writing voice summary, last import info, error display.
- `Views/Settings/SettingsView.swift` — Added `.help("Use File → Import → Facebook to configure")` to Facebook ImportStatusDashboard row.
- `Models/SAMModels.swift` — Added `.samFacebookZipDetected` notification name.

### Key Differences from LinkedIn
- **No Apple Contacts sync** — Facebook doesn't write URLs to Apple Contacts
- **JSON format** — Facebook exports use JSON files, not CSVs
- **48-hour export wait** — Facebook exports take up to 48 hours (vs LinkedIn's 24 hours)
- **Email patterns** — Watches for `facebook.com`/`facebookmail.com` senders with download/ready/export subjects
- **Cross-platform analysis** — Facebook has `runCrossPlatformAnalysis()` that compares with LinkedIn (runs as background task after import, not surfaced in the sheet)

### Architecture Notes
- **Third §5.7 implementation**: Further validates the reusable pattern (state machine, watcher persistence, notification categories). All three platforms share identical architectures.
- **No schema version bump** — all new state is in UserDefaults and coordinator observable properties.
- **Watcher persistence**: Email and file watchers survive app restart via `resumeWatchersIfNeeded()` called from `configure(container:)`.

---

## March 6, 2026 — LinkedIn Smart Auto-Detection Import Flow

### Overview
Applied the reusable auto-detection pipeline (§5.7) — first implemented for Substack — to LinkedIn imports. The old `File → Import → Import LinkedIn Archive...` menu item opened a raw NSOpenPanel with no guidance. The new `File → Import → LinkedIn...` opens a unified import sheet that handles the full lifecycle: scanning ~/Downloads for ZIP files, requesting a data export, watching for the export email, detecting the downloaded ZIP, parsing, reviewing matches, and importing.

### Sheet State Machine
`LinkedInSheetPhase` enum with 12 cases: `.setup`, `.scanning`, `.zipFound(info)`, `.processing`, `.awaitingReview`, `.importing`, `.noZipFound`, `.watchingEmail`, `.emailFound(url)`, `.watchingFile`, `.complete(stats)`, `.failed(message)`.

### Files Changed

#### New File
- `Views/Settings/LinkedInImportSheet.swift` — Full phase-driven import sheet (580px wide). Renders all 12 phases with appropriate UI: ZIP preview with confirm/decline, progress indicators, inline review content (reuses `LinkedInReviewContent`), email/file watcher status, completion summary with Apple Contacts sync prompt and delete-ZIP toggle. Uses `.fileImporter` for manual ZIP selection as fallback.

#### Coordinator
- `Coordinators/LinkedInImportCoordinator.swift` — Added `LinkedInSheetPhase` enum, `LinkedInZipInfo` struct, `LinkedInImportStats` struct. New observable state (`sheetPhase`, `importedZipURL`). Watcher infrastructure: `emailPollingTimer`/`filePollingTimer`, UserDefaults-backed persistence (`sam.linkedin.emailWatcherActive`, `emailWatcherStartDate`, `fileWatcherActive`, `fileWatcherStartDate`, `extractedDownloadURL`). New methods: `beginImportFlow()`, `scanDownloadsFolder()`, `processZip()`, `openLinkedInExportPage()`, email/file watcher start/stop/poll, `scheduleReminder()`, `resumeWatchersIfNeeded()`, `deleteSourceZip()`, `cancelWatchers()`, `cancelAll()`, `completeImportFromSheet()`, `isMailAvailableForWatching`. Relaxed `importFromZip` prefix validation to accept both `Complete_` and `Basic_` prefixes. Added `configure(container:)` method.

#### Review Refactor
- `Views/Settings/LinkedInImportReviewSheet.swift` — Extracted three-section review UI (probable matches, recommended to add, no interaction) into reusable `LinkedInReviewContent` view. Made `ProbableMatchRow`, `CandidateRow`, `AppleContactsSyncConfirmationSheet` internal (was private) for cross-file reuse. `LinkedInImportReviewSheet` simplified to wrapper.

#### System Notifications
- `Services/SystemNotificationService.swift` — Added `LINKEDIN_EXPORT` notification category with "Open Download Page" (foreground, opens URL + starts file watcher) and "Remind Me Later" (triggers calendar-gap-aware rescheduling) actions. New `postLinkedInExportReady(downloadURL:triggerDate:)` method. Delegate handling for both action buttons and default tap.

#### App Integration
- `App/SAMApp.swift` — Renamed menu "Import LinkedIn Archive..." → "Import LinkedIn...". Replaced `importLinkedInArchive()` file picker with `showLinkedInImportSheet` state + `.sheet` presenter. Added `.samLinkedInZipDetected` notification listener to auto-present sheet. Changed `.samLinkedInAwaitingReview` to route to new sheet. Added `LinkedInImportCoordinator.shared.configure(container:)` to `configureDataLayer()`, `cancelAll()` to termination handler, watcher UserDefaults keys to `clearAllData()`.

#### Settings Cleanup
- `Views/Settings/LinkedInImportSettingsView.swift` — Removed step-by-step import instructions, folder picker, preview/status sections, and unused state. Kept: auto-sync Apple Contacts toggle, profile analysis section, writing voice summary, watermark info.
- `Views/Settings/SettingsView.swift` — Added `.help("Use File → Import → LinkedIn to configure")` to LinkedIn ImportStatusDashboard row.
- `Models/SAMModels.swift` — Added `.samLinkedInZipDetected` notification name.

### Architecture Notes
- **Second §5.7 implementation**: Validates the reusable pattern (state machine, watcher persistence, notification categories) established by Substack. LinkedIn adds inline review content (absent in Substack) and ZIP auto-detection from ~/Downloads.
- **No schema version bump** — all new state is in UserDefaults and coordinator observable properties.
- **Watcher persistence**: Email and file watchers survive app restart via `resumeWatchersIfNeeded()` called from `configure(container:)`.

---

## March 5, 2026 — AI Family Inference, Anniversary Enrichment & Duplicate Prevention

### Overview
Added an AI-powered family inference service that analyzes connected family clusters after deduced relationship confirmations to infer transitive relationships (shared children, siblings, in-laws) and propagate anniversary dates between spouses. New relationships are created as unconfirmed DeducedRelations for user review. Added the ability to reject incorrect deduced relations (persisted to prevent re-creation). Fixed duplicate Me contact creation caused by Apple Contacts returning different unified identifiers for group vs. Me card fetches. Also fixed parent/father duplicate deduced relations and a missing SF Symbol.

### What Changed
- **FamilyInferenceService** (new) — Actor singleton following specialist service pattern. After a deduced relationship is confirmed, gathers the connected family cluster via BFS walk, fetches people + contact data (birthday, anniversary), sends focused prompt to AIService, parses JSON response, creates unconfirmed DeducedRelations and queues anniversary PendingEnrichments. Posts `.samDeducedRelationsDidChange` notification.
- **ContactDTO** — Added `DateDTO` nested struct and `dates: [DateDTO]` field. `CNContactDatesKey` added to `.detail` and `.full` KeySets. Parses anniversary and other date labels from `CNContact.dates`.
- **EnrichmentField** — Added `.anniversary` case with "Anniversary" display name.
- **ContactsService** — `.anniversary` handler in `updateContact()` writes `CNLabelDateAnniversary` to Apple Contact dates. `CNContactDatesKey` added to fetch keys.
- **DeducedRelation** — Added `isRejectedValue: Bool?` stored property with `@Transient isRejected` computed accessor (defaults `false`). Nullable for lightweight migration compatibility.
- **DeducedRelationRepository** — `reject(id:)` marks relation as rejected, clears confirmed. `upsert()` skips rejected pairs and checks complementary types (parent↔child). `fetchUnconfirmed()` excludes rejected. `isMoreSpecificLabel()` keeps "father" over "parent".
- **RelationshipGraphCoordinator** — Triggers `FamilyInferenceService.inferFromCluster()` after single and batch confirms. `rejectDeducedRelation(id:)` method. Notification listener for `.samDeducedRelationsDidChange` refreshes unconfirmed count. `gatherDeducedFamilyLinks()` filters rejected relations.
- **RelationshipGraphView** — Edge context menu now appears on all deduced family edges (confirmed + unconfirmed). Added "Reject" option (destructive role). Confirm shown only for unconfirmed edges.
- **EnrichmentReviewSheet** — `.anniversary` items formatted as human-readable dates via `formatAnniversaryDate()`.
- **PeopleRepository** — New `setMeFlag(contactIdentifier:)` for lightweight isMe assignment. `upsertMe()` now falls back to name+email matching when contactIdentifier differs, updates contactIdentifier on fallback match.
- **ContactsImportCoordinator** — Checks if Me contact identifier was already in group import; uses `setMeFlag()` instead of `upsertMe()` to prevent duplicate creation.
- **BackupDocument/BackupCoordinator** — `isRejected` field added to DeducedRelationBackup (optional for backward compat).
- **MinionsView** — Replaced invalid `chess.queen` SF Symbol with `chart.bar.xaxis.ascending`.
- **SAMModels** — Added `.samDeducedRelationsDidChange` notification name.

### Files
| File | Action |
|------|--------|
| `Services/FamilyInferenceService.swift` | New — AI family cluster inference actor |
| `Models/DTOs/ContactDTO.swift` | Modified — DateDTO, dates field, CNContactDatesKey |
| `Models/SAMModels-Enrichment.swift` | Modified — .anniversary enum case |
| `Models/SAMModels.swift` | Modified — DeducedRelation.isRejectedValue, notification |
| `Services/ContactsService.swift` | Modified — .anniversary write handler, CNContactDatesKey in fetch keys |
| `Repositories/DeducedRelationRepository.swift` | Modified — reject(), complementary type dedup, specific label preference |
| `Coordinators/RelationshipGraphCoordinator.swift` | Modified — inference triggers, reject method, notification listener |
| `Views/Business/RelationshipGraphView.swift` | Modified — edge context menu for all deduced edges, reject option |
| `Views/People/EnrichmentReviewSheet.swift` | Modified — anniversary date formatting |
| `Repositories/PeopleRepository.swift` | Modified — setMeFlag(), upsertMe() name+email fallback |
| `Coordinators/ContactsImportCoordinator.swift` | Modified — Me contact duplicate prevention |
| `Models/BackupDocument.swift` | Modified — isRejected field |
| `Coordinators/BackupCoordinator.swift` | Modified — isRejected export/import |
| `Views/Components/MinionsView.swift` | Modified — SF Symbol fix |

### Architecture Notes
- FamilyInferenceService uses `@MainActor static` helpers for SwiftData/Contacts access, sends `Sendable` DTOs to actor for prompt formatting, then dispatches `@MainActor static processResponse()` for writes.
- `DeducedRelation.isRejectedValue` is `Bool?` (nullable) to enable lightweight CoreData migration. The `@Transient isRejected` computed property defaults nil to false.
- Me contact duplication root cause: Apple's `unifiedMeContactWithKeys` can return a different unified identifier than `unifiedContacts(matching: groupPredicate)` for the same underlying person.

---

## March 5, 2026 — Enhanced Post-Meeting/Call Capture with Guided Q&A

### Overview
Rewrote the post-meeting/call note capture experience with a dual-mode guided+freeform interface. Meetings and calls now use the same structured capture sheet with attendee identification (names + role badges), attendance confirmation, step-by-step guided Q&A drawing on briefing data (talking points, pending actions, life events), and automatic dictation polish via on-device LLM. Fixed time calculation bug ("1 hour since it ended" for meetings that ended minutes ago) and connected FollowUpCoachSection to the new capture sheet. No schema change.

### What Changed
- **CapturePayload + CaptureAttendeeInfo** (new DTOs, replacing `PostMeetingPayload`) — Rich payload with captureKind (meeting/call), attendee info (name, role badges, pending actions, recent life events), talking points, open action items, evidence ID
- **PostMeetingCaptureView** — Complete rewrite: dual-mode Guided/Freeform picker in header; attendee badges shown for both modes; Guided mode: 7-step Q&A (attendance → main outcome → talking points → pending actions → action items → follow-up → life events) with progress bar, Back/Next/Skip navigation, contextual reminders from briefing data; Freeform mode: enhanced 4-section layout with contextual placeholders; mode switching maps guided answers into freeform fields; unified for meetings and calls; auto-polish after dictation stops
- **DailyBriefingCoordinator** — `createMeetingNoteTemplate()` now looks up `MeetingBriefing` from `MeetingPrepCoordinator.shared.briefings` to build `CapturePayload` with talking points and attendee profiles; `checkRecentlyEndedCalls()` switched from `QuickNotePayload`/`.samOpenQuickNote` to `CapturePayload(.call)`/`.samOpenPostMeetingCapture`
- **AppShellView** — `postMeetingPayload: PostMeetingPayload?` → `capturePayload: CapturePayload?`; notification handler extracts `CapturePayload` from `userInfo["payload"]`; sheet passes `payload:` to `PostMeetingCaptureView`
- **OutcomeEngine** — Fixed `scanPastMeetingsWithoutNotes()` time calculation: replaced `max(1, Int(hours))` with minute-granularity ("Just ended" / "X minutes" / "X hours"); improved title, rationale, and suggestedNextStep text
- **FollowUpCoachSection** — "Capture Notes" button now opens the structured capture sheet (builds `CapturePayload` from `FollowUpPrompt` and posts `.samOpenPostMeetingCapture`) instead of showing inline `InlineNoteCaptureView`
- **NoteAnalysisService** — `polishDictation()` prompt enhanced with misheard number/dollar correction (e.g. "the hundred adn twenty thousand dollar option" → "the $120,000 option"); applies globally to all dictation polish

### Files
| File | Action |
|------|--------|
| `Views/Awareness/PostMeetingCaptureView.swift` | Rewritten — CapturePayload DTOs, dual-mode guided+freeform, attendance confirmation, contextual prompts, auto-polish |
| `Coordinators/DailyBriefingCoordinator.swift` | Modified — briefing-enriched CapturePayload for meetings, CapturePayload for calls |
| `Views/AppShellView.swift` | Modified — CapturePayload type, notification handler |
| `Coordinators/OutcomeEngine.swift` | Modified — fixed time calculation, improved outcome text |
| `Views/Awareness/FollowUpCoachSection.swift` | Modified — opens capture sheet instead of inline note |
| `Services/NoteAnalysisService.swift` | Modified — number correction in polish prompt |
| `1_Documentation/changelog.md` | Modified — this entry |

---

## March 5, 2026 — Unknown Sender Auto-Match & Meeting Prep Notifications

### Overview
Unknown senders whose Apple Contacts are already in the SAM group are now auto-linked without user intervention. External contacts (in Apple Contacts but not SAM group) surface a confirmation sheet. Meeting briefing notifications now include a "View Briefing" action that expands the meeting prep section in the Today view. Import coordinators refactored for unified contact-matching patterns.

### What Changed
- **UnknownSenderTriageSection** — `TriageMatchCandidate` confirmation flow: auto-links senders whose contacts are already in SAM group, queues external contacts for user confirmation via new sheet
- **SystemNotificationService** — `MEETING_PREP` notification category with "View Briefing" action posting `samExpandMeetingPrep`
- **AwarenessView** — Listener for `samExpandMeetingPrep` to expand "More" section and reveal MeetingPrepSection
- **SAMModels** — `samExpandMeetingPrep` notification name
- **ContactsService** — `isContactInSAMGroup()` method for unknown sender triage
- **EvidenceRepository** — Bulk-link matched contacts to messages/calls by person identifier
- **PeopleRepository** — Lookup and filtering methods for deduplication/matching workflows
- **NotInContactsCapsule** — Match status badge, "Add to SAM" / "Create Contact" action buttons
- **PersonDetailView** — Contact match status display, conditional contact creation buttons, role deduction UI
- **Import coordinators** (Calendar, Communications, Facebook, Mail, Substack) — Refactored to unified contact-matching and SAM group checking patterns
- **CoachingSettingsView** — Settings for notification preferences

### Files
| File | Action |
|------|--------|
| `Views/Awareness/UnknownSenderTriageSection.swift` | Modified — auto-match + confirmation flow |
| `Services/SystemNotificationService.swift` | Modified — meeting prep notification category |
| `Views/Awareness/AwarenessView.swift` | Modified — meeting prep expand listener |
| `Models/SAMModels.swift` | Modified — notification name |
| `Models/SAMModels-Enrichment.swift` | Modified — match resolution types |
| `Services/ContactsService.swift` | Modified — SAM group membership check |
| `Repositories/EvidenceRepository.swift` | Modified — bulk contact linking |
| `Repositories/PeopleRepository.swift` | Modified — matching helpers |
| `Views/Shared/NotInContactsCapsule.swift` | Modified — match status UI |
| `Views/People/PersonDetailView.swift` | Modified — contact status + role deduction |
| `Coordinators/CalendarImportCoordinator.swift` | Modified — unified matching |
| `Coordinators/CommunicationsImportCoordinator.swift` | Modified — unified matching |
| `Coordinators/FacebookImportCoordinator.swift` | Modified — unified matching |
| `Coordinators/MailImportCoordinator.swift` | Modified — unified matching |
| `Coordinators/SubstackImportCoordinator.swift` | Modified — unified matching |
| `Views/Settings/CoachingSettingsView.swift` | Modified — notification settings |
| `Views/Settings/SettingsView.swift` | Modified — settings layout |
| `Models/DTOs/OnboardingView.swift` | Modified — onboarding updates |
| `Info.plist` | Modified — notification configuration |
| `1_Documentation/context.md` | Modified — onboarding guidance |

---

## March 5, 2026 — Evidence-Gated Social Profile Buttons

### Overview
Social profile buttons in PersonDetailView's quickActionsRow now only appear when there is actual interaction evidence for that channel. Previously, the LinkedIn button checked only for a profile URL; now it requires `.linkedIn` evidence in `person.linkedEvidence`. Facebook button added with the same gate (`.facebook` evidence required). A generic `ComposeService.openSocialProfile(url:)` opens non-LinkedIn social profiles in the browser. No schema change.

### What Changed
- **PersonDetailView** — Replaced `resolvedLinkedInURL` with `SocialAction` struct + `evidenceBackedSocialActions` computed property; added `contactLinkedInURL`/`contactFacebookURL` helpers (resolve from Apple Contacts `socialProfiles` as fallback); `quickActionsRow` uses `ForEach` over evidence-backed actions between Email and Add Note buttons
- **ComposeService** — Added `openSocialProfile(url:)` for generic social URL opening; LinkedIn continues to use `openLinkedInMessaging()` (messaging overlay deep-link)

### Files
| File | Action |
|------|--------|
| `Views/People/PersonDetailView.swift` | Modified — evidence-gated social buttons |
| `Services/ComposeService.swift` | Modified — `openSocialProfile(url:)` |
| `1_Documentation/changelog.md` | Modified — this entry |

---

## March 5, 2026 — Message-Category-Aware Channel Preferences

### Overview
Channel preferences are now per-message-category (quick/detailed/social) instead of a single global preference per person. Each outcome carries a message category that drives channel selection. Companion outcomes provide heads-up notifications on alternate channels. Schema SAM_v34.

### What Changed
- **MessageCategory** enum (quick/detailed/social) with display names, icons
- **ContactAddresses** struct — carries email/phone/linkedInProfileURL, resolves address per channel, reports available channels
- **SamPerson** — 6 new fields: `preferred{Quick,Detailed,Social}ChannelRawValue`, `inferred{Quick,Detailed,Social}ChannelRawValue`; `effectiveChannel(for:)` resolves with priority cascade; `contactAddresses` transient property
- **SamOutcome** — `messageCategoryRawValue`, `companionOfID`, `isCompanionOutcome` fields; `messageCategory` transient
- **ComposePayload** — `linkedInProfileURL` + `contactAddresses` fields
- **ComposeWindowView** — Channel switching via ContactAddresses, LinkedIn send action
- **OutcomeEngine** — Category-aware `suggestChannel()`, companion outcome generation
- **MeetingPrepCoordinator** — Per-category channel inference from evidence patterns
- **PersonDetailView** — 3-picker UI for per-category channel preferences, Text button in quickActionsRow
- **OutcomeCardView** — Companion outcome indicator
- **Backup** — BackupDocument + BackupCoordinator updated for new fields

### Files
| File | Action |
|------|--------|
| `Models/SAMModels-Supporting.swift` | Modified — MessageCategory, ContactAddresses, ComposePayload |
| `Models/SAMModels.swift` | Modified — per-category fields on SamPerson + SamOutcome |
| `Models/SAMModels-Undo.swift` | Modified — undo snapshot for new fields |
| `Models/BackupDocument.swift` | Modified — backup DTOs |
| `App/SAMModelContainer.swift` | Modified — schema SAM_v34 |
| `Coordinators/OutcomeEngine.swift` | Modified — category-aware channel + companions |
| `Coordinators/MeetingPrepCoordinator.swift` | Modified — per-category inference |
| `Coordinators/BackupCoordinator.swift` | Modified — backup/restore new fields |
| `Repositories/PeopleRepository.swift` | Modified — per-category channel helpers |
| `Repositories/UndoRepository.swift` | Modified — undo for new fields |
| `Services/ComposeService.swift` | Modified — openLinkedInMessaging |
| `Views/Communication/ComposeWindowView.swift` | Modified — channel switching, LinkedIn send |
| `Views/Awareness/OutcomeQueueView.swift` | Modified — LinkedIn routing + payload |
| `Views/Awareness/LifeEventsSection.swift` | Modified — linkedInProfileURL in payload |
| `Views/People/PersonDetailView.swift` | Modified — 3-picker UI, Text button |
| `Views/Shared/OutcomeCardView.swift` | Modified — companion indicator |
| `1_Documentation/context.md` | Modified — schema v32-v34, priority 4 complete |
| `1_Documentation/changelog.md` | Modified — this entry |

---

## March 5, 2026 — LinkedIn as Reply Channel (Priority 4)

### Overview
LinkedIn upgraded from a clipboard-only dead-end to a first-class reply channel in ComposeWindowView. When a person has a `linkedInProfileURL`, LinkedIn appears in the channel picker, the send button reads "Copy & Open LinkedIn", and clicking it copies the draft to clipboard then opens the LinkedIn messaging overlay in the browser. No schema change.

### What Changed
- **ComposePayload.linkedInProfileURL** — New `String?` field (default `nil`); all existing call sites unchanged
- **ComposeService.openLinkedInMessaging(profileURL:)** — Normalizes URL, appends `/overlay/new-message/`, opens in default browser; falls back to profile page if overlay URL fails
- **ComposeWindowView** — LinkedIn in `availableChannels` when `payload.linkedInProfileURL != nil`; LinkedIn send action copies draft + opens messaging; button label "Copy & Open LinkedIn" when LinkedIn selected
- **OutcomeQueueView** — `.communicate` action lane routes LinkedIn address from `person.linkedInProfileURL` instead of email/phone; passes `linkedInProfileURL` in ComposePayload
- **LifeEventsSection** — Passes `person?.linkedInProfileURL` in ComposePayload

### Files
| File | Action |
|------|--------|
| `Models/SAMModels-Supporting.swift` | Modified — `linkedInProfileURL` on ComposePayload |
| `Services/ComposeService.swift` | Modified — `openLinkedInMessaging()` |
| `Views/Communication/ComposeWindowView.swift` | Modified — channel picker, send action, button label |
| `Views/Awareness/OutcomeQueueView.swift` | Modified — LinkedIn address routing + payload |
| `Views/Awareness/LifeEventsSection.swift` | Modified — pass linkedInProfileURL |
| `1_Documentation/context.md` | Modified — Priority 4 marked complete |
| `1_Documentation/changelog.md` | Modified — this entry |

---

## March 5, 2026 — Global Clipboard Capture Hotkey (Priority 3)

### Overview
Copy a conversation from any app (LinkedIn DMs, WhatsApp, Slack, Teams, etc.), press ⌃⇧V, and SAM opens a capture window that uses AI to parse the conversation structure, lets the user match senders to contacts, and saves the result as evidence. No schema change.

### What Changed
- **EvidenceSource.clipboardCapture** — New case (`qualityWeight: 1.5`, `isInteraction: true`, `iconName: "doc.on.clipboard"`); all exhaustive switches updated (MeetingPrepSection, MeetingPrepCoordinator, SearchResultRow, InboxDetailView, InboxListView, PersonDetailView)
- **GlobalHotkeyService** — `@MainActor @Observable` singleton; registers global ⌃⇧V via `NSEvent.addGlobalMonitorForEvents`; Accessibility permission via `AXIsProcessTrusted`; UserDefaults toggle `sam.clipboardCapture.enabled`
- **ClipboardParsingService** — Actor; reads `NSPasteboard.general`; AI prompt extracts conversation structure (platform, senders, timestamps, messages); returns `ClipboardConversationDTO` / `ClipboardMessageDTO`
- **ClipboardCapturePayload** — Codable/Hashable/Sendable DTO for WindowGroup routing
- **ClipboardCaptureWindowView** — Four-phase auxiliary window (parsing → review → saving → error); inline person picker with autocomplete via `PeopleRepository.search()`; auto-detects "Me" sender; groups messages by matched person; analyzes via `MessageAnalysisService.analyzeConversation()`; creates evidence via `EvidenceRepository.createByIDs()`; "Save as Note" fallback; raw text discarded after analysis
- **SAMApp** — New `WindowGroup("Clipboard Capture")`, hotkey registration in `applicationDidFinishLaunching`, unregistration in `applicationShouldTerminate`, menu command `Edit > Capture Clipboard Conversation (⌃⇧V)`
- **AppShellView** — `.samOpenClipboardCapture` notification handler opens capture window
- **ClipboardCaptureSettingsContent** — DisclosureGroup in AI Settings tab; enable/disable toggle; Accessibility permission status with "Open System Settings" button
- **.samOpenClipboardCapture** notification name added to `SAMModels.swift`

### Files
| File | Action |
|------|--------|
| `Models/SAMModels-Supporting.swift` | Modified — `.clipboardCapture` case + all switch arms |
| `Models/SAMModels.swift` | Modified — `.samOpenClipboardCapture` notification |
| `Services/GlobalHotkeyService.swift` | New |
| `Services/ClipboardParsingService.swift` | New |
| `Models/DTOs/ClipboardCapturePayload.swift` | New |
| `Views/Communication/ClipboardCaptureWindowView.swift` | New |
| `App/SAMApp.swift` | Modified — WindowGroup + hotkey + menu |
| `Views/AppShellView.swift` | Modified — notification handler |
| `Views/Settings/SettingsView.swift` | Modified — settings section |
| `Views/Awareness/MeetingPrepSection.swift` | Modified — switch case |
| `Coordinators/MeetingPrepCoordinator.swift` | Modified — switch case |
| `Views/Search/SearchResultRow.swift` | Modified — switch cases |
| `Views/Inbox/InboxDetailView.swift` | Modified — switch cases |
| `Views/Inbox/InboxListView.swift` | Modified — switch cases |
| `Views/People/PersonDetailView.swift` | Modified — switch case |

---

## March 4, 2026 — Voice Analysis Across All Social Platforms

### Overview
Extended the Substack voice-matching system to LinkedIn and Facebook, and generalized the draft generation voice injection for all platforms. No schema change.

### What Changed
- **UserLinkedInProfileDTO** — Added `writingVoiceSummary` and `recentShareSnippets` fields; voice summary included in `coachingContextFragment()`
- **ProfileAnalysisSnapshot** — Added `voiceShareSnippets: [String]?` (full-length share text for voice re-analysis without re-import)
- **LinkedInImportCoordinator** — Runs `analyzeWritingVoice(shares:)` during import and during re-analysis (using stored snapshot snippets when shares unavailable)
- **FacebookPostDTO** — New Sendable value type for parsed user posts
- **FacebookService.parsePosts(in:)** — Parses `your_facebook_activity/posts/your_posts__check_ins__photos_and_videos_1.json`
- **UserFacebookProfileDTO** — Added `Codable` conformance to all nested types, added `writingVoiceSummary` and `recentPostSnippets` fields
- **BusinessProfileService** — `saveFacebookProfile()` now stores full JSON (was string-only); new `facebookProfile()` method; legacy string fallback preserved
- **FacebookImportCoordinator** — Parses posts in `loadFolder` (Step 5b), runs `analyzeWritingVoice(posts:)` before saving profile in `confirmImport` (Step 9)
- **FacebookAnalysisSnapshot** — Added `postCount`, `recentPostSnippets`, `writingVoiceSummary` for re-analysis support
- **ContentAdvisorService** — Replaced Substack-specific `substackVoiceBlock` with universal `buildVoiceBlock(for:)` that works across all platforms with cross-platform fallback (Substack > LinkedIn > Facebook)
- **LinkedInService** — Fixed date parsing in `parseShares`, `parseReactionsGiven`, `parseCommentsGiven`, `parseInvitations`, `parseRecommendationsReceived`: LinkedIn Complete exports use `yyyy-MM-dd HH:mm:ss` format, not ISO 8601 — added fallback `DateFormatter` so rows are no longer silently skipped
- **LinkedInImportSettingsView** — Added Writing Voice display section with Refresh button
- **FacebookImportSettingsView** — Added Writing Voice display section with Refresh button and post sample count; added post count row in import preview
- **context.md** — Added §5.6 Voice Analysis standard, updated §5.5 Adding a New Platform checklist

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

---

## Message-Category-Aware Channel Preferences + Companion Outcomes (March 5, 2026)

**Schema**: SAM_v33 → SAM_v34

### What Changed

SAM now understands that different *types* of messages should go through different channels. Quick check-ins route to iMessage, formal proposals to email, professional networking to LinkedIn — all configurable per person per category.

### New Types

- **`MessageCategory`** enum (`.quick`, `.detailed`, `.social`) — classifies communication intent for channel routing
- **`ContactAddresses`** struct — carries all known addresses (email, phone, LinkedIn) for channel switching in compose flows
- **`OutcomeKind.messageCategory`** computed property — deterministic mapping from outcome kind to message category

### SamPerson Changes (6 new optional fields)

- `preferredQuickChannelRawValue`, `preferredDetailedChannelRawValue`, `preferredSocialChannelRawValue` — explicit per-category preferences
- `inferredQuickChannelRawValue`, `inferredDetailedChannelRawValue`, `inferredSocialChannelRawValue` — evidence-based inference
- `effectiveChannel(for: MessageCategory)` method — cascading resolution: explicit per-category → inferred per-category → general preference
- `contactAddresses` computed property — aggregates email, phone, LinkedIn for compose flows

### SamOutcome Changes (3 new fields)

- `messageCategoryRawValue` — resolved message category stored on outcome
- `companionOfID: UUID?` — links heads-up companion to primary outcome
- `isCompanionOutcome: Bool` — prevents companion recursion

### OutcomeEngine Enhancements

- `suggestChannel(for:)` — now resolves MessageCategory from OutcomeKind + title keyword overrides, uses `person.effectiveChannel(for: category)` with category defaults (quick→iMessage, detailed→email, social→LinkedIn)
- `maybeCreateCompanionOutcome(for:)` — generates "heads-up" text outcomes when a detailed outcome's channel differs from the person's quick channel
- `generateDraftMessage(for:)` — category-aware tone refinement (quick → 2-3 sentences, detailed → 2-4 paragraphs, social → networking tone)

### MeetingPrepCoordinator

- `inferChannelPreference(for:)` extended with per-category score maps: iMessage/phone evidence → quick, mail/FaceTime → detailed, LinkedIn → social

### PersonDetailView

- **3-picker Communication Preferences**: Quick/Detailed/Social rows with Auto + all channels, inferred hint when no explicit preference
- **Text button** added to quickActionsRow (before Call) — opens Messages via `sms:` URL scheme

### ComposeWindowView

- `resolvedRecipient` computed property uses `contactAddresses` when available for correct per-channel address resolution
- `availableChannels` prefers `contactAddresses.availableChannels` over string-parsing fallback
- `sendViaSystemApp()` and `sendDirectly()` use `resolvedRecipient`
- LinkedIn resolution uses `contactAddresses?.linkedInProfileURL` with fallback

### ComposePayload Call Sites

- OutcomeQueueView and LifeEventsSection now pass `contactAddresses: person?.contactAddresses`

### OutcomeCardView

- Companion indicator ("Heads-up companion" with link icon) displayed for companion outcomes

### Backup & Undo

- PersonBackup, PersonMergeSnapshot, PeopleRepository merge/snapshot, UndoRepository restore all updated with 6 new fields

### Files Summary

| File | Action |
|------|--------|
| `Models/SAMModels-Supporting.swift` | MessageCategory, ContactAddresses, ComposePayload update |
| `Models/SAMModels.swift` | SamPerson 6 fields + helpers; SamOutcome 3 fields |
| `Models/SAMModels-Undo.swift` | PersonMergeSnapshot 6 new fields |
| `Models/BackupDocument.swift` | PersonBackup 6 new fields |
| `App/SAMModelContainer.swift` | Schema SAM_v33 → SAM_v34 |
| `Coordinators/OutcomeEngine.swift` | Category-aware suggestChannel, companions, draft tone |
| `Coordinators/MeetingPrepCoordinator.swift` | Per-category inference |
| `Coordinators/BackupCoordinator.swift` | Export/import/validate new fields |
| `Repositories/PeopleRepository.swift` | Snapshot + merge new fields |
| `Repositories/UndoRepository.swift` | Restore new fields |
| `Views/People/PersonDetailView.swift` | 3-picker preferences, Text button |
| `Views/Communication/ComposeWindowView.swift` | Channel switching via ContactAddresses |
| `Views/Awareness/OutcomeQueueView.swift` | Pass contactAddresses |
| `Views/Awareness/LifeEventsSection.swift` | Pass contactAddresses |
| `Views/Shared/OutcomeCardView.swift` | Companion indicator |

---

## WhatsApp Direct Database Integration (March 5, 2026)

**What**: Full WhatsApp integration — reads messages and call history from the local ChatStorage.sqlite database, generates evidence, supports WhatsApp as a communication channel, and suggests Apple Contact enrichment from WhatsApp phone numbers.

**Why**: WhatsApp is a primary communication channel for many WFG contacts. Reading the local database (unencrypted SQLite via security-scoped bookmarks) follows the same architecture as the iMessage/Phone/FaceTime integration (Phase M), providing complete communication history for relationship intelligence.

### New Files (3)

- `Models/DTOs/WhatsAppMessageDTO.swift` — Sendable DTO for WhatsApp messages (stanzaID, text, date, isFromMe, contactJID, partnerName, messageType, isStarred)
- `Models/DTOs/WhatsAppCallDTO.swift` — Sendable DTO for WhatsApp call events (callIDString, date, duration, outcome, participantJIDs)
- `Services/WhatsAppService.swift` — Actor-isolated SQLite3 reader: `fetchMessages()`, `fetchCalls()`, `fetchAllJIDs()`; Core Data epoch timestamps; JID canonicalization; graceful `tableExists()` check for call history table

### Modified Files (21)

#### Core Integration

- `Models/SAMModels-Supporting.swift` — Added `.whatsApp`/`.whatsAppCall` to `EvidenceSource` (qualityWeight, iconName, displayName); added `.whatsApp` to `CommunicationChannel` (displayName, icon); `ContactAddresses` gains `hasWhatsApp: Bool` for channel routing
- `Models/SAMModels.swift` — `SamPerson.contactAddresses` derives `hasWhatsApp` from linked evidence
- `Models/SAMModels-Enrichment.swift` — Added `.whatsAppMessages` to `EnrichmentSource`
- `Utilities/BookmarkManager.swift` — WhatsApp bookmark: `hasWhatsAppAccess`, `requestWhatsAppAccess()` (NSOpenPanel validates ChatStorage.sqlite), `resolveWhatsAppURL()`, `revokeWhatsAppAccess()`
- `Repositories/EvidenceRepository.swift` — `bulkUpsertWhatsAppMessages()` (sourceUID `whatsapp:{stanzaID}`), `bulkUpsertWhatsAppCalls()` (sourceUID `whatsappcall:{callIDString}`); updated `refreshParticipantResolution()` and `hasRecentCommunication()` filters

#### Import Pipeline

- `Coordinators/CommunicationsImportCoordinator.swift` — WhatsApp messages import (group by JID+day, LLM analysis, upsert), WhatsApp calls import, unknown sender discovery (`fetchAllJIDs` → `UnknownSenderRepository`), enrichment generation (`generateWhatsAppEnrichments()` → `EnrichmentRepository`); new state/settings/watermarks/setter methods

#### Communication Channel

- `Services/ComposeService.swift` — `composeWhatsApp(phone:body:)` via `wa.me` deep link with `whatsapp://` fallback
- `Views/Communication/ComposeWindowView.swift` — `.whatsApp` case in `sendViaSystemApp()`, "Open WhatsApp" button label
- `Coordinators/OutcomeEngine.swift` — WhatsApp-specific draft instructions (casual, text-message tone)
- `Coordinators/MeetingPrepCoordinator.swift` — `.whatsApp`/`.whatsAppCall` evidence maps to `.whatsApp` channel (not iMessage bucket) for channel inference

#### Switch Sites (exhaustive enum cases)

- `Views/Search/SearchResultRow.swift`, `Views/Inbox/InboxListView.swift`, `Views/Inbox/InboxDetailView.swift`, `Views/Awareness/MeetingPrepSection.swift`, `Views/People/PersonDetailView.swift` — Added `.whatsApp`/`.whatsAppCall` icon (`text.bubble`/`phone.bubble`) and color (`.green`)

#### commsSources Sets

- `Coordinators/NoteAnalysisCoordinator.swift`, `Views/Awareness/MeetingQualitySection.swift`, `Coordinators/RelationshipGraphCoordinator.swift` — Added `.whatsApp`, `.whatsAppCall` to communication source filters

#### Triage & Settings

- `Views/Awareness/UnknownSenderTriageSection.swift` — Generic `TriageRow` now shows source-specific icons for ALL sources (not just LinkedIn/Facebook); hides WhatsApp synthetic subjects
- `Views/Settings/CommunicationsSettingsView.swift` — WhatsApp DB access row (grant/revoke), WhatsApp section (messages/calls/AI analysis toggles), WhatsApp counts in import section

### Architecture Notes

- **No schema version bump** — `EvidenceSource` stored as raw strings; new values are forward-compatible
- **Privacy**: message text analyzed by on-device LLM then discarded; only AI summary stored in snippet; `bodyText` always nil
- **JID canonicalization**: `14075800106@s.whatsapp.net` → strip `@s.whatsapp.net`, take last 10 digits to match `SamPerson.phoneAliases`
- **Timestamps**: WhatsApp uses Core Data epoch (`Date(timeIntervalSinceReferenceDate:)`)
- **Call history table**: gracefully handled when missing (`tableExists()` check)
- **Group chats excluded**: `ZSESSIONTYPE = 0` filter (private chats only)

---

## Data Migration & Schema Version Hygiene (March 5, 2026)

**What**: Centralized schema versioning, fixed stale backup version strings, and added legacy store discovery/migration/cleanup tooling.

**Why**: SAM's 23 schema version bumps (v12→v34) each created a new empty store file by changing the `ModelConfiguration` name, silently abandoning all previous data. BackupCoordinator also had `"SAM_v26"` hardcoded in 3 places, producing backups with the wrong schema version. Users accumulate orphaned store files (~75MB) with no way to recover data or reclaim space.

### New Files (1)

- `Services/LegacyStoreMigrationService.swift` — `@MainActor @Observable` service that discovers orphaned `SAM_v*.store` files, migrates the most recent via backup round-trip (copy to temp → open with current schema → export → import), and cleans up old files. Tries stores newest→oldest; handles lightweight migration failures gracefully.

### Modified Files (5)

#### Schema Centralization

- `App/SAMModelContainer.swift` — Added `static let schemaVersion = "SAM_v34"` as single source of truth. Replaced 5 hardcoded `"SAM_v34"` strings. Added policy comment warning against unnecessary version bumps. `defaultStoreURL` now derives from `schemaVersion`.

#### Backup Fix

- `Coordinators/BackupCoordinator.swift` — Replaced 3 stale `"SAM_v26"` references with `SAMModelContainer.schemaVersion`. Added `exportBackup(to:container:)` overload so the migration service can export from a legacy container.

#### Settings UI

- `Views/Settings/SettingsView.swift` — Added "Legacy Data" section in GeneralSettingsView (only visible when orphaned stores are detected): status line with count/size, "Migrate Data..." and "Clean Up Old Files..." buttons with progress feedback, cleanup confirmation alert. Runs discovery on appear.

#### Startup Detection

- `App/SAMApp.swift` — After `configureDataLayer()`, checks if current store is empty (0 people) AND legacy stores exist. Sets `sam.legacyStores.detected` flag for Today view banner.
- `Views/Awareness/AwarenessView.swift` — Added `LegacyDataNoticeBanner` at top of Today view when flag is set, with dismissable orange banner directing user to Settings → General.

### Architecture Notes

- Migration copies legacy store files to a temp directory before opening, protecting originals from CoreData's in-place migration attempt
- Stores too old for SwiftData lightweight migration (mandatory attribute gaps, e.g. v21→v34) fail gracefully — cleanup is still available to reclaim disk space
- No schema version bump — this is tooling/hygiene only
- `SAMModelContainer.schemaVersion` is now the only place the version string appears in code

---

## Substack Auto-Detection Import Pipeline (March 6, 2026)

**What**: Replaced the disabled "Import Substack Feed" menu item with a smart auto-detection pipeline. When the user has previously configured Substack, SAM automatically scans ~/Downloads for export ZIPs, monitors Mail.app for the export-ready email, posts macOS notifications with the download link, and watches for the downloaded file — all without leaving SAM.

**Why**: The previous Substack subscriber import required navigating to Settings → Data Sources → Substack, manually downloading the export, and selecting the CSV via a file picker. This was friction-heavy and easy to forget. The new flow is a single menu item that handles everything, including watching for async exports that take hours to prepare.

### New Files (1)

- `Views/Settings/SubstackImportSheet.swift` — Standalone sheet with 11-phase state machine (setup, scanning, zipFound, processing, awaitingReview, noZipFound, watchingEmail, emailFound, watchingFile, complete, failed). Combines publication feed management with smart subscriber ZIP detection. Manual file picker fallback for all states.

### Modified Files (5)

#### Coordinator Extension

- `Coordinators/SubstackImportCoordinator.swift` — Major extension. Added `SubstackSheetPhase` enum (11 cases), `ZipInfo`/`ImportStats` value types, `beginImportFlow()` routing, `scanDownloadsFolder()` (pattern matching for `export-*.zip`/`substack-export-*.zip`), `processZip(url:)` (unzip via `/usr/bin/unzip` + CSV extraction + matching), `openSubstackExportPage()`, email watcher (5-min Mail.app polling, MIME source parsing for download URL, 2-day timeout), file watcher (30s ~/Downloads polling, 2-day timeout), `scheduleReminder()` (calendar-gap-aware rescheduling), `resumeWatchersIfNeeded()` (watcher persistence across app restarts via UserDefaults), `deleteSourceZip()`, `cancelAll()`.

#### System Notifications

- `Services/SystemNotificationService.swift` — Added `SUBSTACK_EXPORT` notification category with "Open Export Page" (foreground, opens URL + starts file watcher) and "Remind Me Later" (triggers calendar-gap-aware rescheduling) actions. New `postSubstackExportReady(downloadURL:triggerDate:)` method supporting both immediate and scheduled delivery. Delegate handling for both action buttons and default tap.

#### App Integration

- `App/SAMApp.swift` — "Import Substack Feed" (disabled when unconfigured) → "Import Substack..." (always enabled). Added `showSubstackImportSheet` state, `.sheet` presenter, `.samSubstackZipDetected` notification listener to auto-present sheet when file watcher detects ZIP. Added `SubstackImportCoordinator.shared.cancelAll()` to termination handler.

#### Settings Cleanup

- `Views/Settings/SettingsView.swift` — Removed Substack DisclosureGroup from `DataSourcesSettingsView` (configuration moved to File → Import sheet). Updated `ImportStatusDashboard` Substack row to show "File → Import" when no feed URL configured, and last import date when available.

#### Entitlements & Notifications

- `SAM_crm.entitlements` — Added `com.apple.security.files.downloads.read-write` for real ~/Downloads access (sandbox returns container without it). Benefits all future platform auto-detection.
- `Models/SAMModels.swift` — Added `.samSubstackZipDetected` notification name.

### Architecture Notes

- **Reusable pattern**: The auto-detection pipeline is documented in `context.md` §5.7 with a step-by-step guide for adapting to LinkedIn and Facebook. The `{Platform}SheetPhase` enum, watcher persistence model, and notification category structure are designed as templates.
- **No schema version bump** — all new state is in UserDefaults (watcher flags, start dates, extracted URLs) and coordinator observable properties.
- **Watcher persistence**: Both email and file watchers survive app restart. `resumeWatchersIfNeeded()` (called from `configure(container:)`) restarts timers if active flags are set; timeout is calculated from the original start date.
- **Graceful fallback**: If Mail is not configured, the email watcher button is hidden and the sheet shows manual instructions. All phases include a "Select File Manually..." escape hatch.
- **Entitlement scope**: `com.apple.security.files.downloads.read-write` is a standard Apple entitlement that grants read/write to ~/Downloads. This is the real filesystem directory, not the sandbox container.

---

**Changelog Started**: February 10, 2026
**Maintained By**: Project team
**Related Docs**: See `context.md` for current state and roadmap
