# Phase AA: Relationship Graph — Visual Network Intelligence

**Related Docs**: 
- See `phase-aa-interaction-spec.md` for the complete interaction model (supersedes the interaction table in AA.4)
- See `phase-aa-visual-design.md` for colors, rendering parameters, label system, and aesthetic guidelines
- See `agent.md` for product philosophy, AI architecture, and UX principles
- See `context.md` for current architecture and completed phases (A–Z)
- See `changelog.md` for development history

**Prerequisites**: All phases A–Z complete. This phase depends heavily on data produced by Pipeline Intelligence (R), Production Tracking (S), Relationship Decay Prediction (U), and Strategic Coordinator (V).

---

## Goal

Add an interactive, force-directed relationship graph to SAM that reveals structural patterns invisible in list and dashboard views: referral network topology, family cluster coverage gaps, recruiting tree health, communication flow direction, and orphaned connections. The graph is a **strategic tool**, not a decoration — every visual element must surface actionable intelligence.

---

## Design Principles

1. **Mac-native rendering** — Use SwiftUI Canvas with custom layout, not a web view or third-party charting library. The graph must feel like a native macOS experience: smooth 60fps pan/zoom, system cursor changes on hover, contextual menus on right-click, and full keyboard navigation.

2. **Information density without clutter** — The default view should be immediately legible for a network of 50–300 people. Nodes that are less relevant fade or collapse. The user progressively discloses detail by zooming, hovering, or filtering.

3. **Action-oriented** — Clicking a node navigates to the person's detail view. Hovering shows a tooltip with relationship summary, pipeline stage, and top coaching outcome. Right-clicking offers contextual actions (create note, draft message, view in Awareness). The graph is not view-only.

4. **Performance-bounded** — Graph layout computation runs off the main thread. Initial layout uses a deterministic algorithm seeded by existing context groupings (family clusters group together, recruiting trees form hierarchies). Force simulation refines incrementally without blocking the UI.

---

## Architecture

### AA.1 — Graph Data Model (Coordinator Layer)

**New file**: `Coordinators/RelationshipGraphCoordinator.swift`

```swift
@MainActor
@Observable
final class RelationshipGraphCoordinator {
    
    // MARK: - Observable State
    
    var graphStatus: GraphStatus = .idle
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    var lastComputedAt: Date?
    var selectedNodeID: UUID?
    var hoveredNodeID: UUID?
    
    // MARK: - Filter State
    
    var activeRoleFilters: Set<String> = []          // Empty = show all
    var activeEdgeTypeFilters: Set<EdgeType> = []    // Empty = show all
    var showOrphanedNodes: Bool = true
    var showGhostNodes: Bool = true                  // Mentioned-but-not-contacts
    var minimumEdgeWeight: Double = 0.0              // Slider to prune weak connections
    
    // MARK: - Layout State
    
    var viewportCenter: CGPoint = .zero
    var viewportScale: CGFloat = 1.0
    
    // MARK: - Public API
    
    func buildGraph() async { ... }
    func rebuildIfStale() async { ... }              // Rebuild if data changed since lastComputedAt
    func applyFilters() { ... }                      // Re-filter without full rebuild
    func exportGraphImage() async -> NSImage? { ... } // For sharing/printing
    
    // MARK: - Status Enum
    
    enum GraphStatus: Equatable {
        case idle
        case computing
        case ready
        case failed
    }
}
```

**GraphNode** (Sendable DTO):
```swift
struct GraphNode: Identifiable, Sendable {
    let id: UUID                            // SamPerson.id
    let displayName: String
    let roleBadges: [String]
    let primaryRole: String?                // Highest-priority role for coloring
    let pipelineStage: String?              // Current stage in client or recruiting funnel
    let relationshipHealth: HealthLevel     // .healthy, .cooling, .atRisk, .cold
    let productionValue: Double             // Total premium or policy count (for node sizing)
    let isGhost: Bool                       // Mentioned in notes but not a contact
    let isOrphaned: Bool                    // No edges to other nodes
    let topOutcome: String?                 // Highest-priority coaching suggestion (tooltip)
    let photoThumbnail: Data?
    
    // Layout (mutable during simulation, but node itself is value type)
    var position: CGPoint
    var velocity: CGPoint = .zero
    
    enum HealthLevel: String, Sendable {
        case healthy, cooling, atRisk, cold, unknown
    }
}
```

**GraphEdge** (Sendable DTO):
```swift
struct GraphEdge: Identifiable, Sendable {
    let id: UUID
    let sourceID: UUID                      // GraphNode.id
    let targetID: UUID                      // GraphNode.id
    let edgeType: EdgeType
    let weight: Double                      // 0.0–1.0, controls thickness
    let label: String?                      // Optional label ("referred", "spouse", etc.)
    let isReciprocal: Bool                  // Both directions have communication
    let communicationDirection: Direction?   // Who initiates more
    
    enum Direction: String, Sendable {
        case outbound       // User → contact
        case inbound        // Contact → user
        case balanced
    }
}

enum EdgeType: String, CaseIterable, Sendable {
    case deducedFamily      // Connected via DeducedRelation (spouse, parent, child, sibling, other)
    case business           // Share a SamContext of type Business
    case referral           // referredBy / referrals relationship
    case recruitingTree     // Agent recruited by user or by user's agents
    case coAttendee         // Attended same calendar event(s)
    case communicationLink  // Direct message/email/call evidence between two contacts
    case mentionedTogether  // Co-mentioned in notes
}
```

### AA.2 — Graph Builder (Service Layer)

**New file**: `Services/GraphBuilderService.swift`

```swift
actor GraphBuilderService {
    
    /// Build complete graph from current SAM data.
    /// Runs off main thread. Returns Sendable DTOs.
    func buildGraph(
        people: [PersonGraphInput],
        contexts: [ContextGraphInput],
        referralChains: [ReferralLink],
        recruitingTree: [RecruitLink],
        coAttendanceMap: [CoAttendancePair],
        communicationMap: [CommLink],
        noteMentions: [MentionPair],
        ghostMentions: [GhostMention]
    ) -> (nodes: [GraphNode], edges: [GraphEdge]) { ... }
    
    /// Run force-directed layout simulation.
    /// Returns updated node positions after N iterations.
    func layoutGraph(
        nodes: [GraphNode],
        edges: [GraphEdge],
        iterations: Int = 300,
        bounds: CGSize
    ) -> [GraphNode] { ... }
}
```

**Input DTOs** (assembled by coordinator from repositories):

```swift
struct PersonGraphInput: Sendable {
    let id: UUID
    let displayName: String
    let roleBadges: [String]
    let relationshipHealth: GraphNode.HealthLevel
    let productionValue: Double
    let photoThumbnail: Data?
    let topOutcomeText: String?
}

struct ContextGraphInput: Sendable {
    let contextID: UUID
    let contextType: String             // "Business"
    let participantIDs: [UUID]          // SamPerson IDs
}

struct ReferralLink: Sendable {
    let referrerID: UUID
    let referredID: UUID
}

struct RecruitLink: Sendable {
    let recruiterID: UUID
    let recruitID: UUID
    let stage: String                   // RecruitingStage raw value
}

struct CoAttendancePair: Sendable {
    let personA: UUID
    let personB: UUID
    let meetingCount: Int               // Number of shared calendar events
}

struct CommLink: Sendable {
    let personA: UUID
    let personB: UUID
    let evidenceCount: Int
    let lastContactDate: Date
    let dominantDirection: GraphEdge.Direction
}

struct MentionPair: Sendable {
    let personA: UUID
    let personB: UUID
    let coMentionCount: Int
}

struct GhostMention: Sendable {
    let mentionedName: String           // From ExtractedPersonMention
    let mentionedByIDs: [UUID]          // People whose notes mention this name
    let suggestedRole: String?
}
```

### AA.3 — Force-Directed Layout Algorithm

Implement in `GraphBuilderService` as a pure computation (no UI dependency). The algorithm:

**Initial positioning** (deterministic, not random):
- Group people by business SamContext and by deduced family clusters (connected components of deducedFamily edges). Place group members in a tight cluster.
- Position recruiting tree in a top-down hierarchy rooted at the user ("Me" node).
- Position orphaned nodes around the periphery.
- Referral chains create proximity bias (referred people start near their referrer).

**Force simulation** (iterative refinement):
- **Repulsion**: All nodes repel each other (Coulomb's law, charge proportional to node importance). Prevents overlap.
- **Attraction**: Connected nodes attract along edges (Hooke's law, spring constant proportional to edge weight). Keeps related people close.
- **Gravity**: Weak central gravity prevents disconnected clusters from drifting to infinity.
- **Damping**: Velocity decays each iteration to converge to stable layout.
- **Collision**: Minimum node spacing enforced (radius based on node size).

**Performance**:
- Run on a background thread via the `GraphBuilderService` actor
- 300 iterations for initial layout, then 50-iteration incremental updates when data changes
- For >500 nodes, use Barnes-Hut approximation (quadtree spatial partitioning) to reduce repulsion calculation from O(n²) to O(n log n)
- Yield to main thread every 50 iterations: `await Task.yield()`
- Cancel and restart if user changes filters during computation

**Implementation note**: This is pure math in Swift — no LLM involvement. The layout algorithm is deterministic given the same input data.

### AA.4 — Graph Renderer (View Layer)

**New file**: `Views/Business/RelationshipGraphView.swift`

Use SwiftUI `Canvas` for rendering — it provides hardware-accelerated 2D drawing with full control over what's drawn, and handles thousands of shapes efficiently.

**Canvas rendering layers** (back to front):
1. **Edge layer**: Lines between nodes. Thickness = edge weight. Color = edge type. Animated dashes for ghost edges. Arrow indicators for communication direction.
2. **Node layer**: Circles sized by production value (min 20pt, max 60pt). Fill color = primary role. Stroke color = relationship health (green/yellow/orange/red). Photo thumbnail clipped to circle if available.
3. **Label layer**: Display name below each node. Font size scales with zoom. Labels hide below a zoom threshold to prevent clutter.
4. **Overlay layer**: Hover tooltip (relationship summary card). Selection highlight (glow ring). Filter dim (non-matching nodes at 20% opacity).

**Interaction model**:

| Input | Action |
|-------|--------|
| Scroll wheel / pinch | Zoom in/out (0.1× to 5.0×) |
| Click + drag on canvas | Pan viewport |
| Click on node | Select → show detail in inspector or navigate to PersonDetailView |
| Hover on node | Show tooltip: name, role, health, top coaching outcome, edge count |
| Right-click on node | Contextual menu: View Person, Create Note, Draft Message, View in Awareness |
| Click + drag on node | Reposition manually (pin in place, exclude from simulation) |
| Double-click on node | Navigate directly to PersonDetailView |
| ⌘F | Focus search — type name to zoom to and highlight that node |
| Esc | Deselect / reset view |
| ⌘0 | Fit entire graph in view |
| ⌘1–4 | Quick filter presets (All, Clients Only, Recruiting Tree, Referral Network) |

**Zoom-dependent detail levels**:
- **Distant (< 0.3×)**: Nodes as dots, no labels, edges as thin lines. Good for seeing overall network shape.
- **Overview (0.3–0.8×)**: Nodes with role color, labels on larger nodes only, edge type colors visible.
- **Detail (0.8–2.0×)**: All labels visible, photo thumbnails appear, edge labels visible, health stroke visible.
- **Close-up (> 2.0×)**: Full detail including mini role badges on nodes, edge direction arrows, ghost node dashed borders.

### AA.5 — Graph Intelligence Overlays

These overlays transform the graph from a static map into an analytical tool. Each is toggleable from a toolbar above the graph.

**Overlay 1: Referral Hub Detection**
- Compute betweenness centrality for each node (how many shortest paths pass through it)
- Nodes with high centrality get a pulsing highlight ring
- Tooltip shows: "Hub — connects X people across Y family clusters. Referral conversion rate: Z%"
- Implementation: Standard betweenness centrality algorithm in Swift, O(V × E)

**Overlay 2: Coverage Gap Detection**
- For each family cluster (connected component of deducedFamily edges), check if all members are contacts and if products cover expected needs. Cluster label is derived from shared surname.
- Highlight family clusters with gaps: "Johnson Family: 3 members, only 1 is a client. Sarah (spouse) has no coverage."
- Ghost nodes (mentioned but not contacts) get a prominent dashed border with "+ Add Contact" affordance

**Overlay 3: Recruiting Tree Health**
- Color recruiting tree edges by recruit stage (green=producing, blue=licensed, yellow=studying, gray=prospect)
- Highlight branches with stalls (recruit stuck in stage > threshold days)
- Show mentoring cadence: edge dims if user hasn't contacted recruit recently

**Overlay 4: Communication Flow**
- Animate edges with directional particles (dots flowing from initiator toward recipient)
- Thick bidirectional flow = healthy reciprocal relationship
- Thin one-directional flow = user always initiating (or always being contacted)
- No flow = relationship gone cold (edge fades to gray)

**Overlay 5: Time-Based Replay** (stretch goal)
- Slider at bottom of graph: drag to see the network as it existed at any point in the past 12 months
- Nodes appear/disappear as contacts were added
- Edges grow/shrink as communication intensity changed
- Powerful for quarterly business reviews: "Here's how your network grew this quarter"

### AA.6 — Sidebar Integration & Navigation

**Location**: New entry in the main sidebar under the Business section.

```
Sidebar:
  People
  Inbox
  Contexts
  Awareness
  Business
    ├── Dashboard          (existing)
    ├── Pipeline           (existing)
    ├── Production         (existing)
    ├── Goals              (existing)
    └── Relationship Map   ← NEW (Phase AA)
```

**Alternative access points**:
- PersonDetailView toolbar button: "View in Graph" — opens graph centered and zoomed on that person with their immediate connections highlighted
- Business Dashboard: Miniature graph preview widget (non-interactive, click to open full view)
- Awareness Dashboard: "Your network grew by X connections this month" insight card with graph thumbnail

### AA.7 — Graph Caching & Incremental Updates

The full graph rebuild (querying all people, contexts, evidence, referrals, recruiting stages, notes) is expensive. Minimize rebuilds:

**Full rebuild triggers**:
- First launch after Phase AA migration
- User clicks "Rebuild Graph" in Settings or graph toolbar
- Data import completes (contacts, calendar, mail, communications)

**Incremental update triggers**:
- Role badge change on a person → update that node's color/size, check if edges change
- New evidence item → update edge weight for involved people
- New note with mentions → add/update mention edges
- New referral link → add edge
- Recruiting stage change → update edge color in tree

**Cache strategy**:
- Store computed `GraphNode` positions in a lightweight cache (UserDefaults or a dedicated SwiftData model)
- On incremental update, re-run force simulation for only the affected cluster (not the entire graph)
- Cache TTL: 24 hours for full layout, immediate invalidation for structural changes (new nodes/edges)

---

## Data Dependencies (All From Existing Phases)

| Data Source | Phase | Used For |
|-------------|-------|----------|
| SamPerson (roles, health) | A–D | Node color, size, health stroke |
| SamContext (businesses) | G | Business edge clusters |
| DeducedRelation (family clusters) | Deduced Relations | Family cluster edges (deducedFamily) |
| SamEvidenceItem (calendar, mail, messages, calls) | E, J, M | Communication edges, co-attendance, direction |
| SamNote (extracted mentions, discovered relationships) | H, L | Mention edges, ghost nodes |
| SamPerson.referredBy / referrals | Awareness Overhaul | Referral edges |
| RecruitingStage | R | Recruiting tree edges and stage colors |
| ProductionRecord | S | Node sizing by production value |
| RelationshipDecay velocity | U | Node health level |
| StageTransition history | R | Pipeline stage on nodes, time-based replay |
| SamOutcome (top priority) | N | Tooltip coaching suggestion |

**No new SwiftData models required** — the graph is computed entirely from existing data. The only new persistent storage is the optional layout position cache.

---

## Sub-Phase Delivery Plan

### AA.1 — Core Graph Engine (Foundation)
**Scope**: GraphNode, GraphEdge, EdgeType DTOs. GraphBuilderService with force-directed layout. RelationshipGraphCoordinator with buildGraph/applyFilters. No UI yet — verify with unit tests that layout converges and produces correct node/edge counts from test data.

**Test**: Create 20 mock people with known contexts, referrals, and evidence links. Assert correct edge count, edge types, node health levels. Assert layout converges (all node velocities < threshold after 300 iterations). Assert layout respects context clustering (family cluster members within radius R of each other).

### AA.2 — Basic Renderer
**Scope**: RelationshipGraphView with Canvas rendering. Pan, zoom, click-to-select. Node coloring by role. Edge drawing by type. Labels at appropriate zoom levels. Toolbar with zoom controls and fit-to-view button.

**Test**: Visual verification with real SAM data. 60fps pan/zoom with 100+ nodes. Correct node colors match role badge colors in PeopleListView.

### AA.3 — Interaction & Navigation
**Scope**: Hover tooltips, right-click contextual menus, double-click to PersonDetailView, ⌘F search-to-zoom, keyboard shortcuts (⌘0 fit, Esc deselect). "View in Graph" button on PersonDetailView. Sidebar entry under Business.

**Test**: All keyboard shortcuts functional. Navigation to/from PersonDetailView round-trips correctly. Contextual menu actions (Create Note, Draft Message) trigger correct flows.

### AA.4 — Intelligence Overlays
**Scope**: Referral hub detection (betweenness centrality), coverage gap highlighting, recruiting tree health coloring, communication flow animation. Toolbar toggles for each overlay.

**Test**: Verify hub detection identifies known referral centers in test data. Verify coverage gaps correctly flag family clusters with partial coverage. Verify recruiting tree colors match RecruitingStage data.

### AA.5 — Ghost Nodes & Incremental Updates
**Scope**: Ghost nodes from ExtractedPersonMention data. "+ Add Contact" affordance on ghost nodes. Incremental graph updates on data change (role badge, new evidence, new referral). Layout position caching.

**Test**: Ghost nodes appear for names mentioned in notes but not in contacts. Adding a contact for a ghost node transitions it to a real node. Incremental updates don't cause full layout recomputation.

### AA.6 — Polish & Performance
**Scope**: Barnes-Hut optimization for large graphs (>500 nodes). Zoom-dependent detail levels. Export graph as image. Mini-preview widget for Business Dashboard. Accessibility: VoiceOver announces node name/role/health on focus, edge descriptions on traverse. Reduce Motion: disable flow animation, use static indicators instead.

**Test**: Performance profiling with 500-node graph: layout < 2 seconds, pan/zoom maintains 60fps. VoiceOver navigable. Reduce Motion respected.

### AA.7 — Time-Based Replay (Stretch)
**Scope**: Historical slider showing network evolution over past 12 months. Animate node/edge appearance based on StageTransition and evidence dates. Useful for quarterly reviews.

**Test**: Slider at month boundaries shows correct node/edge counts matching historical data.

---

## New Files Summary

```
Services/
  └── GraphBuilderService.swift          Actor — layout algorithm, graph computation

Coordinators/
  └── RelationshipGraphCoordinator.swift @MainActor @Observable — graph state, filters, rebuild

Models/DTOs/
  ├── GraphNode.swift                    Sendable — node representation
  ├── GraphEdge.swift                    Sendable — edge representation + EdgeType enum
  └── GraphInputDTOs.swift              Sendable — PersonGraphInput, ContextGraphInput, etc.

Views/Business/
  ├── RelationshipGraphView.swift        Canvas-based graph renderer
  ├── GraphToolbarView.swift             Filter toggles, overlay switches, zoom controls
  ├── GraphTooltipView.swift             Hover popover with person summary
  └── GraphMiniPreviewView.swift         Non-interactive thumbnail for dashboard
```

---

## Schema Impact

**No schema migration required.** Phase AA reads exclusively from existing models. The only new persistent data is the layout position cache, stored in UserDefaults as serialized JSON (not SwiftData), keyed by a hash of the current node set.

---

## Performance Budget

| Operation | Target | Strategy |
|-----------|--------|----------|
| Full graph build (data query) | < 500ms | Batch fetch from repositories, assemble DTOs on main thread |
| Initial layout (300 iterations, 200 nodes) | < 1.5s | Background actor, yield every 50 iterations |
| Initial layout (300 iterations, 500 nodes) | < 3s | Barnes-Hut approximation |
| Incremental layout (50 iterations, local cluster) | < 200ms | Only simulate affected subgraph |
| Canvas render (200 nodes, 60fps) | 16ms/frame | Canvas hardware-accelerated, skip off-screen nodes |
| Canvas render (500 nodes, 60fps) | 16ms/frame | LOD culling, skip labels below zoom threshold |
| Hover tooltip appearance | < 100ms | Precomputed tooltip data on GraphNode |
| Filter application | < 50ms | In-memory filter on existing node/edge arrays |

---

## Accessibility

- **VoiceOver**: Canvas is not natively accessible. Implement an accessibility tree overlay using `accessibilityChildren` that represents each node as an accessible element with label "[Name], [Role], [Health], [N] connections". Arrow key navigation traverses edges between connected nodes.
- **Dynamic Type**: Tooltip and contextual menu text respect Dynamic Type.
- **Reduce Motion**: Disable force simulation animation (show final positions immediately). Disable communication flow particles. Use static color indicators instead of animated overlays.
- **High Contrast**: Node stroke widths increase. Edge colors use accessible palette. Ghost node borders use pattern fill instead of just dashing.
- **Keyboard**: Full navigation without mouse. Tab cycles through nodes (sorted by relevance). Enter selects. Arrow keys traverse edges. Space opens contextual menu.

---

## What Claude Code Should Do

1. Read this spec completely before planning.
2. Implement sub-phases in order (AA.1 → AA.6, AA.7 is stretch).
3. After AA.1, run unit tests to verify graph engine correctness before building UI.
4. After AA.2, do a visual check with real SAM data — screenshot the graph with 20+ nodes and verify role colors, edge types, and zoom behavior.
5. After each sub-phase, update `context.md` and move completed work to `changelog.md`.
6. Follow all existing architecture patterns: actor-isolated services return Sendable DTOs, coordinators are @MainActor @Observable, views never access raw models directly.
7. The force-directed layout is pure Swift math — no LLM, no external libraries. Implement from scratch following the algorithm described in AA.3.
8. Performance-test with the user's actual data after AA.6. If >300 nodes, verify Barnes-Hut is active and frame rate is acceptable.
