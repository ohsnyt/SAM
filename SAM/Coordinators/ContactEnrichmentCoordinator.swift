//
//  ContactEnrichmentCoordinator.swift
//  SAM
//
//  Orchestrates the contact enrichment review-and-write-back workflow.
//  Accumulates PendingEnrichment candidates from all import sources,
//  exposes them for UI review, and applies approved updates to Apple Contacts.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContactEnrichmentCoordinator")

@MainActor
@Observable
final class ContactEnrichmentCoordinator {

    // MARK: - Singleton

    static let shared = ContactEnrichmentCoordinator()

    // MARK: - Dependencies

    private let enrichmentRepo  = EnrichmentRepository.shared
    private let contactsService = ContactsService.shared
    private let peopleRepo      = PeopleRepository.shared

    // MARK: - State

    /// IDs of all SamPersons that have at least one pending enrichment.
    /// Cached for O(1) lookup in list views.
    private(set) var peopleWithEnrichment: Set<UUID> = []

    private init() {}

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        EnrichmentRepository.shared.configure(container: container)
        refresh()
    }

    // MARK: - Cache Refresh

    /// Refresh the cached set of person IDs with pending enrichment.
    /// Called after import and after each enrichment resolution.
    func refresh() {
        do {
            peopleWithEnrichment = try enrichmentRepo.fetchPeopleWithPendingEnrichment()
        } catch {
            logger.error("Failed to refresh enrichment cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch

    /// Fetch all pending enrichments for a specific person.
    func pendingEnrichments(for personID: UUID) -> [PendingEnrichment] {
        (try? enrichmentRepo.fetchPending(for: personID)) ?? []
    }

    /// Total count of pending enrichments across all people.
    var totalPendingCount: Int {
        peopleWithEnrichment.count
    }

    // MARK: - Apply

    /// Write approved enrichment fields to Apple Contacts, then mark them approved.
    /// Returns true if the Apple Contacts update succeeded.
    @discardableResult
    func applyEnrichments(_ items: [PendingEnrichment], for person: SamPerson) async -> Bool {
        guard !items.isEmpty else { return true }
        guard let contactID = person.contactIdentifier else {
            logger.warning("applyEnrichments: person \(person.id) has no contactIdentifier")
            return false
        }

        // Build the updates dictionary
        var updates: [EnrichmentField: String] = [:]
        for item in items {
            updates[item.field] = item.proposedValue
        }

        // Generate the SAM note block content for this person
        let noteBlock = samNoteBlockContent(for: person)

        let success = await contactsService.updateContact(
            identifier: contactID,
            updates: updates,
            samNoteBlock: noteBlock
        )

        if success {
            do {
                try enrichmentRepo.approve(items)
                refresh()
                logger.debug("Applied \(items.count) enrichment(s) for \(person.displayNameCache ?? "unknown", privacy: .private)")
            } catch {
                logger.error("Failed to mark enrichments approved: \(error.localizedDescription)")
            }
        }

        return success
    }

    // MARK: - Dismiss

    /// Dismiss enrichments the user doesn't want applied.
    func dismissEnrichments(_ items: [PendingEnrichment]) {
        do {
            try enrichmentRepo.dismiss(items)
            refresh()
        } catch {
            logger.error("Failed to dismiss enrichments: \(error.localizedDescription)")
        }
    }

    // MARK: - SAM Note Block

    /// Generate the SAM-managed note block content for a contact.
    /// This is placed below the `--- SAM ---` delimiter in the Apple Contacts note field.
    func samNoteBlockContent(for person: SamPerson) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        var lines: [String] = []

        lines.append("Updated by SAM: \(dateFormatter.string(from: Date()))")

        // Roles
        if !person.roleBadges.isEmpty {
            lines.append("Roles: \(person.roleBadges.joined(separator: ", "))")
        }

        // LinkedIn connection date
        if let connectedOn = person.linkedInConnectedOn {
            lines.append("LinkedIn connected: \(dateFormatter.string(from: connectedOn))")
        }

        // LinkedIn URL
        if let url = person.linkedInProfileURL, !url.isEmpty {
            lines.append("LinkedIn: \(url.hasPrefix("http") ? url : "https://\(url)")")
        }

        // Last interaction (most recent evidence)
        if let lastEvidence = person.linkedEvidence
            .filter({ $0.source.isInteraction })
            .max(by: { $0.occurredAt < $1.occurredAt }) {
            let relativeDate = relativeTimeString(from: lastEvidence.occurredAt)
            lines.append("Last interaction: \(relativeDate) via \(lastEvidence.source.rawValue)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Deduced Relationship Enrichment

    /// Queue bidirectional enrichment items for a confirmed deduced relationship.
    /// Person A gets the forward label ("wife|Ruth Smith"), Person B gets the inverse ("husband|David Smith").
    func queueDeducedRelationshipEnrichments(for relation: DeducedRelation) {
        guard let personA = try? peopleRepo.fetch(id: relation.personAID),
              let personB = try? peopleRepo.fetch(id: relation.personBID),
              personA.contactIdentifier != nil,
              personB.contactIdentifier != nil else {
            logger.debug("Skipping enrichment queuing: one or both people lack contactIdentifier")
            return
        }

        let forwardLabel = relation.sourceLabel
        let inverseLabel = Self.inverseRelationLabel(forwardLabel)
        let personAName = personA.displayNameCache ?? personA.displayName
        let personBName = personB.displayNameCache ?? personB.displayName

        var candidates: [EnrichmentCandidate] = []

        // Person A gets: "forwardLabel|personBName"
        candidates.append(EnrichmentCandidate(
            personID: personA.id,
            field: .contactRelation,
            proposedValue: "\(forwardLabel)|\(personBName)",
            currentValue: nil,
            source: .deducedRelationship,
            sourceDetail: "Deduced family relationship"
        ))

        // Person B gets: "inverseLabel|personAName"
        candidates.append(EnrichmentCandidate(
            personID: personB.id,
            field: .contactRelation,
            proposedValue: "\(inverseLabel)|\(personAName)",
            currentValue: nil,
            source: .deducedRelationship,
            sourceDetail: "Deduced family relationship (inverse)"
        ))

        do {
            let inserted = try enrichmentRepo.bulkRecord(candidates)
            if inserted > 0 {
                refresh()
                logger.debug("Queued \(inserted) deduced relationship enrichment(s)")
            }
        } catch {
            logger.error("Failed to queue deduced relationship enrichments: \(error.localizedDescription)")
        }
    }

    /// Queue enrichments for a batch of confirmed deduced relations.
    func queueDeducedRelationshipEnrichments(for relations: [DeducedRelation]) {
        for relation in relations {
            queueDeducedRelationshipEnrichments(for: relation)
        }
    }

    /// Map a forward relation label to its inverse.
    static func inverseRelationLabel(_ label: String) -> String {
        switch label.lowercased() {
        case "wife":                        return "husband"
        case "husband":                     return "wife"
        case "spouse", "partner":           return "spouse"
        case "mother", "mom":               return "child"
        case "father", "dad":               return "child"
        case "parent":                      return "child"
        case "son", "daughter", "child":    return "parent"
        case "brother", "sister", "sibling": return "sibling"
        default:                            return label
        }
    }

    // MARK: - Helpers

    private func relativeTimeString(from date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case 0:  return "today"
        case 1:  return "yesterday"
        case 2...6: return "\(days) days ago"
        case 7...13: return "1 week ago"
        case 14...29: return "\(days / 7) weeks ago"
        case 30...59: return "1 month ago"
        default: return "\(days / 30) months ago"
        }
    }
}

// MARK: - String helper

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
