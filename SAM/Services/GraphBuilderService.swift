//
//  GraphBuilderService.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA: Relationship Graph — Visual Network Intelligence
//
//  Actor-isolated service that builds graph nodes/edges from raw data
//  and runs the force-directed layout algorithm. All computation happens
//  off the main thread; returns Sendable DTOs.
//

import Foundation
import CoreGraphics
import os

actor GraphBuilderService {

    static let shared = GraphBuilderService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GraphBuilderService")

    // MARK: - Build Graph

    /// Assemble GraphNode + GraphEdge arrays from raw input DTOs.
    func buildGraph(
        people: [PersonGraphInput],
        contexts: [ContextGraphInput],
        referralChains: [ReferralLink],
        recruitingTree: [RecruitLink],
        coAttendanceMap: [CoAttendancePair],
        communicationMap: [CommLink],
        noteMentions: [MentionPair],
        ghostMentions: [GhostMention],
        deducedFamilyLinks: [DeducedFamilyLink] = []
    ) -> (nodes: [GraphNode], edges: [GraphEdge]) {

        let personIDs = Set(people.map(\.id))
        var edges: [GraphEdge] = []

        // --- Context edges (business only) ---
        for ctx in contexts {
            let type: EdgeType
            switch ctx.contextType {
            case "Business":  type = .business
            default: continue
            }
            let participants = ctx.participantIDs.filter { personIDs.contains($0) }
            for i in 0..<participants.count {
                for j in (i + 1)..<participants.count {
                    edges.append(GraphEdge(
                        id: UUID(),
                        sourceID: participants[i],
                        targetID: participants[j],
                        edgeType: type,
                        weight: 0.8,
                        label: ctx.contextType.lowercased(),
                        isReciprocal: true,
                        communicationDirection: nil
                    ))
                }
            }
        }

        // --- Referral edges ---
        for link in referralChains where personIDs.contains(link.referrerID) && personIDs.contains(link.referredID) {
            edges.append(GraphEdge(
                id: UUID(),
                sourceID: link.referrerID,
                targetID: link.referredID,
                edgeType: .referral,
                weight: 0.7,
                label: "referred",
                isReciprocal: false,
                communicationDirection: nil
            ))
        }

        // --- Recruiting tree edges ---
        for link in recruitingTree where personIDs.contains(link.recruiterID) && personIDs.contains(link.recruitID) {
            edges.append(GraphEdge(
                id: UUID(),
                sourceID: link.recruiterID,
                targetID: link.recruitID,
                edgeType: .recruitingTree,
                weight: 0.6,
                label: link.stage,
                isReciprocal: false,
                communicationDirection: nil
            ))
        }

        // --- Co-attendance edges ---
        for pair in coAttendanceMap where personIDs.contains(pair.personA) && personIDs.contains(pair.personB) {
            let w = min(1.0, Double(pair.meetingCount) / 10.0)
            edges.append(GraphEdge(
                id: UUID(),
                sourceID: pair.personA,
                targetID: pair.personB,
                edgeType: .coAttendee,
                weight: w,
                label: pair.meetingCount == 1 ? "1 meeting" : "\(pair.meetingCount) meetings",
                isReciprocal: true,
                communicationDirection: nil
            ))
        }

        // --- Communication link edges ---
        for link in communicationMap where personIDs.contains(link.personA) && personIDs.contains(link.personB) {
            let w = min(1.0, Double(link.evidenceCount) / 20.0)
            edges.append(GraphEdge(
                id: UUID(),
                sourceID: link.personA,
                targetID: link.personB,
                edgeType: .communicationLink,
                weight: w,
                label: nil,
                isReciprocal: link.dominantDirection == .balanced,
                communicationDirection: link.dominantDirection
            ))
        }

        // --- Note mention edges ---
        for pair in noteMentions where personIDs.contains(pair.personA) && personIDs.contains(pair.personB) {
            let w = min(1.0, Double(pair.coMentionCount) / 5.0)
            edges.append(GraphEdge(
                id: UUID(),
                sourceID: pair.personA,
                targetID: pair.personB,
                edgeType: .mentionedTogether,
                weight: w,
                label: nil,
                isReciprocal: true,
                communicationDirection: nil
            ))
        }

        // --- Deduced family edges ---
        for link in deducedFamilyLinks where personIDs.contains(link.personAID) && personIDs.contains(link.personBID) {
            edges.append(GraphEdge(
                id: UUID(),
                sourceID: link.personAID,
                targetID: link.personBID,
                edgeType: .deducedFamily,
                weight: 0.7,
                label: link.label,
                isReciprocal: true,
                communicationDirection: nil,
                deducedRelationID: link.deducedRelationID,
                isConfirmedDeduction: link.isConfirmed
            ))
        }

        // --- Identify connected person IDs ---
        var connectedIDs = Set<UUID>()
        for edge in edges {
            connectedIDs.insert(edge.sourceID)
            connectedIDs.insert(edge.targetID)
        }

        // --- Build nodes for real people ---
        var nodes: [GraphNode] = people.map { p in
            let primary = GraphNode.primaryRole(from: p.roleBadges)
            return GraphNode(
                id: p.id,
                displayName: p.displayName,
                roleBadges: p.roleBadges,
                primaryRole: primary,
                pipelineStage: p.pipelineStage,
                relationshipHealth: p.relationshipHealth,
                productionValue: p.productionValue,
                isGhost: false,
                isOrphaned: !connectedIDs.contains(p.id),
                topOutcome: p.topOutcomeText,
                photoThumbnail: p.photoThumbnail,
                position: .zero
            )
        }

        // --- Ghost nodes (mentioned but not contacts) ---
        for ghost in ghostMentions {
            let ghostID = UUID()
            let ghostNode = GraphNode(
                id: ghostID,
                displayName: ghost.mentionedName,
                roleBadges: ghost.suggestedRole.map { [$0] } ?? [],
                primaryRole: ghost.suggestedRole,
                pipelineStage: nil,
                relationshipHealth: .unknown,
                productionValue: 0,
                isGhost: true,
                isOrphaned: ghost.mentionedByIDs.isEmpty,
                topOutcome: nil,
                photoThumbnail: nil,
                position: .zero
            )
            nodes.append(ghostNode)

            // Add mention edges from ghost to people who mentioned them
            for mentionerID in ghost.mentionedByIDs where personIDs.contains(mentionerID) {
                edges.append(GraphEdge(
                    id: UUID(),
                    sourceID: mentionerID,
                    targetID: ghostID,
                    edgeType: .mentionedTogether,
                    weight: 0.3,
                    label: "mentioned",
                    isReciprocal: false,
                    communicationDirection: nil
                ))
            }
        }

        logger.info("Built graph: \(nodes.count) nodes, \(edges.count) edges")
        return (nodes, edges)
    }

    // MARK: - Layout Algorithm

    /// Run force-directed layout simulation.
    /// Returns updated node positions after N iterations.
    func layoutGraph(
        nodes: [GraphNode],
        edges: [GraphEdge],
        iterations: Int = 300,
        bounds: CGSize,
        contextClusters: [ContextGraphInput] = []
    ) async -> [GraphNode] {
        guard !nodes.isEmpty else { return nodes }

        var mutableNodes = nodes
        let nodeIndex = Dictionary(uniqueKeysWithValues: mutableNodes.enumerated().map { ($1.id, $0) })
        let useBarnesHut = mutableNodes.count > 500

        // --- Initial positioning (deterministic, not random) ---
        assignInitialPositions(&mutableNodes, nodeIndex: nodeIndex, contextClusters: contextClusters, bounds: bounds)

        // --- Build adjacency for attraction ---
        let adjacency = buildAdjacency(edges: edges, nodeIndex: nodeIndex)

        // --- Force simulation parameters ---
        let repulsionStrength: CGFloat = 5000.0
        let attractionStrength: CGFloat = 0.01
        let gravityStrength: CGFloat = 0.02
        let dampingFactor: CGFloat = 0.75
        let minNodeSpacing: CGFloat = 40.0
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)

        for iteration in 0..<iterations {
            // Respect cancellation so callers can abort a stale layout
            guard !Task.isCancelled else {
                logger.info("Layout cancelled at iteration \(iteration)/\(iterations)")
                break
            }

            // Temperature decreases over time (simulated annealing)
            let temperature = max(0.01, 1.0 - CGFloat(iteration) / CGFloat(iterations))

            // --- Repulsion (all pairs) ---
            if useBarnesHut {
                applyBarnesHutRepulsion(&mutableNodes, strength: repulsionStrength * temperature)
            } else {
                applyDirectRepulsion(&mutableNodes, strength: repulsionStrength * temperature)
            }

            // --- Attraction (connected nodes) ---
            applyAttraction(&mutableNodes, adjacency: adjacency, strength: attractionStrength)

            // --- Gravity (toward center) ---
            applyGravity(&mutableNodes, center: center, strength: gravityStrength)

            // --- Collision prevention ---
            resolveCollisions(&mutableNodes, minSpacing: minNodeSpacing)

            // --- Apply velocity with temperature-scaled damping ---
            // As temperature drops, damp more aggressively so the layout settles.
            // At temp 1.0: effectiveDamping ≈ dampingFactor (full exploration).
            // At temp 0.01: effectiveDamping ≈ 0 (rapid settling).
            let effectiveDamping = dampingFactor * temperature
            for i in mutableNodes.indices where !mutableNodes[i].isPinned {
                mutableNodes[i].velocity.x *= effectiveDamping
                mutableNodes[i].velocity.y *= effectiveDamping
                mutableNodes[i].position.x += mutableNodes[i].velocity.x * temperature
                mutableNodes[i].position.y += mutableNodes[i].velocity.y * temperature
            }

            // Yield every 50 iterations
            if iteration > 0 && iteration.isMultiple(of: 50) {
                await Task.yield()
            }
        }

        logger.info("Layout complete: \(mutableNodes.count) nodes, \(iterations) iterations")
        return mutableNodes
    }

    // MARK: - Initial Positioning

    private func assignInitialPositions(
        _ nodes: inout [GraphNode],
        nodeIndex: [UUID: Int],
        contextClusters: [ContextGraphInput],
        bounds: CGSize
    ) {
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        let radius = min(bounds.width, bounds.height) * 0.35

        // Assign context cluster members to cluster positions
        var assigned = Set<UUID>()
        let clusterCount = max(1, contextClusters.count)

        for (ci, ctx) in contextClusters.enumerated() {
            let angle = (2.0 * .pi * Double(ci)) / Double(clusterCount)
            let clusterCenter = CGPoint(
                x: center.x + radius * 0.6 * cos(angle),
                y: center.y + radius * 0.6 * sin(angle)
            )

            for (pi, pid) in ctx.participantIDs.enumerated() {
                guard let idx = nodeIndex[pid], !assigned.contains(pid) else { continue }
                let memberAngle = (2.0 * .pi * Double(pi)) / max(1.0, Double(ctx.participantIDs.count))
                let spread: CGFloat = 30.0 + CGFloat(ctx.participantIDs.count) * 5.0
                nodes[idx].position = CGPoint(
                    x: clusterCenter.x + spread * cos(memberAngle),
                    y: clusterCenter.y + spread * sin(memberAngle)
                )
                assigned.insert(pid)
            }
        }

        // Assign unassigned nodes in a spiral pattern around center
        var unassignedCount = 0
        for i in nodes.indices where !assigned.contains(nodes[i].id) {
            let angle = Double(unassignedCount) * 0.618033988749895 * 2.0 * .pi // Golden angle
            let r = radius * 0.3 + CGFloat(unassignedCount) * 8.0
            nodes[i].position = CGPoint(
                x: center.x + r * cos(angle),
                y: center.y + r * sin(angle)
            )
            unassignedCount += 1
        }
    }

    // MARK: - Adjacency

    private struct AdjacencyEntry: Sendable {
        let neighborIndex: Int
        let weight: Double
    }

    private func buildAdjacency(edges: [GraphEdge], nodeIndex: [UUID: Int]) -> [[AdjacencyEntry]] {
        var adj = [[AdjacencyEntry]](repeating: [], count: nodeIndex.count)
        for edge in edges {
            guard let si = nodeIndex[edge.sourceID], let ti = nodeIndex[edge.targetID] else { continue }
            adj[si].append(AdjacencyEntry(neighborIndex: ti, weight: edge.weight))
            adj[ti].append(AdjacencyEntry(neighborIndex: si, weight: edge.weight))
        }
        return adj
    }

    // MARK: - Force: Direct Repulsion O(n²)

    private func applyDirectRepulsion(_ nodes: inout [GraphNode], strength: CGFloat) {
        let count = nodes.count
        for i in 0..<count {
            guard !nodes[i].isPinned else { continue }
            for j in (i + 1)..<count {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let distSq = max(1.0, dx * dx + dy * dy)
                let force = strength / distSq
                let fx = force * dx / sqrt(distSq)
                let fy = force * dy / sqrt(distSq)

                if !nodes[i].isPinned {
                    nodes[i].velocity.x += fx
                    nodes[i].velocity.y += fy
                }
                if !nodes[j].isPinned {
                    nodes[j].velocity.x -= fx
                    nodes[j].velocity.y -= fy
                }
            }
        }
    }

    // MARK: - Force: Barnes-Hut Repulsion O(n log n)

    private func applyBarnesHutRepulsion(_ nodes: inout [GraphNode], strength: CGFloat) {
        let tree = QuadTree(nodes: nodes)
        for i in nodes.indices where !nodes[i].isPinned {
            let force = tree.computeRepulsion(for: nodes[i].position, excludeIndex: i, strength: strength)
            nodes[i].velocity.x += force.x
            nodes[i].velocity.y += force.y
        }
    }

    // MARK: - Force: Attraction (Hooke's law)

    private func applyAttraction(_ nodes: inout [GraphNode], adjacency: [[AdjacencyEntry]], strength: CGFloat) {
        // Adjacency is bidirectional (each edge listed for both endpoints),
        // so only apply force to node i here — node j gets its turn when
        // j is the outer loop index. This avoids double-counting.
        for i in nodes.indices where !nodes[i].isPinned {
            for entry in adjacency[i] {
                let j = entry.neighborIndex
                let dx = nodes[j].position.x - nodes[i].position.x
                let dy = nodes[j].position.y - nodes[i].position.y
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > 1.0 else { continue }

                let force = strength * CGFloat(entry.weight) * dist
                nodes[i].velocity.x += force * dx / dist
                nodes[i].velocity.y += force * dy / dist
            }
        }
    }

    // MARK: - Force: Gravity

    private func applyGravity(_ nodes: inout [GraphNode], center: CGPoint, strength: CGFloat) {
        for i in nodes.indices where !nodes[i].isPinned {
            let dx = center.x - nodes[i].position.x
            let dy = center.y - nodes[i].position.y
            nodes[i].velocity.x += dx * strength
            nodes[i].velocity.y += dy * strength
        }
    }

    // MARK: - Collision Resolution

    private func resolveCollisions(_ nodes: inout [GraphNode], minSpacing: CGFloat) {
        let count = nodes.count
        let minDistSq = minSpacing * minSpacing
        for i in 0..<count {
            for j in (i + 1)..<count {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let distSq = dx * dx + dy * dy
                guard distSq < minDistSq && distSq > 0.001 else { continue }

                let dist = sqrt(distSq)
                let overlap = (minSpacing - dist) / 2.0
                let nx = dx / dist
                let ny = dy / dist

                if !nodes[i].isPinned {
                    nodes[i].position.x += nx * overlap
                    nodes[i].position.y += ny * overlap
                }
                if !nodes[j].isPinned {
                    nodes[j].position.x -= nx * overlap
                    nodes[j].position.y -= ny * overlap
                }
            }
        }
    }
}

// MARK: - QuadTree (Barnes-Hut)

/// Spatial partitioning structure for O(n log n) repulsion.
private final class QuadTree: @unchecked Sendable {
    private let root: QuadNode
    private let theta: CGFloat = 0.8   // Accuracy threshold (lower = more accurate)

    init(nodes: [GraphNode]) {
        // Compute bounding box
        var minX: CGFloat = .infinity, minY: CGFloat = .infinity
        var maxX: CGFloat = -.infinity, maxY: CGFloat = -.infinity
        for node in nodes {
            minX = min(minX, node.position.x)
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x)
            maxY = max(maxY, node.position.y)
        }
        let padding: CGFloat = 10.0
        let bounds = CGRect(
            x: minX - padding, y: minY - padding,
            width: max(1, maxX - minX + 2 * padding),
            height: max(1, maxY - minY + 2 * padding)
        )

        root = QuadNode(bounds: bounds)
        for (index, node) in nodes.enumerated() {
            root.insert(position: node.position, index: index)
        }
    }

    func computeRepulsion(for position: CGPoint, excludeIndex: Int, strength: CGFloat) -> CGPoint {
        var force = CGPoint.zero
        root.computeForce(on: position, excludeIndex: excludeIndex, theta: theta, strength: strength, force: &force)
        return force
    }
}

private final class QuadNode: @unchecked Sendable {
    let bounds: CGRect
    let depth: Int
    var centerOfMass: CGPoint = .zero
    var totalMass: CGFloat = 0
    var bodyIndex: Int? = nil
    var bodyPosition: CGPoint? = nil
    var children: [QuadNode?] = [nil, nil, nil, nil]
    var isLeaf: Bool = true

    /// Max subdivision depth — prevents infinite recursion for coincident points.
    static let maxDepth = 40

    init(bounds: CGRect, depth: Int = 0) {
        self.bounds = bounds
        self.depth = depth
    }

    func insert(position: CGPoint, index: Int) {
        guard bounds.contains(position) else { return }

        if totalMass == 0 {
            // Empty node — place body here
            bodyIndex = index
            bodyPosition = position
            centerOfMass = position
            totalMass = 1
            return
        }

        // At max depth, coalesce coincident or near-coincident points
        // instead of subdividing further (prevents stack overflow).
        if depth >= Self.maxDepth {
            let newMass = totalMass + 1
            centerOfMass = CGPoint(
                x: (centerOfMass.x * totalMass + position.x) / newMass,
                y: (centerOfMass.y * totalMass + position.y) / newMass
            )
            totalMass = newMass
            return
        }

        if isLeaf {
            // Subdivide and redistribute existing body
            isLeaf = false
            if let existingPos = bodyPosition, let existingIdx = bodyIndex {
                bodyPosition = nil
                bodyIndex = nil
                insertIntoChild(position: existingPos, index: existingIdx)
            }
        }

        // Insert new body into appropriate child
        insertIntoChild(position: position, index: index)

        // Update center of mass
        let newMass = totalMass + 1
        centerOfMass = CGPoint(
            x: (centerOfMass.x * totalMass + position.x) / newMass,
            y: (centerOfMass.y * totalMass + position.y) / newMass
        )
        totalMass = newMass
    }

    private func insertIntoChild(position: CGPoint, index: Int) {
        let midX = bounds.midX
        let midY = bounds.midY
        let quadrant: Int
        if position.x <= midX {
            quadrant = position.y <= midY ? 0 : 2
        } else {
            quadrant = position.y <= midY ? 1 : 3
        }

        if children[quadrant] == nil {
            let childBounds: CGRect
            switch quadrant {
            case 0: childBounds = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height / 2)
            case 1: childBounds = CGRect(x: midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height / 2)
            case 2: childBounds = CGRect(x: bounds.minX, y: midY, width: bounds.width / 2, height: bounds.height / 2)
            default: childBounds = CGRect(x: midX, y: midY, width: bounds.width / 2, height: bounds.height / 2)
            }
            children[quadrant] = QuadNode(bounds: childBounds, depth: depth + 1)
        }
        children[quadrant]?.insert(position: position, index: index)
    }

    func computeForce(on position: CGPoint, excludeIndex: Int, theta: CGFloat, strength: CGFloat, force: inout CGPoint) {
        guard totalMass > 0 else { return }

        if isLeaf {
            guard bodyIndex != excludeIndex, let bp = bodyPosition else { return }
            let dx = position.x - bp.x
            let dy = position.y - bp.y
            let distSq = max(1.0, dx * dx + dy * dy)
            let f = strength / distSq
            let dist = sqrt(distSq)
            force.x += f * dx / dist
            force.y += f * dy / dist
            return
        }

        // Check if this node is far enough to approximate
        let dx = position.x - centerOfMass.x
        let dy = position.y - centerOfMass.y
        let distSq = max(1.0, dx * dx + dy * dy)
        let size = max(bounds.width, bounds.height)

        if size * size / distSq < theta * theta {
            // Far enough — treat as single body
            let f = strength * totalMass / distSq
            let dist = sqrt(distSq)
            force.x += f * dx / dist
            force.y += f * dy / dist
        } else {
            // Too close — recurse into children
            for child in children {
                child?.computeForce(on: position, excludeIndex: excludeIndex, theta: theta, strength: strength, force: &force)
            }
        }
    }
}
