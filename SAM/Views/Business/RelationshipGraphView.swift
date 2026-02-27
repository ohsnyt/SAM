//
//  RelationshipGraphView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA.2: Basic Graph Renderer
//  Phase AA.3: Interaction & Navigation
//
//  Canvas-based relationship network visualisation with pan, zoom,
//  click-to-select, hover tooltips, context menu, double-click
//  navigation, node dragging, keyboard shortcuts, and search-to-zoom.
//

import SwiftUI
import Combine

struct RelationshipGraphView: View {

    // MARK: - Coordinator

    @State private var coordinator = RelationshipGraphCoordinator.shared

    // MARK: - Viewport State

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGPoint = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGPoint = .zero
    @State private var canvasSize: CGSize = .zero

    // MARK: - Interaction State

    @State private var hoveredNodeID: UUID?
    @State private var hoverScreenPosition: CGPoint = .zero
    @State private var draggedNodeID: UUID?
    @State private var searchText: String = ""
    @State private var searchIsActive: Bool = false
    @FocusState private var searchFieldFocused: Bool

    // Ghost merge state
    @State private var showGhostMergePicker: Bool = false
    @State private var ghostMergeSourceName: String = ""
    @State private var dropTargetNodeID: UUID?
    @State private var showDropMergeConfirmation: Bool = false
    @State private var pendingDropMergePersonID: UUID?

    // Edge confirmation state
    @State private var showEdgeConfirmAlert: Bool = false
    @State private var pendingEdgeConfirmation: GraphEdge?

    // Edge hover state
    @State private var hoveredEdge: GraphEdge?

    // MARK: - Navigation

    @AppStorage("sam.sidebar.selection") private var sidebarSelection: String = "graph"

    // MARK: - Body

    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .toolbar {
                GraphToolbarView(
                    coordinator: coordinator,
                    scale: $scale,
                    offset: $offset,
                    fitToView: fitToView
                )
            }
            .task {
                if coordinator.graphStatus != .ready {
                    let bounds = canvasSize.width > 0 ? canvasSize : CGSize(width: 1200, height: 800)
                    await coordinator.buildGraph(bounds: bounds)
                    fitToView()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samPersonDidChange)) { note in
                if let personID = note.userInfo?["personID"] as? UUID {
                    coordinator.updateNode(personID: personID)
                } else {
                    Task {
                        await coordinator.rebuildIfStale()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .samUndoDidRestore)) { _ in
                Task {
                    await coordinator.rebuildIfStale()
                    fitToView()
                }
            }
            .onKeyPress(.escape) { handleEscape() }
            .onKeyPress(phases: .down) { keyPress in
                handleKeyPress(keyPress)
            }
            .sheet(isPresented: $showGhostMergePicker) {
                GhostMergePersonPicker(
                    ghostName: ghostMergeSourceName,
                    onSelect: { person in
                        showGhostMergePicker = false
                        Task {
                            await coordinator.mergeGhost(
                                named: ghostMergeSourceName,
                                intoPersonID: person.id
                            )
                            fitToView()
                        }
                    },
                    onCancel: { showGhostMergePicker = false }
                )
            }
            .alert(
                "Link Ghost to Contact?",
                isPresented: $showDropMergeConfirmation
            ) {
                Button("Link") {
                    guard let targetID = pendingDropMergePersonID else { return }
                    Task {
                        await coordinator.mergeGhost(
                            named: ghostMergeSourceName,
                            intoPersonID: targetID
                        )
                        fitToView()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let targetID = pendingDropMergePersonID,
                   let targetNode = coordinator.nodes.first(where: { $0.id == targetID }) {
                    Text("Link all \"\(ghostMergeSourceName)\" mentions to \(targetNode.displayName)?")
                }
            }
            .alert("Confirm Relationship?", isPresented: $showEdgeConfirmAlert) {
                Button("Confirm") {
                    if let edge = pendingEdgeConfirmation,
                       let relID = edge.deducedRelationID {
                        coordinator.confirmDeducedRelation(id: relID)
                    }
                    pendingEdgeConfirmation = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingEdgeConfirmation = nil
                }
            } message: {
                if let edge = pendingEdgeConfirmation {
                    let sourceName = coordinator.nodes.first(where: { $0.id == edge.sourceID })?.displayName ?? "?"
                    let targetName = coordinator.nodes.first(where: { $0.id == edge.targetID })?.displayName ?? "?"
                    Text("\(sourceName) is \(edge.label ?? "related to") \(targetName)")
                }
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            statusContent
            searchOverlay
            tooltipOverlay
            edgeTooltipOverlay
            focusModeOverlay
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch coordinator.graphStatus {
        case .idle:
            ContentUnavailableView(
                "Relationship Map",
                systemImage: "circle.grid.cross",
                description: Text("Loading graph data…")
            )
        case .computing:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(coordinator.progress)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            ContentUnavailableView(
                "Unable to Build Graph",
                systemImage: "exclamationmark.triangle",
                description: Text(coordinator.progress)
            )
        case .ready:
            graphCanvas
        }
    }

    @ViewBuilder
    private var searchOverlay: some View {
        if searchIsActive {
            VStack {
                HStack {
                    Spacer()
                    searchField
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var tooltipOverlay: some View {
        if let hovID = hoveredNodeID,
           hovID != draggedNodeID,
           let node = coordinator.nodes.first(where: { $0.id == hovID }) {
            let edgeCount = coordinator.edges.filter { $0.sourceID == hovID || $0.targetID == hovID }.count
            GraphTooltipView(node: node, edgeCount: edgeCount)
                .position(tooltipPosition(for: hoverScreenPosition))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var edgeTooltipOverlay: some View {
        if let edge = hoveredEdge, edge.edgeType == .deducedFamily,
           hoveredNodeID == nil {
            let sourceName = coordinator.nodes.first(where: { $0.id == edge.sourceID })?.displayName ?? "?"
            let targetName = coordinator.nodes.first(where: { $0.id == edge.targetID })?.displayName ?? "?"
            let status = edge.isConfirmedDeduction ? "confirmed" : "unconfirmed"
            let hint = edge.isConfirmedDeduction ? "" : "\nDouble-click to confirm"
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sourceName) — \(edge.label ?? "related") — \(targetName)")
                    .font(.caption.bold())
                Text("(\(status))\(hint)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(tooltipPosition(for: hoverScreenPosition))
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var focusModeOverlay: some View {
        if coordinator.focusMode != nil {
            VStack {
                HStack {
                    Image(systemName: "scope")
                    Text("Showing deduced relationships")
                        .font(.callout.bold())
                    Button("Exit Focus Mode") {
                        coordinator.clearFocusMode()
                        fitToView()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
                Spacer()
            }
        }
    }

    // MARK: - Keyboard Handlers

    private func handleEscape() -> KeyPress.Result {
        if searchIsActive {
            searchIsActive = false
            searchText = ""
            return .handled
        }
        coordinator.selectedNodeID = nil
        return .handled
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard keyPress.modifiers.contains(.command) else { return .ignored }
        switch keyPress.key {
        case "f":
            searchIsActive = true
            searchFieldFocused = true
            return .handled
        case "1":
            coordinator.activeRoleFilters.removeAll()
            coordinator.activeEdgeTypeFilters.removeAll()
            coordinator.applyFilters()
            return .handled
        case "2":
            coordinator.activeRoleFilters = ["Client"]
            coordinator.activeEdgeTypeFilters.removeAll()
            coordinator.applyFilters()
            return .handled
        case "3":
            coordinator.activeRoleFilters.removeAll()
            coordinator.activeEdgeTypeFilters = [.recruitingTree]
            coordinator.applyFilters()
            return .handled
        case "4":
            coordinator.activeRoleFilters.removeAll()
            coordinator.activeEdgeTypeFilters = [.referral]
            coordinator.applyFilters()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find person…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit {
                    performSearch()
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 220)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return }

        if let match = coordinator.nodes.first(where: {
            $0.displayName.lowercased().contains(query)
        }) {
            coordinator.selectedNodeID = match.id
            zoomToNode(match)
            searchIsActive = false
            searchText = ""
        }
    }

    private func zoomToNode(_ node: GraphNode) {
        withAnimation(.easeInOut(duration: 0.4)) {
            coordinator.viewportCenter = node.position
            scale = max(scale, 1.0)
            lastScale = scale
            offset = .zero
            lastOffset = .zero
        }
    }

    // MARK: - Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)

                // --- 1. Edges ---
                drawEdges(context: &context, center: c)

                // --- 2. Nodes ---
                drawNodes(context: &context, center: c)

                // --- 3. Labels ---
                drawLabels(context: &context, center: c, size: size)

                // --- 4. Selection ring ---
                drawSelection(context: &context, center: c)
            }
            .onAppear {
                canvasSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
            }
            // Zoom
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let proposed = lastScale * value
                        scale = min(max(proposed, 0.1), 5.0)
                    }
                    .onEnded { _ in
                        lastScale = scale
                    }
            )
            // Drag: pan viewport or reposition node (+ ghost merge drop)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if draggedNodeID == nil {
                            // Determine if drag started on a node
                            let startGP = graphPoint(value.startLocation, center: center)
                            if let hitNode = hitTestNode(at: startGP) {
                                draggedNodeID = hitNode.id
                            }
                        }

                        if let dragID = draggedNodeID,
                           let idx = coordinator.nodes.firstIndex(where: { $0.id == dragID }) {
                            // Reposition the dragged node
                            let gp = graphPoint(value.location, center: center)
                            coordinator.nodes[idx].position = gp
                            coordinator.nodes[idx].isPinned = true

                            // Ghost → real node drop target detection
                            let draggedNode = coordinator.nodes[idx]
                            if draggedNode.isGhost {
                                let hitTarget = hitTestNode(at: gp)
                                if let target = hitTarget,
                                   target.id != dragID,
                                   !target.isGhost {
                                    dropTargetNodeID = target.id
                                } else {
                                    dropTargetNodeID = nil
                                }
                            }
                        } else {
                            // Pan viewport
                            offset = CGPoint(
                                x: lastOffset.x + value.translation.width,
                                y: lastOffset.y + value.translation.height
                            )
                        }
                    }
                    .onEnded { _ in
                        // Check if a ghost was dropped on a real node
                        if let dragID = draggedNodeID,
                           let targetID = dropTargetNodeID,
                           let draggedNode = coordinator.nodes.first(where: { $0.id == dragID }),
                           let targetNode = coordinator.nodes.first(where: { $0.id == targetID }),
                           draggedNode.isGhost && !targetNode.isGhost {
                            ghostMergeSourceName = draggedNode.displayName
                            pendingDropMergePersonID = targetID
                            showDropMergeConfirmation = true
                        }

                        draggedNodeID = nil
                        dropTargetNodeID = nil
                        lastOffset = offset
                    }
            )
            // Double-click to navigate
            .onTapGesture(count: 2) { location in
                handleDoubleTap(at: location, center: center)
            }
            // Single-click to select
            .onTapGesture { location in
                handleTap(at: location, center: center)
            }
            // Hover tracking for tooltips
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverScreenPosition = location
                    let gp = graphPoint(location, center: center)
                    let hitNode = hitTestNode(at: gp)
                    hoveredNodeID = hitNode?.id
                    // Edge hover only when not over a node
                    if hitNode == nil {
                        hoveredEdge = hitTestEdge(at: location, center: center)
                    } else {
                        hoveredEdge = nil
                    }
                case .ended:
                    hoveredNodeID = nil
                    hoveredEdge = nil
                }
            }
            // Context menu based on hovered node
            .contextMenu {
                if let hovID = hoveredNodeID ?? coordinator.selectedNodeID,
                   let node = coordinator.nodes.first(where: { $0.id == hovID }) {
                    contextMenuItems(for: node)
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for node: GraphNode) -> some View {
        if node.isGhost {
            Button {
                addGhostAsContact(node)
            } label: {
                Label("Add as Contact", systemImage: "person.crop.circle.badge.plus")
            }

            Button {
                ghostMergeSourceName = node.displayName
                showGhostMergePicker = true
            } label: {
                Label("Link to Existing Contact…", systemImage: "link.badge.plus")
            }
        } else {
            Button {
                navigateToPerson(node.id)
            } label: {
                Label("View Person", systemImage: "person.circle")
            }
        }

        Button {
            coordinator.selectedNodeID = node.id
            zoomToNode(node)
        } label: {
            Label("Focus in Graph", systemImage: "scope")
        }

        if node.isPinned {
            Divider()

            Button {
                if let idx = coordinator.nodes.firstIndex(where: { $0.id == node.id }) {
                    coordinator.nodes[idx].isPinned = false
                }
            } label: {
                Label("Unpin Node", systemImage: "pin.slash")
            }
        }
    }

    private func addGhostAsContact(_ node: GraphNode) {
        Task {
            guard let contact = await ContactsService.shared.createContact(
                fullName: node.displayName,
                email: nil,
                note: nil
            ) else { return }
            // Import the new contact so it becomes a SamPerson
            await ContactsImportCoordinator.shared.importNow()
            // Rebuild graph to replace ghost with real node
            await coordinator.buildGraph()
            fitToView()
        }
    }

    // MARK: - Navigation Helpers

    private func navigateToPerson(_ personID: UUID) {
        NotificationCenter.default.post(
            name: .samNavigateToPerson,
            object: nil,
            userInfo: ["personID": personID]
        )
    }

    private func handleDoubleTap(at location: CGPoint, center: CGPoint) {
        let gp = graphPoint(location, center: center)

        // Check edge hit first (deduced family confirmation)
        if let edge = hitTestEdge(at: location, center: center),
           edge.edgeType == .deducedFamily,
           !edge.isConfirmedDeduction,
           edge.deducedRelationID != nil {
            pendingEdgeConfirmation = edge
            showEdgeConfirmAlert = true
            return
        }

        if let node = hitTestNode(at: gp) {
            guard !node.isGhost else { return }
            navigateToPerson(node.id)
        }
    }

    // MARK: - Tooltip Positioning

    private func tooltipPosition(for screenPt: CGPoint) -> CGPoint {
        let tooltipWidth: CGFloat = 200
        let tooltipHeight: CGFloat = 120
        let margin: CGFloat = 16

        var x = screenPt.x + margin + tooltipWidth / 2
        var y = screenPt.y - margin - tooltipHeight / 2

        // Keep within canvas bounds
        if x + tooltipWidth / 2 > canvasSize.width {
            x = screenPt.x - margin - tooltipWidth / 2
        }
        if y - tooltipHeight / 2 < 0 {
            y = screenPt.y + margin + tooltipHeight / 2
        }

        return CGPoint(x: x, y: y)
    }

    // MARK: - Coordinate Transforms

    private func screenPoint(_ graphPt: CGPoint, center: CGPoint) -> CGPoint {
        CGPoint(
            x: (graphPt.x - coordinator.viewportCenter.x) * scale + center.x + offset.x,
            y: (graphPt.y - coordinator.viewportCenter.y) * scale + center.y + offset.y
        )
    }

    private func graphPoint(_ screenPt: CGPoint, center: CGPoint) -> CGPoint {
        CGPoint(
            x: (screenPt.x - center.x - offset.x) / scale + coordinator.viewportCenter.x,
            y: (screenPt.y - center.y - offset.y) / scale + coordinator.viewportCenter.y
        )
    }

    // MARK: - Node Sizing

    private func nodeRadius(for node: GraphNode) -> CGFloat {
        let base: CGFloat = 10
        let maxR: CGFloat = 30
        let production = CGFloat(node.productionValue)
        let normalized = min(1.0, production / 10_000)
        return base + (maxR - base) * normalized
    }

    // MARK: - Hit Testing

    private func hitTestNode(at graphPt: CGPoint) -> GraphNode? {
        for node in coordinator.nodes.reversed() {
            let radius = nodeRadius(for: node)
            let dx = graphPt.x - node.position.x
            let dy = graphPt.y - node.position.y
            if dx * dx + dy * dy <= radius * radius {
                return node
            }
        }
        return nil
    }

    /// Hit-test edges by checking distance from screen point to line segment.
    private func hitTestEdge(at screenPt: CGPoint, center: CGPoint) -> GraphEdge? {
        let threshold: CGFloat = 8.0
        let nodeMap = Dictionary(uniqueKeysWithValues: coordinator.nodes.map { ($0.id, $0) })

        for edge in coordinator.edges {
            guard let source = nodeMap[edge.sourceID],
                  let target = nodeMap[edge.targetID] else { continue }

            let sp = screenPoint(source.position, center: center)
            let tp = screenPoint(target.position, center: center)
            let dist = distanceToLineSegment(point: screenPt, lineStart: sp, lineEnd: tp)
            if dist <= threshold {
                return edge
            }
        }
        return nil
    }

    /// Perpendicular distance from a point to a line segment.
    private func distanceToLineSegment(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            let px = point.x - lineStart.x
            let py = point.y - lineStart.y
            return sqrt(px * px + py * py)
        }
        var t = ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        let projX = lineStart.x + t * dx
        let projY = lineStart.y + t * dy
        let px = point.x - projX
        let py = point.y - projY
        return sqrt(px * px + py * py)
    }

    private func handleTap(at location: CGPoint, center: CGPoint) {
        let gp = graphPoint(location, center: center)
        if let node = hitTestNode(at: gp) {
            coordinator.selectedNodeID = node.id
        } else {
            coordinator.selectedNodeID = nil
        }
    }

    // MARK: - Fit to View

    private func fitToView() {
        let nodes = coordinator.nodes
        guard !nodes.isEmpty, canvasSize.width > 0 else { return }

        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for node in nodes {
            let r = nodeRadius(for: node)
            minX = min(minX, node.position.x - r)
            maxX = max(maxX, node.position.x + r)
            minY = min(minY, node.position.y - r)
            maxY = max(maxY, node.position.y + r)
        }

        let graphWidth = maxX - minX
        let graphHeight = maxY - minY
        guard graphWidth > 0, graphHeight > 0 else { return }

        coordinator.viewportCenter = CGPoint(
            x: (minX + maxX) / 2,
            y: (minY + maxY) / 2
        )

        let padding: CGFloat = 0.9
        let scaleX = canvasSize.width / graphWidth * padding
        let scaleY = canvasSize.height / graphHeight * padding
        scale = min(scaleX, scaleY, 5.0)
        lastScale = scale
        offset = .zero
        lastOffset = .zero
    }

    // MARK: - Drawing: Edges

    private func drawEdges(context: inout GraphicsContext, center: CGPoint) {
        let nodeMap = Dictionary(uniqueKeysWithValues: coordinator.nodes.map { ($0.id, $0) })

        for edge in coordinator.edges {
            guard let source = nodeMap[edge.sourceID],
                  let target = nodeMap[edge.targetID] else { continue }

            let sp = screenPoint(source.position, center: center)
            let tp = screenPoint(target.position, center: center)

            var path = Path()
            path.move(to: sp)
            path.addLine(to: tp)

            let thickness = (1 + edge.weight * 3) * min(scale, 1.5)
            let color = edgeColor(for: edge.edgeType)

            if edge.edgeType == .deducedFamily {
                if edge.isConfirmedDeduction {
                    // Confirmed: solid pink line
                    context.stroke(path, with: .color(color), lineWidth: thickness)
                } else {
                    // Unconfirmed: dashed pink line
                    let dashes: [CGFloat] = [8, 5]
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: thickness, dash: dashes)
                    )
                }
            } else if edge.edgeType == .mentionedTogether && scale > 0.3 {
                let dashes: [CGFloat] = [6, 4]
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: thickness, dash: dashes)
                )
            } else {
                context.stroke(path, with: .color(color), lineWidth: thickness)
            }
        }
    }

    // MARK: - Drawing: Nodes

    private func drawNodes(context: inout GraphicsContext, center: CGPoint) {
        for node in coordinator.nodes {
            let sp = screenPoint(node.position, center: center)
            let radius = nodeRadius(for: node) * scale

            guard radius > 1 else { continue }

            let rect = CGRect(
                x: sp.x - radius,
                y: sp.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            let fillColor = roleColor(for: node)
            let fillPath = Path(ellipseIn: rect)
            context.fill(fillPath, with: .color(fillColor))

            let strokeColor = healthColor(for: node.relationshipHealth)
            context.stroke(fillPath, with: .color(strokeColor), lineWidth: 2 * min(scale, 1.5))

            if node.isGhost && scale > 2.0 {
                let dashStyle = StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                context.stroke(fillPath, with: .color(.secondary), style: dashStyle)
            }

            // Pinned indicator
            if node.isPinned && scale > 0.5 {
                let pinSize: CGFloat = 8 * min(scale, 1.5)
                let pinRect = CGRect(
                    x: sp.x + radius - pinSize * 0.3,
                    y: sp.y - radius - pinSize * 0.3,
                    width: pinSize,
                    height: pinSize
                )
                let pinText = Text(Image(systemName: "pin.fill"))
                    .font(.system(size: pinSize))
                    .foregroundStyle(Color.secondary)
                let resolved = context.resolve(pinText)
                context.draw(resolved, in: pinRect)
            }

            // Photo thumbnail at sufficient zoom
            if scale > 0.8, let photoData = node.photoThumbnail,
               let nsImage = NSImage(data: photoData) {
                let image = Image(nsImage: nsImage)
                let resolved = context.resolve(image)
                var clipped = context
                clipped.clipToLayer { clipCtx in
                    clipCtx.fill(fillPath, with: .color(.white))
                }
                clipped.draw(resolved, in: rect)
                context.stroke(fillPath, with: .color(strokeColor), lineWidth: 2 * min(scale, 1.5))
            }
        }
    }

    // MARK: - Drawing: Labels

    private func drawLabels(context: inout GraphicsContext, center: CGPoint, size: CGSize) {
        guard scale >= 0.3 else { return }

        for node in coordinator.nodes {
            let sp = screenPoint(node.position, center: center)
            let radius = nodeRadius(for: node) * scale

            if scale < 0.8 && radius < 15 * scale { continue }

            guard sp.x > -100 && sp.x < size.width + 100 &&
                  sp.y > -100 && sp.y < size.height + 100 else { continue }

            let fontSize = max(9, min(13, 11 * scale))
            let text = Text(node.displayName)
                .font(.system(size: fontSize))
                .foregroundStyle(Color.primary)

            let resolved = context.resolve(text)
            let textSize = resolved.measure(in: CGSize(width: 200, height: 50))

            context.draw(resolved, at: CGPoint(
                x: sp.x,
                y: sp.y + radius + textSize.height / 2 + 2
            ), anchor: .center)
        }
    }

    // MARK: - Drawing: Selection Ring & Drop Target

    private func drawSelection(context: inout GraphicsContext, center: CGPoint) {
        // Selection ring
        if let selectedID = coordinator.selectedNodeID,
           let node = coordinator.nodes.first(where: { $0.id == selectedID }) {
            let sp = screenPoint(node.position, center: center)
            let radius = nodeRadius(for: node) * scale + 4

            let rect = CGRect(
                x: sp.x - radius,
                y: sp.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            let path = Path(ellipseIn: rect)

            let glowRect = rect.insetBy(dx: -3, dy: -3)
            let glowPath = Path(ellipseIn: glowRect)
            context.stroke(glowPath, with: .color(.accentColor.opacity(0.3)), lineWidth: 4)

            context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
        }

        // Drop target highlight (green ring when dragging ghost onto real node)
        if let dropID = dropTargetNodeID,
           let targetNode = coordinator.nodes.first(where: { $0.id == dropID }) {
            let sp = screenPoint(targetNode.position, center: center)
            let radius = nodeRadius(for: targetNode) * scale + 6

            let rect = CGRect(
                x: sp.x - radius,
                y: sp.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            let glowRect = rect.insetBy(dx: -4, dy: -4)
            let glowPath = Path(ellipseIn: glowRect)
            context.stroke(glowPath, with: .color(.green.opacity(0.3)), lineWidth: 5)

            let path = Path(ellipseIn: rect)
            context.stroke(path, with: .color(.green), lineWidth: 2.5)
        }
    }

    // MARK: - Color Helpers

    private func roleColor(for node: GraphNode) -> Color {
        if node.isGhost {
            return .gray.opacity(0.5)
        }
        guard let role = node.primaryRole else {
            return .gray.opacity(0.7)
        }
        return RoleBadgeStyle.forBadge(role).color
    }

    private func healthColor(for health: GraphNode.HealthLevel) -> Color {
        switch health {
        case .healthy: return .green
        case .cooling:  return .yellow
        case .atRisk:   return .orange
        case .cold:     return .red
        case .unknown:  return .gray
        }
    }

    private func edgeColor(for type: EdgeType) -> Color {
        switch type {
        case .household:         return .green.opacity(0.6)
        case .business:          return .purple.opacity(0.6)
        case .referral:          return .orange.opacity(0.6)
        case .recruitingTree:    return .teal.opacity(0.6)
        case .coAttendee:        return .blue.opacity(0.4)
        case .communicationLink: return .secondary
        case .mentionedTogether: return .mint.opacity(0.4)
        case .deducedFamily:     return .pink.opacity(0.7)
        }
    }
}

// MARK: - Preview

#Preview {
    RelationshipGraphView()
        .frame(width: 900, height: 700)
}
