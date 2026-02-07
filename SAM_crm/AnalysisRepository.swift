import Foundation
import SwiftData

public final class AnalysisRepository {
    public static let shared = AnalysisRepository()
    private init() {}
    private var container: ModelContainer { SAMModelContainer.shared }

    @MainActor
    public func saveNoteArtifact(artifact: NoteAnalysisArtifact, note: SamNote) throws -> SamAnalysisArtifact {
        let context = container.mainContext
        let model = SamAnalysisArtifact(
            sourceKind: .note,
            summary: artifact.summary,
            facts: artifact.facts,
            implications: artifact.implications,
            affect: artifact.affect.flatMap(AnalysisAffect.init(rawValue:)),
            note: note
        )
        context.insert(model)
        try context.save()
        return model
    }
}
