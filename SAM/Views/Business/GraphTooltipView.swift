//
//  GraphTooltipView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA.3: Interaction & Navigation
//
//  Hover popover displaying person summary on graph node hover.
//

import SwiftUI

struct GraphTooltipView: View {

    let node: GraphNode
    let edgeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name + role badges
            HStack(spacing: 6) {
                Text(node.displayName)
                    .samFont(.headline)

                if node.isGhost {
                    Text("Ghost")
                        .samFont(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }

            if !node.roleBadges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(node.roleBadges, id: \.self) { badge in
                        let style = RoleBadgeStyle.forBadge(badge)
                        Label(badge, systemImage: style.icon)
                            .samFont(.caption2)
                            .foregroundStyle(style.color)
                    }
                }
            }

            Divider()

            if node.isGhost {
                // Ghost-specific info
                Text("Mentioned in notes — not yet in Contacts")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)

                Text("\(edgeCount) connection\(edgeCount == 1 ? "" : "s")")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)

                Text("Right-click to add or link to contact")
                    .samFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                // Health
                HStack(spacing: 4) {
                    Circle()
                        .fill(healthColor)
                        .frame(width: 8, height: 8)
                    Text(healthLabel)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                // Connections
                Text("\(edgeCount) connection\(edgeCount == 1 ? "" : "s")")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)

                // Top outcome
                if let outcome = node.topOutcome {
                    Divider()
                    Text(outcome)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 140, maxWidth: 220, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    // MARK: - Helpers

    private var healthColor: Color {
        switch node.relationshipHealth {
        case .healthy: return .green
        case .cooling:  return .yellow
        case .atRisk:   return .orange
        case .cold:     return .red
        case .unknown:  return .gray
        }
    }

    private var healthLabel: String {
        switch node.relationshipHealth {
        case .healthy: return "Healthy"
        case .cooling:  return "Cooling"
        case .atRisk:   return "At Risk"
        case .cold:     return "Cold"
        case .unknown:  return "Unknown"
        }
    }
}
