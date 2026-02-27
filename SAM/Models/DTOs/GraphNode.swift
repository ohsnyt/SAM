//
//  GraphNode.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA: Relationship Graph — Visual Network Intelligence
//
//  Sendable DTO representing a person node in the relationship graph.
//

import Foundation
import CoreGraphics

struct GraphNode: Identifiable, Sendable {
    let id: UUID                            // SamPerson.id
    let displayName: String
    let roleBadges: [String]
    let primaryRole: String?                // Highest-priority role for coloring
    let pipelineStage: String?              // Current stage in client or recruiting funnel
    let relationshipHealth: HealthLevel
    let productionValue: Double             // Total premium (for node sizing)
    let isGhost: Bool                       // Mentioned in notes but not a contact
    let isOrphaned: Bool                    // No edges to other nodes
    let topOutcome: String?                 // Highest-priority coaching suggestion (tooltip)
    let photoThumbnail: Data?

    // Layout — mutable during simulation
    var position: CGPoint
    var velocity: CGPoint = .zero
    var isPinned: Bool = false              // User-repositioned, exclude from simulation

    enum HealthLevel: String, Sendable, CaseIterable {
        case healthy, cooling, atRisk, cold, unknown
    }
}

// MARK: - Role Priority

extension GraphNode {
    /// Role priority for determining primary display role (lower = higher priority).
    static let rolePriority: [String: Int] = [
        "Client": 0,
        "Applicant": 1,
        "Agent": 2,
        "Lead": 3,
        "External Agent": 4,
        "Referral Partner": 5,
        "Vendor": 6,
        "Prospect": 7,
    ]

    /// Returns the highest-priority role from a list of badges.
    nonisolated static func primaryRole(from badges: [String]) -> String? {
        badges.min { (rolePriority[$0] ?? 99) < (rolePriority[$1] ?? 99) }
    }
}
