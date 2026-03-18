//
//  GraphToolbarView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA.2/AA.4: Graph Renderer
//
//  Toolbar content for RelationshipGraphView: zoom controls,
//  filter pickers, overlay toggles, status display, and rebuild.
//

import SwiftUI

struct GraphToolbarView: ToolbarContent {

    @Bindable var coordinator: RelationshipGraphCoordinator
    @Binding var scale: CGFloat
    @Binding var offset: CGPoint
    var fitToView: () -> Void

    private let predefinedRoles = ["Client", "Applicant", "Lead", "Agent", "External Agent", "Referral Partner", "Vendor", "Prospect"]

    /// Dynamically discovered roles from the graph data: predefined roles first (in order), then custom roles alphabetically.
    private var allRoles: [String] {
        let dataRoles = Set(coordinator.allNodes.flatMap(\.roleBadges))
        var seen = Set<String>()
        var result: [String] = []
        for role in predefinedRoles where dataRoles.contains(role) {
            if seen.insert(role).inserted { result.append(role) }
        }
        for role in dataRoles.sorted() {
            if seen.insert(role).inserted { result.append(role) }
        }
        return result
    }

    var body: some ToolbarContent {

        // MARK: - Status

        ToolbarItem(placement: .automatic) {
            Text(coordinator.progress)
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }

        // MARK: - Filters

        ToolbarItem(placement: .automatic) {
            filterMenus
        }

        // MARK: - Toggle Controls

        ToolbarItem(placement: .automatic) {
            HStack(spacing: 4) {
                Toggle(isOn: Binding(
                    get: { coordinator.familyClusteringEnabled },
                    set: { coordinator.familyClusteringEnabled = $0; coordinator.applyFilters() }
                )) {
                    Image(systemName: "person.2.circle")
                }
                .toggleStyle(.button)
                .help("Toggle Family Clustering (⌘G)")

                Toggle(isOn: Binding(
                    get: { coordinator.edgeBundlingEnabled },
                    set: { coordinator.edgeBundlingEnabled = $0 }
                )) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .help("Toggle Edge Bundling (⌘B)")
            }
        }

        // MARK: - Deduced Relationships Review

        if coordinator.unconfirmedDeducedRelationCount > 0 && coordinator.focusMode == nil {
            ToolbarItem(placement: .automatic) {
                Button {
                    coordinator.activateFocusMode("deducedRelationships")
                } label: {
                    Label("Review Family (\(coordinator.unconfirmedDeducedRelationCount))", systemImage: "person.2.fill")
                }
                .help("Review deduced family relationships")
            }
        }

        // MARK: - Intelligence Overlays

        ToolbarItem(placement: .automatic) {
            overlayMenu
        }

        // MARK: - Zoom Controls

        ToolbarItem(placement: .automatic) {
            zoomControls
        }

        // MARK: - Rebuild

        ToolbarItem(placement: .automatic) {
            Button {
                Task { await coordinator.buildGraph() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rebuild Graph")
            .disabled(coordinator.graphStatus == .computing)
        }
    }

    // MARK: - Overlay Menu

    private var overlayMenu: some View {
        Menu {
            Button("No Overlay") {
                coordinator.activeOverlay = nil
            }
            Divider()
            ForEach(RelationshipGraphCoordinator.OverlayType.allCases, id: \.self) { overlay in
                Button {
                    if coordinator.activeOverlay == overlay {
                        coordinator.activeOverlay = nil
                    } else {
                        coordinator.activeOverlay = overlay
                        if overlay == .referralHub {
                            coordinator.computeBetweennessCentrality()
                        }
                    }
                } label: {
                    HStack {
                        Text(overlay.rawValue)
                        if coordinator.activeOverlay == overlay {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: coordinator.activeOverlay != nil ? "eye.circle.fill" : "eye.circle")
        }
        .help("Intelligence Overlays")
    }

    // MARK: - Filter Menus

    private var filterMenus: some View {
        HStack(spacing: 4) {
            // Role filter
            Menu {
                Button("Show All Roles") {
                    coordinator.activeRoleFilters.removeAll()
                    coordinator.applyFilters()
                }
                Divider()
                ForEach(allRoles, id: \.self) { role in
                    let isActive = coordinator.activeRoleFilters.contains(role)
                    let style = RoleBadgeStyle.forBadge(role)
                    Button {
                        if isActive {
                            coordinator.activeRoleFilters.remove(role)
                        } else {
                            coordinator.activeRoleFilters.insert(role)
                        }
                        coordinator.applyFilters()
                    } label: {
                        HStack {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isActive ? style.color : .secondary)
                            Image(systemName: style.icon)
                                .foregroundStyle(style.color)
                            Text(role)
                        }
                    }
                }
            } label: {
                roleFilterLabel
            }
            .help("Filter by role")

            // Edge type filter
            Menu {
                Button("Show All Connections") {
                    coordinator.activeEdgeTypeFilters.removeAll()
                    coordinator.applyFilters()
                }
                Divider()
                ForEach(EdgeType.allCases, id: \.self) { edgeType in
                    let isActive = coordinator.activeEdgeTypeFilters.contains(edgeType)
                    Button {
                        if isActive {
                            coordinator.activeEdgeTypeFilters.remove(edgeType)
                        } else {
                            coordinator.activeEdgeTypeFilters.insert(edgeType)
                        }
                        coordinator.applyFilters()
                    } label: {
                        HStack {
                            Text(edgeType.displayName)
                            if isActive {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Connections", systemImage: "line.diagonal")
            }
            .help("Filter by connection type")
            .overlay(alignment: .topTrailing) {
                filterBadge(count: coordinator.activeEdgeTypeFilters.count)
            }

            // Visibility toggles
            Menu {
                Toggle("My Connections", isOn: Binding(
                    get: { coordinator.showMeNode },
                    set: { coordinator.showMeNode = $0; Task { await coordinator.buildGraph() } }
                ))
                Toggle("Ghost Nodes", isOn: Binding(
                    get: { coordinator.showGhostNodes },
                    set: { coordinator.showGhostNodes = $0; coordinator.applyFilters() }
                ))
                Toggle("Orphaned Nodes", isOn: Binding(
                    get: { coordinator.showOrphanedNodes },
                    set: {
                        coordinator.showOrphanedNodes = $0
                        if $0 { coordinator.revealedNodeIDs.removeAll() }
                        coordinator.applyFilters()
                    }
                ))
            } label: {
                Label("Visibility", systemImage: "eye")
            }
            .help("Toggle node visibility")
        }
    }

    // MARK: - Zoom Controls

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scale = min(scale * 1.25, 5.0)
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In")

            Text("\(Int(scale * 100))%")
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scale = max(scale / 1.25, 0.1)
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out")

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    fitToView()
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit to View")
            .keyboardShortcut("0", modifiers: .command)
        }
    }

    // MARK: - Filter Badge

    /// Role filter menu label: shows colored role icons when filtered, generic icon when not.
    @ViewBuilder
    private var roleFilterLabel: some View {
        let active = coordinator.activeRoleFilters
        if active.isEmpty {
            Label("Roles", systemImage: "person.3")
        } else {
            // Show up to 3 role icons in their colors, plus overflow count
            let sorted = allRoles.filter { active.contains($0) }
            let visible = sorted.prefix(3)
            let overflow = active.count - visible.count
            HStack(spacing: 3) {
                ForEach(Array(visible), id: \.self) { role in
                    let style = RoleBadgeStyle.forBadge(role)
                    Image(systemName: style.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(style.color)
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func filterBadge(count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Color.accentColor)
                .clipShape(Circle())
                .offset(x: 4, y: -4)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - EdgeType Display Name

extension EdgeType {
    var displayName: String {
        switch self {
        case .business:          return "Business"
        case .referral:          return "Referral"
        case .recruitingTree:    return "Recruiting Tree"
        case .coAttendee:        return "Co-Attendee"
        case .communicationLink: return "Communication"
        case .mentionedTogether: return "Mentioned Together"
        case .deducedFamily:     return "Deduced Family"
        case .familyReference:   return "Family (Notes)"
        case .roleRelationship:  return "Role Relationship"
        }
    }
}
