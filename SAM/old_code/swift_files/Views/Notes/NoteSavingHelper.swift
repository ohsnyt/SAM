import Foundation
import SwiftData

public enum NoteSavingHelper {
  public static func saveNote(text: String, selectedPeopleIDs: [UUID], container: ModelContainer) throws -> SamNote {
      print("💾 [NoteSavingHelper] Saving note with text length: \(text.count), people count: \(selectedPeopleIDs.count)")
      let context = container.mainContext
      // Resolve SamPerson objects by id
      let fetch = FetchDescriptor<SamPerson>(predicate: #Predicate { selectedPeopleIDs.contains($0.id) })
      let people = (try? context.fetch(fetch)) ?? []
      print("💾 [NoteSavingHelper] Resolved \(people.count) people from \(selectedPeopleIDs.count) IDs")
      let note = SamNote(text: text, people: people)
      context.insert(note)
      try context.save()
      print("✅ [NoteSavingHelper] Note saved successfully with ID: \(note.id), people: \(note.people.map { $0.displayName })")
      // Note: Insight generation is now handled asynchronously via InsightGeneratorNotesAdapter
      return note
  }
}
