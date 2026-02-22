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

    /// Canonical email set for the Me contact — used instead of EKParticipant.isCurrentUser
    /// which can be unreliable (returns true for organizer or all attendees in some calendar configs).
    private func meEmailSet() -> Set<String> {
        guard let me = try? PeopleRepository.shared.fetchMe() else { return [] }
        var emails = Set<String>()
        if let primary = canonicalizeEmail(me.emailCache) {
            emails.insert(primary)
        }
        for alias in me.emailAliases {
            if let canonical = canonicalizeEmail(alias) {
                emails.insert(canonical)
            }
        }
        return emails
    }

    /// Build participant hints from an EventDTO's attendees and organizer.
    /// `knownEmails` is the set of canonical emails that match a SamPerson in the database.
    private func buildParticipantHints(from event: EventDTO, knownEmails: Set<String>) -> [ParticipantHint] {
        var hints: [ParticipantHint] = []
        let meEmails = meEmailSet()

        // Map attendees
        for attendee in event.attendees {
            let displayName = attendee.name ?? attendee.emailAddress ?? "Unknown"
            let canonical = canonicalizeEmail(attendee.emailAddress)
            let isMe = canonical.map { meEmails.contains($0) } ?? false
            let matched = canonical.map { knownEmails.contains($0) } ?? false
            logger.debug("Participant '\(displayName)': email=\(canonical ?? "nil"), isMe=\(isMe), matched=\(matched)")
            let hint = ParticipantHint(
                displayName: displayName,
                isOrganizer: false,
                isVerified: isMe || matched,
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
                let isMe = canonical.map { meEmails.contains($0) } ?? false
                let matched = canonical.map { knownEmails.contains($0) } ?? false
                let organizerHint = ParticipantHint(
                    displayName: organizerName,
                    isOrganizer: true,
                    isVerified: isMe || matched,
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

    // MARK: - Phone-Based Resolution

    /// Canonicalize a phone number: strip non-digits, take last 10.
    private func canonicalizePhone(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    /// Resolve SamPerson records by phone numbers using phoneAliases.
    private func resolvePeople(byPhones phones: [String]) -> [SamPerson] {
        guard let context = context else { return [] }
        do {
            let descriptor = FetchDescriptor<SamPerson>()
            let allPeople = try context.fetch(descriptor)
            let phoneSet = Set(phones.compactMap { canonicalizePhone($0) })
            guard !phoneSet.isEmpty else { return [] }
            logger.debug("Resolving people by phones: \(Array(phoneSet))")
            let matches = allPeople.filter { person in
                let aliases = Set(person.phoneAliases.compactMap { self.canonicalizePhone($0) })
                return !aliases.isDisjoint(with: phoneSet)
            }
            logger.debug("Matched \(matches.count) people by phone")
            return matches
        } catch {
            logger.error("Failed to resolve people by phones: \(error)")
            return []
        }
    }

    /// Reliably set linkedPeople on an evidence item.
    /// Direct assignment (`item.linkedPeople = newValue`) doesn't always trigger
    /// SwiftData's change tracking on existing objects. Explicit removeAll + append does.
    private func setLinkedPeople(_ people: [SamPerson], on evidence: SamEvidenceItem) {
        evidence.linkedPeople.removeAll()
        for person in people {
            evidence.linkedPeople.append(person)
        }
    }

    /// Resolve people by a handle that could be an email or phone number.
    private func resolvePeopleByHandle(_ handle: String) -> [SamPerson] {
        if handle.contains("@") {
            return resolvePeople(byEmails: [handle])
        } else {
            return resolvePeople(byPhones: [handle])
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
            existing.endedAt = event.endDate
            existing.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
            setLinkedPeople(resolved, on: existing)
        } else {
            // Create new evidence
            let evidence = SamEvidenceItem(
                id: UUID(),
                state: .needsReview,
                sourceUID: sourceUID,
                source: .calendar,
                occurredAt: event.startDate,
                endedAt: event.endDate,
                title: event.title,
                snippet: event.snippet,
                bodyText: event.notes
            )
            evidence.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
            setLinkedPeople(resolved, on: evidence)

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
                existing.endedAt = event.endDate
                existing.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
                setLinkedPeople(resolved, on: existing)

                updated += 1
            } else {
                // Create new
                let evidence = SamEvidenceItem(
                    id: UUID(),
                    state: .needsReview,
                    sourceUID: sourceUID,
                    source: .calendar,
                    occurredAt: event.startDate,
                    endedAt: event.endDate,
                    title: event.title,
                    snippet: event.snippet,
                    bodyText: event.notes
                )
                evidence.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
                setLinkedPeople(resolved, on: evidence)

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

    // MARK: - Re-Resolution after Contacts Change

    /// Re-resolve linkedPeople AND refresh participantHints.isVerified for all
    /// calendar and mail evidence. Call after any change to the People list
    /// (contacts import, unknown sender triage, manual contact creation).
    ///
    /// Uses PeopleRepository as the authoritative source for known emails,
    /// avoiding cross-ModelContext staleness (EvidenceRepository and
    /// PeopleRepository each have their own ModelContext).
    func refreshParticipantResolution() throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        // Read the authoritative email set from PeopleRepository's context
        let allKnownEmails = try PeopleRepository.shared.allKnownEmails()
        let allPeople = try PeopleRepository.shared.fetchAll()
        let meEmails = meEmailSet()

        let all = try fetchAll()
        var updated = 0

        for item in all {
            guard item.source == .calendar || item.source == .mail
                    || item.source == .iMessage || item.source == .phoneCall
                    || item.source == .faceTime else { continue }

            // Collect all emails from participant hints
            let emails = item.participantHints.compactMap { hint in
                hint.rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard !emails.isEmpty else { continue }

            // Resolve people using PeopleRepository's authoritative data
            let emailSet = Set(emails)
            let resolved = allPeople.filter { person in
                let primary = canonicalizeEmail(person.emailCache)
                if let primary, emailSet.contains(primary) { return true }
                let aliases = person.emailAliases.map { $0.lowercased() }
                return !Set(aliases).isDisjoint(with: emailSet)
            }

            // Refresh isVerified on each participant hint
            var hintsChanged = false
            var newHints = item.participantHints
            for i in newHints.indices {
                let canonical = canonicalizeEmail(newHints[i].rawEmail)
                let isMe = canonical.map { meEmails.contains($0) } ?? false
                let matched = canonical.map { allKnownEmails.contains($0) } ?? false
                let newVerified = isMe || matched
                if newHints[i].isVerified != newVerified {
                    newHints[i].isVerified = newVerified
                    hintsChanged = true
                }
            }

            // Update linkedPeople if the resolved set changed
            let oldIDs = Set(item.linkedPeople.map(\.id))
            let newIDs = Set(resolved.map(\.id))
            let peopleChanged = oldIDs != newIDs

            if hintsChanged || peopleChanged {
                item.participantHints = newHints
                setLinkedPeople(resolved, on: item)
                updated += 1
            }
        }

        if updated > 0 {
            try context.save()
            logger.info("Refreshed participant resolution for \(updated) evidence items")
        }
    }

    /// Legacy alias — calls `refreshParticipantResolution()`.
    func reresolveParticipantsForUnlinkedEvidence() throws {
        try refreshParticipantResolution()
    }

    // MARK: - Recent Meeting Lookup

    /// Find the most recent calendar event involving a person that ended within the given time window.
    /// Used by InlineNoteCaptureView to auto-link notes to recent meetings.
    ///
    /// Logic: find calendar evidence where `linkedPeople` contains this person,
    /// the event has ended within `maxWindow` seconds of now, and no newer event
    /// for this person has started since the candidate ended.
    func findRecentMeeting(forPersonID personID: UUID, maxWindow: TimeInterval = 7200) -> SamEvidenceItem? {
        guard let context = context else { return nil }

        do {
            let descriptor = FetchDescriptor<SamEvidenceItem>(
                sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
            )
            let allItems = try context.fetch(descriptor)
            let now = Date.now

            // Filter to calendar events linked to this person that have ended
            let candidates = allItems.filter { item in
                guard item.source == .calendar else { return false }
                guard item.linkedPeople.contains(where: { $0.id == personID }) else { return false }

                let endTime = item.endedAt ?? item.occurredAt.addingTimeInterval(3600)
                let elapsed = now.timeIntervalSince(endTime)
                return elapsed >= 0 && elapsed <= maxWindow
            }

            // Return the most recent candidate that doesn't have a newer event after it
            for candidate in candidates {
                let candidateEnd = candidate.endedAt ?? candidate.occurredAt.addingTimeInterval(3600)

                // Check if another event for this person started after this candidate ended
                let hasNewer = allItems.contains { other in
                    guard other.id != candidate.id else { return false }
                    guard other.source == .calendar else { return false }
                    guard other.linkedPeople.contains(where: { $0.id == personID }) else { return false }
                    return other.occurredAt > candidateEnd
                }

                if !hasNewer {
                    return candidate
                }
            }

            return nil
        } catch {
            logger.error("findRecentMeeting failed: \(error)")
            return nil
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
                setLinkedPeople(resolved, on: existing)
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
                setLinkedPeople(resolved, on: evidence)
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

    // MARK: - iMessage Bulk Upsert

    /// Bulk upsert iMessage evidence items with optional analysis data.
    /// Privacy: bodyText is NEVER stored — only the AI summary goes into snippet.
    func bulkUpsertMessages(_ messages: [(MessageDTO, MessageAnalysisDTO?)]) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        var created = 0, updated = 0

        for (message, analysis) in messages {
            let sourceUID = "imessage:\(message.guid)"

            // Resolve people by handle
            let resolved = resolvePeopleByHandle(message.handleID)

            // Build snippet: use analysis summary if available, otherwise truncated text
            let snippet: String
            if let summary = analysis?.summary {
                snippet = summary
            } else if let text = message.text {
                snippet = String(text.prefix(200))
            } else {
                snippet = message.hasAttachment ? "[Attachment]" : "[No text]"
            }

            // Build signals from analysis
            var signals: [EvidenceSignal] = []
            if let analysis = analysis {
                for event in analysis.temporalEvents {
                    signals.append(EvidenceSignal(
                        type: .lifeEvent,
                        message: "\(event.description): \(event.dateString)",
                        confidence: event.confidence
                    ))
                }
            }

            if let existing = try fetch(sourceUID: sourceUID) {
                existing.snippet = snippet
                existing.bodyText = nil
                existing.occurredAt = message.date
                setLinkedPeople(resolved, on: existing)
                existing.signals = signals
                updated += 1
            } else {
                let title: String
                if let name = resolved.first?.displayNameCache ?? resolved.first?.displayName {
                    title = message.isFromMe ? "Message to \(name)" : "Message from \(name)"
                } else {
                    title = message.isFromMe ? "Message sent" : "Message received"
                }

                let evidence = SamEvidenceItem(
                    id: UUID(),
                    state: .needsReview,
                    sourceUID: sourceUID,
                    source: .iMessage,
                    occurredAt: message.date,
                    title: title,
                    snippet: snippet,
                    signals: signals
                )
                setLinkedPeople(resolved, on: evidence)
                context.insert(evidence)
                created += 1
            }
        }

        try context.save()
        logger.info("iMessage bulk upsert: \(created) created, \(updated) updated")
    }

    // MARK: - Call Record Bulk Upsert

    /// Bulk upsert call/FaceTime evidence items (metadata only, no LLM analysis).
    func bulkUpsertCallRecords(_ calls: [CallRecordDTO]) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        var created = 0, updated = 0

        for call in calls {
            let dateTimestamp = Int64(call.date.timeIntervalSinceReferenceDate)
            let sourceUID = "call:\(call.id):\(dateTimestamp)"

            let resolved = resolvePeople(byPhones: [call.address])
            let personName = resolved.first?.displayNameCache ?? resolved.first?.displayName

            let source: EvidenceSource = call.callType.isFaceTime ? .faceTime : .phoneCall

            // Build title
            let title: String
            if !call.wasAnswered {
                if call.isOutgoing {
                    title = personName.map { "Unanswered call to \($0)" } ?? "Unanswered outgoing call"
                } else {
                    title = personName.map { "Missed call from \($0)" } ?? "Missed call"
                }
            } else {
                let typeLabel = call.callType.isFaceTime ? "FaceTime" : "Phone call"
                if call.isOutgoing {
                    title = personName.map { "\(typeLabel) to \($0)" } ?? "\(typeLabel) (outgoing)"
                } else {
                    title = personName.map { "\(typeLabel) from \($0)" } ?? "\(typeLabel) (incoming)"
                }
            }

            // Build snippet
            let snippet: String
            if !call.wasAnswered {
                snippet = call.isOutgoing ? "Not answered" : "Missed"
            } else {
                let minutes = Int(call.duration) / 60
                let seconds = Int(call.duration) % 60
                if minutes > 0 {
                    snippet = "\(minutes)m \(seconds)s"
                } else {
                    snippet = "\(seconds)s"
                }
            }

            let endedAt = call.wasAnswered ? call.date.addingTimeInterval(call.duration) : nil

            if let existing = try fetch(sourceUID: sourceUID) {
                existing.title = title
                existing.snippet = snippet
                existing.occurredAt = call.date
                existing.endedAt = endedAt
                setLinkedPeople(resolved, on: existing)
                updated += 1
            } else {
                let evidence = SamEvidenceItem(
                    id: UUID(),
                    state: .needsReview,
                    sourceUID: sourceUID,
                    source: source,
                    occurredAt: call.date,
                    endedAt: endedAt,
                    title: title,
                    snippet: snippet
                )
                setLinkedPeople(resolved, on: evidence)
                context.insert(evidence)
                created += 1
            }
        }

        try context.save()
        logger.info("Call record bulk upsert: \(created) created, \(updated) updated")
    }

    /// Prune mail evidence items whose sourceUID is no longer in the valid set.
    /// When `scopedToSenderEmails` is provided, only prune items whose sender is in
    /// that set — this prevents deleting evidence for intentionally-skipped unknown senders.
    func pruneMailOrphans(validSourceUIDs: Set<String>, scopedToSenderEmails: Set<String>? = nil) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        let allItems = try fetchAll()
        var deleted = 0

        for item in allItems {
            guard item.source == .mail else { continue }

            // If scoped, only prune items whose sender is in the known set
            if let scopedEmails = scopedToSenderEmails {
                let senderEmail = item.participantHints
                    .first(where: { $0.isOrganizer })?
                    .rawEmail?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard let senderEmail, scopedEmails.contains(senderEmail) else { continue }
            }

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
