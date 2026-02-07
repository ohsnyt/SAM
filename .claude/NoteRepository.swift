import Foundation
import SwiftData

public final class NoteRepository {
    public static let shared = NoteRepository()
    private init() {}

    // Use the shared SAMModelContainer if available; fall back to a new container if not.
    private var container: ModelContainer { SAMModelContainer.shared }

    @MainActor
    public func createNote(text: String, people: [SamPerson]) throws -> SamNote {
        let context = container.mainContext
        let note = SamNote(text: text, people: people)
        context.insert(note)
        try context.save()
        return note
    }
}
