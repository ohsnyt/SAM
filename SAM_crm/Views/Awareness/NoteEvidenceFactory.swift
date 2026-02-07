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
      
      print("📝 [NoteEvidenceFactory] Creating evidence for note \(note.id)")
      print("📝 [NoteEvidenceFactory] Note has \(note.people.count) linked people: \(note.people.map { $0.displayName })")
      
      if let existing = try? ctx.fetch(FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.sourceUID == uid })).first {
          print("📝 [NoteEvidenceFactory] Found existing evidence for note \(note.id)")
          // Update linked people in case they changed
          existing.linkedPeople = note.people
          try ctx.save()
          print("📝 [NoteEvidenceFactory] Updated existing evidence, now has \(existing.linkedPeople.count) linked people")
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
      print("✅ [NoteEvidenceFactory] Created evidence item for note \(note.id), evidence ID: \(item.id)")
      print("📝 [NoteEvidenceFactory] Evidence has \(item.linkedPeople.count) linked people: \(item.linkedPeople.map { $0.displayName })")
      return item
  }
}
