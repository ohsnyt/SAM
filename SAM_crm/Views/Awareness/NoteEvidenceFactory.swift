import Foundation
import SwiftData

public enum NoteEvidenceFactory {
  /// Returns an existing or newly created evidence item representing this note.
  /// Uses source = .note and sourceUID = note.id.uuidString.
  @MainActor
  public static func evidence(for note: SamNote, in container: ModelContainer) throws -> SamEvidenceItem {
      let ctx = container.mainContext
      // Try fetch by sourceUID
      let uid = note.id.uuidString
      if let existing = try? ctx.fetch(FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.sourceUID == uid })).first {
          return existing
      }
      // Create new evidence
      let title = "Note"
      let snippet = String(note.text.prefix(120))
      let item = SamEvidenceItem(
          id: UUID(),
          state: .needsReview,
          sourceUID: uid,
          source: .note,
          occurredAt: note.createdAt,
          title: title,
          snippet: snippet,
          bodyText: note.text,
          participantHints: [],
          signals: [],
          proposedLinks: []
      )
      // Link people from the note
      item.linkedPeople = note.people
      ctx.insert(item)
      try ctx.save()
      return item
  }
}
