//
//  NetworkGrowthSection.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA.6: Dashboard Integration
//
//  Network growth metrics card for the Awareness Review & Analytics group.
//

import SwiftUI

struct NetworkGrowthSection: View {

    @State private var coordinator = RelationshipGraphCoordinator.shared

    private var hasData: Bool {
        coordinator.graphStatus == .ready && !coordinator.nodes.isEmpty
    }

    var body: some View {
        if hasData {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "circle.grid.cross")
                        .foregroundStyle(.cyan)
                    Text("Network")
                        .font(.headline)
                    Spacer()
                    Text("\(coordinator.nodes.count) people")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                // Metric cards
                HStack(spacing: 12) {
                    NetworkMetricCard(
                        icon: "person.2.fill",
                        value: "\(totalConnections)",
                        label: "Connections",
                        accent: .blue
                    )
                    NetworkMetricCard(
                        icon: "point.3.connected.trianglepath.dotted",
                        value: String(format: "%.1f", avgConnections),
                        label: "Avg per Person",
                        accent: .teal
                    )
                    NetworkMetricCard(
                        icon: "person.fill.questionmark",
                        value: "\(ghostCount)",
                        label: "Ghosts",
                        accent: .gray
                    )
                    NetworkMetricCard(
                        icon: "circle.dashed",
                        value: "\(orphanCount)",
                        label: "Orphans",
                        accent: .orange
                    )
                }
                .padding()

                // Health distribution
                if !healthDistribution.isEmpty {
                    Divider()

                    HStack(spacing: 16) {
                        ForEach(healthDistribution, id: \.label) { item in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 8, height: 8)
                                Text("\(item.count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text(item.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Computed Metrics

    private var totalConnections: Int {
        coordinator.edges.count
    }

    private var avgConnections: Double {
        let nodeCount = coordinator.nodes.filter { !$0.isGhost }.count
        guard nodeCount > 0 else { return 0 }
        return Double(coordinator.edges.count) / Double(nodeCount)
    }

    private var ghostCount: Int {
        coordinator.nodes.filter { $0.isGhost }.count
    }

    private var orphanCount: Int {
        coordinator.nodes.filter { $0.isOrphaned && !$0.isGhost }.count
    }

    private var healthDistribution: [HealthItem] {
        let nonGhosts = coordinator.nodes.filter { !$0.isGhost }
        guard !nonGhosts.isEmpty else { return [] }

        let counts: [(GraphNode.HealthLevel, String, Color)] = [
            (.healthy, "Healthy", .green),
            (.cooling, "Cooling", .yellow),
            (.atRisk, "At Risk", .orange),
            (.cold, "Cold", .red),
        ]

        return counts.compactMap { level, label, color in
            let count = nonGhosts.filter { $0.relationshipHealth == level }.count
            guard count > 0 else { return nil }
            return HealthItem(label: label, count: count, color: color)
        }
    }
}

// MARK: - Supporting Types

private struct HealthItem {
    let label: String
    let count: Int
    let color: Color
}

private struct NetworkMetricCard: View {

    let icon: String
    let value: String
    let label: String
    let accent: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accent)

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.3), lineWidth: 1)
        )
    }
}
