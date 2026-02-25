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

/// A freeform note created by the user (Phase H, redesigned Phase L-2)
///
/// **Architecture**: Notes are SAM-native content that users create after
/// interactions. They link to people, contexts, and evidence. On-device LLM
/// analysis extracts structured data (people mentioned, topics, action items,
/// summary) which is stored directly on the note for quick access.
///
/// **Phase L-2**: Simplified to one note = one text block + metadata.
/// The multi-entry model was removed in favor of direct `content` editing.
@Model
public final class SamNote {
    @Attribute(.unique) public var id: UUID

    /// The note text (single text block)
    public var content: String

    /// LLM-generated 1-2 sentence summary suitable for display in lists
    public var summary: String?

    public var createdAt: Date
    public var updatedAt: Date

    // ── Source tracking ──────────────────────────────────────────────

    /// How this note was created: "typed" or "dictated"
    public var sourceTypeRawValue: String = "typed"

    @Transient
    public var sourceType: SourceType {
        get { SourceType(rawValue: sourceTypeRawValue) ?? .typed }
        set { sourceTypeRawValue = newValue.rawValue }
    }

    public enum SourceType: String, Codable, Sendable {
        case typed
        case dictated
    }

    /// Dedup key for imported notes (e.g., "evernote:<guid>")
    public var sourceImportUID: String?

    // ── Analysis state ──────────────────────────────────────────────

    /// Has LLM processed this note's current content?
    public var isAnalyzed: Bool = false

    /// Prompt version used for analysis (bump to trigger re-analysis)
    public var analysisVersion: Int = 0

    // ── Links (user-specified or LLM-confirmed) ────────────────────

    /// People linked to this note (either manually or via LLM extraction)
    @Relationship(deleteRule: .nullify)
    public var linkedPeople: [SamPerson] = []

    /// Contexts linked to this note
    @Relationship(deleteRule: .nullify)
    public var linkedContexts: [SamContext] = []

    /// Evidence items linked to this note (e.g., note attached to calendar event)
    @Relationship(deleteRule: .nullify)
    public var linkedEvidence: [SamEvidenceItem] = []

    // ── LLM extraction results (embedded value arrays) ─────────────

    /// People mentioned in note content (extracted by LLM)
    public var extractedMentions: [ExtractedPersonMention] = []

    /// Action items identified by LLM
    public var extractedActionItems: [NoteActionItem] = []

    /// Topics identified by LLM (strings like "life insurance", "retirement planning")
    public var extractedTopics: [String] = []

    /// Relationships between people discovered by LLM (e.g., spousal, referral)
    public var discoveredRelationships: [DiscoveredRelationship] = []

    /// Life events detected by LLM (e.g., new baby, job change, retirement)
    public var lifeEvents: [LifeEvent] = []

    // ── Follow-up draft ─────────────────────────────────────────────

    /// LLM-generated follow-up message draft for meeting-related notes.
    /// Set after analysis if the note is linked to a person with a recent calendar event.
    /// Nil when dismissed by the user or not applicable.
    public var followUpDraft: String?

    // ── Images ───────────────────────────────────────────────────────

    /// Images attached to this note (Evernote imports, pasted screenshots)
    @Relationship(deleteRule: .cascade, inverse: \NoteImage.note)
    public var images: [NoteImage] = []

    // ── Legacy analysis artifact (Phase 5) ─────────────────────────
    /// @deprecated Will migrate to extractedMentions/extractedActionItems above
    @Relationship(deleteRule: .cascade)
    public var analysisArtifact: SamAnalysisArtifact?

    public init(
        id: UUID = UUID(),
        content: String,
        summary: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isAnalyzed: Bool = false,
        analysisVersion: Int = 0,
        sourceType: SourceType = .typed,
        sourceImportUID: String? = nil
    ) {
        self.id = id
        self.content = content
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isAnalyzed = isAnalyzed
        self.analysisVersion = analysisVersion
        self.sourceTypeRawValue = sourceType.rawValue
        self.sourceImportUID = sourceImportUID
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
