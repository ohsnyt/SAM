//
//  GraphEdge.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA: Relationship Graph — Visual Network Intelligence
//
//  Sendable DTO representing a connection between two nodes in the graph.
//

import Foundation

struct GraphEdge: Identifiable, Sendable {
    let id: UUID
    let sourceID: UUID                      // GraphNode.id
    let targetID: UUID                      // GraphNode.id
    let edgeType: EdgeType
    let weight: Double                      // 0.0–1.0, controls thickness
    let label: String?                      // Optional label ("referred", "spouse", etc.)
    let isReciprocal: Bool                  // Both directions have communication
    let communicationDirection: Direction?   // Who initiates more
    let deducedRelationID: UUID?            // DeducedRelation.id for confirmation callbacks
    let isConfirmedDeduction: Bool          // Whether a deduced edge has been user-confirmed

    enum Direction: String, Sendable {
        case outbound       // User → contact
        case inbound        // Contact → user
        case balanced
    }

    init(
        id: UUID = UUID(),
        sourceID: UUID,
        targetID: UUID,
        edgeType: EdgeType,
        weight: Double,
        label: String?,
        isReciprocal: Bool,
        communicationDirection: Direction?,
        deducedRelationID: UUID? = nil,
        isConfirmedDeduction: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.edgeType = edgeType
        self.weight = weight
        self.label = label
        self.isReciprocal = isReciprocal
        self.communicationDirection = communicationDirection
        self.deducedRelationID = deducedRelationID
        self.isConfirmedDeduction = isConfirmedDeduction
    }
}

enum EdgeType: String, CaseIterable, Sendable {
    case business           // Share a SamContext of type Business
    case referral           // referredBy / referrals relationship
    case recruitingTree     // Agent recruited by user or by user's agents
    case coAttendee         // Attended same calendar event(s)
    case communicationLink  // Direct message/email/call evidence between two contacts
    case mentionedTogether  // Co-mentioned in notes
    case deducedFamily      // Deduced family relationship from Apple Contacts
    case roleRelationship   // Direct role-based relationship between "Me" and a contact
}
