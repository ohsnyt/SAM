import Foundation
import SwiftData

public final class AnalysisRepository {
    public static let shared = AnalysisRepository()
    private init() {}
    private var container: ModelContainer { SAMModelContainer.shared }

    @MainActor
    public func saveNoteArtifact(artifact: NoteAnalysisArtifact, note: SamNote) throws -> SamAnalysisArtifact {
        let context = container.mainContext
        
        // Convert PersonEntity -> StoredPersonEntity
        let storedPeople = artifact.people.map { person in
            StoredPersonEntity(
                name: person.name,
                relationship: person.relationship,
                aliases: person.aliases,
                isNewPerson: person.isNewPerson
            )
        }
        
        // Convert FinancialTopicEntity -> StoredFinancialTopicEntity
        let storedTopics = artifact.topics.map { topic in
            StoredFinancialTopicEntity(
                productType: topic.productType,
                amount: topic.amount,
                beneficiary: topic.beneficiary,
                sentiment: topic.sentiment
            )
        }
        
        let model = SamAnalysisArtifact(
            sourceKind: .note,
            summary: artifact.summary,
            facts: artifact.facts,
            implications: artifact.implications,
            affect: artifact.affect.flatMap(AnalysisAffect.init(rawValue:)),
            people: storedPeople,
            topics: storedTopics,
            actions: artifact.actions,
            usedLLM: artifact.usedLLM,
            note: note
        )
        context.insert(model)
        try context.save()
        
        print("✅ [AnalysisRepository] Saved artifact with \(storedPeople.count) people, \(storedTopics.count) topics, usedLLM: \(artifact.usedLLM)")
        
        return model
    }
}
