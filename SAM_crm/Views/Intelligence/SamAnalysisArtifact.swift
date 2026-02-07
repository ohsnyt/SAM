import Foundation
import SwiftData

public enum AnalysisSourceKind: String, Codable {
    case note, email, zoomTranscript, sms, other
}

public enum AnalysisAffect: String, Codable {
    case positive, neutral, negative
}

@Model
public final class SamAnalysisArtifact {
    public var id: UUID
    public var createdAt: Date
    public var sourceKindRawValue: String
    public var summary: String
    public var facts: [String]
    public var implications: [String]
    public var affectRawValue: String?

    // Relationships to sources (expand over time)
    @Relationship public var note: SamNote?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceKind: AnalysisSourceKind,
        summary: String,
        facts: [String],
        implications: [String],
        affect: AnalysisAffect?,
        note: SamNote? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceKindRawValue = sourceKind.rawValue
        self.summary = summary
        self.facts = facts
        self.implications = implications
        self.affectRawValue = affect?.rawValue
        self.note = note
    }

    public var sourceKind: AnalysisSourceKind {
        AnalysisSourceKind(rawValue: sourceKindRawValue) ?? .other
    }

    public var affect: AnalysisAffect? {
        affectRawValue.flatMap(AnalysisAffect.init(rawValue:))
    }
}

// NOTE: Ensure `SamAnalysisArtifact` is added to the app's ModelContainer schema.
