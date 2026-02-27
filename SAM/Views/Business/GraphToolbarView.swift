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

    private let allRoles = ["Client", "Applicant", "Lead", "Agent", "External Agent", "Referral Partner", "Vendor", "Prospect"]

    var body: some ToolbarContent {

        // MARK: - Status

        ToolbarItem(placement: .automatic) {
            Text(coordinator.progress)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // MARK: - Filters

        ToolbarItem(placement: .automatic) {
            filterMenus
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
                    Button {
                        if isActive {
                            coordinator.activeRoleFilters.remove(role)
                        } else {
                            coordinator.activeRoleFilters.insert(role)
                        }
                        coordinator.applyFilters()
                    } label: {
                        HStack {
                            let style = RoleBadgeStyle.forBadge(role)
                            Image(systemName: style.icon)
                                .foregroundStyle(style.color)
                            Text(role)
                            if isActive {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Roles", systemImage: "person.3")
            }
            .help("Filter by role")
            .overlay(alignment: .topTrailing) {
                filterBadge(count: coordinator.activeRoleFilters.count)
            }

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
                    set: { coordinator.showOrphanedNodes = $0; coordinator.applyFilters() }
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
                .font(.caption)
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
        }
    }
}
