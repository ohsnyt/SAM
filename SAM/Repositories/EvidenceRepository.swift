//
//  EvidenceRepository.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Phase E: Calendar & Evidence (Completed February 10, 2026)
//
//  SwiftData CRUD operations for SamEvidenceItem.
//  No direct EKEvent access - receives DTOs from CalendarService.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EvidenceRepository")

@MainActor
@Observable
final class EvidenceRepository {

    // MARK: - Singleton

    static let shared = EvidenceRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    /// Configure the repository with the app-wide ModelContainer.
    /// Must be called once at app launch before any operations.
    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Fetch Operations

    /// Fetch all evidence items that need review.
    func fetchNeedsReview() throws -> [SamEvidenceItem] {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )

        let allItems = try context.fetch(descriptor)
        return allItems.filter { $0.state == .needsReview }
    }

    /// Fetch all reviewed/done evidence items.
    func fetchDone() throws -> [SamEvidenceItem] {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )

        let allItems = try context.fetch(descriptor)
        return allItems.filter { $0.state == .done }
    }

    /// Fetch all evidence items (all states).
    func fetchAll() throws -> [SamEvidenceItem] {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )

        return try context.fetch(descriptor)
    }

    /// Fetch a single evidence item by ID.
    func fetch(id: UUID) throws -> SamEvidenceItem? {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamEvidenceItem>()
        let allItems = try context.fetch(descriptor)
        return allItems.first { $0.id == id }
    }

    /// Fetch evidence item by sourceUID (for idempotent upsert).
    func fetch(sourceUID: String) throws -> SamEvidenceItem? {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamEvidenceItem>()
        let allItems = try context.fetch(descriptor)
        return allItems.first { $0.sourceUID == sourceUID }
    }

    // MARK: - Create Operations

    /// Create or update an evidence item from any source (notes, manual, etc.).
    /// Uses sourceUID for idempotent upsert — if an item with the same sourceUID
    /// exists, it is updated; otherwise a new item is created.
    @discardableResult
    func create(
        sourceUID: String,
        source: EvidenceSource,
        occurredAt: Date,
        title: String,
        snippet: String,
        bodyText: String? = nil,
        linkedPeople: [SamPerson] = [],
        linkedContexts: [SamContext] = []
    ) throws -> SamEvidenceItem {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        // Idempotent: update if sourceUID already exists
        if let existing = try fetch(sourceUID: sourceUID) {
            existing.title = title
            existing.snippet = snippet
            existing.bodyText = bodyText
            existing.occurredAt = occurredAt
            existing.linkedPeople = linkedPeople
            existing.linkedContexts = linkedContexts
            try context.save()
            return existing
        }

        let evidence = SamEvidenceItem(
            id: UUID(),
            state: .needsReview,
            sourceUID: sourceUID,
            source: source,
            occurredAt: occurredAt,
            title: title,
            snippet: snippet,
            bodyText: bodyText
        )
        evidence.linkedPeople = linkedPeople
        evidence.linkedContexts = linkedContexts

        context.insert(evidence)
        try context.save()

        return evidence
    }

    // MARK: - Mapping Helpers

    /// Build participant hints from an EventDTO's attendees and organizer.
    /// `knownEmails` is the set of canonical emails that match a SamPerson in the database.
    private func buildParticipantHints(from event: EventDTO, knownEmails: Set<String>) -> [ParticipantHint] {
        var hints: [ParticipantHint] = []

        // Map attendees
        for attendee in event.attendees {
            let displayName = attendee.name ?? attendee.emailAddress ?? "Unknown"
            let canonical = canonicalizeEmail(attendee.emailAddress)
            let matched = canonical.map { knownEmails.contains($0) } ?? false
            logger.debug("Participant '\(displayName)': email=\(canonical ?? "nil"), isCurrentUser=\(attendee.isCurrentUser), matched=\(matched)")
            let hint = ParticipantHint(
                displayName: displayName,
                isOrganizer: false,
                isVerified: attendee.isCurrentUser || matched,
                rawEmail: attendee.emailAddress
            )
            hints.append(hint)
        }

        // Mark organizer if present
        if let organizer = event.organizer {
            let organizerName = organizer.name ?? organizer.emailAddress ?? "Unknown"
            // Try to find matching attendee by email; otherwise append a new organizer hint
            if let orgEmail = organizer.emailAddress,
               let idx = hints.firstIndex(where: { $0.rawEmail?.lowercased() == orgEmail.lowercased() }) {
                hints[idx].isOrganizer = true
            } else {
                let canonical = canonicalizeEmail(organizer.emailAddress)
                let matched = canonical.map { knownEmails.contains($0) } ?? false
                let organizerHint = ParticipantHint(
                    displayName: organizerName,
                    isOrganizer: true,
                    isVerified: organizer.isCurrentUser || matched,
                    rawEmail: organizer.emailAddress
                )
                hints.append(organizerHint)
            }
        }

        return hints
    }

    /// Extract all canonical emails from resolved people for isVerified checking.
    private func knownEmailSet(from people: [SamPerson]) -> Set<String> {
        var emails = Set<String>()
        for person in people {
            if let primary = canonicalizeEmail(person.emailCache) {
                emails.insert(primary)
            }
            for alias in person.emailAliases {
                if let canonical = canonicalizeEmail(alias) {
                    emails.insert(canonical)
                }
            }
        }
        return emails
    }

    /// Canonicalize an email string by trimming and lowercasing.
    private func canonicalizeEmail(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else { return nil }
        return email.lowercased()
    }

    /// Resolve SamPerson records by a list of email addresses (case-insensitive) using emailCache.
    private func resolvePeople(byEmails emails: [String]) -> [SamPerson] {
        guard let context = context else { return [] }
        do {
            let descriptor = FetchDescriptor<SamPerson>()
            let allPeople = try context.fetch(descriptor)
            let emailSet = Set(emails.compactMap { canonicalizeEmail($0) })
            logger.debug("Resolving people by emails: \(Array(emailSet))")
            let matches = allPeople.filter { person in
                let primary = canonicalizeEmail(person.emailCache)
                if let primary, emailSet.contains(primary) { return true }
                // Check aliases
                let aliases = person.emailAliases.map { $0.lowercased() }
                return !Set(aliases).isDisjoint(with: emailSet)
            }
            logger.debug("Matched \(matches.count) people")
            return matches
        } catch {
            logger.error("Failed to resolve people by emails: \(error)")
            return []
        }
    }

    // MARK: - Upsert Operations

    /// Upsert evidence item from calendar event.
    /// Creates new item if sourceUID doesn't exist, updates if it does.
    func upsert(event: EventDTO) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let sourceUID = event.sourceUID
        let emails = event.participantEmails.compactMap { canonicalizeEmail($0) }

        // Resolve people first so we can determine which emails are verified
        let resolved = resolvePeople(byEmails: emails)
        let knownEmails = knownEmailSet(from: resolved)

        // Check if evidence already exists
        if let existing = try fetch(sourceUID: sourceUID) {
            // Update existing evidence
            existing.title = event.title
            existing.snippet = event.snippet
            existing.bodyText = event.notes
            existing.occurredAt = event.startDate
            existing.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
            existing.linkedPeople = resolved
        } else {
            // Create new evidence
            let evidence = SamEvidenceItem(
                id: UUID(),
                state: .needsReview,
                sourceUID: sourceUID,
                source: .calendar,
                occurredAt: event.startDate,
                title: event.title,
                snippet: event.snippet,
                bodyText: event.notes
            )
            evidence.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
            evidence.linkedPeople = resolved

            context.insert(evidence)
        }

        try context.save()
    }

    /// Bulk upsert multiple events (more efficient than individual upserts).
    func bulkUpsert(events: [EventDTO]) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        var created = 0
        var updated = 0

        for event in events {
            let sourceUID = event.sourceUID
            let emails = event.participantEmails.compactMap { canonicalizeEmail($0) }

            // Resolve people first so we can determine which emails are verified
            let resolved = resolvePeople(byEmails: emails)
            let knownEmails = knownEmailSet(from: resolved)

            if let existing = try fetch(sourceUID: sourceUID) {
                // Update existing
                existing.title = event.title
                existing.snippet = event.snippet
                existing.bodyText = event.notes
                existing.occurredAt = event.startDate
                existing.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
                existing.linkedPeople = resolved

                updated += 1
            } else {
                // Create new
                let evidence = SamEvidenceItem(
                    id: UUID(),
                    state: .needsReview,
                    sourceUID: sourceUID,
                    source: .calendar,
                    occurredAt: event.startDate,
                    title: event.title,
                    snippet: event.snippet,
                    bodyText: event.notes
                )
                evidence.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
                evidence.linkedPeople = resolved

                context.insert(evidence)
                created += 1
            }
        }

        try context.save()

        logger.info("Bulk upsert complete: \(created) created, \(updated) updated")
    }

    // MARK: - Update Operations

    /// Mark evidence item as reviewed/done.
    func markAsReviewed(item: SamEvidenceItem) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        item.state = .done
        try context.save()
    }

    /// Mark evidence item as needs review.
    func markAsNeedsReview(item: SamEvidenceItem) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        item.state = .needsReview
        try context.save()
    }

    // MARK: - Delete Operations

    /// Delete a single evidence item.
    func delete(item: SamEvidenceItem) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        context.delete(item)
        try context.save()
    }

    /// Delete all evidence items (use with caution).
    func deleteAll() throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let allItems = try fetchAll()

        for item in allItems {
            context.delete(item)
        }

        try context.save()

        logger.notice("Deleted all evidence items: \(allItems.count)")
    }

    // MARK: - Pruning Operations

    /// Prune evidence items that no longer exist in calendar.
    /// Compares current evidence with provided sourceUIDs and deletes orphans.
    func pruneOrphans(validSourceUIDs: Set<String>) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let allItems = try fetchAll()
        var deleted = 0

        for item in allItems {
            // Only prune calendar evidence (not user notes, etc.)
            guard item.source == .calendar else { continue }

            // If sourceUID doesn't exist in valid set, delete it
            if let sourceUID = item.sourceUID, !validSourceUIDs.contains(sourceUID) {
                context.delete(item)
                deleted += 1
            }
        }

        try context.save()

        if deleted > 0 {
            logger.info("Pruned \(deleted) orphaned evidence items")
        }
    }

    // MARK: - Re-Resolution after Contacts Import

    /// Re-run resolution of linkedPeople for evidence items that appear to be "Not in Contacts" yet.
    /// Criteria: has participantHints with at least one rawEmail, but linkedPeople is empty.
    func reresolveParticipantsForUnlinkedEvidence() throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        let all = try fetchAll()
        var updated = 0

        for item in all {
            // Only consider calendar evidence for now
            guard item.source == .calendar else { continue }

            // If already linked to people, skip
            if !item.linkedPeople.isEmpty { continue }

            // Collect emails from participant hints
            let emails = item.participantHints.compactMap { hint in
                hint.rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }

            guard !emails.isEmpty else { continue }

            let resolved = resolvePeople(byEmails: emails)
            if !resolved.isEmpty {
                item.linkedPeople = resolved
                updated += 1
            }
        }

        if updated > 0 {
            try context.save()
            logger.info("Re-resolved participants for \(updated) evidence items after contacts import")
        }
    }

    // MARK: - Email Bulk Upsert Operations

    /// Bulk upsert email evidence items with optional analysis data.
    func bulkUpsertEmails(_ emails: [(EmailDTO, EmailAnalysisDTO?)]) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        var created = 0, updated = 0

        for (email, analysis) in emails {
            let sourceUID = email.sourceUID
            let participantEmails = email.allParticipantEmails
            let resolved = resolvePeople(byEmails: participantEmails)
            let knownEmails = knownEmailSet(from: resolved)

            // Build participant hints from email participants
            let hints = buildMailParticipantHints(from: email, knownEmails: knownEmails)

            // Build snippet: use analysis summary if available, otherwise email snippet
            let snippet = analysis?.summary ?? email.bodySnippet

            // Build signals from analysis
            var signals: [EvidenceSignal] = []
            if let analysis = analysis {
                // Convert temporal events to signals
                for event in analysis.temporalEvents {
                    signals.append(EvidenceSignal(
                        type: .lifeEvent,
                        message: "\(event.description): \(event.dateString)",
                        confidence: event.confidence
                    ))
                }
                // Convert entities to signals
                for entity in analysis.namedEntities where entity.kind == .financialInstrument {
                    signals.append(EvidenceSignal(
                        type: .financialEvent,
                        message: "Product mentioned: \(entity.name)",
                        confidence: entity.confidence
                    ))
                }
            }

            if let existing = try fetch(sourceUID: sourceUID) {
                existing.title = email.subject
                existing.snippet = snippet
                existing.bodyText = nil  // Never store raw email body
                existing.occurredAt = email.date
                existing.participantHints = hints
                existing.linkedPeople = resolved
                existing.signals = signals
                updated += 1
            } else {
                let evidence = SamEvidenceItem(
                    id: UUID(),
                    state: .needsReview,
                    sourceUID: sourceUID,
                    source: .mail,
                    occurredAt: email.date,
                    title: email.subject,
                    snippet: snippet,
                    participantHints: hints,
                    signals: signals
                )
                evidence.linkedPeople = resolved
                context.insert(evidence)
                created += 1
            }
        }

        try context.save()
        logger.info("Mail bulk upsert: \(created) created, \(updated) updated")
    }

    /// Build participant hints from email DTO.
    private func buildMailParticipantHints(from email: EmailDTO, knownEmails: Set<String>) -> [ParticipantHint] {
        var hints: [ParticipantHint] = []

        // Sender
        let senderCanonical = canonicalizeEmail(email.senderEmail)
        let senderMatched = senderCanonical.map { knownEmails.contains($0) } ?? false
        hints.append(ParticipantHint(
            displayName: email.senderName ?? email.senderEmail,
            isOrganizer: true,  // Sender is "organizer" for emails
            isVerified: senderMatched,
            rawEmail: email.senderEmail
        ))

        // Recipients
        for recipient in email.recipientEmails {
            let canonical = canonicalizeEmail(recipient)
            let matched = canonical.map { knownEmails.contains($0) } ?? false
            hints.append(ParticipantHint(
                displayName: recipient,
                isOrganizer: false,
                isVerified: matched,
                rawEmail: recipient
            ))
        }

        return hints
    }

    /// Prune mail evidence items whose sourceUID is no longer in the valid set.
    func pruneMailOrphans(validSourceUIDs: Set<String>) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        let allItems = try fetchAll()
        var deleted = 0

        for item in allItems {
            guard item.source == .mail else { continue }
            if let sourceUID = item.sourceUID, !validSourceUIDs.contains(sourceUID) {
                context.delete(item)
                deleted += 1
            }
        }

        try context.save()
        if deleted > 0 {
            logger.info("Pruned \(deleted) orphaned mail evidence items")
        }
    }

    // MARK: - Error Types

    enum RepositoryError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "EvidenceRepository not configured. Call configure(container:) first."
            }
        }
    }
}
