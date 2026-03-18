//
//  GraphLegendView.swift
//  SAM
//
//  Compact legend overlay for the relationship graph showing
//  edge types (color, line style) and node types.
//

import SwiftUI

struct GraphLegendView: View {

    let hasGhostNodes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legend")
                .samFont(.caption)
                .foregroundStyle(.primary)

            // MARK: - Connection Types

            VStack(alignment: .leading, spacing: 5) {
                Text("Connections")
                    .samFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                LegendEdgeRow(color: Color(red: 0.494, green: 0.341, blue: 0.761),
                              style: .solid, label: "Business Context")
                LegendEdgeRow(color: Color(red: 0.149, green: 0.651, blue: 0.604),
                              style: .solid, label: "Referral")
                LegendEdgeRow(color: Color(red: 0.259, green: 0.647, blue: 0.961),
                              style: .solid, label: "Recruiting Tree")
                LegendEdgeRow(color: Color(red: 0.553, green: 0.431, blue: 0.388),
                              style: .solid, label: "Communication")
                LegendEdgeRow(color: Color(red: 0.471, green: 0.565, blue: 0.612),
                              style: .dashed, label: "Co-Attendee")
                LegendEdgeRow(color: Color(red: 0.741, green: 0.741, blue: 0.741),
                              style: .dotted, label: "Mentioned Together")
                LegendEdgeRow(color: .pink,
                              style: .solid, label: "Family (confirmed)")
                LegendEdgeRow(color: .pink,
                              style: .dashed, label: "Family (unconfirmed)")
            }

            Divider()

            // MARK: - Node Types

            VStack(alignment: .leading, spacing: 5) {
                Text("Nodes")
                    .samFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                LegendNodeRow(health: .green, label: "Healthy")
                LegendNodeRow(health: .yellow, label: "Cooling")
                LegendNodeRow(health: .orange, label: "At Risk")
                LegendNodeRow(health: .red, label: "Cold")
                LegendNodeRow(health: .gray, label: "Unknown")
            }

            if hasGhostNodes {
                Divider()

                HStack(spacing: 6) {
                    // Marching ants ghost icon
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ghost Node")
                            .samFont(.caption2)
                        Text("Right-click to match to a contact")
                            .samFont(.caption2)
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 200, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

// MARK: - Legend Rows

private enum LegendLineStyle {
    case solid, dashed, dotted
}

private struct LegendEdgeRow: View {
    let color: Color
    let style: LegendLineStyle
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            // Line sample
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))

                let strokeStyle: StrokeStyle
                switch style {
                case .solid:
                    strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round)
                case .dashed:
                    strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 3])
                case .dotted:
                    strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 3])
                }
                context.stroke(path, with: .color(color), style: strokeStyle)
            }
            .frame(width: 24, height: 10)

            Text(label)
                .samFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LegendNodeRow: View {
    let health: Color
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 14, height: 14)
                Circle()
                    .strokeBorder(health, lineWidth: 2)
                    .frame(width: 14, height: 14)
            }
            Text(label)
                .samFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
