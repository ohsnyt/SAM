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
                logger.info("Applied \(items.count) enrichment(s) for \(person.displayNameCache ?? "unknown", privacy: .public)")
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
