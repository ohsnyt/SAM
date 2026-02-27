//
//  GraphMiniPreviewView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA.4: Graph Renderer (View Layer)
//
//  Non-interactive thumbnail preview of the relationship graph
//  for embedding in the Business Dashboard.
//

import SwiftUI

struct GraphMiniPreviewView: View {

    @State private var coordinator = RelationshipGraphCoordinator.shared
    @AppStorage("sam.sidebar.selection") private var sidebarSelection: String = "awareness"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Relationship Map", systemImage: "circle.grid.cross")
                    .font(.headline)
                Spacer()
                if coordinator.graphStatus == .ready {
                    Text("\(coordinator.nodes.count) people")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            miniCanvas
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture {
                    sidebarSelection = "graph"
                }

            if coordinator.graphStatus != .ready {
                statusLabel
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            if coordinator.graphStatus == .idle {
                await coordinator.buildGraph()
            }
        }
    }

    // MARK: - Mini Canvas

    @ViewBuilder
    private var miniCanvas: some View {
        if coordinator.graphStatus == .ready, !coordinator.nodes.isEmpty {
            Canvas { context, size in
                let bounds = nodeBounds()
                guard bounds.width > 0, bounds.height > 0 else { return }

                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let graphCenter = CGPoint(
                    x: (bounds.minX + bounds.maxX) / 2,
                    y: (bounds.minY + bounds.maxY) / 2
                )

                let padding: CGFloat = 0.85
                let scaleX = size.width / bounds.width * padding
                let scaleY = size.height / bounds.height * padding
                let scale = min(scaleX, scaleY)

                func screenPt(_ gp: CGPoint) -> CGPoint {
                    CGPoint(
                        x: (gp.x - graphCenter.x) * scale + center.x,
                        y: (gp.y - graphCenter.y) * scale + center.y
                    )
                }

                // Draw edges
                let nodeMap = Dictionary(uniqueKeysWithValues: coordinator.nodes.map { ($0.id, $0) })
                for edge in coordinator.edges {
                    guard let source = nodeMap[edge.sourceID],
                          let target = nodeMap[edge.targetID] else { continue }
                    var path = Path()
                    path.move(to: screenPt(source.position))
                    path.addLine(to: screenPt(target.position))
                    context.stroke(path, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                }

                // Draw nodes
                for node in coordinator.nodes {
                    let sp = screenPt(node.position)
                    let radius = max(2, miniNodeRadius(for: node) * scale)
                    let rect = CGRect(x: sp.x - radius, y: sp.y - radius, width: radius * 2, height: radius * 2)
                    let color = nodeColor(for: node)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        } else {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch coordinator.graphStatus {
        case .computing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Building graph…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Text("Graph unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .idle:
            Text("Graph not loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func nodeBounds() -> CGRect {
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for node in coordinator.nodes {
            minX = min(minX, node.position.x)
            maxX = max(maxX, node.position.x)
            minY = min(minY, node.position.y)
            maxY = max(maxY, node.position.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func miniNodeRadius(for node: GraphNode) -> CGFloat {
        let base: CGFloat = 3
        let maxR: CGFloat = 8
        let normalized = min(1.0, CGFloat(node.productionValue) / 10_000)
        return base + (maxR - base) * normalized
    }

    private func nodeColor(for node: GraphNode) -> Color {
        if node.isGhost { return .gray.opacity(0.4) }
        guard let role = node.primaryRole else { return .gray.opacity(0.6) }
        return RoleBadgeStyle.forBadge(role).color
    }
}
