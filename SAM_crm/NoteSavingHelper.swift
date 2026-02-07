import Foundation
import SwiftData

public enum NoteSavingHelper {
  public static func saveNote(text: String, selectedPeopleIDs: [UUID], container: ModelContainer) throws -> SamNote {
      let context = container.mainContext
      // Resolve SamPerson objects by id
      let fetch = FetchDescriptor<SamPerson>(predicate: #Predicate { selectedPeopleIDs.contains($0.id) })
      let people = (try? context.fetch(fetch)) ?? []
      let note = SamNote(text: text, people: people)
      context.insert(note)
      try context.save()
      note.generateInsight()
      return note
  }
}
