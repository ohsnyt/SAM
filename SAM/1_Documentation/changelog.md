# SAM — Changelog

**Purpose**: This file tracks completed milestones, architectural decisions, and historical context. See `context.md` for current state and future plans.

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

**Changelog Started**: February 10, 2026
**Maintained By**: Project team
**Related Docs**: See `context.md` for current state and roadmap
