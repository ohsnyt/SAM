# Phase AA Interaction Specification: Graph Interaction Model

**Companion to**: `phase-aa-relationship-graph.md` (architecture, data model, rendering), `phase-aa-visual-design.md` (colors, rendering details, label system)  
**Supersedes**: The interaction table in AA.4 of the original spec  
**Related Docs**: `agent.md`, `context.md`, `sam-graph-ux-research.md`

---

## Purpose

This document specifies the complete interaction model for SAM's relationship graph. It replaces the basic click/hover/drag table in Phase AA with a cohesive system built around three core ideas:

1. **Relational-distance selection** — click depth maps to network depth, modifier keys filter by edge type
2. **Progressive gravitational pull** — explore the network by magnetically attracting distant connections toward a focal point, one bridge node at a time
3. **Family clustering** — toggle a layout mode where family members (identified by deduced relations) share a visual boundary, reducing cognitive load from hundreds of individuals to dozens of family units

These mechanics are designed for how WFG financial strategists actually think about their network: in terms of families, referral chains, and recruiting trees — not individual contact records.

---

## 1. Node Interaction Fundamentals

### 1.1 Hit Testing

The current graph feels difficult to grab because the hit-test radius matches the visual radius. Fix this first — it provides the largest UX improvement for the least effort.

**Hit radius**: Visual node radius + 8pt padding. A node rendered at 20pt diameter has a 28pt hit-test circle. A node at 60pt has a 68pt circle. This compensates for imprecise cursor targeting, especially on trackpads.

**Voronoi hit testing** (polish phase): Partition the canvas into Voronoi cells so every point maps to the nearest node. Eliminates all dead zones — there is no place on the canvas where a click does nothing. The Voronoi diagram updates whenever node positions change (after simulation ticks or manual drags). At SAM's scale (50–300 nodes), the computation is trivial.

**Hit priority**: When nodes overlap or nearly overlap, the frontmost node wins. Frontmost is determined by: (1) selected nodes draw above unselected, (2) hovered node draws above all others, (3) higher production value draws above lower (bigger nodes are visually in front).

### 1.2 Cursor Feedback

| State | Cursor | Notes |
|-------|--------|-------|
| Hovering over node | `NSCursor.openHand` | Indicates grabbable |
| Dragging a node | `NSCursor.closedHand` | 1:1 cursor follow, no simulation velocity |
| Hovering over empty canvas | `NSCursor.arrow` | Default |
| Dragging on empty canvas (marquee) | `NSCursor.crosshair` | Rubber-band rectangle visible |
| Option+dragging on canvas (lasso) | `NSCursor.crosshair` | Freehand path visible |
| Hovering over bridge indicator | Custom cursor or `NSCursor.pointingHand` | Indicates clickable action |
| Hovering over ghost node | `NSCursor.openHand` + dashed outline pulse | Signals it's a merge candidate |

### 1.3 Node Pinning

When a user manually repositions a node (by dragging), that node becomes **pinned** — excluded from the force simulation. This prevents the simulation from undoing the user's intentional arrangement.

**Pin behavior**:
- Dragged nodes become pinned on mouse-up at their release position
- Pinned nodes display a subtle pin icon (📌) at top-right of the node circle, visible at Detail zoom level and above
- Double-click a pinned node's pin icon to unpin it (it rejoins the simulation)
- "Reset Layout" toolbar button unpins all nodes and reruns the full layout algorithm
- Pinned positions persist in the layout cache (UserDefaults) between sessions
- When pinned nodes exist, the simulation runs for unpinned nodes only, treating pinned nodes as fixed anchor points that still exert forces

---

## 2. Relational-Distance Selection

### 2.1 Core Mechanic

Click depth maps to network hop depth. Modifier keys filter which edge types are traversed during the expansion.

| Click | Without Modifier | Option (⌥) | Command (⌘) | Shift (⇧) |
|-------|-----------------|-------------|--------------|------------|
| Single click | Select node only | Select node only | Select node only | Toggle node in/out of current selection |
| Double click | Node + 1 hop (all edges) | Node + 1 hop (family only) | Node + 1 hop (referral only) | Node + 1 hop (recruiting only) |
| Triple click | Node + 2 hops (all edges) | Node + 2 hops (family only) | Node + 2 hops (referral only) | Node + 2 hops (recruiting only) |

**"All edges"** means: deducedFamily, business, referral, recruitingTree, coAttendee, communicationLink, and mentionedTogether. This is the broadest expansion — "show me this person's world."

**Family-only** (Option) answers: "Show me this family." Option+double-click John → John + spouse + children (traverses deducedFamily edges). Option+triple-click → adds their family members (son's spouse, daughter's family).

**Referral-only** (Command) answers: "Show me this referral chain." Cmd+double-click Linda → Linda + everyone she referred. Cmd+triple-click → adds everyone those people referred.

**Recruiting-only** (Shift) answers: "Show me this downline branch." Shift+double-click → you + direct recruits. Shift+triple-click → you + recruits + their recruits.

### 2.2 Selection Expansion Animation

On double-click or triple-click, the selection does not snap instantly. It expands visually as a **ripple**:

1. **Frame 0** (click): The clicked node highlights with a selection ring (2pt glow, accent color)
2. **Frame 0–100ms**: A translucent ring radiates outward from the clicked node, like a ripple on water
3. **Frame 100–200ms**: First-hop nodes highlight as the ripple reaches them. Each newly selected node gets the selection ring. Edges connecting them to the clicked node brighten.
4. **Frame 200–300ms** (triple-click only): The ripple continues outward. Second-hop nodes highlight. Their connecting edges brighten.
5. **Frame 300ms+**: Ripple fades. Selection is stable. A small badge appears near the clicked node showing the count (e.g., "8 selected").

The animation uses `withAnimation(.easeOut(duration: 0.3))` on the selection state changes. The ripple ring itself is a `Canvas` overlay — an expanding circle with decreasing opacity, drawn on each frame.

**Why animate**: The ripple shows the user exactly which nodes were added and through which edges. Without it, 15 nodes lighting up simultaneously gives no sense of the network structure being traversed. The ripple makes the graph-theoretic distance visible.

### 2.3 Selection Count Warning

When the expanded selection exceeds 15 nodes:
- The selection badge changes from accent color to orange
- The badge text reads "23 selected" (or whatever the count is)
- This is informational only — it does not prevent the user from proceeding

When the expanded selection exceeds 40 nodes:
- The badge changes to red
- This still does not prevent action, but signals that dragging this many nodes will be a large operation

### 2.4 Post-Selection Adjustment

After the expansion ripple completes, the user can refine the selection before acting:

- **Shift+click** any highlighted node to deselect it (remove from selection)
- **Shift+click** any unhighlighted node to add it to the selection
- This allows "double-click to select the family, then Shift+click to remove the kid who's irrelevant to this task"

The selection remains stable until the user clicks on empty canvas (deselects all), single-clicks a new node (new selection), or performs another expansion click.

### 2.5 Drag Behavior with Selection

| Action | Result |
|--------|--------|
| Drag a **selected** node | All selected nodes move as a group, preserving relative positions. Unselected nodes re-simulate (simulation re-heats for them). |
| Drag an **unselected** node | Deselects all, selects only that node, drags it alone. |
| Double-click-and-hold (200ms), then move mouse | Expansion ripple plays during the hold. Drag begins on first mouse-move after 200ms. All expanded nodes move as a group. |
| Double-click-and-release (< 200ms between clicks, no movement) | Expansion ripple plays. Selection highlights but no drag. User can inspect, adjust, then drag later. |

**Simulation re-heat during drag**: When selected nodes are being dragged, set `simulationAlpha = 0.3` for unselected nodes. This causes the rest of the graph to gently adjust to the new positions — related nodes will drift toward the dragged cluster, unrelated nodes will spread to fill vacated space. On mouse-up, the simulation decays normally (alpha → 0 over ~1 second).

**Group drag mechanics**: Store the offset from each selected node's position to the cursor at drag-start. On each mouse-move, update every selected node's position by applying the cursor delta to its original offset. This preserves the spatial arrangement of the group perfectly. Use `CADisplayLink` (or `DisplayLink` in SwiftUI) for 60fps position updates during drag.

**Momentum on release** (optional polish): If the user "throws" a group (fast mouse-up velocity), apply a brief momentum animation — the group slides in the throw direction, decelerating over 300ms. This makes the graph feel physical and alive.

---

## 3. Progressive Gravitational Pull

This is the primary exploration mechanic. Instead of selecting and dragging large numbers of distant nodes, the user **attracts** distant connections toward a focal point, one bridge at a time.

### 3.1 Bridge Indicators

A **bridge node** is any node in the current view that has connections to nodes that are currently distant — far enough away that they're not part of the visible local cluster. "Distant" is defined as: the connected node's screen-space distance from the bridge node exceeds 3× the average edge length in the current viewport, OR the connected node is off-screen.

**Visual treatment**: Bridge nodes display a small circular badge at their 2 o'clock position (upper-right edge of the node circle). The badge contains a number — the count of distant connections.

**Badge styling**:
- Background: Semi-transparent accent color
- Text: White, bold, compact font (SF Rounded, 9pt)
- Size: 16pt diameter for single digit, expanding for double digits
- Position: Offset so it overlaps the node edge slightly — clearly attached but not obscuring the node face

**Badge visibility**: Only appears at Overview zoom level (0.3×) and above. At Distant zoom, nodes are too small for badges to be legible.

**Badge color encodes cluster size**:
- Blue badge: 1–5 distant connections (small pull)
- Orange badge: 6–15 distant connections (medium pull — will moderately increase local density)
- Red badge: 16+ distant connections (large pull — will significantly reshape the local area)

### 3.2 Pull Interaction

**Trigger**: Click the bridge indicator badge on a node. Not the node itself (that's selection), specifically the small numbered badge.

**Preview on hover**: When the cursor hovers over a bridge badge, ghost silhouettes of the distant nodes appear — faint, translucent outlines at their eventual destination positions (calculated as if the pull had already happened, placed near the bridge node with the simulation's force rules). Ghost edges connect them to the bridge node as dashed translucent lines. This preview shows what *would* arrive without committing to the action.

**Pull animation** (on badge click):

1. **Frame 0**: Badge pulses once (scale 1.0 → 1.3 → 1.0) to confirm the click
2. **Frame 0–100ms**: The distant nodes receive a temporary strong attractive force toward the bridge node. Their current simulation forces to other nodes weaken (multiplied by 0.3)
3. **Frame 100–600ms**: Nodes migrate toward the bridge node. The animation uses spring physics — they accelerate, overshoot slightly past the bridge node's neighborhood, then settle back. Each node finds its own equilibrium position near the bridge, influenced by:
   - Attraction to the bridge node (strong, temporary)
   - Repulsion from other nodes already in the cluster (normal collision avoidance)
   - Residual attraction to their *other* connections (these edges stretch but don't break)
4. **Frame 600–800ms**: Elastic settle. Nodes reach their resting positions. The bridge badge disappears (or updates to show remaining distant connections if only a subset was pulled)
5. **Frame 800ms+**: The graph's simulation runs a brief re-equilibrium pass (alpha 0.1, 50 iterations) so everything adjusts gently

**Important**: Nodes that are pulled in retain their edges to the rest of the graph. Those edges may now be long, stretching back to wherever the nodes came from. This visual tension is intentional — it shows the user that these nodes also belong to other clusters. If a pulled-in node's residual edge tension is strong enough (it has many connections elsewhere), it will settle farther from the bridge node, leaning toward its other community. This spatial tension is information about network structure.

### 3.3 Release Interaction

Every pull is reversible. After pulling nodes toward a bridge, the user can **release** them back to their natural positions.

**Trigger**: Click the bridge node that initiated the pull. A small "release" icon (↩ or a spring icon) appears next to bridge nodes that have active pulls. Alternatively, right-click the bridge node → "Release Pulled Connections."

**Release animation**: The reverse of pull. The temporary attractive force is removed. The nodes' original simulation forces reassert. Over 500ms, the nodes drift back toward their equilibrium positions. The bridge badge reappears with the count.

**"Reset All Pulls" toolbar button**: Releases all pulled nodes across the entire graph in one action. Useful when the user has done extensive exploration and wants to return to the "natural" layout.

### 3.4 Chained Exploration

The pull mechanic supports iterative, depth-first network exploration:

1. Start at your top client, John. He has a bridge badge showing "6."
2. Click the badge. John's 6 distant connections migrate in. You can now see his full neighborhood — wife, referral source, two recruits, a co-attendee, a note mention.
3. One of those pulled-in nodes (Linda, a referral) has her own bridge badge: "4."
4. Click Linda's badge. Her 4 connections pull in and settle near her, which is near John. Now you can see two layers of the network around John.
5. One of Linda's connections (Tom) has a bridge badge: "2." Click it to pull in Tom's connections.
6. At any point, you can release a specific bridge's pulls (click its release icon) or reset everything.

This creates an organic, user-paced exploration of the network. The user "reels in" the network toward their point of interest, seeing the structure build up layer by layer. It's the fishing-line metaphor — pull what you need, inspect it, pull more if you want, and release when you're done.

### 3.5 Pull vs. Selection Integration

Pulling and selection are independent operations that compose naturally:

- Pull brings distant nodes closer spatially. It does not select them.
- After pulling, the user can double-click a pulled-in node to select it and its neighborhood (which now includes both its original connections AND the bridge it was pulled toward).
- The user can select a group of pulled-in nodes and drag them to a new position manually.
- If the user drags a bridge node that has active pulls, the pulled-in nodes follow (they're attracted to the bridge, so they'll track its movement during the next simulation tick).

---

## 4. Family Clustering Mode

### 4.1 Toolbar Toggle

A toolbar button labeled "Families" (icon: overlapping people) toggles family clustering mode. The toggle state persists across sessions (stored in UserDefaults alongside other graph preferences).

### 4.2 Visual Treatment

When active, each connected component of deducedFamily edges with 2+ members in the graph gets a **group boundary**:

- **Shape**: Rounded rectangle (cornerRadius 12pt) that encloses all family cluster member nodes with 16pt padding
- **Fill**: Translucent tint matching the cluster's dominant role color (e.g., if the family is primarily "Client," the fill is the client role color at 8% opacity)
- **Stroke**: 1pt line in the same color at 30% opacity
- **Label**: Shared last name (e.g., "Johnson Family") displayed in compact font at the top-left inside corner of the boundary, 9pt, 50% opacity. Visible at Overview zoom and above. If members have different last names, use the most common surname among them.
- **Rendering layer**: Drawn between the edge layer and node layer — edges pass behind boundaries, nodes sit on top of them

**Layout behavior in clustering mode**: The force simulation adds a **containment force** that keeps family cluster members within their group boundary. The boundary itself is not a rigid container — it's a soft constraint. If a family member has strong connections outside the cluster, it may drift to the edge of the boundary, visually leaning toward its external connection. The boundary elastically expands to accommodate.

Family boundaries repel each other, like large nodes. This prevents overlapping family clusters and creates natural spacing between family groups.

### 4.3 Interaction in Grouping Mode

| Action | Result |
|--------|--------|
| Drag any node inside a family boundary | The entire family cluster moves. All member nodes maintain their relative positions within the boundary. |
| Drag a node out of its boundary (drag > 40pt beyond boundary edge) | The node detaches from the family cluster for this layout session. It becomes an independent node. A subtle "snap-back" indicator appears on the boundary (a small + icon) that the user can click to pull the node back. This does NOT remove the person's deduced relations in the data model — it's purely a visual layout override. |
| Drag a ghost node into a family boundary | Triggers the ghost merge flow (Section 5). "Add [ghost name] to [family name]?" |
| Click on the family boundary background | Selects all members of the family cluster |
| Double-click on the boundary background | Selects all family cluster members + 1 hop (all edges) — effectively the family plus everyone they connect to |
| Right-click on boundary | Contextual menu: "Select Family Members," "Collapse Family Cluster" |

### 4.4 Family Cluster Collapse

From the right-click menu or by clicking a collapse icon on the boundary, a family cluster can be **collapsed** into a single composite node:

- The boundary shrinks to a single large node (diameter = max node size, 60pt)
- The composite node displays the shared last name and a small count badge ("3" for three members)
- The composite node's edges are the union of all member edges (deduplicated). An edge from the composite to an outside node means "at least one family member connects to that person."
- Edge thickness on the composite reflects the strongest connection any member has to the target
- Double-click the composite node to expand it back to individual members
- This is powerful for high-level network overview: collapse all family clusters to see inter-family referral chains with minimal visual noise

---

## 5. Ghost Node Merge

### 5.1 Ghost Node Identification

Ghost nodes appear when SAM detects mentions of people who don't have a SamPerson record:

- **CNContact relations** (e.g., contact card lists "spouse: Sarah" but there's no contact for Sarah)
- **Note content** (e.g., "spoke with John about his wife Sarah" extracts a person mention with no matching contact)
- **Calendar co-attendance** with unrecognized names

### 5.2 Ghost Node Visual Treatment

- **Border**: Dashed stroke (4pt dash, 4pt gap), same role-color system as real nodes but at 60% opacity
- **Fill**: Translucent (15% opacity fill vs. solid fill for real nodes)
- **Glyph**: "?" character centered in the node (or a person silhouette with "?" overlay) when no photo is available
- **Label**: The mentioned name (e.g., "Sarah") with italic styling
- **Size**: Fixed at minimum node size (20pt) since there's no production value to scale by

### 5.3 Drag-to-Merge Interaction

When the user begins dragging a ghost node:

1. **Drag start**: Compatible real nodes highlight with a glowing ring. "Compatible" means: name similarity (fuzzy match on display name), shared family cluster (connected via deducedFamily edges to the same person), or shared edge context. Incompatible nodes dim to 30% opacity.

2. **Approach** (ghost within 40pt of a compatible node): The compatible node's glow intensifies. A translucent "link" line appears between the ghost and the target. The ghost snaps to a position adjacent to the target (magnetic snap). Cursor changes to a merge indicator.

3. **Drop on compatible node**: A confirmation popover appears anchored to the merge point:
   ```
   ┌─────────────────────────────────────────┐
   │  Link "Sarah" → Sarah Johnson?          │
   │                                         │
   │  Source: Mentioned in John Johnson's     │
   │          notes (3 mentions)              │
   │                                         │
   │  This will:                              │
   │  • Connect note mentions to Sarah Johnson│
   │  • Add deduced "spouse" relationship     │
   │  • Transfer ghost edges to real contact  │
   │                                         │
   │          [ Cancel ]    [ Link ]          │
   └─────────────────────────────────────────┘
   ```

4. **Confirm ("Link")**: 
   - Ghost node dissolves (scale 1.0 → 0.0 over 200ms with fade)
   - All ghost edges animate to the real node (edges curve and reconnect over 300ms)
   - The real node briefly pulses to indicate it received new connections
   - In the data model: `ExtractedPersonMention` records link to the SamPerson. Deduced relationships become permanent edges.

5. **Cancel**: Ghost returns to its original position with a spring animation.

### 5.4 Ghost Node in Family Clustering Mode

When family clustering is active:
- Ghost nodes that were mentioned in the context of a family cluster float near that cluster's boundary (outside but adjacent)
- Dragging a ghost into the family boundary (not onto a specific node) triggers: "Add [name] to [family name] as a new contact?"
- This creates a new SamPerson record AND a DeducedRelation linking them to the nearest member in the cluster
- The ghost transforms into a real node inside the boundary

### 5.5 Ghost Node Contextual Menu

Right-click a ghost node:
- **Find Match…** — Opens a search popover to find the matching contact by name/phone/email
- **Create Contact** — Creates a new SamPerson from the ghost data (name, deduced relationships)
- **Dismiss** — Removes the ghost from the graph (marks the mention as "resolved — no action"). The ghost does not reappear unless new mentions are detected.
- **Dismiss All Ghosts** — Clears all current ghost nodes (available from graph toolbar, not per-node)

---

## 6. Marquee and Lasso Selection

For cases where relational-distance selection isn't the right tool — when the user wants to select a spatial region regardless of network structure.

### 6.1 Marquee (Rubber-Band Rectangle)

**Trigger**: Click and drag on empty canvas.

- A translucent rectangle draws from the mouse-down point to the current cursor position
- All nodes whose center falls within the rectangle are added to the selection on mouse-up
- The rectangle uses a dashed blue border with a 5% blue fill
- Combining with Shift: Shift+drag adds to the existing selection (doesn't deselect current)

### 6.2 Lasso (Freehand Selection)

**Trigger**: Option+drag on empty canvas.

- A freehand path draws following the cursor
- On mouse-up, the path closes and all nodes whose center falls within the enclosed area are selected
- The path uses the same visual style as marquee (dashed blue border, translucent fill)
- More natural for selecting irregular clusters that don't fit a rectangle
- Combining with Shift: Shift+Option+drag adds to existing selection

---

## 7. Layout Algorithm

### 7.1 Multi-Phase Layout Pipeline

Replace the current single-pass Fruchterman-Reingold with a three-phase pipeline that runs sequentially on the `GraphBuilderService` actor:

**Phase 1 — Deterministic Initial Placement** (unchanged from original AA spec):
- Family cluster members (connected by deducedFamily edges) placed in tight clusters (circular arrangement, radius proportional to member count)
- Recruiting tree positioned hierarchically (user/"Me" at top, recruits below, their recruits below that)
- Referral chains create proximity bias (referred people start near referrer)
- Orphaned nodes placed around periphery
- This phase produces a semantically meaningful starting layout that prevents "wrong side of cluster" trapping

**Phase 2 — Stress Majorization** (replaces raw Kamada-Kawai):
- Algorithm: Gansner, Koren, North (2004) stress majorization
- Computes all-pairs shortest path distances using BFS (unweighted) or Dijkstra (if using edge weight as distance). For SAM's scale (50–300 nodes), Floyd-Warshall at O(V³) is acceptable and simpler to implement.
- Iteratively adjusts node positions to minimize the stress function: `Σ w_ij × (||p_i - p_j|| - d_ij)²` where `d_ij` is graph-theoretic distance and `w_ij = 1/d_ij²`
- Converges monotonically (guaranteed, unlike basic KK). No oscillation.
- Run 100 iterations. Check convergence: if stress reduction < 0.1% between iterations, stop early.
- **Purpose**: Establishes correct global structure — nodes far apart in the network are far apart spatially.

**Phase 3 — Fruchterman-Reingold Refinement** (same as current, but now operating on a good starting layout):
- Standard repulsion (Coulomb) + attraction (Hooke) + gravity + damping + collision
- 200 iterations with decaying temperature
- **Purpose**: Fine-tunes local neighbor spacing, resolves overlaps, makes the layout feel "spring-like."

**Phase 4 — PrEd Edge-Crossing Reduction** (new):
- Algorithm: Improved PrEd (Simonetto et al., 2011)
- After layout stabilizes, add a repulsive force between each node and non-incident edges
- The force prevents nodes from crossing edges they don't belong to
- Run 50 iterations with low temperature (small movements only — don't disrupt the global layout)
- **Purpose**: Reduces edge crossings without changing the overall structure. This is the "polish" pass.

### 7.2 Performance Budget (Updated)

| Phase | 200 nodes | 300 nodes | 500 nodes |
|-------|-----------|-----------|-----------|
| Initial placement | < 10ms | < 15ms | < 25ms |
| All-pairs shortest path | < 50ms | < 150ms | < 500ms |
| Stress majorization (100 iter) | < 200ms | < 400ms | < 800ms |
| FR refinement (200 iter) | < 300ms | < 500ms | < 1s |
| PrEd crossing reduction (50 iter) | < 100ms | < 200ms | < 400ms |
| **Total** | **< 700ms** | **< 1.3s** | **< 2.7s** |

All phases run on the `GraphBuilderService` actor. Yield to main thread (`Task.yield()`) every 50 iterations. Cancel and restart if user changes filters during computation. Display a subtle progress indicator (thin bar under the graph toolbar) during computation.

For >500 nodes, enable Barnes-Hut approximation for the FR phase (already in original spec).

### 7.3 Incremental Layout

When the graph changes incrementally (new edge, role change, new node):
- Do NOT rerun the full pipeline
- Mark affected nodes as "hot" — reset their velocity, increase their simulation temperature
- Run 50 iterations of FR on the hot subgraph (the affected nodes and their 1-hop neighbors)
- The rest of the graph stays pinned during incremental updates
- This keeps incremental updates under 200ms

### 7.4 Edge Bundling (Toggleable)

When the graph has 100+ edges, offer force-directed edge bundling from the toolbar.

**Implementation**:
- Model each edge as a polyline with 7 control points (evenly spaced between source and target)
- Run a spring simulation on control points: nearby, similarly-directed control points attract
- "Similarly directed" = the edge direction vectors (source→target) form an angle < 60°
- Attraction strength falls off with distance between control points
- 50 iterations of the bundling simulation (runs after the node layout completes)
- Render bundled edges as Bézier curves through the control points
- Use `Path` in the Canvas drawing context with `addCurve(to:control1:control2:)` segments

**Visual effect**: Transforms a tangle of straight-line crossings into visible directional "cables" that fan out at endpoints. The user can immediately see "these 12 people all connect back to this referral hub" as a coherent bundle rather than 12 crossing lines.

**Toggle behavior**: Toolbar button toggles between straight edges and bundled edges. Transition animates over 500ms (control points interpolate from straight-line positions to bundled positions or vice versa). User preference persists in UserDefaults.

---

## 8. Focus + Context Depth (Pseudo-3D)

Since SAM stays 2D (see research doc for rationale — Apple deprecated SceneKit, flat-screen 3D adds occlusion for no readability gain), create a sense of depth through focus and context rendering.

### 8.1 Selection-Based Focus

When any node is selected:
- **Selected node**: Full opacity, full size, all labels visible, all edge labels visible. Rendered on top layer.
- **1-hop neighbors**: 90% opacity, full size. Edge labels visible for connections to the selected node.
- **2-hop neighbors**: 60% opacity, 85% size scale. Edge labels hidden.
- **3+ hops**: 30% opacity, 70% size scale. Edge labels hidden. Node labels only visible at Detail zoom.
- **Edge rendering follows the same gradient**: Edges connecting to the selected node are full opacity and full width. Edges 1 hop away are 70% opacity. Edges 2+ hops away are 30% opacity.

When nothing is selected, all nodes render at uniform opacity and scale (no depth effect).

### 8.2 Edge Layer Separation

Independent of selection focus, edges render at different base opacities by type:
- **Family edges (deducedFamily)**: Foreground (100% base opacity, 2pt width)
- **Referral edges**: Midground (80% base opacity, 1.5pt width)
- **Recruiting tree edges**: Midground (80% base opacity, 1.5pt width)
- **Communication/co-attendance edges**: Background (50% base opacity, 1pt width)
- **Mention-together edges**: Background (30% base opacity, 0.5pt width, dotted)

This creates a natural visual hierarchy where the most structurally important relationships are always visible and weaker signals recede. Combined with selection focus, you get a clear foreground/background separation.

### 8.3 Topological Fisheye (Scroll-on-Node)

When the cursor hovers over a node, the scroll wheel expands or contracts that node's local neighborhood instead of zooming the viewport.

**Scroll up** (while hovering over a node):
- The node's 1-hop neighbors spread outward, creating more space between them
- Labels appear on the spread-out nodes (even if zoom level would normally hide them)
- Edge type labels become visible
- The effect applies a local zoom that increases the spacing multiplier for edges connected to the hovered node
- Maximum local expansion: 2.5× normal edge length

**Scroll down** (while hovering over a node):
- The neighborhood contracts back to normal density
- Minimum: 0.5× normal edge length (compresses the cluster)

**Scroll on empty canvas**: Normal viewport zoom (unchanged from original spec)

**How to distinguish**: Track the hovered node ID. If `hoveredNodeID != nil`, scroll events go to the topological fisheye system. If `hoveredNodeID == nil`, scroll events go to viewport zoom.

This gives a way to inspect dense clusters without losing the overall graph context — one of the most effective techniques in the graph visualization literature for exploring large networks on a limited screen.

---

## 9. Keyboard Shortcuts

### 9.1 Updated Shortcut Table

| Input | Action |
|-------|--------|
| ⌘F | Focus search — type name to locate, zoom to, and select that node |
| Esc | Deselect all. If in fisheye expansion, collapse fisheye first. If pulls are active, second Esc releases all pulls. |
| ⌘0 | Fit entire graph in viewport |
| ⌘1 | Quick filter: All nodes (remove filters) |
| ⌘2 | Quick filter: Clients only |
| ⌘3 | Quick filter: Recruiting tree only |
| ⌘4 | Quick filter: Referral network only |
| ⌘G | Toggle family clustering mode |
| ⌘B | Toggle edge bundling |
| ⌘R | Reset layout (unpin all, rerun full layout pipeline) |
| Delete/Backspace | If ghost node is selected: dismiss ghost. If real node: no action (deletion is a data operation, not a graph operation). |
| Arrow keys | When a node is selected: move selection to the nearest connected node in that direction. This enables keyboard-only graph traversal. |
| Tab | Cycle selection through nodes (sorted by production value descending — most important nodes first) |
| Space | Open contextual menu on selected node (same as right-click) |

### 9.2 Accessibility

All keyboard shortcuts also serve as the VoiceOver navigation model:

- **Tab**: Announces node name, role, health, connection count. Moves focus to next node.
- **Arrow keys**: Announces the edge type and target node. "Referral connection to Linda Martinez, Client, healthy, 5 connections."
- **Space**: Opens contextual menu with VoiceOver focus on first menu item.
- **Enter**: Navigates to PersonDetailView for the focused node.

The `accessibilityChildren` implementation from the original spec's AA.6 sub-phase should generate elements for every visible node and every edge. Each accessible element includes:
- Label: "[Name], [primary role], [health level], [N] connections, [bridge badge if present: N distant connections]"
- Hint: "Double-click to select neighborhood. Use arrow keys to traverse connections."
- Traits: `.isButton` (for click behavior)

---

## 10. Contextual Menus

### 10.1 Node Contextual Menu (Right-Click)

For **real nodes**:
```
┌────────────────────────────────┐
│ View John Johnson              │  → NavigationPath to PersonDetailView
│ ──────────────────────────────│
│ Create Note…                   │  → New note pre-tagged with this person
│ Draft Message…                 │  → Opens message compose
│ View in Awareness              │  → Opens Awareness with person focused
│ ──────────────────────────────│
│ Select Family Cluster ⌥-dbl   │  → Selects family cluster members
│ Select Referral Chain ⌘-dbl   │  → Selects referral connections  
│ Select Downline      ⇧-dbl    │  → Selects recruiting tree branch
│ ──────────────────────────────│
│ Pin Position                   │  → Pins node at current location (toggle)
│ Release Pulled Connections     │  → Only visible if node has active pulls
│ ──────────────────────────────│
│ Hide from Graph                │  → Temporarily removes from view (not from data)
└────────────────────────────────┘
```

For **ghost nodes**:
```
┌────────────────────────────────┐
│ Find Matching Contact…         │  → Search popover for merge
│ Create New Contact             │  → Creates SamPerson from ghost data
│ ──────────────────────────────│
│ Dismiss Ghost                  │  → Removes from graph, marks resolved
└────────────────────────────────┘
```

For **family boundary** (in clustering mode):
```
┌────────────────────────────────┐
│ Select Family Members          │
│ Collapse Family Cluster        │  → Merge into composite node
│ ──────────────────────────────│
│ Hide from Graph                │
└────────────────────────────────┘
```

### 10.2 Canvas Contextual Menu (Right-Click on Empty Space)

```
┌────────────────────────────────┐
│ Fit to View            ⌘0     │
│ Reset Layout           ⌘R     │
│ ──────────────────────────────│
│ Toggle Families        ⌘G     │
│ Toggle Edge Bundling   ⌘B     │
│ ──────────────────────────────│
│ Release All Pulls              │
│ Unpin All Nodes                │
│ Show Hidden Nodes              │  → Restores any nodes hidden via contextual menu
│ ──────────────────────────────│
│ Export as Image…               │
└────────────────────────────────┘
```

---

## 11. Toolbar Layout

The graph toolbar sits above the Canvas, flush with the content area. Items grouped logically:

```
[ 🔍 Search ] | [ Fit ⌘0 ] [ Zoom − ] [ 100% ] [ Zoom + ] | [ Families ⌘G ] [ Bundling ⌘B ] | [ Overlays ▾ ] | [ Reset ⌘R ] | [ Export ]
```

**Overlays dropdown** contains toggles for each intelligence overlay from AA.5:
- ☑ Referral Hubs
- ☑ Coverage Gaps
- ☐ Recruiting Health
- ☐ Communication Flow
- ☐ Time Replay (stretch)

Each overlay toggle updates the graph rendering immediately. Multiple overlays can be active simultaneously.

---

## 12. Sub-Phase Integration

This interaction spec integrates into the existing Phase AA sub-phase plan as follows:

### AA.2 — Basic Renderer (updated)
Add: Expanded hit radius (visual + 8pt), cursor feedback (openHand/closedHand), node pinning on drag.

### AA.3 — Interaction & Navigation (substantially expanded)
This is the core implementation phase for this spec. Implement in order:
1. Single-click selection, Shift+click toggle, drag behavior
2. Marquee selection (drag on empty canvas)
3. Relational-distance selection (double/triple click with modifier keys)
4. Selection ripple animation
5. Group drag with simulation re-heat
6. Bridge indicator computation and rendering
7. Gravitational pull and release mechanics
8. Ghost node drag-to-merge flow
9. Keyboard shortcuts and contextual menus
10. Lasso selection (Option+drag)

### AA.3.5 — Family Clustering (new sub-phase)
1. Family boundary rendering (rounded rectangle enclosures based on deducedFamily edge connected components)
2. Group drag behavior (drag any member moves cluster)
3. Family cluster collapse into composite node
4. Ghost-into-family merge flow (creates SamPerson + DeducedRelation)
5. Toolbar toggle and persistence

### AA.4 — Intelligence Overlays (unchanged)
No changes to overlay specs. They render on top of the new interaction model.

### AA.6 — Polish & Performance (expanded)
Add: Topological fisheye (scroll-on-node), focus + context depth rendering, edge bundling toggle, momentum on drag release, Voronoi hit testing.

### New: AA.1 Layout Algorithm Update
Replace the single-pass FR in `GraphBuilderService.layoutGraph()` with the four-phase pipeline (deterministic placement → stress majorization → FR refinement → PrEd crossing reduction). This should be implemented early — ideally as the first change — since every interaction improvement benefits from a better base layout.

---

## 13. State Model Additions

The `RelationshipGraphCoordinator` needs these new observable properties:

```swift
// Selection
var selectedNodeIDs: Set<UUID> = []         // Changed from single selectedNodeID
var selectionAnchorID: UUID?                 // The node that was clicked to start the expansion

// Family Clustering
var isFamilyClusteringActive: Bool = false    // Toolbar toggle
var collapsedFamilyClusterKeys: Set<String> = [] // Keyed by sorted person IDs in the cluster

// Bridge / Pull State
var bridgeIndicators: [UUID: BridgeInfo] = [:] // nodeID → count + distant node IDs
var activePulls: [UUID: PullState] = [:]       // bridgeNodeID → pulled node IDs + original positions

// Pinning
var pinnedNodeIDs: Set<UUID> = []             // Nodes excluded from simulation
var pinnedPositions: [UUID: CGPoint] = [:]    // Their fixed positions

// Edge Bundling
var isEdgeBundlingActive: Bool = false
var bundledEdgePaths: [UUID: [CGPoint]] = [:] // edgeID → control points (when bundling active)

// Fisheye
var fisheyeNodeID: UUID?                      // Currently expanded node (nil = no fisheye)
var fisheyeExpansion: CGFloat = 1.0           // 0.5 ... 2.5, multiplier on local edge length

// Hidden Nodes
var hiddenNodeIDs: Set<UUID> = []             // Temporarily hidden via contextual menu
```

New DTOs:

```swift
struct BridgeInfo: Sendable {
    let distantNodeIDs: [UUID]   // Nodes that are far from this bridge
    let clusterSize: ClusterSize // .small (1-5), .medium (6-15), .large (16+)
    
    enum ClusterSize { case small, medium, large }
}

struct PullState: Sendable {
    let pulledNodeIDs: Set<UUID>
    let originalPositions: [UUID: CGPoint] // Where they were before the pull
}
```

---

## 14. Animation Timing Reference

All animations use SwiftUI/Core Animation with these durations:

| Animation | Duration | Curve | Notes |
|-----------|----------|-------|-------|
| Selection ripple | 300ms | easeOut | Per hop: 100ms expand, sequential |
| Group drag | Per-frame | linear | 60fps via CADisplayLink/DisplayLink |
| Drag momentum | 300ms | easeOut | Applied on mouse-up if velocity > threshold |
| Pull migration | 600ms | spring (damping 0.7) | Elastic overshoot then settle |
| Pull release | 500ms | easeInOut | Smooth drift back to original position |
| Ghost merge dissolve | 200ms | easeIn | Scale 1→0 with opacity fade |
| Edge transfer (on merge) | 300ms | easeInOut | Edges curve from ghost position to real node |
| Family cluster collapse | 400ms | spring (damping 0.8) | Members converge to center, boundary shrinks |
| Family cluster expand | 400ms | spring (damping 0.8) | Composite splits, members spread out |
| Edge bundling toggle | 500ms | easeInOut | Control points interpolate between straight and bundled |
| Fisheye expansion | 200ms | easeOut | Local spacing increases |
| Fisheye contraction | 200ms | easeIn | Local spacing decreases |
| Focus + context opacity | 200ms | easeInOut | On selection change |
| Simulation re-heat | ~1000ms | linear decay | Alpha 0.3 → 0 over ~60 frames |
| Bridge badge pulse | 200ms | easeInOut | Scale 1.0 → 1.3 → 1.0 on click |

**Reduce Motion**: When the user has "Reduce motion" enabled in System Preferences:
- All spring animations become `easeInOut` with 0% overshoot
- Ripple animation is replaced by simultaneous highlight (no sequential expansion)
- Pull migration is instant (nodes teleport to new positions, then one 200ms settle)
- Momentum on drag release is disabled
- Communication flow particles (from AA.5 overlays) are replaced by static directional arrows

---

## What Claude Code Should Do

1. Read this spec completely alongside `phase-aa-relationship-graph.md` before planning.
2. Begin with the layout algorithm update (Section 7) — implement stress majorization and PrEd in `GraphBuilderService`. Unit test: verify that edge crossings decrease compared to pure FR. Verify convergence (stress decreases monotonically).
3. Implement interaction improvements in the order listed in Section 12 (AA.3 implementation order). Each item is independently useful — don't batch them.
4. After implementing bridge indicators (Section 3), test with real SAM data: verify that bridge badges appear on nodes with distant connections and that the pull animation moves nodes smoothly.
5. Family clustering (Section 4) can be implemented in parallel with the pull system — they're independent features that compose.
6. Ghost node merge (Section 5) depends on family clustering for the drag-into-boundary variant. Implement ghost merge after family clustering is working.
7. Edge bundling (Section 7.4) and topological fisheye (Section 8.3) are polish features. Implement after core interactions are solid.
8. Test accessibility after each major interaction feature. VoiceOver should be able to traverse the graph and discover all interactive elements.
9. All animations must respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. See Section 14 for Reduce Motion substitutions.
10. Update `context.md` and `changelog.md` after implementing each sub-section.
