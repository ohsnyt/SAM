//
//  GraphInputDTOs.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase AA: Relationship Graph — Visual Network Intelligence
//
//  Sendable input DTOs assembled by the coordinator from repositories,
//  passed to GraphBuilderService for graph construction.
//

import Foundation

struct PersonGraphInput: Sendable {
    let id: UUID
    let displayName: String
    let roleBadges: [String]
    let relationshipHealth: GraphNode.HealthLevel
    let productionValue: Double
    let photoThumbnail: Data?
    let topOutcomeText: String?
    let pipelineStage: String?
}

struct ContextGraphInput: Sendable {
    let contextID: UUID
    let contextType: String             // "Household", "Business"
    let participantIDs: [UUID]          // SamPerson IDs
}

struct ReferralLink: Sendable {
    let referrerID: UUID
    let referredID: UUID
}

struct RecruitLink: Sendable {
    let recruiterID: UUID
    let recruitID: UUID
    let stage: String                   // RecruitingStageKind raw value
}

struct CoAttendancePair: Sendable {
    let personA: UUID
    let personB: UUID
    let meetingCount: Int               // Number of shared calendar events
}

struct CommLink: Sendable {
    let personA: UUID
    let personB: UUID
    let evidenceCount: Int
    let lastContactDate: Date
    let dominantDirection: GraphEdge.Direction
}

struct MentionPair: Sendable {
    let personA: UUID
    let personB: UUID
    let coMentionCount: Int
}

struct GhostMention: Sendable {
    let mentionedName: String           // From ExtractedPersonMention
    let mentionedByIDs: [UUID]          // People whose notes mention this name
    let suggestedRole: String?
}

struct DeducedFamilyLink: Sendable {
    let personAID: UUID
    let personBID: UUID
    let relationType: String            // DeducedRelationType raw value
    let label: String                   // e.g., "spouse", "daughter"
    let isConfirmed: Bool
    let deducedRelationID: UUID         // For confirmation callback
}

struct RoleRelationshipLink: Sendable {
    let meID: UUID                      // "Me" person ID
    let personID: UUID                  // Target contact ID
    let role: String                    // "Client", "Agent", "Lead", etc.
    let healthLevel: GraphNode.HealthLevel
}
