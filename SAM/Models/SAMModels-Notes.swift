//
//  SAMModels-Notes.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//
//  Note and analysis artifact models for Phase 5 features
//

import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Notes
// ─────────────────────────────────────────────────────────────────────

/// A freeform note created by the user (Phase 5)
@Model
public final class SamNote {
    @Attribute(.unique) public var id: UUID
    
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date
    
    /// People linked to this note
    @Relationship(deleteRule: .nullify)
    public var linkedPeople: [SamPerson] = []
    
    /// Contexts linked to this note
    @Relationship(deleteRule: .nullify)
    public var linkedContexts: [SamContext] = []
    
    /// Analysis artifact generated from this note (if any)
    @Relationship(deleteRule: .cascade)
    public var analysisArtifact: SamAnalysisArtifact?
    
    public init(
        id: UUID = UUID(),
        content: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Analysis Artifacts
// ─────────────────────────────────────────────────────────────────────

/// Structured data extracted from notes, emails, or transcripts via LLM analysis
@Model
public final class SamAnalysisArtifact {
    @Attribute(.unique) public var id: UUID
    
    public var sourceType: AnalysisSourceType
    public var analyzedAt: Date
    
    /// Extracted entities as JSON (Phase 5)
    public var peopleJSON: String?       // Array of detected person names with relationships
    public var topicsJSON: String?       // Array of financial topics with amounts
    public var factsJSON: String?        // Array of factual statements
    public var implicationsJSON: String? // Array of opportunities/risks/concerns
    
    /// Actions extracted
    public var actions: [String] = []
    
    /// Sentiment
    public var affect: String?           // "positive", "neutral", "negative"
    
    /// Whether LLM was used (vs heuristic)
    public var usedLLM: Bool = false
    
    /// Relationships
    public var note: SamNote?
    
    public init(
        id: UUID = UUID(),
        sourceType: AnalysisSourceType,
        analyzedAt: Date = .now,
        peopleJSON: String? = nil,
        topicsJSON: String? = nil,
        factsJSON: String? = nil,
        implicationsJSON: String? = nil,
        actions: [String] = [],
        affect: String? = nil,
        usedLLM: Bool = false
    ) {
        self.id = id
        self.sourceType = sourceType
        self.analyzedAt = analyzedAt
        self.peopleJSON = peopleJSON
        self.topicsJSON = topicsJSON
        self.factsJSON = factsJSON
        self.implicationsJSON = implicationsJSON
        self.actions = actions
        self.affect = affect
        self.usedLLM = usedLLM
    }
}

public enum AnalysisSourceType: String, Codable, Sendable {
    case note = "Note"
    case email = "Email"
    case transcript = "Transcript"
}
