//
//  NoteAnalysisDTO.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase H: Notes & Note Intelligence
//
//  Sendable data transfer object for LLM analysis results.
//  Crosses actor boundary from NoteAnalysisService → NoteAnalysisCoordinator.
//

import Foundation

/// Sendable wrapper for LLM-generated analysis of a note
public struct NoteAnalysisDTO: Sendable {
    
    /// 1-2 sentence summary suitable for display
    public let summary: String?
    
    /// People mentioned in the note
    public let people: [PersonMentionDTO]
    
    /// Financial/life topics discussed
    public let topics: [String]
    
    /// Actionable items extracted
    public let actionItems: [ActionItemDTO]

    /// Relationships discovered between people mentioned in the note
    public let discoveredRelationships: [DiscoveredRelationshipDTO]

    /// Timestamp of analysis
    public let analyzedAt: Date

    /// Analysis version (prompt version)
    public let analysisVersion: Int

    public init(
        summary: String?,
        people: [PersonMentionDTO],
        topics: [String],
        actionItems: [ActionItemDTO],
        discoveredRelationships: [DiscoveredRelationshipDTO] = [],
        analyzedAt: Date = .now,
        analysisVersion: Int
    ) {
        self.summary = summary
        self.people = people
        self.topics = topics
        self.actionItems = actionItems
        self.discoveredRelationships = discoveredRelationships
        self.analyzedAt = analyzedAt
        self.analysisVersion = analysisVersion
    }
}

/// Sendable representation of an extracted person mention
public struct PersonMentionDTO: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let role: String?
    public let relationshipTo: String?
    public let contactUpdates: [ContactUpdateDTO]
    public let confidence: Double
    
    public init(
        id: UUID = UUID(),
        name: String,
        role: String?,
        relationshipTo: String?,
        contactUpdates: [ContactUpdateDTO],
        confidence: Double
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.relationshipTo = relationshipTo
        self.contactUpdates = contactUpdates
        self.confidence = confidence
    }
}

/// Sendable representation of a contact field update suggestion
public struct ContactUpdateDTO: Sendable {
    public let field: String  // "birthday", "spouse", "company", etc.
    public let value: String
    public let confidence: Double
    
    public init(field: String, value: String, confidence: Double) {
        self.field = field
        self.value = value
        self.confidence = confidence
    }
}

/// Sendable representation of a discovered relationship between people
public struct DiscoveredRelationshipDTO: Sendable, Identifiable {
    public let id: UUID
    public let personName: String
    public let relationshipType: String  // "spouse_of", "parent_of", etc.
    public let relatedTo: String
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        personName: String,
        relationshipType: String,
        relatedTo: String,
        confidence: Double
    ) {
        self.id = id
        self.personName = personName
        self.relationshipType = relationshipType
        self.relatedTo = relatedTo
        self.confidence = confidence
    }
}

/// Sendable representation of an action item
public struct ActionItemDTO: Sendable, Identifiable {
    public let id: UUID
    public let type: String  // "update_contact", "send_congratulations", etc.
    public let description: String
    public let suggestedText: String?
    public let suggestedChannel: String?  // "sms", "email", "phone"
    public let urgency: String  // "immediate", "soon", "standard", "low"
    public let personName: String?
    
    public init(
        id: UUID = UUID(),
        type: String,
        description: String,
        suggestedText: String?,
        suggestedChannel: String?,
        urgency: String,
        personName: String?
    ) {
        self.id = id
        self.type = type
        self.description = description
        self.suggestedText = suggestedText
        self.suggestedChannel = suggestedChannel
        self.urgency = urgency
        self.personName = personName
    }
}
