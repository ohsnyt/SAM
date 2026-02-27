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
//  navigation, node dragging, keyboard shortcuts, search-to-zoom,
//  multi-select, marquee selection, focus+context depth, LOD rendering,
//  edge termination at circumference, direction arrows, node shadows,
//  scroll-wheel zoom, cursor feedback, and keyboard arrow navigation.
//

import SwiftUI

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

    // Marquee selection state
    @State private var isMarqueeActive: Bool = false
    @State private var marqueeStart: CGPoint = .zero
    @State private var marqueeEnd: CGPoint = .zero

    // Ghost merge state
    @State private var showGhostMergePicker: Bool = false
    @State private var ghostMergeSourceName: String = ""
    @State private var dropTargetNodeID: UUID?
    @State private var showDropMergeConfirmation: Bool = false
    @State private var pendingDropMergePersonID: UUID?

    // Family cluster drag state
    @State private var clusterDragOffsets: [UUID: CGPoint] = [:]  // nodeID → offset from dragged node
    @State private var isDraggingCluster: Bool = false

    // Ghost merge compatibility state
    @State private var compatibleNodeIDs: Set<UUID> = []  // Nodes compatible with dragged ghost
    @State private var magneticSnapTargetID: UUID?  // Node within 40pt snap range

    // Lasso selection state
    @State private var isLassoActive: Bool = false
    @State private var lassoPoints: [CGPoint] = []  // Screen-space points of the freehand path

    // Group drag state (multi-select drag)
    @State private var groupDragOffsets: [UUID: CGPoint] = [:]  // nodeID → offset from dragged node
    @State private var isDraggingGroup: Bool = false

    // Ripple animation state
    @State private var rippleCenter: CGPoint?  // Graph-space center for ripple
    @State private var rippleProgress: CGFloat = 0  // 0…1 animation progress
    @State private var rippleMaxRadius: CGFloat = 0  // Max radius of ripple

    // Ghost marching ants animation phase
    @State private var ghostAnimationPhase: CGFloat = 0

    // Grid pattern during drag
    @State private var showDragGrid: Bool = false

    // Edge confirmation state
    @State private var showEdgeConfirmAlert: Bool = false
    @State private var pendingEdgeConfirmation: GraphEdge?

    // Edge hover state
    @State private var hoveredEdge: GraphEdge?

    // MARK: - Navigation

    @AppStorage("sam.sidebar.selection") private var sidebarSelection: String = "graph"

    // MARK: - Environment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var highContrast: Bool { colorSchemeContrast == .increased }

    // MARK: - Constants

    private static let minNodeDiameter: CGFloat = 24
    private static let maxNodeDiameter: CGFloat = 56
    private static let hitPadding: CGFloat = 8

    // MARK: - Body

    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .task {
                for await notification in NotificationCenter.default.notifications(named: .samPersonDidChange) {
                    if let personID = notification.userInfo?["personID"] as? UUID {
                        coordinator.updateNode(personID: personID)
                    } else {
                        await coordinator.rebuildIfStale()
                    }
                }
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: .samUndoDidRestore) {
                    await coordinator.rebuildIfStale()
                    fitToView()
                }
            }
            .task {
                // Ghost marching ants animation timer
                guard !reduceMotion else { return }
                let hasGhosts = coordinator.nodes.contains { $0.isGhost }
                guard hasGhosts else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    ghostAnimationPhase += 1
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
        coordinator.selectedNodeIDs.removeAll()
        coordinator.selectionAnchorID = nil
        return .handled
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // Delete key: dismiss selected ghost nodes
        if keyPress.key == .delete || keyPress.key == .deleteForward {
            let selectedGhosts = coordinator.nodes.filter {
                coordinator.selectedNodeIDs.contains($0.id) && $0.isGhost
            }
            if !selectedGhosts.isEmpty {
                for ghost in selectedGhosts {
                    coordinator.dismissedGhostNames.insert(ghost.displayName)
                }
                coordinator.selectedNodeIDs.subtract(selectedGhosts.map(\.id))
                coordinator.applyFilters()
                return .handled
            }
        }

        // Arrow key navigation between connected nodes
        if !keyPress.modifiers.contains(.command) {
            switch keyPress.key {
            case .leftArrow, .rightArrow, .upArrow, .downArrow:
                if let nextID = coordinator.nearestConnectedNode(inDirection: keyPress.key) {
                    if keyPress.modifiers.contains(.shift) {
                        coordinator.selectedNodeIDs.insert(nextID)
                    } else {
                        coordinator.selectedNodeIDs = [nextID]
                    }
                    coordinator.selectionAnchorID = nextID
                    if let node = coordinator.nodes.first(where: { $0.id == nextID }) {
                        zoomToNode(node)
                    }
                    return .handled
                }
                return .ignored
            case .tab:
                // Cycle through nodes by production value
                let sorted = coordinator.nodes.filter { !$0.isGhost }.sorted { $0.productionValue > $1.productionValue }
                guard !sorted.isEmpty else { return .ignored }
                if let current = coordinator.selectionAnchorID,
                   let idx = sorted.firstIndex(where: { $0.id == current }) {
                    let next = sorted[(idx + 1) % sorted.count]
                    coordinator.selectedNodeID = next.id
                    zoomToNode(next)
                } else {
                    let first = sorted[0]
                    coordinator.selectedNodeID = first.id
                    zoomToNode(first)
                }
                return .handled
            case .return:
                // Return/Enter: navigate to selected person
                if let anchorID = coordinator.selectionAnchorID,
                   let node = coordinator.nodes.first(where: { $0.id == anchorID }),
                   !node.isGhost {
                    navigateToPerson(anchorID)
                    return .handled
                }
                return .ignored
            default:
                break
            }
        }

        guard keyPress.modifiers.contains(.command) else { return .ignored }
        switch keyPress.key {
        case "f":
            searchIsActive = true
            searchFieldFocused = true
            return .handled
        case "b":
            coordinator.edgeBundlingEnabled.toggle()
            return .handled
        case "g":
            coordinator.familyClusteringEnabled.toggle()
            coordinator.applyFilters()
            return .handled
        case "r":
            coordinator.invalidateLayoutCache()
            Task { await coordinator.buildGraph(); fitToView() }
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
        if reduceMotion {
            coordinator.viewportCenter = node.position
            scale = max(scale, 1.0)
            lastScale = scale
            offset = .zero
            lastOffset = .zero
        } else {
            withAnimation(.easeInOut(duration: 0.4)) {
                coordinator.viewportCenter = node.position
                scale = max(scale, 1.0)
                lastScale = scale
                offset = .zero
                lastOffset = .zero
            }
        }
    }

    // MARK: - Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let viewport = CGRect(origin: .zero, size: geo.size)

            canvasWithGestures(center: center, viewport: viewport, geoSize: geo.size)
        }
    }

    /// Canvas + gesture/interaction modifiers, extracted to help the type-checker.
    @ViewBuilder
    private func canvasWithGestures(center: CGPoint, viewport: CGRect, geoSize: CGSize) -> some View {
        Canvas { context, size in
            drawCanvas(context: &context, size: size, viewport: viewport)
        }
        .onAppear { canvasSize = geoSize }
        .onChange(of: geoSize) { _, newSize in canvasSize = newSize }
        .onChange(of: scale) { _, _ in updateBridgeIndicators(center: center, viewport: viewport) }
        .onChange(of: offset) { _, _ in updateBridgeIndicators(center: center, viewport: viewport) }
        .gesture(
            MagnificationGesture()
                .onChanged { value in scale = min(max(lastScale * value, 0.1), 5.0) }
                .onEnded { _ in lastScale = scale }
        )
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in handleDragChanged(value, center: center) }
                .onEnded { _ in handleDragEnded(center: center) }
        )
        .onTapGesture(count: 3) { location in handleTripleTap(at: location, center: center) }
        .onTapGesture(count: 2) { location in handleDoubleTap(at: location, center: center) }
        .onTapGesture { location in handleTap(at: location, center: center) }
        .onContinuousHover { phase in handleHover(phase, center: center) }
        .contextMenu { canvasContextMenu }
        .overlay { ScrollWheelZoomView(scale: $scale, lastScale: $lastScale) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Relationship Graph")
        .accessibilityHint("\(coordinator.nodes.count) people, \(coordinator.edges.count) connections")
        .accessibilityChildren { accessibilityNodes }
    }

    private func handleHover(_ phase: HoverPhase, center: CGPoint) {
        switch phase {
        case .active(let location):
            hoverScreenPosition = location
            let gp = graphPoint(location, center: center)
            let hitNode = hitTestNode(at: gp)
            let prevHovered = hoveredNodeID
            hoveredNodeID = hitNode?.id

            if hitNode != nil && prevHovered == nil {
                NSCursor.openHand.push()
            } else if hitNode == nil && prevHovered != nil {
                NSCursor.pop()
            }

            if hitNode == nil {
                hoveredEdge = hitTestEdge(at: location, center: center)
            } else {
                hoveredEdge = nil
            }
        case .ended:
            if hoveredNodeID != nil { NSCursor.pop() }
            hoveredNodeID = nil
            hoveredEdge = nil
        }
    }

    @ViewBuilder
    private var canvasContextMenu: some View {
        if let hovID = hoveredNodeID ?? coordinator.selectedNodeID,
           let node = coordinator.nodes.first(where: { $0.id == hovID }) {
            contextMenuItems(for: node)
        } else {
            canvasContextMenuItems
        }
    }

    @ViewBuilder
    private var accessibilityNodes: some View {
        ForEach(coordinator.nodes) { node in
            let edgeCount = coordinator.edges.filter { $0.sourceID == node.id || $0.targetID == node.id }.count
            let healthText = node.relationshipHealth.rawValue
            let roleText = node.roleBadges.joined(separator: ", ")

            Rectangle()
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(node.displayName)
                .accessibilityValue("\(roleText). Health: \(healthText). \(edgeCount) connections.")
                .accessibilityHint(node.isGhost ? "Ghost node — not yet a contact" : "Double-tap to view person")
                .accessibilityAddTraits(coordinator.selectedNodeIDs.contains(node.id) ? [.isSelected, .isButton] : [.isButton])
                .accessibilityAction {
                    coordinator.selectedNodeID = node.id
                    zoomToNode(node)
                }
        }
    }

    // MARK: - Marquee Selection

    private func completeMarqueeSelection(center: CGPoint) {
        let minX = min(marqueeStart.x, marqueeEnd.x)
        let maxX = max(marqueeStart.x, marqueeEnd.x)
        let minY = min(marqueeStart.y, marqueeEnd.y)
        let maxY = max(marqueeStart.y, marqueeEnd.y)
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        var selected = Set<UUID>()
        for node in coordinator.nodes {
            let sp = screenPoint(node.position, center: center)
            if rect.contains(sp) {
                selected.insert(node.id)
            }
        }

        if NSEvent.modifierFlags.contains(.shift) {
            coordinator.selectedNodeIDs.formUnion(selected)
        } else {
            coordinator.selectedNodeIDs = selected
        }
        if let first = selected.first, coordinator.selectionAnchorID == nil {
            coordinator.selectionAnchorID = first
        }
    }

    /// Complete lasso selection: hit test all nodes against the closed freehand path.
    private func completeLassoSelection(center: CGPoint) {
        guard lassoPoints.count >= 3 else { return }

        // Close the path
        var path = Path()
        path.move(to: lassoPoints[0])
        for i in 1..<lassoPoints.count {
            path.addLine(to: lassoPoints[i])
        }
        path.closeSubpath()

        var selected = Set<UUID>()
        for node in coordinator.nodes {
            let sp = screenPoint(node.position, center: center)
            if path.contains(sp) {
                selected.insert(node.id)
            }
        }

        // Shift+Option+drag adds to existing selection
        if NSEvent.modifierFlags.contains(.shift) {
            coordinator.selectedNodeIDs.formUnion(selected)
        } else {
            coordinator.selectedNodeIDs = selected
        }
        if let first = selected.first, coordinator.selectionAnchorID == nil {
            coordinator.selectionAnchorID = first
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

            Divider()

            Button {
                coordinator.dismissedGhostNames.insert(node.displayName)
                coordinator.applyFilters()
            } label: {
                Label("Dismiss Ghost", systemImage: "eye.slash")
            }

            Button {
                // Dismiss all ghost nodes
                for ghostNode in coordinator.nodes where ghostNode.isGhost {
                    coordinator.dismissedGhostNames.insert(ghostNode.displayName)
                }
                coordinator.applyFilters()
            } label: {
                Label("Dismiss All Ghosts", systemImage: "eye.slash.fill")
            }
        } else {
            Button {
                navigateToPerson(node.id)
            } label: {
                Label("View Person", systemImage: "person.circle")
            }

            Button {
                NotificationCenter.default.post(
                    name: .samCreateNoteForPerson,
                    object: nil,
                    userInfo: ["personID": node.id]
                )
            } label: {
                Label("Create Note", systemImage: "square.and.pencil")
            }

            Button {
                NotificationCenter.default.post(
                    name: .samDraftMessageForPerson,
                    object: nil,
                    userInfo: ["personID": node.id]
                )
            } label: {
                Label("Draft Message", systemImage: "envelope")
            }

            Divider()

            if coordinator.edges.contains(where: {
                ($0.sourceID == node.id || $0.targetID == node.id) && $0.edgeType == .referral
            }) {
                Button {
                    coordinator.selectConnectedByEdgeType(from: node.id, edgeType: .referral)
                } label: {
                    Label("Select Referral Chain", systemImage: "arrow.triangle.branch")
                }
            }

            if coordinator.edges.contains(where: {
                ($0.sourceID == node.id || $0.targetID == node.id) && $0.edgeType == .recruitingTree
            }) {
                Button {
                    coordinator.selectConnectedByEdgeType(from: node.id, edgeType: .recruitingTree)
                } label: {
                    Label("Select Downline", systemImage: "person.3")
                }
            }

            if coordinator.familyClusteringEnabled,
               let cluster = coordinator.familyCluster(for: node.id) {
                Button {
                    coordinator.selectFamilyCluster(cluster)
                } label: {
                    Label("Select Family Members", systemImage: "person.2")
                }
            }
        }

        Divider()

        Button {
            coordinator.selectedNodeID = node.id
            zoomToNode(node)
        } label: {
            Label("Focus in Graph", systemImage: "scope")
        }

        if node.isPinned {
            Button {
                if let idx = coordinator.nodes.firstIndex(where: { $0.id == node.id }) {
                    coordinator.nodes[idx].isPinned = false
                }
            } label: {
                Label("Unpin Node", systemImage: "pin.slash")
            }
        }

        if !node.isGhost {
            Button {
                coordinator.hiddenNodeIDs.insert(node.id)
                coordinator.applyFilters()
            } label: {
                Label("Hide from Graph", systemImage: "eye.slash")
            }
        }

        // Release pulled connections for this bridge node
        if coordinator.activePulls[node.id] != nil {
            Button {
                coordinator.releasePulledConnections(bridgeNodeID: node.id)
            } label: {
                Label("Release Pulled Connections", systemImage: "arrow.uturn.backward")
            }
        }
    }

    @ViewBuilder
    private var canvasContextMenuItems: some View {
        Button {
            fitToView()
        } label: {
            Label("Fit to View", systemImage: "arrow.up.left.and.arrow.down.right")
        }

        Button {
            coordinator.invalidateLayoutCache()
            Task { await coordinator.buildGraph(); fitToView() }
        } label: {
            Label("Reset Layout", systemImage: "arrow.counterclockwise")
        }

        Divider()

        Toggle("Family Clustering", isOn: Binding(
            get: { coordinator.familyClusteringEnabled },
            set: { coordinator.familyClusteringEnabled = $0; coordinator.applyFilters() }
        ))

        Toggle("Edge Bundling", isOn: Binding(
            get: { coordinator.edgeBundlingEnabled },
            set: { coordinator.edgeBundlingEnabled = $0 }
        ))

        Divider()

        if !coordinator.activePulls.isEmpty {
            Button {
                coordinator.releaseAllPulls()
            } label: {
                Label("Release All Pulls", systemImage: "arrow.uturn.backward")
            }
        }

        Button {
            coordinator.unpinAllNodes()
        } label: {
            Label("Unpin All Nodes", systemImage: "pin.slash")
        }

        if !coordinator.hiddenNodeIDs.isEmpty {
            Button {
                coordinator.hiddenNodeIDs.removeAll()
                coordinator.applyFilters()
            } label: {
                Label("Show Hidden Nodes", systemImage: "eye")
            }
        }

        if !coordinator.dismissedGhostNames.isEmpty {
            Button {
                coordinator.dismissedGhostNames.removeAll()
                coordinator.applyFilters()
            } label: {
                Label("Show Dismissed Ghosts", systemImage: "eye")
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
            await ContactsImportCoordinator.shared.importNow()
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

            // Relational-distance selection: double-click = 1-hop neighbors
            // Modifier keys filter by edge type:
            //   Option = family only, Shift = recruiting only
            let modifiers = NSEvent.modifierFlags
            let edgeFilter: EdgeType?
            if modifiers.contains(.option) {
                edgeFilter = .deducedFamily
            } else if modifiers.contains(.shift) {
                edgeFilter = .recruitingTree
            } else {
                edgeFilter = nil  // All edge types
            }

            coordinator.expandSelection(from: node.id, hops: 1, edgeTypeFilter: edgeFilter)
            triggerRippleAnimation(from: node.position, hops: 1, center: center)
        } else if coordinator.familyClusteringEnabled,
                  let cluster = hitTestFamilyCluster(at: location, center: center) {
            // Double-click family cluster boundary → select all members + 1-hop neighbors
            coordinator.selectFamilyCluster(cluster, includeNeighbors: true)
        }
    }

    /// Triple-click: select 2-hop neighbors with modifier key filtering.
    private func handleTripleTap(at location: CGPoint, center: CGPoint) {
        let gp = graphPoint(location, center: center)
        guard let node = hitTestNode(at: gp), !node.isGhost else { return }

        let modifiers = NSEvent.modifierFlags
        let edgeFilter: EdgeType?
        if modifiers.contains(.option) {
            edgeFilter = .deducedFamily
        } else if modifiers.contains(.shift) {
            edgeFilter = .recruitingTree
        } else {
            edgeFilter = nil
        }

        coordinator.expandSelection(from: node.id, hops: 2, edgeTypeFilter: edgeFilter)
        triggerRippleAnimation(from: node.position, hops: 2, center: center)
    }

    /// Start a ripple animation centered on a graph point.
    private func triggerRippleAnimation(from graphPt: CGPoint, hops: Int, center: CGPoint) {
        guard !reduceMotion else { return }

        rippleCenter = graphPt

        // Compute max radius based on furthest selected node
        var maxDist: CGFloat = 80
        for nodeID in coordinator.selectedNodeIDs {
            if let node = coordinator.nodes.first(where: { $0.id == nodeID }) {
                let d = hypot(node.position.x - graphPt.x, node.position.y - graphPt.y)
                if d > maxDist { maxDist = d }
            }
        }
        rippleMaxRadius = maxDist + 20
        rippleProgress = 0

        withAnimation(.spring(.responsive)) {
            rippleProgress = 1.0
        }

        // Clear ripple after animation completes
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            rippleCenter = nil
            rippleProgress = 0
        }
    }

    // MARK: - Tooltip Positioning

    private func tooltipPosition(for screenPt: CGPoint) -> CGPoint {
        let tooltipWidth: CGFloat = 200
        let tooltipHeight: CGFloat = 120
        let margin: CGFloat = 16

        var x = screenPt.x + margin + tooltipWidth / 2
        var y = screenPt.y - margin - tooltipHeight / 2

        if x + tooltipWidth / 2 > canvasSize.width {
            x = screenPt.x - margin - tooltipWidth / 2
        }
        if y - tooltipHeight / 2 < 0 {
            y = screenPt.y + margin + tooltipHeight / 2
        }

        return CGPoint(x: x, y: y)
    }

    // MARK: - Drag Gesture Handlers

    private func handleDragChanged(_ value: DragGesture.Value, center: CGPoint) {
        if draggedNodeID == nil && !isMarqueeActive && !isLassoActive {
            let startGP = graphPoint(value.startLocation, center: center)
            let modifiers = NSEvent.modifierFlags

            if let hitNode = hitTestNode(at: startGP) {
                draggedNodeID = hitNode.id
                NSCursor.closedHand.push()

                // Group drag: if dragging a node that's part of multi-selection
                if coordinator.selectedNodeIDs.contains(hitNode.id) && coordinator.selectedNodeIDs.count > 1 {
                    isDraggingGroup = true
                    groupDragOffsets = [:]
                    for selectedID in coordinator.selectedNodeIDs where selectedID != hitNode.id {
                        if let selectedNode = coordinator.nodes.first(where: { $0.id == selectedID }) {
                            groupDragOffsets[selectedID] = CGPoint(
                                x: selectedNode.position.x - hitNode.position.x,
                                y: selectedNode.position.y - hitNode.position.y
                            )
                        }
                    }
                }
                // Family cluster group drag: store offsets for all cluster members
                else if coordinator.familyClusteringEnabled,
                   let cluster = coordinator.familyCluster(for: hitNode.id) {
                    isDraggingCluster = true
                    clusterDragOffsets = [:]
                    for memberID in cluster.memberIDs where memberID != hitNode.id {
                        if let memberNode = coordinator.nodes.first(where: { $0.id == memberID }) {
                            clusterDragOffsets[memberID] = CGPoint(
                                x: memberNode.position.x - hitNode.position.x,
                                y: memberNode.position.y - hitNode.position.y
                            )
                        }
                    }
                } else {
                    isDraggingCluster = false
                    isDraggingGroup = false
                    clusterDragOffsets = [:]
                    groupDragOffsets = [:]
                }
            } else if modifiers.contains(.option) {
                // Option+drag on empty canvas starts lasso selection
                isLassoActive = true
                lassoPoints = [value.startLocation, value.location]
            } else if modifiers.contains(.shift) {
                // Shift+drag on empty canvas starts marquee
                isMarqueeActive = true
                marqueeStart = value.startLocation
                marqueeEnd = value.location
            }
        }

        if isLassoActive {
            lassoPoints.append(value.location)
        } else if isMarqueeActive {
            marqueeEnd = value.location
        } else if let dragID = draggedNodeID,
           let idx = coordinator.nodes.firstIndex(where: { $0.id == dragID }) {
            let gp = graphPoint(value.location, center: center)
            coordinator.nodes[idx].position = gp
            coordinator.nodes[idx].isPinned = true

            // Move group-selected nodes together
            if isDraggingGroup {
                for (selectedID, selectedOffset) in groupDragOffsets {
                    if let selIdx = coordinator.nodes.firstIndex(where: { $0.id == selectedID }) {
                        coordinator.nodes[selIdx].position = CGPoint(
                            x: gp.x + selectedOffset.x,
                            y: gp.y + selectedOffset.y
                        )
                        coordinator.nodes[selIdx].isPinned = true
                    }
                }
            }
            // Move family cluster members together
            else if isDraggingCluster {
                for (memberID, memberOffset) in clusterDragOffsets {
                    if let memberIdx = coordinator.nodes.firstIndex(where: { $0.id == memberID }) {
                        coordinator.nodes[memberIdx].position = CGPoint(
                            x: gp.x + memberOffset.x,
                            y: gp.y + memberOffset.y
                        )
                        coordinator.nodes[memberIdx].isPinned = true
                    }
                }
            }

            // Ghost → real node drop target detection with fuzzy matching
            handleGhostDragDetection(dragID: dragID, idx: idx, gp: gp)
        } else if !isMarqueeActive && !isLassoActive {
            // Pan viewport
            offset = CGPoint(
                x: lastOffset.x + value.translation.width,
                y: lastOffset.y + value.translation.height
            )
        }
    }

    private func handleGhostDragDetection(dragID: UUID, idx: Int, gp: CGPoint) {
        let draggedNode = coordinator.nodes[idx]
        guard draggedNode.isGhost else { return }

        // Compute compatible nodes on first drag frame
        if compatibleNodeIDs.isEmpty {
            let ghostName = draggedNode.displayName.lowercased()
            let ghostSurname = ghostName.split(separator: " ").last.map(String.init) ?? ""
            compatibleNodeIDs = Set(coordinator.nodes.compactMap { candidate -> UUID? in
                guard !candidate.isGhost, candidate.id != dragID else { return nil }
                let candidateName = candidate.displayName.lowercased()
                let candidateSurname = candidateName.split(separator: " ").last.map(String.init) ?? ""
                if levenshteinDistance(ghostName, candidateName) < 3 { return candidate.id }
                if !ghostSurname.isEmpty && ghostSurname == candidateSurname { return candidate.id }
                return nil
            })
        }

        // Magnetic snap: find closest compatible node within 40pt
        var closestID: UUID?
        var closestDist: CGFloat = 40
        for candidateID in compatibleNodeIDs {
            guard let candidate = coordinator.nodes.first(where: { $0.id == candidateID }) else { continue }
            let d = hypot(gp.x - candidate.position.x, gp.y - candidate.position.y)
            if d < closestDist {
                closestDist = d
                closestID = candidateID
            }
        }
        magneticSnapTargetID = closestID

        // Snap ghost position to target if within range
        if let snapID = closestID,
           let snapNode = coordinator.nodes.first(where: { $0.id == snapID }) {
            coordinator.nodes[idx].position = snapNode.position
            dropTargetNodeID = snapID
        } else {
            let hitTarget = hitTestNode(at: gp)
            if let target = hitTarget,
               target.id != dragID,
               !target.isGhost {
                dropTargetNodeID = target.id
            } else {
                dropTargetNodeID = nil
            }
        }
    }

    private func handleDragEnded(center: CGPoint) {
        // Lasso selection completion
        if isLassoActive {
            completeLassoSelection(center: center)
            isLassoActive = false
            lassoPoints = []
        }

        // Marquee selection completion
        if isMarqueeActive {
            completeMarqueeSelection(center: center)
            isMarqueeActive = false
        }

        // Ghost drop merge
        if let dragID = draggedNodeID,
           let targetID = dropTargetNodeID,
           let draggedNode = coordinator.nodes.first(where: { $0.id == dragID }),
           let targetNode = coordinator.nodes.first(where: { $0.id == targetID }),
           draggedNode.isGhost && !targetNode.isGhost {
            ghostMergeSourceName = draggedNode.displayName
            pendingDropMergePersonID = targetID
            showDropMergeConfirmation = true
        }

        if draggedNodeID != nil {
            NSCursor.pop()
        }
        draggedNodeID = nil
        dropTargetNodeID = nil
        isDraggingCluster = false
        isDraggingGroup = false
        clusterDragOffsets = [:]
        groupDragOffsets = [:]
        compatibleNodeIDs = []
        magneticSnapTargetID = nil
        lastOffset = offset
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

    // MARK: - Node Sizing (sqrt scaling per visual design spec §3.1)

    private func nodeRadius(for node: GraphNode) -> CGFloat {
        let minR = Self.minNodeDiameter / 2  // 12pt
        let maxR = Self.maxNodeDiameter / 2  // 28pt
        let normalized = node.productionValue / coordinator.maxProductionValue
        return minR + (maxR - minR) * sqrt(min(1.0, max(0.0, normalized)))
    }

    // MARK: - Focus+Context opacity (interaction spec §8.1)

    private func nodeOpacity(for node: GraphNode) -> Double {
        guard !coordinator.selectedNodeIDs.isEmpty else { return 1.0 }
        let hops = coordinator.hopDistance(for: node.id)
        switch hops {
        case 0: return 1.0
        case 1: return 0.9
        case 2: return 0.6
        default: return 0.3
        }
    }

    private func nodeScaleFactor(for node: GraphNode) -> CGFloat {
        guard !coordinator.selectedNodeIDs.isEmpty else { return 1.0 }
        let hops = coordinator.hopDistance(for: node.id)
        switch hops {
        case 0: return 1.0
        case 1: return 1.0
        case 2: return 0.85
        default: return 0.7
        }
    }

    private func edgeOpacity(for edge: GraphEdge) -> Double {
        guard !coordinator.selectedNodeIDs.isEmpty else {
            return baseEdgeOpacity(for: edge.edgeType)
        }
        let sourceHops = coordinator.hopDistance(for: edge.sourceID)
        let targetHops = coordinator.hopDistance(for: edge.targetID)
        let minHops = min(sourceHops, targetHops)
        switch minHops {
        case 0: return 1.0
        case 1: return 0.7
        default: return 0.3
        }
    }

    private func baseEdgeOpacity(for type: EdgeType) -> Double {
        switch type {
        case .deducedFamily: return 1.0
        case .referral, .recruitingTree: return 0.8
        case .business, .roleRelationship: return 0.7
        case .coAttendee, .communicationLink: return 0.5
        case .mentionedTogether: return 0.3
        }
    }

    // MARK: - Hit Testing

    private func hitTestNode(at graphPt: CGPoint) -> GraphNode? {
        // Reversed so frontmost (drawn last) wins
        for node in coordinator.nodes.reversed() {
            let radius = nodeRadius(for: node) + Self.hitPadding  // +8pt padding per spec
            let dx = graphPt.x - node.position.x
            let dy = graphPt.y - node.position.y
            if dx * dx + dy * dy <= radius * radius {
                return node
            }
        }
        return nil
    }

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
            if NSEvent.modifierFlags.contains(.shift) {
                // Shift+click toggles multi-select
                if coordinator.selectedNodeIDs.contains(node.id) {
                    coordinator.selectedNodeIDs.remove(node.id)
                    if coordinator.selectionAnchorID == node.id {
                        coordinator.selectionAnchorID = coordinator.selectedNodeIDs.first
                    }
                } else {
                    coordinator.selectedNodeIDs.insert(node.id)
                    coordinator.selectionAnchorID = node.id
                }
            } else {
                coordinator.selectedNodeIDs = [node.id]
                coordinator.selectionAnchorID = node.id
            }
        } else if let bridgeNodeID = hitTestBridgeBadge(at: location, center: center) {
            // Click on bridge badge → pull/release distant connections
            triggerBridgePull(bridgeNodeID: bridgeNodeID, center: center)
        } else if coordinator.familyClusteringEnabled,
                  let cluster = hitTestFamilyCluster(at: location, center: center) {
            // Click on family cluster boundary selects all members
            coordinator.selectFamilyCluster(cluster)
        } else {
            coordinator.selectedNodeIDs.removeAll()
            coordinator.selectionAnchorID = nil
        }
    }

    /// Hit-test bridge indicator badges. Returns the node ID if a badge was tapped.
    private func hitTestBridgeBadge(at screenPt: CGPoint, center: CGPoint) -> UUID? {
        guard scale >= 0.3 else { return nil }

        for (nodeID, distantCount) in coordinator.bridgeIndicators {
            guard distantCount > 0 else { continue }
            guard let node = coordinator.nodes.first(where: { $0.id == nodeID }) else { continue }

            let sp = screenPoint(node.position, center: center)
            let scaleFactor = nodeScaleFactor(for: node)
            let radius = nodeRadius(for: node) * scale * scaleFactor

            // Badge position: 2 o'clock (same as drawBridgeIndicators)
            let badgeAngle = -CGFloat.pi / 6
            let badgeCenter = CGPoint(
                x: sp.x + (radius - 2) * cos(badgeAngle),
                y: sp.y + (radius - 2) * sin(badgeAngle)
            )

            let badgeDiameter: CGFloat = distantCount >= 10 ? 20 : 16
            let hitRadius = badgeDiameter / 2 + 4  // Extra padding for easier tapping
            let dx = screenPt.x - badgeCenter.x
            let dy = screenPt.y - badgeCenter.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                return nodeID
            }
        }
        return nil
    }

    /// Trigger a bridge pull or release.
    private func triggerBridgePull(bridgeNodeID: UUID, center: CGPoint) {
        let viewport = CGRect(origin: .zero, size: canvasSize)

        var screenPositions: [UUID: CGPoint] = [:]
        var totalEdgeLen: CGFloat = 0
        var edgeCount: CGFloat = 0

        for node in coordinator.nodes {
            screenPositions[node.id] = screenPoint(node.position, center: center)
        }
        for edge in coordinator.edges {
            guard let sp = screenPositions[edge.sourceID],
                  let tp = screenPositions[edge.targetID] else { continue }
            totalEdgeLen += hypot(tp.x - sp.x, tp.y - sp.y)
            edgeCount += 1
        }
        let avgEdgeLen = edgeCount > 0 ? totalEdgeLen / edgeCount : 200

        coordinator.pullDistantConnections(
            bridgeNodeID: bridgeNodeID,
            screenPositions: screenPositions,
            viewport: viewport,
            averageEdgeLength: avgEdgeLen
        )
    }

    /// Hit-test family cluster boundaries. Returns the cluster if the point is inside a boundary.
    private func hitTestFamilyCluster(at screenPt: CGPoint, center: CGPoint) -> FamilyCluster? {
        for cluster in coordinator.familyClusters {
            guard !coordinator.collapsedFamilyClusters.contains(cluster.id) else { continue }

            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
            var minY = CGFloat.infinity, maxY = -CGFloat.infinity
            var memberCount = 0

            for memberID in cluster.memberIDs {
                guard let node = coordinator.nodes.first(where: { $0.id == memberID }) else { continue }
                let sp = screenPoint(node.position, center: center)
                let r = nodeRadius(for: node) * scale * nodeScaleFactor(for: node)
                minX = min(minX, sp.x - r)
                maxX = max(maxX, sp.x + r)
                minY = min(minY, sp.y - r)
                maxY = max(maxY, sp.y + r)
                memberCount += 1
            }

            guard memberCount >= 2, minX < maxX, minY < maxY else { continue }

            let padding: CGFloat = 20 * scale
            let boundaryRect = CGRect(
                x: minX - padding,
                y: minY - padding,
                width: (maxX - minX) + 2 * padding,
                height: (maxY - minY) + 2 * padding
            )

            if boundaryRect.contains(screenPt) {
                return cluster
            }
        }
        return nil
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

    // MARK: - Bridge Indicator Update

    private func updateBridgeIndicators(center: CGPoint, viewport: CGRect) {
        guard scale >= 0.3 else {
            coordinator.bridgeIndicators = [:]
            return
        }

        var screenPositions: [UUID: CGPoint] = [:]
        var totalEdgeLen: CGFloat = 0
        var edgeCount: CGFloat = 0

        for node in coordinator.nodes {
            screenPositions[node.id] = screenPoint(node.position, center: center)
        }

        // Compute average edge length
        for edge in coordinator.edges {
            guard let sp = screenPositions[edge.sourceID],
                  let tp = screenPositions[edge.targetID] else { continue }
            totalEdgeLen += hypot(tp.x - sp.x, tp.y - sp.y)
            edgeCount += 1
        }

        let avgEdgeLen = edgeCount > 0 ? totalEdgeLen / edgeCount : 200

        coordinator.computeBridgeIndicators(
            screenPositions: screenPositions,
            viewport: viewport,
            averageEdgeLength: avgEdgeLen
        )
    }

    // MARK: - Visibility Check (Off-Screen Culling)

    private func isVisible(_ screenPt: CGPoint, radius: CGFloat, viewport: CGRect) -> Bool {
        let insetViewport = viewport.insetBy(dx: -radius - 20, dy: -radius - 20)
        return insetViewport.contains(screenPt)
    }

    // MARK: - Drawing: Main Canvas

    /// Central draw method for the Canvas, extracted to help the type-checker.
    private func drawCanvas(context: inout GraphicsContext, size: CGSize, viewport: CGRect) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)

        // Canvas background color per visual design spec
        let bgRect = CGRect(origin: .zero, size: size)
        context.fill(Path(bgRect), with: .color(Color.samGraphBackground))

        // --- 0. Drag grid pattern ---
        if draggedNodeID != nil {
            drawDragGrid(context: &context, size: size)
        }

        // --- 1. Family cluster boundaries (behind edges) ---
        if coordinator.familyClusteringEnabled {
            drawFamilyClusterBoundaries(context: &context, center: c, viewport: viewport)
        }

        // --- 2. Edges ---
        drawEdges(context: &context, center: c, viewport: viewport)

        // --- 3. Node shadows (drawn before node fills) ---
        drawNodeShadows(context: &context, center: c, viewport: viewport)

        // --- 4. Nodes ---
        drawNodes(context: &context, center: c, viewport: viewport)

        // --- 5. Bridge indicators ---
        if scale >= 0.3 {
            drawBridgeIndicators(context: &context, center: c, viewport: viewport)
        }

        // --- 6. Labels ---
        drawLabels(context: &context, center: c, size: size, viewport: viewport)

        // --- 7. Selection ring ---
        drawSelection(context: &context, center: c)

        // --- 8. Marquee rectangle ---
        drawMarquee(context: &context)

        // --- 9. Lasso selection path ---
        drawLasso(context: &context)

        // --- 10. Selection ripple animation ---
        drawRipple(context: &context, center: c)
    }

    // MARK: - Drawing: Edges

    /// Group edges by the unordered pair of endpoints for parallel-edge offset detection.
    private func edgePairKey(sourceID: UUID, targetID: UUID) -> String {
        let a = sourceID.uuidString
        let b = targetID.uuidString
        return a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    private func drawEdges(context: inout GraphicsContext, center: CGPoint, viewport: CGRect) {
        let nodeMap = Dictionary(uniqueKeysWithValues: coordinator.nodes.map { ($0.id, $0) })

        // Pre-compute edge group counts for parallel offset
        var edgeGroups: [String: [GraphEdge]] = [:]
        for edge in coordinator.edges {
            let key = edgePairKey(sourceID: edge.sourceID, targetID: edge.targetID)
            edgeGroups[key, default: []].append(edge)
        }

        // Track edge index within its group
        var edgeGroupIndex: [UUID: (index: Int, total: Int)] = [:]
        for (_, group) in edgeGroups {
            for (i, edge) in group.enumerated() {
                edgeGroupIndex[edge.id] = (index: i, total: group.count)
            }
        }

        for edge in coordinator.edges {
            guard let source = nodeMap[edge.sourceID],
                  let target = nodeMap[edge.targetID] else { continue }

            let sp = screenPoint(source.position, center: center)
            let tp = screenPoint(target.position, center: center)

            // Off-screen culling
            let edgeRect = CGRect(
                x: min(sp.x, tp.x), y: min(sp.y, tp.y),
                width: abs(tp.x - sp.x), height: abs(tp.y - sp.y)
            )
            guard viewport.insetBy(dx: -40, dy: -40).intersects(edgeRect) else { continue }

            let sourceRadius = nodeRadius(for: source) * scale * nodeScaleFactor(for: source)
            let targetRadius = nodeRadius(for: target) * scale * nodeScaleFactor(for: target)

            let dx = tp.x - sp.x
            let dy = tp.y - sp.y
            let dist = hypot(dx, dy)
            guard dist > 1 else { continue }

            let ux = dx / dist
            let uy = dy / dist

            let edgeStart = CGPoint(x: sp.x + ux * sourceRadius, y: sp.y + uy * sourceRadius)
            let edgeEnd = CGPoint(x: tp.x - ux * targetRadius, y: tp.y - uy * targetRadius)

            let edgeLen = hypot(edgeEnd.x - edgeStart.x, edgeEnd.y - edgeStart.y)
            guard edgeLen > 2 else { continue }

            // Parallel edge offset (§4.3): perpendicular offset for multi-edges
            let groupInfo = edgeGroupIndex[edge.id] ?? (index: 0, total: 1)
            let parallelOffset = computeParallelOffset(
                index: groupInfo.index,
                total: groupInfo.total,
                perpX: -uy,
                perpY: ux
            )

            // Compute base thickness per edge type (§4.1, High Contrast: +0.5pt)
            let baseThickness = edgeBaseThickness(for: edge.edgeType) + (highContrast ? 0.5 : 0)
            let thickness = max(0.5, baseThickness * (0.5 + 0.5 * edge.weight) * min(scale, 1.5))
            let baseColor: Color = edge.edgeType == .roleRelationship
                ? edgeColorForRoleRelationship(edge: edge, nodeMap: nodeMap)
                : edgeColor(for: edge.edgeType)
            let opacity = edgeOpacity(for: edge)
            let color = baseColor.opacity(opacity)

            // Draw edge: bundled spline, straight line, or quadratic Bézier
            var path = Path()
            var midPoint: CGPoint

            if coordinator.edgeBundlingEnabled,
               let bundledPts = coordinator.bundledEdgePaths[edge.id],
               bundledPts.count >= 3 {
                // Edge bundling: convert graph-space control points to screen-space
                let screenPts = bundledPts.map { screenPoint($0, center: center) }
                path.move(to: screenPts[0])
                // Draw as connected cubic Bézier segments through control points
                // Using Catmull-Rom-like approach: pairs of control points for cubic curves
                if screenPts.count == 3 {
                    path.addQuadCurve(to: screenPts[2], control: screenPts[1])
                } else {
                    for i in stride(from: 1, to: screenPts.count - 1, by: 2) {
                        let cp = screenPts[i]
                        let endIdx = min(i + 1, screenPts.count - 1)
                        let end = screenPts[endIdx]
                        if endIdx == i + 1 && i + 2 < screenPts.count {
                            // More points ahead: use quadratic through this control
                            path.addQuadCurve(to: end, control: cp)
                        } else {
                            path.addQuadCurve(to: end, control: cp)
                        }
                    }
                    // If odd number of remaining points, line to last
                    if let last = screenPts.last, path.currentPoint != last {
                        path.addLine(to: last)
                    }
                }
                midPoint = screenPts[screenPts.count / 2]
            } else if groupInfo.total <= 1 || parallelOffset == 0 {
                // Single edge: straight line
                path.move(to: edgeStart)
                path.addLine(to: edgeEnd)
                midPoint = CGPoint(
                    x: (edgeStart.x + edgeEnd.x) / 2,
                    y: (edgeStart.y + edgeEnd.y) / 2
                )
            } else {
                // Parallel edge: quadratic Bézier curve
                let mid = CGPoint(
                    x: (edgeStart.x + edgeEnd.x) / 2,
                    y: (edgeStart.y + edgeEnd.y) / 2
                )
                let controlPoint = CGPoint(
                    x: mid.x + parallelOffset * (-uy),
                    y: mid.y + parallelOffset * ux
                )
                path.move(to: edgeStart)
                path.addQuadCurve(to: edgeEnd, control: controlPoint)
                // Bézier midpoint at t=0.5
                midPoint = CGPoint(
                    x: 0.25 * edgeStart.x + 0.5 * controlPoint.x + 0.25 * edgeEnd.x,
                    y: 0.25 * edgeStart.y + 0.5 * controlPoint.y + 0.25 * edgeEnd.y
                )
            }

            // Stroke with appropriate dash pattern
            if edge.edgeType == .deducedFamily {
                if edge.isConfirmedDeduction {
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round))
                } else {
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round, dash: [8, 5]))
                }
            } else if edge.edgeType == .mentionedTogether && scale > 0.3 {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round, dash: [2, 4]))
            } else if edge.edgeType == .coAttendee {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round, dash: [8, 4]))
            } else {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: thickness, lineCap: .round))
            }

            // Direction arrows at Detail+ zoom
            if scale >= 0.8 {
                let isDirected: Bool
                switch edge.edgeType {
                case .referral, .recruitingTree, .roleRelationship:
                    isDirected = true
                case .communicationLink:
                    isDirected = edge.communicationDirection != nil && edge.communicationDirection != .balanced
                default:
                    isDirected = false
                }

                if isDirected {
                    // For curved edges, use tangent direction at endpoint
                    let arrowDir: CGPoint
                    if groupInfo.total > 1 && parallelOffset != 0 {
                        // Tangent of quadratic Bézier at t=1
                        let controlPoint = CGPoint(
                            x: (edgeStart.x + edgeEnd.x) / 2 + parallelOffset * (-uy),
                            y: (edgeStart.y + edgeEnd.y) / 2 + parallelOffset * ux
                        )
                        let tdx = edgeEnd.x - controlPoint.x
                        let tdy = edgeEnd.y - controlPoint.y
                        let tlen = hypot(tdx, tdy)
                        arrowDir = tlen > 0 ? CGPoint(x: tdx / tlen, y: tdy / tlen) : CGPoint(x: ux, y: uy)
                    } else {
                        arrowDir = CGPoint(x: ux, y: uy)
                    }
                    drawChevronArrow(context: &context, at: edgeEnd, direction: arrowDir, color: color, lineWidth: thickness)
                }

                if edge.isReciprocal && edge.edgeType == .communicationLink {
                    let arrowDir: CGPoint
                    if groupInfo.total > 1 && parallelOffset != 0 {
                        let controlPoint = CGPoint(
                            x: (edgeStart.x + edgeEnd.x) / 2 + parallelOffset * (-uy),
                            y: (edgeStart.y + edgeEnd.y) / 2 + parallelOffset * ux
                        )
                        let tdx = edgeStart.x - controlPoint.x
                        let tdy = edgeStart.y - controlPoint.y
                        let tlen = hypot(tdx, tdy)
                        arrowDir = tlen > 0 ? CGPoint(x: tdx / tlen, y: tdy / tlen) : CGPoint(x: -ux, y: -uy)
                    } else {
                        arrowDir = CGPoint(x: -ux, y: -uy)
                    }
                    drawChevronArrow(context: &context, at: edgeStart, direction: arrowDir, color: color, lineWidth: thickness, arrowLength: 6)
                }
            }

            // Edge labels at appropriate zoom levels (§5.4, §5.5)
            if let label = edge.label, !label.isEmpty {
                let showEdgeLabel: Bool
                if scale > 2.0 {
                    showEdgeLabel = true  // Close-up: all edge labels
                } else if scale >= 0.8 {
                    // Detail: only edges connected to selected or hovered node
                    let isSelectedEdge = coordinator.selectedNodeIDs.contains(edge.sourceID)
                        || coordinator.selectedNodeIDs.contains(edge.targetID)
                    let isHoveredEdge = hoveredNodeID == edge.sourceID || hoveredNodeID == edge.targetID
                    showEdgeLabel = isSelectedEdge || isHoveredEdge
                } else {
                    showEdgeLabel = false
                }

                if showEdgeLabel {
                    drawEdgeLabel(
                        context: &context,
                        label: label,
                        at: midPoint,
                        perpX: -uy,
                        perpY: ux,
                        color: color,
                        viewport: viewport
                    )
                }
            }
        }
    }

    /// Compute perpendicular offset for parallel edges between the same node pair.
    private func computeParallelOffset(index: Int, total: Int, perpX: CGFloat, perpY: CGFloat) -> CGFloat {
        guard total > 1 else { return 0 }
        let spacing: CGFloat = 8.0 * scale
        // Center the group: offsets are -n/2..+n/2
        let halfCount = CGFloat(total - 1) / 2.0
        return (CGFloat(index) - halfCount) * spacing
    }

    /// Base thickness per edge type per visual design spec §4.1
    private func edgeBaseThickness(for type: EdgeType) -> CGFloat {
        switch type {
        case .deducedFamily: return 2.5
        case .business, .referral, .recruitingTree, .roleRelationship: return 2.0
        case .coAttendee, .communicationLink: return 1.5
        case .mentionedTogether: return 1.0
        }
    }

    /// Draw an edge label at the given midpoint, offset perpendicular to the edge.
    private func drawEdgeLabel(
        context: inout GraphicsContext,
        label: String,
        at midPoint: CGPoint,
        perpX: CGFloat,
        perpY: CGFloat,
        color: Color,
        viewport: CGRect
    ) {
        guard isVisible(midPoint, radius: 60, viewport: viewport) else { return }

        let fontSize = max(7, min(12, 9 * scale))
        let labelText = Text(label)
            .font(.system(size: fontSize))
            .foregroundStyle(Color.primary.opacity(0.6))

        let resolved = context.resolve(labelText)
        let textSize = resolved.measure(in: CGSize(width: 100, height: 30))

        // Offset 4pt perpendicular to edge direction (above the line)
        let offset: CGFloat = 4 * scale + textSize.height / 2
        let labelPos = CGPoint(
            x: midPoint.x + perpX * offset,
            y: midPoint.y + perpY * offset
        )

        // Background pill
        let pillRect = CGRect(
            x: labelPos.x - textSize.width / 2 - 3,
            y: labelPos.y - textSize.height / 2 - 1,
            width: textSize.width + 6,
            height: textSize.height + 2
        )
        context.fill(
            Path(roundedRect: pillRect, cornerRadius: 3),
            with: .color(Color.samGraphBackground.opacity(0.85))
        )

        context.draw(resolved, at: labelPos, anchor: .center)
    }

    /// Draw a chevron arrowhead at the given point, pointing in the given direction.
    private func drawChevronArrow(
        context: inout GraphicsContext,
        at point: CGPoint,
        direction: CGPoint,
        color: Color,
        lineWidth: CGFloat,
        arrowLength: CGFloat = 8
    ) {
        let arrowWidth: CGFloat = arrowLength * 0.75
        let perpX = -direction.y
        let perpY = direction.x

        let tip = point
        let backLeft = CGPoint(
            x: tip.x - direction.x * arrowLength + perpX * arrowWidth / 2,
            y: tip.y - direction.y * arrowLength + perpY * arrowWidth / 2
        )
        let backRight = CGPoint(
            x: tip.x - direction.x * arrowLength - perpX * arrowWidth / 2,
            y: tip.y - direction.y * arrowLength - perpY * arrowWidth / 2
        )

        var arrowPath = Path()
        arrowPath.move(to: backLeft)
        arrowPath.addLine(to: tip)
        arrowPath.addLine(to: backRight)

        context.stroke(
            arrowPath,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Drawing: Node Shadows

    private func drawNodeShadows(context: inout GraphicsContext, center: CGPoint, viewport: CGRect) {
        // Skip shadows at distant zoom for performance
        guard scale >= 0.3 else { return }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        for node in coordinator.nodes {
            guard !node.isGhost else { continue }  // Ghost nodes have no shadow

            let sp = screenPoint(node.position, center: center)
            let scaleFactor = nodeScaleFactor(for: node)
            let radius = nodeRadius(for: node) * scale * scaleFactor

            guard radius > 2 else { continue }
            guard isVisible(sp, radius: radius + 10, viewport: viewport) else { continue }

            let isHovered = hoveredNodeID == node.id
            let isDragged = draggedNodeID == node.id

            let shadowOffset: CGFloat
            let shadowBlur: CGFloat
            let shadowOpacity: Double

            if isDragged {
                shadowOffset = 4
                shadowBlur = 10
                shadowOpacity = isDark ? 0.5 : 0.3
            } else if isHovered {
                shadowOffset = 2
                shadowBlur = 6
                shadowOpacity = isDark ? 0.4 : 0.25
            } else {
                shadowOffset = 1
                shadowBlur = isDark ? 4 : 3
                shadowOpacity = isDark ? 0.3 : 0.15
            }

            let shadowRect = CGRect(
                x: sp.x - radius,
                y: sp.y - radius + shadowOffset,
                width: radius * 2,
                height: radius * 2
            )
            let shadowPath = Path(ellipseIn: shadowRect)

            var shadowContext = context
            shadowContext.addFilter(.blur(radius: shadowBlur))
            shadowContext.fill(shadowPath, with: .color(.black.opacity(shadowOpacity)))
        }
    }

    // MARK: - Drawing: Nodes

    private func drawNodes(context: inout GraphicsContext, center: CGPoint, viewport: CGRect) {
        for node in coordinator.nodes {
            let sp = screenPoint(node.position, center: center)
            let scaleFactor = nodeScaleFactor(for: node)
            let radius = nodeRadius(for: node) * scale * scaleFactor
            let opacity = nodeOpacity(for: node)

            guard radius > 1 else { continue }
            guard isVisible(sp, radius: radius, viewport: viewport) else { continue }

            let rect = CGRect(
                x: sp.x - radius,
                y: sp.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            let fillPath = Path(ellipseIn: rect)

            // Ghost nodes: translucent fill + marching ants dashed border
            if node.isGhost {
                let roleCol = roleColor(for: node)
                let ghostFillOpacity = reduceTransparency ? 0.30 : 0.15
                context.fill(fillPath, with: .color(roleCol.opacity(ghostFillOpacity * opacity)))

                // Marching ants: animated dashPhase (gated on !reduceMotion)
                let dashes: [CGFloat] = reduceMotion ? [4, 2, 2, 4] : [4, 4]
                let dashPhase = reduceMotion ? 0 : ghostAnimationPhase
                let ghostStrokeWidth: CGFloat = highContrast ? 2.5 : 1.5
                context.stroke(
                    fillPath,
                    with: .color(roleCol.opacity(0.6 * opacity)),
                    style: StrokeStyle(lineWidth: ghostStrokeWidth, dash: dashes, dashPhase: dashPhase)
                )

                // Question mark glyph for ghost nodes
                if scale >= 0.5 {
                    let glyphSize = radius * 1.2
                    let glyphText = Text(Image(systemName: "person.fill.questionmark"))
                        .font(.system(size: glyphSize))
                        .foregroundStyle(Color.primary.opacity(0.6 * opacity))
                    let resolved = context.resolve(glyphText)
                    context.draw(resolved, at: sp, anchor: .center)
                }
            } else {
                // Real nodes: solid fill + health stroke
                let fillColor = roleColor(for: node)
                context.fill(fillPath, with: .color(fillColor.opacity(opacity)))

                // Health stroke (High Contrast: +1pt)
                let healthCol = healthColor(for: node.relationshipHealth)
                let baseHealthWidth = healthStrokeWidth(for: node.relationshipHealth)
                let healthWidth = (baseHealthWidth + (highContrast ? 1.0 : 0)) * min(scale, 1.5)
                context.stroke(fillPath, with: .color(healthCol.opacity(opacity)), lineWidth: healthWidth)

                // Photo thumbnail at Detail+ zoom
                if scale > 0.8, let photoData = node.photoThumbnail,
                   let nsImage = NSImage(data: photoData) {
                    let image = Image(nsImage: nsImage)
                    let resolved = context.resolve(image)
                    var clipped = context
                    clipped.clipToLayer { clipCtx in
                        clipCtx.fill(fillPath, with: .color(.white))
                    }
                    clipped.draw(resolved, in: rect)
                    // Re-draw health stroke on top of photo
                    context.stroke(fillPath, with: .color(healthCol.opacity(opacity)), lineWidth: healthWidth)
                }
            }

            // Compatible node highlight during ghost drag
            if !compatibleNodeIDs.isEmpty && compatibleNodeIDs.contains(node.id) {
                let highlightRadius = radius + 4
                let highlightRect = CGRect(
                    x: sp.x - highlightRadius,
                    y: sp.y - highlightRadius,
                    width: highlightRadius * 2,
                    height: highlightRadius * 2
                )
                let highlightPath = Path(ellipseIn: highlightRect)
                let isSnapTarget = magneticSnapTargetID == node.id
                let highlightColor: Color = isSnapTarget ? .green : .green.opacity(0.4)
                let highlightWidth: CGFloat = isSnapTarget ? 3.0 : 1.5
                context.stroke(highlightPath, with: .color(highlightColor), lineWidth: highlightWidth)
            }

            // Intelligence overlay: Referral Hub Detection - pulsing glow on high-centrality nodes
            if coordinator.activeOverlay == .referralHub, !node.isGhost {
                let centrality = coordinator.betweennessCentrality[node.id] ?? 0
                let maxCentrality = coordinator.betweennessCentrality.values.max() ?? 1
                let normalizedCentrality = maxCentrality > 0 ? centrality / maxCentrality : 0

                if normalizedCentrality > 0.3 {  // Only highlight top hubs
                    let glowRadius = radius + 6 + CGFloat(normalizedCentrality) * 8
                    let glowRect = CGRect(
                        x: sp.x - glowRadius,
                        y: sp.y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )
                    let glowColor = Color.orange.opacity(0.3 * normalizedCentrality * opacity)
                    context.fill(Path(ellipseIn: glowRect), with: .color(glowColor))
                    context.stroke(
                        Path(ellipseIn: glowRect),
                        with: .color(Color.orange.opacity(0.6 * normalizedCentrality * opacity)),
                        lineWidth: 1.5
                    )
                }
            }

            // Intelligence overlay: Communication Flow — node size emphasis by comm volume
            if coordinator.activeOverlay == .communicationFlow, !node.isGhost {
                let commEdges = coordinator.edges.filter {
                    ($0.sourceID == node.id || $0.targetID == node.id) && $0.edgeType == .communicationLink
                }
                if commEdges.count >= 3 {
                    let flowRadius = radius + 3
                    let flowRect = CGRect(
                        x: sp.x - flowRadius,
                        y: sp.y - flowRadius,
                        width: flowRadius * 2,
                        height: flowRadius * 2
                    )
                    context.stroke(
                        Path(ellipseIn: flowRect),
                        with: .color(Color.cyan.opacity(0.5 * opacity)),
                        lineWidth: 1.5
                    )
                }
            }

            // Intelligence overlay: Recruiting Tree Health — stage indicator ring
            if coordinator.activeOverlay == .recruitingHealth, !node.isGhost {
                let recruitEdges = coordinator.edges.filter {
                    ($0.sourceID == node.id || $0.targetID == node.id) && $0.edgeType == .recruitingTree
                }
                if !recruitEdges.isEmpty {
                    let stageColor: Color = node.roleBadges.contains("Agent") ? .green : .blue
                    let stageRadius = radius + 3
                    let stageRect = CGRect(
                        x: sp.x - stageRadius,
                        y: sp.y - stageRadius,
                        width: stageRadius * 2,
                        height: stageRadius * 2
                    )
                    context.stroke(
                        Path(ellipseIn: stageRect),
                        with: .color(stageColor.opacity(0.6 * opacity)),
                        lineWidth: 2.0
                    )
                }
            }

            // Role glyph at Close-up zoom (>2.0×) for color-blindness accessibility
            if scale > 2.0, !node.isGhost, let primaryRole = node.roleBadges.first {
                let glyphName = roleGlyphName(for: primaryRole)
                let glyphSize: CGFloat = max(8, radius * 0.5)
                // 10 o'clock position
                let glyphAngle = CGFloat.pi * 5 / 6  // ~150°
                let glyphCenter = CGPoint(
                    x: sp.x + (radius - 2) * cos(glyphAngle),
                    y: sp.y - (radius - 2) * sin(glyphAngle)
                )
                let glyphText = Text(Image(systemName: glyphName))
                    .font(.system(size: glyphSize))
                    .foregroundStyle(Color.primary.opacity(0.7 * opacity))
                let resolvedGlyph = context.resolve(glyphText)
                context.draw(resolvedGlyph, at: glyphCenter, anchor: .center)
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
        }
    }

    // MARK: - Drawing: Labels

    private func drawLabels(context: inout GraphicsContext, center: CGPoint, size: CGSize, viewport: CGRect) {
        guard scale >= 0.3 else { return }  // No labels at Distant zoom

        // At Overview zoom (0.3–0.5), only show top-N labels by production
        let showAll = scale >= 0.8
        let showTopN = scale >= 0.5 && scale < 0.8
        let topNodeIDs: Set<UUID>

        if showTopN {
            let sorted = coordinator.nodes
                .sorted { $0.productionValue > $1.productionValue }
                .prefix(30)
            topNodeIDs = Set(sorted.map(\.id))
                .union(coordinator.selectedNodeIDs)
        } else if !showAll {
            // Between 0.3 and 0.5: show top 10
            let sorted = coordinator.nodes
                .sorted { $0.productionValue > $1.productionValue }
                .prefix(10)
            topNodeIDs = Set(sorted.map(\.id))
                .union(coordinator.selectedNodeIDs)
        } else {
            topNodeIDs = []
        }

        // Label collision avoidance: track placed label rects
        var placedRects: [CGRect] = []

        for node in coordinator.nodes {
            // Filter by zoom level
            if !showAll && !topNodeIDs.contains(node.id) { continue }

            let sp = screenPoint(node.position, center: center)
            let scaleFactor = nodeScaleFactor(for: node)
            let radius = nodeRadius(for: node) * scale * scaleFactor
            let opacity = nodeOpacity(for: node)

            guard isVisible(sp, radius: radius + 30, viewport: viewport) else { continue }

            let fontSize = max(7, min(16, 11 * scale))
            let fontWeight: Font.Weight = highContrast ? .medium : .regular
            let text = Text(node.displayName)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(Color.primary.opacity(opacity))
                .italic(node.isGhost)

            let resolved = context.resolve(text)
            let textSize = resolved.measure(in: CGSize(width: 120, height: 50))

            // Collision avoidance: try positions in priority order
            // below-center, below-right, below-left, above-center, right, left
            let gap: CGFloat = 4
            let candidatePositions: [(CGFloat, CGFloat)] = [
                (sp.x, sp.y + radius + textSize.height / 2 + gap),          // below-center
                (sp.x + radius * 0.5, sp.y + radius + textSize.height / 2 + gap), // below-right
                (sp.x - radius * 0.5, sp.y + radius + textSize.height / 2 + gap), // below-left
                (sp.x, sp.y - radius - textSize.height / 2 - gap),          // above-center
                (sp.x + radius + textSize.width / 2 + gap, sp.y),           // right
                (sp.x - radius - textSize.width / 2 - gap, sp.y),           // left
            ]

            var bestPos = CGPoint(x: candidatePositions[0].0, y: candidatePositions[0].1)
            var bestOverlap: CGFloat = .infinity

            for (cx, cy) in candidatePositions {
                let candidateRect = CGRect(
                    x: cx - textSize.width / 2,
                    y: cy - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                )

                var totalOverlap: CGFloat = 0
                for placed in placedRects {
                    let overlap = candidateRect.intersection(placed)
                    if !overlap.isNull {
                        totalOverlap += overlap.width * overlap.height
                    }
                }

                if totalOverlap < bestOverlap {
                    bestOverlap = totalOverlap
                    bestPos = CGPoint(x: cx, y: cy)
                }

                if totalOverlap == 0 { break }  // No collision, use this position
            }

            let labelRect = CGRect(
                x: bestPos.x - textSize.width / 2,
                y: bestPos.y - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            placedRects.append(labelRect)

            // Label background pill at Detail+ zoom (Reduce Transparency: fully opaque)
            if scale >= 0.8 {
                let pillRect = labelRect.insetBy(dx: -2, dy: -1)
                let pillOpacity: Double = reduceTransparency ? 1.0 : 0.8
                context.fill(
                    Path(roundedRect: pillRect, cornerRadius: 3),
                    with: .color(Color.samGraphBackground.opacity(pillOpacity))
                )
            }

            context.draw(resolved, at: bestPos, anchor: .center)
        }
    }

    // MARK: - Drawing: Selection Ring & Drop Target

    private func drawSelection(context: inout GraphicsContext, center: CGPoint) {
        // Selection rings for all selected nodes
        for selectedID in coordinator.selectedNodeIDs {
            guard let node = coordinator.nodes.first(where: { $0.id == selectedID }) else { continue }
            let sp = screenPoint(node.position, center: center)
            let scaleFactor = nodeScaleFactor(for: node)
            let radius = nodeRadius(for: node) * scale * scaleFactor + 4

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

        // Selection count badge
        if coordinator.selectedNodeIDs.count > 1,
           let anchorID = coordinator.selectionAnchorID,
           let anchorNode = coordinator.nodes.first(where: { $0.id == anchorID }) {
            let sp = screenPoint(anchorNode.position, center: center)
            let count = coordinator.selectedNodeIDs.count
            let badgeColor: Color = count > 40 ? .red : count > 15 ? .orange : .accentColor
            let badgeText = Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            let resolved = context.resolve(badgeText)
            let badgeSize: CGFloat = count >= 10 ? 22 : 18
            let badgeRect = CGRect(
                x: sp.x + nodeRadius(for: anchorNode) * scale - badgeSize / 4,
                y: sp.y - nodeRadius(for: anchorNode) * scale - badgeSize / 2,
                width: badgeSize,
                height: badgeSize
            )
            context.fill(Path(ellipseIn: badgeRect), with: .color(badgeColor))
            context.draw(resolved, at: CGPoint(x: badgeRect.midX, y: badgeRect.midY), anchor: .center)
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

    // MARK: - Drawing: Family Cluster Boundaries

    private func drawFamilyClusterBoundaries(
        context: inout GraphicsContext,
        center: CGPoint,
        viewport: CGRect
    ) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        for cluster in coordinator.familyClusters {
            guard !coordinator.collapsedFamilyClusters.contains(cluster.id) else { continue }

            // Compute bounding rect of member nodes
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
            var minY = CGFloat.infinity, maxY = -CGFloat.infinity
            var maxRadius: CGFloat = 0
            var memberCount = 0

            for memberID in cluster.memberIDs {
                guard let node = coordinator.nodes.first(where: { $0.id == memberID }) else { continue }
                let sp = screenPoint(node.position, center: center)
                let r = nodeRadius(for: node) * scale * nodeScaleFactor(for: node)
                minX = min(minX, sp.x - r)
                maxX = max(maxX, sp.x + r)
                minY = min(minY, sp.y - r)
                maxY = max(maxY, sp.y + r)
                maxRadius = max(maxRadius, r)
                memberCount += 1
            }

            guard memberCount >= 2, minX < maxX, minY < maxY else { continue }

            // Expand by padding (20pt visual padding per spec §7.1)
            let padding: CGFloat = 20 * scale
            let boundaryRect = CGRect(
                x: minX - padding,
                y: minY - padding,
                width: (maxX - minX) + 2 * padding,
                height: (maxY - minY) + 2 * padding
            )

            // Off-screen culling
            guard viewport.insetBy(dx: -40, dy: -40).intersects(boundaryRect) else { continue }

            // Corner radius per spec §7.1
            let shortSide = min(boundaryRect.width, boundaryRect.height)
            let cornerRadius = min(24 * scale, shortSide / 4)

            let boundaryPath = Path(roundedRect: boundaryRect, cornerRadius: cornerRadius)

            // Fill: dominant role color at 6%/8% opacity (§7.2)
            let roleCol: Color
            if let role = cluster.dominantRole {
                roleCol = RoleBadgeStyle.forBadge(role).color
            } else {
                roleCol = .gray
            }
            let baseFillOpacity: Double = isDark ? 0.08 : 0.06
            let fillOpacity: Double = reduceTransparency ? 0.15 : baseFillOpacity
            context.fill(boundaryPath, with: .color(roleCol.opacity(fillOpacity)))

            // Stroke: same color at 20% opacity, 1pt (§7.2)
            context.stroke(boundaryPath, with: .color(roleCol.opacity(0.2)), lineWidth: 1)

            // Label: cluster name at Overview+ zoom (0.5×+) per §7.3
            if scale >= 0.5 {
                let fontSize = max(7, min(13, 10 * scale))
                let labelText = Text(cluster.displayName)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.4))
                let resolved = context.resolve(labelText)
                let labelPos = CGPoint(
                    x: boundaryRect.minX + 8 * scale + cornerRadius / 2,
                    y: boundaryRect.minY + 8 * scale + fontSize / 2
                )
                context.draw(resolved, at: labelPos, anchor: .leading)
            }
        }
    }

    // MARK: - Drawing: Bridge Indicators

    private func drawBridgeIndicators(
        context: inout GraphicsContext,
        center: CGPoint,
        viewport: CGRect
    ) {
        for (nodeID, distantCount) in coordinator.bridgeIndicators {
            guard distantCount > 0 else { continue }
            guard let node = coordinator.nodes.first(where: { $0.id == nodeID }) else { continue }

            let sp = screenPoint(node.position, center: center)
            let scaleFactor = nodeScaleFactor(for: node)
            let radius = nodeRadius(for: node) * scale * scaleFactor

            guard isVisible(sp, radius: radius + 20, viewport: viewport) else { continue }

            // Badge position: 2 o'clock (upper-right edge of node) per §3.1
            let badgeAngle = -CGFloat.pi / 6  // 2 o'clock = -30°
            let badgeCenter = CGPoint(
                x: sp.x + (radius - 2) * cos(badgeAngle),
                y: sp.y + (radius - 2) * sin(badgeAngle)
            )

            // Badge size
            let badgeDiameter: CGFloat = distantCount >= 10 ? 20 : 16
            let badgeRect = CGRect(
                x: badgeCenter.x - badgeDiameter / 2,
                y: badgeCenter.y - badgeDiameter / 2,
                width: badgeDiameter,
                height: badgeDiameter
            )

            // Badge color encodes cluster size (§3.1)
            let badgeColor: Color
            if distantCount >= 16 {
                badgeColor = Color(red: 0.957, green: 0.263, blue: 0.212)  // #F44336 red
            } else if distantCount >= 6 {
                badgeColor = Color(red: 1.0, green: 0.596, blue: 0.0)  // #FF9800 orange
            } else {
                badgeColor = Color(red: 0.259, green: 0.647, blue: 0.961)  // #42A5F5 blue
            }

            // Draw badge circle
            context.fill(Path(ellipseIn: badgeRect), with: .color(badgeColor))

            // Draw count text
            let countText = Text("\(distantCount)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            let resolved = context.resolve(countText)
            context.draw(resolved, at: badgeCenter, anchor: .center)
        }
    }

    // MARK: - Drawing: Marquee Rectangle

    private func drawMarquee(context: inout GraphicsContext) {
        guard isMarqueeActive else { return }

        let minX = min(marqueeStart.x, marqueeEnd.x)
        let minY = min(marqueeStart.y, marqueeEnd.y)
        let width = abs(marqueeEnd.x - marqueeStart.x)
        let height = abs(marqueeEnd.y - marqueeStart.y)

        let rect = CGRect(x: minX, y: minY, width: width, height: height)

        // Fill
        context.fill(Path(rect), with: .color(.accentColor.opacity(0.05)))

        // Dashed border
        let dashes: [CGFloat] = [6, 3]
        context.stroke(
            Path(rect),
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: 1, dash: dashes)
        )
    }

    // MARK: - Drawing: Drag Grid Pattern

    private func drawDragGrid(context: inout GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 20
        let dotRadius: CGFloat = 0.5
        let dotColor = Color.primary.opacity(0.08)

        var x: CGFloat = 0
        while x < size.width {
            var y: CGFloat = 0
            while y < size.height {
                let dotRect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
                y += spacing
            }
            x += spacing
        }
    }

    // MARK: - Drawing: Lasso Selection Path

    private func drawLasso(context: inout GraphicsContext) {
        guard isLassoActive, lassoPoints.count >= 2 else { return }

        var path = Path()
        path.move(to: lassoPoints[0])
        for i in 1..<lassoPoints.count {
            path.addLine(to: lassoPoints[i])
        }

        // Dashed accent-color stroke
        let dashes: [CGFloat] = [6, 4]
        context.stroke(
            path,
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: dashes)
        )

        // Light fill preview of closed path
        var closedPath = path
        closedPath.closeSubpath()
        context.fill(closedPath, with: .color(.accentColor.opacity(0.04)))
    }

    // MARK: - Drawing: Selection Ripple

    private func drawRipple(context: inout GraphicsContext, center: CGPoint) {
        guard let rc = rippleCenter, rippleProgress > 0, rippleProgress < 1 else { return }

        let sp = screenPoint(rc, center: center)
        let currentRadius = rippleMaxRadius * scale * rippleProgress
        let opacity = 0.3 * (1.0 - rippleProgress)

        let ripplePath = Path(ellipseIn: CGRect(
            x: sp.x - currentRadius,
            y: sp.y - currentRadius,
            width: currentRadius * 2,
            height: currentRadius * 2
        ))

        context.stroke(
            ripplePath,
            with: .color(.accentColor.opacity(opacity)),
            lineWidth: 2
        )
    }

    // MARK: - Color Helpers

    // MARK: - String Distance

    /// Levenshtein edit distance between two strings.
    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }

    private func roleColor(for node: GraphNode) -> Color {
        if node.isGhost {
            return .gray
        }
        guard let role = node.primaryRole else {
            return .gray
        }
        return RoleBadgeStyle.forBadge(role).color
    }

    /// SF Symbol glyph name for each role, used at Close-up zoom for color-blindness accessibility.
    private func roleGlyphName(for role: String) -> String {
        switch role {
        case "Client":          return "person.crop.circle.badge.checkmark"
        case "Applicant":       return "person.crop.circle.badge.clock"
        case "Lead":            return "person.crop.circle.badge.plus"
        case "Agent":           return "person.crop.circle.badge.fill"
        case "External Agent":  return "person.2.circle"
        case "Vendor":          return "building.2.crop.circle"
        case "Recruit":         return "person.crop.circle.badge.questionmark"
        default:                return "person.circle"
        }
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

    /// Health stroke width increases with urgency per visual design spec §2.2
    private func healthStrokeWidth(for health: GraphNode.HealthLevel) -> CGFloat {
        switch health {
        case .healthy: return 2.0
        case .cooling:  return 2.5
        case .atRisk:   return 3.0
        case .cold:     return 3.0
        case .unknown:  return 1.5
        }
    }

    private func edgeColor(for type: EdgeType) -> Color {
        switch type {
        case .business:          return Color(red: 0.494, green: 0.341, blue: 0.761)  // #7E57C2
        case .referral:          return Color(red: 0.149, green: 0.651, blue: 0.604)  // #26A69A
        case .recruitingTree:    return Color(red: 0.259, green: 0.647, blue: 0.961)  // #42A5F5
        case .coAttendee:        return Color(red: 0.471, green: 0.565, blue: 0.612)  // #78909C
        case .communicationLink: return Color(red: 0.553, green: 0.431, blue: 0.388)  // #8D6E63
        case .mentionedTogether: return Color(red: 0.741, green: 0.741, blue: 0.741)  // #BDBDBD
        case .deducedFamily:     return .pink
        case .roleRelationship:  return .accentColor  // Fallback; overridden per-edge with target's role color
        }
    }

    /// Role-aware edge color for roleRelationship edges — uses the target node's role color.
    private func edgeColorForRoleRelationship(edge: GraphEdge, nodeMap: [UUID: GraphNode]) -> Color {
        if let target = nodeMap[edge.targetID], let role = target.primaryRole {
            return RoleBadgeStyle.forBadge(role).color
        }
        return .accentColor
    }
}

// MARK: - Scroll Wheel Zoom (NSView overlay for scroll event capture)

private struct ScrollWheelZoomView: NSViewRepresentable {
    @Binding var scale: CGFloat
    @Binding var lastScale: CGFloat

    func makeNSView(context: Context) -> ScrollWheelCaptureView {
        let view = ScrollWheelCaptureView()
        view.onScroll = { deltaY in
            Task { @MainActor in
                let factor: CGFloat = 1.0 + deltaY * 0.03
                let proposed = scale * factor
                scale = min(max(proposed, 0.1), 5.0)
                lastScale = scale
            }
        }
        return view
    }

    func updateNSView(_ nsView: ScrollWheelCaptureView, context: Context) {}
}

private final class ScrollWheelCaptureView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // Only handle scroll wheel (not momentum from trackpad)
        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            // Discrete scroll wheel (mouse)
            onScroll?(event.scrollingDeltaY)
        } else if !event.phase.isEmpty {
            // Trackpad pinch-to-scroll: use deltaY with smaller factor
            onScroll?(event.scrollingDeltaY * 0.3)
        }
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Pass through all mouse events except scroll wheel
        nil
    }
}

// MARK: - Canvas Background Color

extension Color {
    /// Warm gray (light) / dark blue-gray (dark) per visual design spec §9.1
    static var samGraphBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 0.102, green: 0.102, blue: 0.180, alpha: 1.0)  // #1A1A2E
            } else {
                return NSColor(red: 0.973, green: 0.976, blue: 0.980, alpha: 1.0)  // #F8F9FA
            }
        })
    }
}

// MARK: - Spring Animation Presets

extension Spring {
    /// Fast, snappy spring for selection glow and UI feedback.
    static let responsive = Spring(response: 0.3, dampingRatio: 0.7)
    /// Medium spring for pull/release and interactive transitions.
    static let interactive = Spring(response: 0.5, dampingRatio: 0.65)
    /// Slower spring for layout and structural transitions.
    static let structural = Spring(response: 0.6, dampingRatio: 0.8)
}

// MARK: - Preview

#Preview {
    RelationshipGraphView()
        .frame(width: 900, height: 700)
}
