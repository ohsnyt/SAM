# Phase AA Visual Design Specification

**Companion to**: `phase-aa-interaction-spec.md` (interactions), `phase-aa-relationship-graph.md` (architecture)  
**Purpose**: Define the exact visual rendering parameters so Claude Code produces a beautiful, polished graph — not just a functional one.

---

## 1. Design Philosophy

SAM's relationship graph should feel like a living document, not a technical diagram. The aesthetic reference points are Apple Maps (how it renders pins, labels, and route lines), Contacts.app (how it presents relationship cards), and the Liquid Glass design language in macOS Tahoe 26.

**Guiding principles**:

- **Content is foreground, chrome is Glass**: Nodes and edges render as opaque, well-defined content. Toolbar, tooltips, popovers, and overlays use Liquid Glass materials via `.glassEffect()`. Never apply Glass to nodes or edges themselves — they are the data, not the UI shell.
- **Warm, not clinical**: Prefer rounded shapes, soft shadows, and organic curves over sharp corners, hard lines, and geometric precision. The graph should invite exploration, not feel like an engineering schematic.
- **Calm defaults, vivid on focus**: The default graph state uses muted, harmonious colors. Intensity increases on hover, selection, and interaction. This means idle nodes have slightly desaturated fills and selection/hover adds saturation and glow.
- **Information through aesthetics**: Every visual choice encodes meaning. Color = role. Size = production value. Stroke = health. Opacity = relevance to current selection. Dash pattern = confidence level. Nothing is decorative-only.

---

## 2. Color System

### 2.1 Role Colors

These match the existing role badge colors used throughout SAM (agent.md line 282). For the graph, use these as node fill colors at 85% saturation for the idle state, full saturation on hover/selection.

| Role | Light Mode | Dark Mode | SwiftUI Asset Name |
|------|------------|-----------|-------------------|
| Client | `#34A853` (green) | `#81C995` | `Color.samClientGreen` |
| Applicant | `#F9AB00` (amber) | `#FDD663` | `Color.samApplicantAmber` |
| Lead | `#EA8600` (orange) | `#FBA94C` | `Color.samLeadOrange` |
| Vendor | `#9334E6` (purple) | `#C58AF9` | `Color.samVendorPurple` |
| Agent | `#00897B` (teal) | `#4DB6AC` | `Color.samAgentTeal` |
| External Agent | `#3949AB` (indigo) | `#7986CB` | `Color.samExternalIndigo` |
| No Role / Unknown | `#78909C` (blue-gray) | `#90A4AE` | `Color.samNeutralGray` |

**Implementation note**: Define these as named colors in the asset catalog with both Any Appearance and Dark Appearance variants. The graph renderer reads `primaryRole` from `GraphNode` and maps to the appropriate color. When a person has multiple roles, use the highest-priority role (Client > Agent > Applicant > Lead > Vendor > External Agent) for the node fill.

### 2.2 Relationship Health Colors

Applied as the **node stroke** (border ring). These signal urgency at a glance.

| Health | Stroke Color (Light) | Stroke Color (Dark) | Stroke Width |
|--------|---------------------|--------------------|----|
| Healthy | `#2E7D32` (deep green) | `#66BB6A` | 2.0pt |
| Cooling | `#F9A825` (warm yellow) | `#FFD54F` | 2.5pt |
| At Risk | `#E65100` (deep orange) | `#FF8A65` | 3.0pt |
| Cold | `#C62828` (deep red) | `#EF5350` | 3.0pt |
| Unknown | `#B0BEC5` (light gray) | `#78909C` | 1.5pt |

**Note**: Stroke width increases with urgency. This means at-risk and cold nodes are visually heavier, drawing the eye to problems. The width difference is subtle (2pt vs 3pt) but perceptible, especially when scanning a full graph.

**High Contrast mode**: All stroke widths increase by 1.5pt. Health colors shift to the system-provided high-contrast accessible palette. Add a secondary indicator inside the stroke: a small icon glyph (✓ for healthy, ↓ for cooling, ⚠ for at-risk, ✕ for cold) rendered at the 10 o'clock position of the node, 8pt, matching stroke color. This ensures health is not communicated by color alone.

### 2.3 Edge Type Colors

Edges use softer, more muted colors than nodes — they should recede behind node fills. All edge colors are applied at the opacity specified in the interaction spec's edge layer separation (Section 8.2).

| Edge Type | Color (Light) | Color (Dark) | Line Style |
|-----------|--------------|-------------|------------|
| Family (Deduced) | `.pink.opacity(0.7)` | `.pink.opacity(0.7)` | Solid; dashed if unconfirmed |
| Business | `#7E57C2` (soft purple) | `#9575CD` | Solid |
| Referral | `#26A69A` (muted teal) | `#4DB6AC` | Solid |
| Recruiting Tree | `#42A5F5` (sky blue) | `#64B5F6` | Solid |
| Co-Attendee | `#78909C` (blue-gray) | `#90A4AE` | Dash (8pt on, 4pt off) |
| Communication Link | `#8D6E63` (warm brown) | `#A1887F` | Solid, thin |
| Mentioned Together | `#BDBDBD` (light gray) | `#757575` | Dot (2pt on, 4pt off) |

**Edge gradients**: For edges connecting nodes of different role colors, the edge can optionally render as a gradient from the source node's role color to the edge type color. This is a subtle effect — only visible at Detail zoom (0.8×+) and can be toggled off. Default: off. When enabled, it makes referral chains especially readable because you can see the color flow from referrer to referred.

### 2.4 Selection and Interaction Colors

| State | Effect | Color |
|-------|--------|-------|
| Hovered node | Outer glow | System accent color (`.accentColor`) at 40% opacity, 6pt blur radius |
| Selected node | Outer glow | System accent color at 70% opacity, 8pt blur radius, + 1pt accent stroke inside the health stroke |
| Selection ripple | Expanding ring | System accent color at 30% opacity, fading to 0% at edge |
| Bridge badge | Badge background | Role-dependent: blue `#42A5F5`, orange `#FF9800`, red `#F44336` per cluster size |
| Ghost node preview | Silhouette | Current foreground color at 15% opacity |
| Pull migration path | Motion trail | System accent color at 10% opacity, 3pt width |
| Marquee/lasso | Selection rectangle/path | System accent color, 1pt dashed border, 5% fill |

**Why system accent color**: Users may customize their macOS accent color. Using `.accentColor` means the graph's interactive highlights automatically match the user's system preference, which feels native and intentional.

---

## 3. Node Rendering

### 3.1 Shape and Size

Nodes are **circles**. Not rounded squares, not hexagons, not variable shapes by type. Circles are the standard in relationship graph visualization because they have no orientation bias (no "top" or "side"), they tile efficiently in force-directed layouts, and they leave maximum space for labels below.

**Size scaling**: Node diameter scales with `productionValue` on a square-root curve, not linear. This prevents high-production clients from dominating the graph while still making them visibly larger.

```
diameter = minSize + (maxSize - minSize) × sqrt(normalizedProduction)
```

Where:
- `minSize` = 24pt (enough for a recognizable circle at all zoom levels)
- `maxSize` = 56pt (large but not overwhelming)
- `normalizedProduction` = `thisNode.productionValue / maxProductionValue` (0.0 to 1.0)
- The "Me" node (the agent/user) always renders at 56pt regardless of production

Nodes with zero production (leads, ghosts, contacts with no policies) render at `minSize` (24pt).

### 3.2 Node Fill and Photo

**Without photo**: Solid fill using the role color. At idle state, the fill is the role color at 85% saturation (slightly muted). On hover, the fill shifts to 100% saturation. On selection, the fill is 100% saturation plus the outer glow.

**With photo**: The contact photo is clipped to a circle and fills the node entirely. The role color becomes a 3pt ring between the photo edge and the health stroke — a thin colored border that identifies the role without obscuring the face. If the photo is very small or low-resolution, fall back to the solid-fill treatment.

**Photo rendering details**:
- Clip using `context.clip(to: circlePath)` in the Canvas draw call
- Apply a 0.5pt inner stroke at 20% black (in light mode) or 20% white (in dark mode) to define the photo edge against any background — this prevents light photos from disappearing into a light canvas
- Photos are drawn from `GraphNode.photoThumbnail` (pre-scaled `Data` blob). Do not load full-resolution contact photos during rendering.

### 3.3 Node Shadow

Every node gets a subtle drop shadow that creates a sense of floating above the canvas:

- **Offset**: (0, 1pt) — directly below, very slight
- **Blur radius**: 3pt
- **Color**: Black at 15% opacity (light mode), black at 30% opacity (dark mode)

On hover, the shadow intensifies:
- **Offset**: (0, 2pt)
- **Blur radius**: 6pt
- **Color**: Black at 25% opacity (light mode), black at 40% opacity (dark mode)

On drag, the shadow lifts further (simulating the node rising off the surface):
- **Offset**: (0, 4pt)
- **Blur radius**: 10pt
- **Color**: Black at 30% opacity (light mode), black at 50% opacity (dark mode)

These shadows are drawn in the Canvas before the node fill, offset by the shadow parameters. Use `context.drawLayer` with shadow configuration.

### 3.4 The "Me" Node

The agent's own node has special treatment to anchor the graph visually:

- Always 56pt diameter
- Fill: A subtle radial gradient from the system accent color (center) to the accent color at 70% saturation (edge). This makes it the most visually distinct node without using a different shape.
- Stroke: 2.5pt accent color (no health stroke — the agent doesn't have a "relationship health" with themselves)
- Label: "Me" in bold, centered below the node
- Shadow: Slightly stronger than other nodes (blur 5pt default, 8pt hover)
- Position: The layout algorithm should be biased to place this node centrally. It serves as the gravitational anchor of the network.

### 3.5 Ghost Node Rendering

Ghost nodes look intentionally provisional — the user should immediately recognize them as unresolved:

- **Fill**: Role color (if deduced) or neutral gray, at 15% opacity. The node interior should be mostly transparent, letting the canvas or edges behind it show through.
- **Stroke**: Dashed (4pt on, 4pt off), 1.5pt width, role color at 60% opacity
- **Glyph**: SF Symbol `person.fill.questionmark` centered inside the node, rendered at 60% opacity in the foreground color. Size: 60% of node diameter.
- **Shadow**: None. Ghost nodes should feel flat and insubstantial compared to real nodes.
- **Label**: Italic styling (see Section 5)
- **Animation** (idle, when `showGhostNodes` is true): The dashed stroke slowly rotates — the dash pattern offsets by 1pt per frame, creating a gentle "marching ants" effect. This subtle animation draws attention to unresolved ghosts without being distracting. At 60fps, one full rotation of the dash pattern takes about 3 seconds. Disable under Reduce Motion; use a static double-dash pattern (4on, 2off, 2on, 4off) instead to differentiate from regular dashes.

---

## 4. Edge Rendering

### 4.1 Line Width by Type and Weight

Edge thickness encodes both type importance and connection strength:

```
thickness = baseThickness × (0.5 + 0.5 × weight)
```

Where `weight` is the 0.0–1.0 value from `GraphEdge.weight` and `baseThickness` varies by type:

| Edge Type | Base Thickness | Resulting Range |
|-----------|---------------|-----------------|
| Family (Deduced) | 2.5pt | 1.25pt – 2.5pt |
| Business | 2.0pt | 1.0pt – 2.0pt |
| Referral | 2.0pt | 1.0pt – 2.0pt |
| Recruiting Tree | 2.0pt | 1.0pt – 2.0pt |
| Co-Attendee | 1.5pt | 0.75pt – 1.5pt |
| Communication | 1.5pt | 0.75pt – 1.5pt |
| Mentioned Together | 1.0pt | 0.5pt – 1.0pt |

**Minimum rendered thickness**: 0.5pt (below this, lines become invisible on retina displays). If the calculated thickness is < 0.5pt, clamp to 0.5pt.

### 4.2 Line Caps and Joins

- **Line cap**: `.round` — always. Square caps look harsh and create visual noise at intersections.
- **Line join**: `.round` — for any edges rendered as polylines (bundled edges).
- **Anti-aliasing**: Enabled by default in Canvas. Do not disable.

### 4.3 Edge Curvature for Parallel Edges

When two nodes share multiple edge types (e.g., John and Sarah are family AND have a communication link AND are co-attendees), drawing all edges as overlapping straight lines creates visual mud. Instead, offset parallel edges:

**Algorithm**:
1. For a given node pair (A, B), count the number of edges between them: `n`
2. If `n == 1`: Draw a straight line from A center to B center
3. If `n == 2`: Draw two quadratic Bézier curves. Both pass through the midpoint of A-B but are offset perpendicular to the A-B axis by ±8pt. This creates a gentle lens shape.
4. If `n == 3`: Straight line through center, two Bézier curves offset by ±12pt
5. If `n >= 4`: Use offsets of `±8pt × i` for `i = 1, 2, ...` with a straight center line if `n` is odd

**Control point calculation**: For a Bézier curve between points A and B with offset `d`:
- Midpoint: `M = (A + B) / 2`
- Perpendicular unit vector: `perp = normalize(rotate90(B - A))`
- Control point: `C = M + perp × d`
- Draw: `path.move(to: A); path.addQuadCurve(to: B, control: C)`

This spread means the user can visually distinguish multiple relationship types between the same two people, and each edge's color identifies its type.

### 4.4 Direction Arrows

For directed edges (referral: referrer → referred; recruiting: recruiter → recruit; communication: dominant direction), draw an arrowhead at the target end:

**Arrow shape**: Not a triangle. Use a **chevron** — two short lines angled 30° from the edge direction, meeting at the target point. This is visually lighter than a filled triangle and consistent with Apple's SF Symbol arrow aesthetic.

- **Arrow length**: 8pt (the two chevron lines extend 8pt back from the target point)
- **Arrow width**: 6pt (the perpendicular spread of the chevron)
- **Stroke width**: Same as the edge line width
- **Color**: Same as the edge color

For **bidirectional** edges where `isReciprocal == true` and `communicationDirection == .balanced`: draw chevrons at both ends. Make these chevrons slightly smaller (6pt length) to avoid visual heaviness.

For edges where direction is not meaningful (family (deduced), co-attendee, mentioned-together): no arrowheads.

### 4.5 Edge Hover and Selection

**Hover**: When the cursor passes within 6pt of an edge line, the edge brightens:
- Opacity increases to 100% (regardless of base layer opacity)
- Thickness increases by 1pt
- A tooltip appears at the cursor showing: "Referral: Linda → John (since Mar 2024)" — the edge type, direction, and label
- The two connected nodes receive a subtle glow (same as node hover glow but at 50% intensity), even if the cursor isn't directly over them

**Selection**: When both endpoints of an edge are selected, the edge renders at full brightness (100% opacity, edge type color at full saturation). When only one endpoint is selected, the edge renders at the focus+context opacity defined in the interaction spec.

**Hit testing for edges**: Use a 6pt-wide hit zone centered on the edge path. For curved edges (parallel offset Béziers), the hit zone follows the curve. This is implemented by checking point-to-path distance in the Canvas gesture handler.

### 4.6 Edge Entry Point on Nodes

Edges should not visually overlap the node circle. They terminate at the node's **circumference**, not its center. Calculate the intersection point of the edge line (or curve) with the node's circle boundary, and start/end the edge stroke there.

For curved parallel edges, compute the tangent direction of the Bézier at the endpoint, and place the chevron arrowhead aligned to that tangent — not aligned to the straight line between node centers.

---

## 5. Label System

Labels are one of the biggest visual quality differentiators between a "programmer graph" and a polished product. These rules ensure labels are always readable, never overlap, and never obscure critical information.

### 5.1 Font and Style

| Element | Font | Size | Weight | Style |
|---------|------|------|--------|-------|
| Node label (real) | SF Pro Text | 11pt (scales with zoom) | Regular | Normal |
| Node label (ghost) | SF Pro Text | 11pt (scales with zoom) | Regular | Italic |
| Node label ("Me") | SF Pro Text | 12pt (scales with zoom) | Semibold | Normal |
| Edge label | SF Pro Text | 9pt (scales with zoom) | Regular | Normal |
| Family boundary label | SF Pro Text | 10pt | Medium | Normal |
| Bridge badge count | SF Pro Rounded | 9pt | Bold | Normal |
| Selection count badge | SF Pro Rounded | 10pt | Bold | Normal |
| Tooltip text | System default (13pt) | — | — | — |

**Zoom scaling**: Label font size scales linearly with viewport zoom, but clamped to a readable range. If the base size is 11pt:
- At 0.3× zoom: `11 × 0.3 = 3.3pt` → clamped to minimum 7pt (barely readable, only shown on important nodes)
- At 1.0× zoom: 11pt (default)
- At 2.0× zoom: `11 × 2.0 = 22pt` → clamped to maximum 16pt (prevents labels from becoming absurdly large)

### 5.2 Label Positioning

**Primary position**: Centered horizontally below the node, with 4pt vertical gap between the node's bottom edge and the label's top.

**Collision avoidance**: Labels must not overlap other labels or other nodes. Implement a simple priority-based displacement algorithm:

1. After node positions are finalized (post-simulation), compute the bounding rect of each label at its primary position (centered below node).
2. Check for overlaps with other label rects and with other node circles.
3. For each collision, try alternative positions in priority order:
   - Below-center (primary — already tried)
   - Below-right (offset right by 50% of label width)
   - Below-left (offset left by 50% of label width)
   - Above-center
   - Right of node (label left edge at node right edge + 4pt, vertically centered)
   - Left of node (label right edge at node left edge - 4pt, vertically centered)
4. Use the first non-colliding position. If all positions collide, use the primary position but reduce opacity to 50% — the label is present but defers to more important content.
5. Node labels have higher priority than edge labels. If a node label and edge label would overlap, the edge label hides (it's available via hover tooltip).

**Truncation**: If a label exceeds the available space (e.g., a name like "Christopher Richardson-Montgomery"), truncate with ellipsis. Maximum label width: 120pt (at 1.0× zoom). For names that truncate, the full name is always visible in the hover tooltip.

### 5.3 Label Background

At Detail zoom (0.8×+), render a subtle background pill behind each label:
- Background: Canvas background color at 80% opacity (effectively a frosted backing)
- Corner radius: 3pt
- Padding: 2pt horizontal, 1pt vertical
- This prevents labels from becoming illegible when they cross over edges

At lower zoom levels, labels render without a background (they're too small for the pill to be meaningful).

### 5.4 Label Visibility by Zoom Level

Not all labels should appear at all zoom levels. In a 200-node graph at overview zoom, 200 labels would be unreadable noise.

| Zoom Level | Node Labels Shown | Edge Labels Shown |
|------------|------------------|-------------------|
| Distant (< 0.3×) | None | None |
| Overview (0.3–0.5×) | Top 10 by production value, + "Me" node, + any selected | None |
| Overview+ (0.5–0.8×) | Top 30 by production value, + all selected, + all hovered neighborhood | None |
| Detail (0.8–2.0×) | All visible nodes | Labels on edges connected to selected or hovered node only |
| Close-up (> 2.0×) | All visible nodes | All edges |

**Transition**: Labels don't pop in/out abruptly. As zoom crosses a threshold, newly qualifying labels fade in over 150ms (opacity 0 → 1). Labels being hidden fade out over 150ms.

### 5.5 Edge Labels

Edge labels (e.g., "spouse," "referred," "recruiter") render at the midpoint of the edge, offset 4pt perpendicular to the edge direction (above the line for left-to-right edges, below for right-to-left — this keeps labels consistently readable).

For curved parallel edges, the label follows the curve and is positioned at the Bézier midpoint (t = 0.5), offset perpendicular to the tangent at that point.

Edge labels are always smaller and more subdued than node labels. Color: 60% opacity foreground color. They should never compete with node labels for attention.

---

## 6. Reciprocal Relationship Deduction

This addresses the bidirectional confirmation problem David raised: when SAM deduces "John is Sarah's father" and "Sarah is John's daughter," those are the same relationship stated from two perspectives. They must be confirmed in a single action, not two separate prompts.

### 6.1 Reciprocal Relationship Pairs

Define a set of known reciprocal pairs. When one side is deduced, the other is implied:

| Relationship A → B | Relationship B → A |
|--------------------|--------------------|
| father | daughter / son |
| mother | daughter / son |
| parent | child |
| spouse | spouse |
| sibling | sibling |
| referrer | referred |
| recruiter | recruit |
| employer | employee |
| mentor | mentee |

### 6.2 Deduction and Confirmation Flow

When the graph builder or AI pipeline deduces a relationship:

1. **Check for reciprocal**: If "John → father → Sarah" is deduced, automatically compute the reciprocal "Sarah → daughter → John."
2. **Present as a single confirmation**: The ghost merge popover or relationship confirmation dialog shows both sides:
   ```
   ┌───────────────────────────────────────────┐
   │  Relationship Detected                     │
   │                                           │
   │  John Johnson  ←→  Sarah Johnson          │
   │                                           │
   │  John is Sarah's father                   │
   │  Sarah is John's daughter                 │
   │                                           │
   │  Source: Mentioned in John's note          │
   │          (Dec 12, 2025)                    │
   │                                           │
   │         [ Dismiss ]    [ Confirm ]         │
   └───────────────────────────────────────────┘
   ```
3. **Single confirmation creates both edges**: Clicking "Confirm" creates both the father→daughter and daughter→father relationship records in the data model. The graph adds or updates a single bidirectional edge.
4. **Single edge, dual labels**: In the graph, reciprocal relationships render as a single edge (not two parallel edges). The edge label shows the dominant perspective based on context — when hovering near John's end, the tooltip says "father of Sarah." When hovering near Sarah's end, it says "daughter of John." The visible label on the edge shows the shorter/more common form, e.g., "parent-child" or "father / daughter."

### 6.3 Relationship Type Inference for Gender

When SAM deduces "parent" from a note like "spoke with John about his kid Sarah," and gender information is available from the contact card:
- If the parent's gender is known → "father" or "mother" instead of "parent"
- If the child's gender is known → "son" or "daughter" instead of "child"
- If neither is known → keep "parent" / "child" as the generic label

The confirmation dialog should show the most specific available terminology. This detail matters for WFG agents who think in terms of "John's wife" and "Sarah's daughter," not "John's spouse" and "Sarah's child."

### 6.4 Deduplication of Existing Relationships

Before presenting a confirmation, check whether the relationship already exists. If John is already marked as Sarah's father in the data model, do not prompt again when a new note mentions the same relationship. Instead, silently increment the evidence count on the existing edge (increasing its weight/confidence).

If a new deduction *contradicts* an existing relationship (e.g., existing: "John is Sarah's colleague," new deduction: "John is Sarah's father"), present both and let the user resolve:
```
┌───────────────────────────────────────────────┐
│  Relationship Update                           │
│                                               │
│  John and Sarah are currently linked as:      │
│  "colleagues" (since Oct 2024)                │
│                                               │
│  New evidence suggests they may also be:      │
│  "father / daughter"                          │
│                                               │
│  Source: John's note (Dec 12, 2025):          │
│  "met with my daughter Sarah about..."        │
│                                               │
│   [ Keep Existing ]  [ Add Both ]  [ Replace ]│
└───────────────────────────────────────────────┘
```

---

## 7. Family Cluster Boundary Rendering

A family cluster boundary encloses the connected component of deduced-family relationships. The label is derived from the shared surname among members (e.g., "Johnson Family").

### 7.1 Boundary Shape

Use a **rounded rectangle** that dynamically sizes to enclose all family cluster member nodes, computed as follows:

1. Find the axis-aligned bounding box of all member node centers
2. Expand the box by `memberNodeMaxRadius + 20pt` on each side (the 20pt is visual padding so nodes don't touch the edge)
3. Apply corner radius: `min(24pt, shortestSide / 4)` — this prevents over-rounding on narrow tall family clusters while keeping generous rounding on wider ones

**Alternative for 2-member family clusters**: When a family cluster has exactly 2 members, a rounded rectangle degenerates into a wide pill. This is acceptable — two nodes side by side inside a capsule shape looks clean.

### 7.2 Boundary Fill and Stroke

- **Fill**: Dominant role color of the family cluster at 6% opacity (light mode) / 8% opacity (dark mode). "Dominant role" = the role with the most members, or the highest-priority role if tied. This creates a barely-there tint that groups the members visually without competing with node fills.
- **Stroke**: Same color at 20% opacity, 1pt width, no dash
- **Corner radius**: As computed above

The boundary should feel like a soft, translucent cloud behind the nodes — not a hard container. Think of it as a highlight swatch on a whiteboard, not a drawn box.

### 7.3 Boundary Label

- Position: Inside the boundary, top-left corner, 8pt inset from the rounded corner
- Font: SF Pro Text, 10pt, Medium weight
- Color: Foreground color at 40% opacity
- Content: The family cluster name derived from shared surname (e.g., "Johnson Family")
- Truncation: Truncate to 24 characters with ellipsis. Family cluster names longer than this are available in the tooltip.
- Visibility: Only at Overview+ zoom (0.5×) and above. Below that, the boundary shape alone provides grouping information.

---

## 8. Tooltip Rendering

### 8.1 Tooltip Material

Tooltips use Liquid Glass: apply `.glassEffect(.regular)` to the tooltip container view if rendering as a SwiftUI overlay, or simulate the frosted-glass look in Canvas with a blurred background rect + semi-transparent white fill if rendering within the Canvas draw cycle.

**Recommended approach**: Render tooltips as SwiftUI overlay views positioned above the Canvas, not drawn inside the Canvas. This gives you native Liquid Glass, Dynamic Type support, and proper text rendering. Position the overlay using the node's screen-space coordinates converted from Canvas space.

### 8.2 Tooltip Content Layout

```
┌─────────────────────────────────────┐
│ ┌────┐  John Johnson                │
│ │ 📷 │  Client · Agent              │  ← Photo + name + role badges
│ └────┘  ❤️ Healthy                   │  ← Health with color dot
│─────────────────────────────────────│
│ 8 connections · 3 referrals made    │  ← Quick stats
│ Last contact: 3 days ago            │
│─────────────────────────────────────│
│ 💡 Schedule annual review —         │  ← Top coaching outcome
│    renewal coming in 45 days        │
└─────────────────────────────────────┘
```

- **Width**: 240pt fixed
- **Photo**: 32×32pt circle, clipped same as node photo
- **Appearance delay**: 400ms hover before tooltip appears (prevents flicker during quick mouse traversal)
- **Disappearance**: Tooltip fades out 200ms after cursor leaves the node hit zone
- **Position**: Prefer above-right of the node. If that would go off-screen, try above-left, then below-right, then below-left.

### 8.3 Edge Tooltip

Simpler than node tooltip. Appears on edge hover:

```
┌─────────────────────────────────────┐
│ Referral                            │
│ Linda Martinez → John Johnson       │
│ Since: March 2024                   │
│ Strength: ████████░░ Strong         │
└─────────────────────────────────────┘
```

- **Width**: 200pt
- **Strength bar**: A 60pt-wide horizontal bar filled proportionally to `edge.weight`. Color matches edge type color.

---

## 9. Canvas Background

### 9.1 Background Color

- **Light mode**: `#F8F9FA` — a very light warm gray, slightly warmer than pure white. Pure white is harsh and makes colored nodes look fluorescent.
- **Dark mode**: `#1A1A2E` — a very dark blue-gray. Pure black (`#000000`) is harsh; this dark tone has just enough warmth to feel intentional.

Define these as `Color.samGraphBackground` in the asset catalog.

### 9.2 Grid Pattern (Optional)

When nodes are being dragged (and the snap-to-grid feature is enabled), render a subtle dot grid:
- Dot spacing: 20pt
- Dot size: 1pt
- Dot color: foreground color at 8% opacity
- The grid fades in when drag begins, fades out 300ms after drag ends
- Default: off. Enable via a toolbar option or preference.

No grid should be visible during normal viewing. The graph should feel organic, not mechanical.

---

## 10. Dark Mode Adaptation

SAM must look intentionally designed in both light and dark mode, not simply inverted.

**General principles**:
- Node fills are slightly more saturated in dark mode (the darker background absorbs more color, so saturation needs to increase ~10% to maintain perceived vibrancy)
- Shadows shift from subtle (light mode) to more pronounced (dark mode) — shadows do more visual work when the background is dark
- Edge colors shift to their lighter variants (see Section 2.3 color table)
- Ghost node dashed strokes increase to 70% opacity (they're harder to see against dark backgrounds at 60%)
- Family boundary fills increase to 8% opacity (see Section 7.2)
- Label background pills use the canvas background color at 85% opacity

**Specific adjustments**:

| Element | Light Mode | Dark Mode |
|---------|-----------|-----------|
| Node shadow opacity | 15% | 30% |
| Node shadow blur | 3pt | 4pt |
| Edge base opacity | Per type (Section 2.3) | +10% across the board |
| Label color | Primary foreground | Primary foreground (no change — system handles this) |
| Label background pill | Canvas BG at 80% | Canvas BG at 85% |
| Selection glow | Accent at 70% | Accent at 80% |
| Canvas background | `#F8F9FA` | `#1A1A2E` |

---

## 11. Transition and Animation Polish

Beyond the timing table in the interaction spec, these visual details make animations feel premium:

### 11.1 Spring Parameters

All spring animations use these parameters unless otherwise specified:

- **Responsive spring** (for UI feedback — selection glow, badge pulse): `Animation.spring(response: 0.3, dampingFraction: 0.7)`
- **Interactive spring** (for drag release, pull migration): `Animation.spring(response: 0.5, dampingFraction: 0.65)` — slightly underdamped for a gentle bounce
- **Structural spring** (for layout changes, family cluster collapse): `Animation.spring(response: 0.6, dampingFraction: 0.8)` — more damped, feels weighty

### 11.2 Glow Animation on Selection

When a node is selected, the glow doesn't just appear — it blooms:
1. Frame 0: No glow
2. Frame 0–100ms: Glow radius expands from 0 to 12pt, opacity rises from 0 to accent color at 70%
3. Frame 100–200ms: Glow settles from 12pt to its resting 8pt radius (slight overshoot and return)
4. Steady state: 8pt glow at 70% opacity, with a very slow pulse (opacity oscillates between 65% and 75% over 2 seconds, sinusoidal). This pulse is barely perceptible but makes the selection feel alive rather than static.
5. On deselection: Glow fades from 70% to 0% over 150ms, radius shrinks from 8pt to 0.

**Reduce Motion**: Glow appears instantly at steady state (no bloom animation). No pulse.

### 11.3 Node Hover Transition

When the cursor enters a node's hit zone:
- Fill saturation animates from 85% to 100% over 100ms
- Shadow transitions from idle to hover values over 100ms
- Glow fades in over 100ms

When the cursor exits:
- All hover effects fade out over 150ms (slightly slower than fade-in, per Apple's HIG guidance that exit transitions should be gentler)

---

## 12. Performance Considerations for Visual Quality

### 12.1 Canvas Drawing Order

Draw layers strictly in this order (back to front):
1. Canvas background fill
2. Grid dots (if active during drag)
3. Family cluster boundaries (fill, then stroke)
4. Edges (sorted by type: mention-together first, then communication, then co-attendee, then recruiting/referral/business, then family (deduced) last — so the most important edges draw on top)
5. Edge labels (only where visible per zoom rules)
6. Ghost node preview silhouettes (during pull hover)
7. Node shadows
8. Node fills (with photo mask where applicable)
9. Node strokes (health ring)
10. Role color ring (between photo and health stroke, if photo present)
11. Node glyphs (ghost "?" icon, pin 📌 icon, bridge badge)
12. Node labels (with background pills where applicable)
13. Selection glow and ripple effects
14. Marquee/lasso selection shapes
15. Drag motion indicators

### 12.2 Off-Screen Culling

Do not draw any element whose bounding box is entirely outside the current viewport. For a 200-node graph at overview zoom, easily half the nodes may be off-screen. Check `viewport.contains(nodeBoundingRect.insetBy(dx: -20, dy: -20))` before drawing each node and its associated labels/edges. The 20pt inset ensures that partially visible elements still draw (preventing pop-in at viewport edges).

### 12.3 Level of Detail Rendering

At **Distant zoom (< 0.3×)**: Skip photo rendering, skip label rendering, skip edge labels, draw nodes as simple filled circles (no shadow, no stroke, no glyph). Draw edges as simple lines (no arrows, no dash patterns). This keeps the Distant zoom at maximum performance for large graphs.

At **Overview zoom (0.3–0.8×)**: Add node strokes and role colors. Add labels on priority nodes. Add edge type colors but skip edge labels and arrows.

At **Detail zoom (0.8–2.0×)**: Full rendering — photos, shadows, labels, arrows, everything.

At **Close-up zoom (> 2.0×)**: Add role badge glyphs, edge labels on all edges, maximum detail.

These LOD transitions should be smooth — cross-fade new detail in over 100ms as zoom crosses each threshold, rather than popping in abruptly.

---

## 13. Accessibility Beyond VoiceOver

### 13.1 Color Blindness

The role colors in Section 2.1 include green, amber, orange, purple, teal, and indigo. The green-orange pair and the teal-indigo pair could be problematic for deuteranopia (red-green color blindness).

**Mitigation**: Never rely on color alone to communicate role. Each role also has a unique **glyph** that appears inside the node at Close-up zoom (> 2.0×) and in tooltips at all zoom levels:

| Role | Glyph (SF Symbol) |
|------|--------------------|
| Client | `person.crop.circle.badge.checkmark` |
| Applicant | `person.crop.circle.badge.clock` |
| Lead | `person.crop.circle.badge.plus` |
| Vendor | `building.2.crop.circle` |
| Agent | `person.crop.circle.badge.fill` |
| External Agent | `person.2.circle` |

Additionally, the edge type colors in Section 2.3 are differentiated by line style (solid vs. dashed vs. dotted) as well as color, so color is never the sole differentiator.

### 13.2 Reduce Transparency

When the user has "Reduce transparency" enabled in System Preferences:
- Ghost node fills change from 15% opacity to 30% opacity with a visible hatch pattern
- Family boundary fills change from 6% to 15% opacity
- Label background pills become fully opaque
- Tooltip backgrounds become fully opaque (no Glass effect)
- Canvas background remains solid (no change)

### 13.3 Increase Contrast

When the user has "Increase contrast" enabled:
- All node strokes increase by 1pt
- All edge base thicknesses increase by 0.5pt
- Label font weight increases by one step (Regular → Medium, Medium → Semibold)
- Selection glow opacity increases to 90%
- Ghost node stroke increases to 80% opacity

---

## What Claude Code Should Do

1. **Read this spec alongside the interaction spec and the main architecture spec** before implementing any visual rendering. All three documents work together.
2. **Create the color assets first**: Define all named colors in Section 2 in the asset catalog with light and dark variants. Use `Color("samClientGreen")` style references throughout — never hard-code hex values in drawing code.
3. **Implement node rendering before edge rendering**. Get nodes looking right first (fill, stroke, shadow, photo clipping), then add edges. Edges are more complex due to parallel offsets and label positioning.
4. **Test label collision avoidance with real data**. Synthetic test data often has short, uniform-length names. Real WFG agent contacts include names like "Christopher Richardson-Montgomery III" and "Dr. Amara Osei-Bonsu." Test with a mix of name lengths and verify truncation and displacement work correctly.
5. **Test dark mode and light mode independently**. Do not assume that "it looks good in light mode" means it looks good in dark mode. Shadows, ghost nodes, and edge visibility all need dark-mode-specific tuning.
6. **Test at all four zoom levels**. Verify LOD transitions are smooth, labels fade in/out correctly, and the graph looks intentionally designed at every zoom level — not just the one you happened to develop at.
7. **Respect all accessibility settings**: VoiceOver, Reduce Motion, Reduce Transparency, Increase Contrast. Test each independently. The graph should be usable and attractive under every combination.
8. **The reciprocal relationship confirmation flow** (Section 6) is a data-layer change that affects `GraphBuilderService` and the ghost merge UI. Implement it before the ghost merge interaction — the merge popover needs to display reciprocal pairs correctly.
9. **Edge rendering is the highest-risk visual area**. Parallel edge curvature, arrow placement at node circumference, label positioning along curves, and edge bundling all compound in complexity. Implement straight single-edges first, then add parallel offsets, then arrows, then edge labels. Test each layer before adding the next.
10. **Screenshot at each milestone** and compare against this spec. Does the node shadow feel like it's floating? Do family cluster boundaries feel like soft clouds? Do ghost nodes feel provisional? If the answer is no, the parameters need tuning.
