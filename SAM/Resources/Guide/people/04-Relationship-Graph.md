# Relationship Graph

The Relationship Graph visualizes your entire network as an interactive map of people and their connections.

## Navigation

| Action | How |
|--------|-----|
| **Pan** | Click and drag the canvas |
| **Zoom** | Scroll wheel or pinch gesture |
| **Select** | Click any node |
| **Multi-select** | Shift+click to add nodes to selection |
| **Marquee select** | Click and drag on empty space to select all nodes in a rectangle |
| **Lasso select** | Freehand draw around nodes to select them |
| **Navigate connections** | Shift+Arrow keys to move selection to connected nodes |
| **Open detail** | Double-click a node to go to that person's detail view |
| **Clear selection** | Press Escape |

## Node Appearance

Each node represents a person in your network:

- **Size** scales with production value — bigger nodes mean more business
- **Color** matches role badges (green=Client, yellow=Applicant, orange=Lead, teal=Agent, etc.)
- **Photo or initials** displayed inside the circle
- **Ghost nodes** appear semi-transparent with a marching-ants border — these are people mentioned in notes but not yet confirmed as contacts

Hover over any node to see a tooltip with name, roles, and a production summary.

## Edge Types

Lines between nodes represent different relationship types:

| Line Style | Relationship |
|-----------|-------------|
| **Solid** | Referral — one person referred the other |
| **Dashed** | Recruiting — prospect-to-agent relationship |
| **Light** | Co-attendance — appeared in the same meeting or event |
| **Dotted** | Communication — email or message exchange |
| **Double** | Deduced family — automated family detection |
| **Marching ants** | Ghost mention — unconfirmed reference from notes |

Hover over any edge to see the relationship label and confidence score.

## Toolbar Controls

| Control | What It Does |
|---------|-------------|
| **Reset View** | Zoom to fit the entire graph in the viewport |
| **Family Clustering** | Toggle to collapse family groups into clusters |
| **Edge Bundling** | Reduce visual clutter by bundling nearby edges |
| **Intelligence Overlays** | Menu with visualization modes (see below) |
| **Role Filters** | Show only people with specific roles |

## Intelligence Overlays

The overlay menu lets you visualize different dimensions of your network:

- **Referral Hub Detection** — Highlights people who generate the most referrals
- **Communication Flow** — Shows the direction and intensity of communication
- **Recruiting Tree Health** — Visualizes your recruiting pipeline as a tree structure
- **Coverage Gap Detection** — Identifies underserved areas in your network

## Working with Ghost Nodes

Ghost nodes represent people mentioned in your notes who aren't yet SAM contacts. You can:

- **Drag a ghost onto a real node** to link them (SAM asks for confirmation)
- **Right-click a ghost** to merge it with an existing contact or dismiss it
- **Dismiss** removes the ghost from view

## Context Menu

Right-click any node for quick actions:

- **Show in Detail View** — Navigate to their profile
- **Edit Relationships** — Modify connections
- **Merge** — Combine duplicate contacts
- **Hide This Node** — Remove from the graph view
- **Mark Family** — Group with related contacts for family clustering

## Tips

- Use Referral Hub Detection to identify your best referral sources
- Family clustering helps you see household relationships at a glance
- Shift+Arrow keys are the fastest way to explore connections from a selected person
- The graph rebuilds automatically when you add contacts or relationships

---

## See Also

- **Contact List** — Browse and filter your contacts in list form with health indicators
- **Person Detail** — Open a person's full profile by double-clicking their node in the graph
