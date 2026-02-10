import Foundation
import SwiftData

public enum AnalysisSourceKind: String, Codable {
    case note, email, zoomTranscript, sms, other
}

public enum AnalysisAffect: String, Codable {
    case positive, neutral, negative
}

// Codable structs for storing LLM-extracted structured data
public struct StoredPersonEntity: Codable {
    public let name: String
    public let relationship: String?
    public let aliases: [String]
    public let isNewPerson: Bool
    
    public init(name: String, relationship: String?, aliases: [String] = [], isNewPerson: Bool = false) {
        self.name = name
        self.relationship = relationship
        self.aliases = aliases
        self.isNewPerson = isNewPerson
    }
}

public struct StoredFinancialTopicEntity: Codable {
    public let productType: String
    public let amount: String?
    public let beneficiary: String?
    public let sentiment: String?
    
    public init(productType: String, amount: String?, beneficiary: String?, sentiment: String? = nil) {
        self.productType = productType
        self.amount = amount
        self.beneficiary = beneficiary
        self.sentiment = sentiment
    }
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
    
    // LLM-extracted structured data (JSON-encoded)
    public var peopleJSON: Data?
    public var topicsJSON: Data?
    public var actions: [String]
    public var usedLLM: Bool

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
        people: [StoredPersonEntity] = [],
        topics: [StoredFinancialTopicEntity] = [],
        actions: [String] = [],
        usedLLM: Bool = false,
        note: SamNote? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceKindRawValue = sourceKind.rawValue
        self.summary = summary
        self.facts = facts
        self.implications = implications
        self.affectRawValue = affect?.rawValue
        
        // Encode structured data as JSON
        self.peopleJSON = try? JSONEncoder().encode(people)
        self.topicsJSON = try? JSONEncoder().encode(topics)
        self.actions = actions
        self.usedLLM = usedLLM
        
        self.note = note
    }

    public var sourceKind: AnalysisSourceKind {
        AnalysisSourceKind(rawValue: sourceKindRawValue) ?? .other
    }

    public var affect: AnalysisAffect? {
        affectRawValue.flatMap(AnalysisAffect.init(rawValue:))
    }
    
    // Computed properties to decode structured data
    @Transient public var people: [StoredPersonEntity] {
        guard let data = peopleJSON else { return [] }
        return (try? JSONDecoder().decode([StoredPersonEntity].self, from: data)) ?? []
    }
    
    @Transient public var topics: [StoredFinancialTopicEntity] {
        guard let data = topicsJSON else { return [] }
        return (try? JSONDecoder().decode([StoredFinancialTopicEntity].self, from: data)) ?? []
    }
}

// NOTE: Ensure `SamAnalysisArtifact` is added to the app's ModelContainer schema.
