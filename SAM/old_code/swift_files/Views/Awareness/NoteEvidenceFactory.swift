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
          // Regenerate proposed links based on current artifact
          existing.proposedLinks = generateProposedLinks(from: note, container: container)
          try ctx.save()
          print("📝 [NoteEvidenceFactory] Updated existing evidence, now has \(existing.linkedPeople.count) linked people and \(existing.proposedLinks.count) proposed links")
          return existing
      }
      
      // Create new evidence
      let title = "Note"
      let snippet = String(note.text.prefix(120))
      
      // Generate proposed links from artifact
      let proposedLinks = generateProposedLinks(from: note, container: container)
      
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
          proposedLinks: proposedLinks
      )
      // Link people from the note
      item.linkedPeople = note.people
      ctx.insert(item)
      try ctx.save()
      print("✅ [NoteEvidenceFactory] Created evidence item for note \(note.id), evidence ID: \(item.id)")
      print("📝 [NoteEvidenceFactory] Evidence has \(item.linkedPeople.count) linked people: \(item.linkedPeople.map { $0.displayName })")
      print("📝 [NoteEvidenceFactory] Evidence has \(item.proposedLinks.count) proposed links")
      return item
  }
  
  /// Generates proposed links from the note's analysis artifact
  /// This creates suggestions to add detected family members to existing contacts
  @MainActor
  private static func generateProposedLinks(from note: SamNote, container: ModelContainer) -> [ProposedLink] {
      guard let artifact = note.analysisArtifact else {
          print("📝 [NoteEvidenceFactory] No artifact found for note")
          return []
      }
      
      guard !note.people.isEmpty else {
          print("📝 [NoteEvidenceFactory] No linked people to suggest family members for")
          return []
      }
      
      var links: [ProposedLink] = []
      
      // For each detected person in the artifact
      for detectedPerson in artifact.people {
          // Skip if this person doesn't have a relationship
          guard let relationship = detectedPerson.relationship,
                !relationship.isEmpty,
                isFamily(relationship) else {
              continue
          }
          
          // Create a proposed link for each person the note is linked to
          for linkedPerson in note.people {
              let link = ProposedLink(
                  id: UUID(),
                  target: .person,
                  targetID: linkedPerson.id,
                  displayName: linkedPerson.displayNameCache ?? "Unknown",
                  secondaryLine: "Add \(detectedPerson.name) as \(relationship)",
                  confidence: 0.9, // High confidence since it's from explicit note
                  reason: "Detected from note: \"\(detectedPerson.name)\" mentioned as \(relationship)",
                  status: .pending,
                  decidedAt: nil
              )
              links.append(link)
              print("📝 [NoteEvidenceFactory] Created proposed link: Add \(detectedPerson.name) as \(relationship) to \(linkedPerson.displayNameCache ?? "Unknown")")
          }
      }
      
      return links
  }
  
  /// Checks if a relationship string indicates a family member
  private static func isFamily(_ relationship: String) -> Bool {
      let lower = relationship.lowercased()
      return lower.contains("son") ||
             lower.contains("daughter") ||
             lower.contains("child") ||
             lower.contains("spouse") ||
             lower.contains("wife") ||
             lower.contains("husband") ||
             lower.contains("partner") ||
             lower.contains("parent") ||
             lower.contains("mother") ||
             lower.contains("father") ||
             lower.contains("sibling") ||
             lower.contains("brother") ||
             lower.contains("sister")
  }
}
