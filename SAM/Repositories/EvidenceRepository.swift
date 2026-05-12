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

    /// Fetch evidence whose `occurredAt` falls in `(start, end]`. If `end` is nil,
    /// returns everything after `start`. Pushes the date predicate into SwiftData
    /// so callers don't have to load the full table just to filter it.
    func fetchOccurringBetween(_ start: Date, _ end: Date?) throws -> [SamEvidenceItem] {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        let descriptor: FetchDescriptor<SamEvidenceItem>
        if let end {
            descriptor = FetchDescriptor<SamEvidenceItem>(
                predicate: #Predicate { $0.occurredAt > start && $0.occurredAt <= end },
                sortBy: [SortDescriptor(\.occurredAt)]
            )
        } else {
            descriptor = FetchDescriptor<SamEvidenceItem>(
                predicate: #Predicate { $0.occurredAt > start },
                sortBy: [SortDescriptor(\.occurredAt)]
            )
        }

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

    /// Update the occurrence status for an evidence item (did this calendar event actually happen?).
    /// Used by PostMeetingCaptureView when the user resolves a pending review.
    func updateReviewStatus(id: UUID, status: EvidenceReviewStatus) throws {
        guard let context = context else { throw RepositoryError.notConfigured }
        guard let item = try fetch(id: id) else { return }
        item.reviewStatus = status
        try context.save()
    }

    /// Cached sourceUID → SamEvidenceItem lookup, built on first use per import cycle.
    private var sourceUIDCache: [String: SamEvidenceItem]?

    /// Build or return the cached sourceUID lookup table.
    private func getSourceUIDLookup() throws -> [String: SamEvidenceItem] {
        if let cache = sourceUIDCache { return cache }
        guard let context = context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamEvidenceItem>()
        let allItems = try context.fetch(descriptor)
        var lookup: [String: SamEvidenceItem] = [:]
        lookup.reserveCapacity(allItems.count)
        for item in allItems {
            if let uid = item.sourceUID {
                lookup[uid] = item
            }
        }
        sourceUIDCache = lookup
        logger.debug("Built sourceUID lookup cache: \(lookup.count) evidence items")
        return lookup
    }

    /// Invalidate the sourceUID cache (call after bulk inserts to pick up new items).
    private func invalidateSourceUIDCache() {
        sourceUIDCache = nil
    }

    /// Fetch evidence item by sourceUID (for idempotent upsert).
    func fetch(sourceUID: String) throws -> SamEvidenceItem? {
        let lookup = try getSourceUIDLookup()
        return lookup[sourceUID]
    }

    // MARK: - Search

    /// Search evidence items by title and snippet (case-insensitive).
    func search(query: String) throws -> [SamEvidenceItem] {
        guard !query.isEmpty else { return try fetchAll() }

        let lowercaseQuery = query.lowercased()
        let all = try fetchAll()

        return all.filter { item in
            item.title.lowercased().contains(lowercaseQuery) ||
            item.snippet.lowercased().contains(lowercaseQuery)
        }
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

        // Snapshot photoThumbnailCache before relationship changes dirty the person
        // objects — cross-context saves can overwrite the cache with nil.
        let photoSnapshots = linkedPeople.map { ($0, $0.photoThumbnailCache) }

        // Idempotent: update if sourceUID already exists
        if let existing = try fetch(sourceUID: sourceUID) {
            existing.title = title
            existing.snippet = snippet
            existing.bodyText = bodyText
            existing.occurredAt = occurredAt
            existing.linkedPeople = linkedPeople
            existing.linkedContexts = linkedContexts
            try context.save()
            restorePhotoCacheIfNeeded(photoSnapshots, in: context)
            OutcomeBundleGenerator.shared.nudgeForEvidence(personIDs: linkedPeople.map(\.id))
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
        restorePhotoCacheIfNeeded(photoSnapshots, in: context)
        OutcomeBundleGenerator.shared.nudgeForEvidence(personIDs: linkedPeople.map(\.id))

        return evidence
    }

    /// Restore photoThumbnailCache values that were zeroed out by a cross-context save.
    private func restorePhotoCacheIfNeeded(_ snapshots: [(SamPerson, Data?)], in context: ModelContext) {
        for (person, cachedPhoto) in snapshots {
            if person.photoThumbnailCache == nil, cachedPhoto != nil {
                person.photoThumbnailCache = cachedPhoto
                try? context.save()
            }
        }
    }

    /// Create evidence by people/context IDs — re-fetches objects in this repository's
    /// own model context to avoid cross-context relationship errors.
    @discardableResult
    func createByIDs(
        sourceUID: String,
        source: EvidenceSource,
        occurredAt: Date,
        title: String,
        snippet: String,
        bodyText: String? = nil,
        linkedPeopleIDs: [UUID] = [],
        linkedContextIDs: [UUID] = []
    ) throws -> SamEvidenceItem {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        // Re-fetch only needed objects by ID to avoid loading entire tables
        // and risking stale writes of large Data? properties (photoThumbnailCache).
        let people: [SamPerson]
        if !linkedPeopleIDs.isEmpty {
            let idSet = linkedPeopleIDs
            let descriptor = FetchDescriptor<SamPerson>(predicate: #Predicate { idSet.contains($0.id) })
            people = try context.fetch(descriptor)
        } else {
            people = []
        }

        let contexts: [SamContext]
        if !linkedContextIDs.isEmpty {
            let idSet = linkedContextIDs
            let descriptor = FetchDescriptor<SamContext>(predicate: #Predicate { idSet.contains($0.id) })
            contexts = try context.fetch(descriptor)
        } else {
            contexts = []
        }

        return try create(
            sourceUID: sourceUID,
            source: source,
            occurredAt: occurredAt,
            title: title,
            snippet: snippet,
            bodyText: bodyText,
            linkedPeople: people,
            linkedContexts: contexts
        )
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

    /// Resolve SamPerson records by a list of email addresses using cached lookup table.
    private func resolvePeople(byEmails emails: [String]) -> [SamPerson] {
        let emailSet = Set(emails.compactMap { canonicalizeEmail($0) })
        guard !emailSet.isEmpty else { return [] }
        let lookup = getEmailLookup()
        var seen = Set<PersistentIdentifier>()
        var matches: [SamPerson] = []
        for email in emailSet {
            if let people = lookup[email] {
                for person in people where seen.insert(person.persistentModelID).inserted {
                    matches.append(person)
                }
            }
        }
        return matches
    }

    // MARK: - Phone-Based Resolution

    /// Canonicalize a phone number: strip non-digits, take last 10.
    private func canonicalizePhone(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    // MARK: - Cached Lookup Tables

    /// Cached phone → [SamPerson] lookup, built once per import cycle.
    private var phoneLookupCache: [String: [SamPerson]]?
    /// Cached email → [SamPerson] lookup, built once per import cycle.
    private var emailLookupCache: [String: [SamPerson]]?

    /// Invalidate cached lookup tables. Call at the start of each import cycle
    /// or when contacts change.
    func invalidateResolutionCache() {
        phoneLookupCache = nil
        emailLookupCache = nil
        sourceUIDCache = nil
    }

    /// Build or return the cached phone → people lookup table.
    private func getPhoneLookup() -> [String: [SamPerson]] {
        if let cache = phoneLookupCache { return cache }
        guard let context = context else { return [:] }
        do {
            let descriptor = FetchDescriptor<SamPerson>()
            let allPeople = try context.fetch(descriptor)
            var lookup: [String: [SamPerson]] = [:]
            for person in allPeople {
                for alias in person.phoneAliases {
                    if let canonical = canonicalizePhone(alias) {
                        lookup[canonical, default: []].append(person)
                    }
                }
            }
            phoneLookupCache = lookup
            logger.debug("Built phone lookup cache: \(lookup.count) canonical phones → \(allPeople.count) people")
            return lookup
        } catch {
            logger.error("Failed to build phone lookup: \(error)")
            return [:]
        }
    }

    /// Build or return the cached email → people lookup table.
    private func getEmailLookup() -> [String: [SamPerson]] {
        if let cache = emailLookupCache { return cache }
        guard let context = context else { return [:] }
        do {
            let descriptor = FetchDescriptor<SamPerson>()
            let allPeople = try context.fetch(descriptor)
            var lookup: [String: [SamPerson]] = [:]
            for person in allPeople {
                if let primary = canonicalizeEmail(person.emailCache) {
                    lookup[primary, default: []].append(person)
                }
                for alias in person.emailAliases {
                    let lower = alias.lowercased()
                    if !lower.isEmpty {
                        lookup[lower, default: []].append(person)
                    }
                }
            }
            emailLookupCache = lookup
            logger.debug("Built email lookup cache: \(lookup.count) canonical emails → \(allPeople.count) people")
            return lookup
        } catch {
            logger.error("Failed to build email lookup: \(error)")
            return [:]
        }
    }

    /// Resolve SamPerson records by phone numbers using cached lookup table.
    private func resolvePeople(byPhones phones: [String]) -> [SamPerson] {
        let phoneSet = Set(phones.compactMap { canonicalizePhone($0) })
        guard !phoneSet.isEmpty else { return [] }
        let lookup = getPhoneLookup()
        var seen = Set<PersistentIdentifier>()
        var matches: [SamPerson] = []
        for phone in phoneSet {
            if let people = lookup[phone] {
                for person in people where seen.insert(person.persistentModelID).inserted {
                    matches.append(person)
                }
            }
        }
        return matches
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

    /// Build a participant hint from a raw handle (email or phone).
    /// Used by iMessage / call / WhatsApp upserts so the identifier survives on
    /// the evidence item and `refreshParticipantResolution()` can re-link later.
    private func buildHandleHint(handle: String, displayName: String?, isVerified: Bool) -> ParticipantHint {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            return ParticipantHint(
                displayName: displayName ?? trimmed,
                isVerified: isVerified,
                rawEmail: trimmed,
                rawPhone: nil
            )
        } else {
            return ParticipantHint(
                displayName: displayName ?? trimmed,
                isVerified: isVerified,
                rawEmail: nil,
                rawPhone: trimmed
            )
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
            existing.isAllDay = event.isAllDay
            existing.calendarAvailability = event.availability.rawValue
            existing.direction = .bidirectional
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
            evidence.isAllDay = event.isAllDay
            evidence.calendarAvailability = event.availability.rawValue
            evidence.direction = .bidirectional
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
                existing.isAllDay = event.isAllDay
                existing.calendarAvailability = event.availability.rawValue
                existing.direction = .bidirectional
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
                evidence.isAllDay = event.isAllDay
                evidence.calendarAvailability = event.availability.rawValue
                evidence.direction = .bidirectional
                evidence.participantHints = buildParticipantHints(from: event, knownEmails: knownEmails)
                setLinkedPeople(resolved, on: evidence)

                context.insert(evidence)
                created += 1
            }
        }

        try context.save()

        logger.debug("Bulk upsert complete: \(created) created, \(updated) updated")
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
            logger.debug("Pruned \(deleted) orphaned evidence items")
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
    func refreshParticipantResolution() async throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        // Build email/phone indices from EvidenceRepository's OWN context. Using
        // PeopleRepository.fetchAll() returned SamPerson instances from a
        // separate context — attaching them via setLinkedPeople produced
        // cross-context references that crashed in
        // SamPerson.roleBadges.getter ("backing data detached") when SwiftUI
        // later read those persons. Single-context resolution is the safe path.
        invalidateResolutionCache()
        let personByEmail: [String: SamPerson] = {
            var flat: [String: SamPerson] = [:]
            for (email, people) in getEmailLookup() {
                if let first = people.first { flat[email] = first }
            }
            return flat
        }()
        let personByPhone: [String: SamPerson] = {
            var flat: [String: SamPerson] = [:]
            for (phone, people) in getPhoneLookup() {
                if let first = people.first { flat[phone] = first }
            }
            return flat
        }()
        let allKnownEmails = Set(personByEmail.keys)
        let meEmails = meEmailSet()

        let all = try fetchAll()
        var updated = 0
        var batch = 0

        for item in all {
            guard item.source == .calendar || item.source == .mail
                    || item.source == .iMessage || item.source == .phoneCall
                    || item.source == .faceTime || item.source == .whatsApp
                    || item.source == .whatsAppCall else { continue }

            // Collect all emails from participant hints
            let emails = item.participantHints.compactMap { hint in
                hint.rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            let phones = item.participantHints.compactMap { hint in
                canonicalizePhone(hint.rawPhone)
            }
            guard !emails.isEmpty || !phones.isEmpty else { continue }

            // Resolve people via the prebuilt email + phone indexes. Dedup with
            // a Set since a person may match multiple hints (e.g., both email
            // and phone on the same evidence).
            var resolvedIDs: Set<UUID> = []
            var resolved: [SamPerson] = []
            for email in emails {
                if let person = personByEmail[email], resolvedIDs.insert(person.id).inserted {
                    resolved.append(person)
                }
            }
            for phone in phones {
                if let person = personByPhone[phone], resolvedIDs.insert(person.id).inserted {
                    resolved.append(person)
                }
            }

            // Refresh isVerified on each participant hint
            var hintsChanged = false
            var newHints = item.participantHints
            for i in newHints.indices {
                let canonicalEmail = canonicalizeEmail(newHints[i].rawEmail)
                let canonicalPhone = canonicalizePhone(newHints[i].rawPhone)
                let isMe = canonicalEmail.map { meEmails.contains($0) } ?? false
                let emailMatched = canonicalEmail.map { allKnownEmails.contains($0) } ?? false
                let phoneMatched = canonicalPhone.map { personByPhone[$0] != nil } ?? false
                let newVerified = isMe || emailMatched || phoneMatched
                if newHints[i].isVerified != newVerified {
                    newHints[i].isVerified = newVerified
                    hintsChanged = true
                }
            }

            // Update linkedPeople if the resolved set changed
            let oldIDs = Set(item.linkedPeople.map(\.id))
            let peopleChanged = oldIDs != resolvedIDs

            if hintsChanged || peopleChanged {
                item.participantHints = newHints
                setLinkedPeople(resolved, on: item)
                updated += 1
            }

            batch += 1
            if batch % 500 == 0 { await Task.yield() }
        }

        if updated > 0 {
            try context.save()
            logger.debug("Refreshed participant resolution for \(updated) evidence items")
        }
    }

    /// Legacy alias — calls `refreshParticipantResolution()`.
    func reresolveParticipantsForUnlinkedEvidence() async throws {
        try await refreshParticipantResolution()
    }

    // MARK: - Handle Hint Back-Fill

    /// One-time back-fill: populate `rawPhone` on `participantHints` for
    /// existing iMessage / phoneCall / faceTime / whatsApp / whatsAppCall
    /// evidence imported before phone-based hints were stored.
    ///
    /// Reads handle/JID from the source SQLite DBs by sourceUID, fills in
    /// hints, then calls `refreshParticipantResolution()` to link any
    /// previously-unlinked evidence to existing people via phone match.
    ///
    /// Returns the number of evidence items that received a hint update.
    @discardableResult
    func backfillHandleHints(bookmarkManager: BookmarkManager) async throws -> Int {
        guard let context = context else { throw RepositoryError.notConfigured }

        let all = try fetchAll()

        // Bucket evidence by source, indexed for fast lookup during the
        // service-result merge step.
        var iMessageByGUID: [String: SamEvidenceItem] = [:]
        var callBySourceUID: [String: SamEvidenceItem] = [:]
        var waMessageByStanzaID: [String: SamEvidenceItem] = [:]
        var waCallByCallID: [String: SamEvidenceItem] = [:]

        for item in all {
            // Skip items that already have a phone hint — they were imported
            // after the new code path. Email-only hints still get processed so
            // we can add phone hints on top.
            let hasPhone = item.participantHints.contains { $0.rawPhone != nil }
            if hasPhone { continue }
            guard let uid = item.sourceUID else { continue }

            switch item.source {
            case .iMessage:
                guard uid.hasPrefix("imessage:") else { continue }
                let guid = String(uid.dropFirst("imessage:".count))
                iMessageByGUID[guid] = item
            case .phoneCall, .faceTime:
                guard uid.hasPrefix("call:") else { continue }
                callBySourceUID[uid] = item
            case .whatsApp:
                guard uid.hasPrefix("whatsapp:") else { continue }
                let stanzaID = String(uid.dropFirst("whatsapp:".count))
                waMessageByStanzaID[stanzaID] = item
            case .whatsAppCall:
                guard uid.hasPrefix("whatsappcall:") else { continue }
                let callID = String(uid.dropFirst("whatsappcall:".count))
                waCallByCallID[callID] = item
            default:
                continue
            }
        }

        var updated = 0

        // iMessage back-fill
        if !iMessageByGUID.isEmpty, let resolved = bookmarkManager.resolveMessagesURL() {
            let dir = resolved.directory
            guard dir.startAccessingSecurityScopedResource() else {
                logger.warning("Back-fill: could not access Messages directory")
                return updated
            }
            defer { bookmarkManager.stopAccessing(dir) }

            do {
                let guidToHandle = try await iMessageService.shared.fetchHandlesForGUIDs(
                    dbURL: resolved.database,
                    guids: Set(iMessageByGUID.keys)
                )
                for (guid, handle) in guidToHandle {
                    guard let item = iMessageByGUID[guid] else { continue }
                    let hint = buildHandleHint(handle: handle, displayName: nil, isVerified: false)
                    item.participantHints = mergeHandleHint(into: item.participantHints, new: hint)
                    updated += 1
                }
            } catch {
                logger.error("iMessage back-fill failed: \(error)")
            }
        }

        // Call history back-fill
        if !callBySourceUID.isEmpty, let resolved = bookmarkManager.resolveCallHistoryURL() {
            let dir = resolved.directory
            if dir.startAccessingSecurityScopedResource() {
                defer { bookmarkManager.stopAccessing(dir) }
                do {
                    let uidToAddress = try await CallHistoryService.shared.fetchAddressesForSourceUIDs(
                        dbURL: resolved.database,
                        sourceUIDs: Set(callBySourceUID.keys)
                    )
                    for (uid, address) in uidToAddress {
                        guard let item = callBySourceUID[uid] else { continue }
                        let hint = buildHandleHint(handle: address, displayName: nil, isVerified: false)
                        item.participantHints = mergeHandleHint(into: item.participantHints, new: hint)
                        updated += 1
                    }
                } catch {
                    logger.error("Call back-fill failed: \(error)")
                }
            } else {
                logger.warning("Back-fill: could not access CallHistory directory")
            }
        }

        // WhatsApp back-fill (messages + calls share one bookmark)
        if (!waMessageByStanzaID.isEmpty || !waCallByCallID.isEmpty),
           let resolved = bookmarkManager.resolveWhatsAppURL() {
            let dir = resolved.directory
            if dir.startAccessingSecurityScopedResource() {
                defer { bookmarkManager.stopAccessing(dir) }

                if !waMessageByStanzaID.isEmpty {
                    do {
                        let stanzaToJID = try await WhatsAppService.shared.fetchJIDsForStanzaIDs(
                            dbURL: resolved.messagesDB,
                            stanzaIDs: Set(waMessageByStanzaID.keys)
                        )
                        for (stanza, jid) in stanzaToJID {
                            guard let item = waMessageByStanzaID[stanza] else { continue }
                            let phone = whatsAppJIDToPhone(jid)
                            let hint = buildHandleHint(handle: phone, displayName: nil, isVerified: false)
                            item.participantHints = mergeHandleHint(into: item.participantHints, new: hint)
                            updated += 1
                        }
                    } catch {
                        logger.error("WhatsApp message back-fill failed: \(error)")
                    }
                }

                if !waCallByCallID.isEmpty {
                    do {
                        let callToJIDs = try await WhatsAppService.shared.fetchJIDsForCallIDs(
                            dbURL: resolved.callsDB,
                            callIDStrings: Set(waCallByCallID.keys)
                        )
                        for (callID, jids) in callToJIDs {
                            guard let item = waCallByCallID[callID] else { continue }
                            var hints = item.participantHints
                            for jid in jids {
                                let phone = whatsAppJIDToPhone(jid)
                                let hint = buildHandleHint(handle: phone, displayName: nil, isVerified: false)
                                hints = mergeHandleHint(into: hints, new: hint)
                            }
                            item.participantHints = hints
                            updated += 1
                        }
                    } catch {
                        logger.error("WhatsApp call back-fill failed: \(error)")
                    }
                }
            } else {
                logger.warning("Back-fill: could not access WhatsApp directory")
            }
        }

        if updated > 0 {
            try context.save()
            logger.info("Back-filled rawPhone hints on \(updated) evidence items")
        }

        // Now re-run participant resolution so phone hints get matched to people.
        try await refreshParticipantResolution()

        return updated
    }

    /// Merge a new handle hint into an existing hints array, deduplicating by
    /// (rawEmail, rawPhone). Avoids duplicate hints when an evidence item is
    /// processed twice (e.g., multi-participant calls).
    private func mergeHandleHint(into hints: [ParticipantHint], new: ParticipantHint) -> [ParticipantHint] {
        var result = hints
        let duplicate = result.contains { existing in
            (existing.rawEmail?.lowercased() == new.rawEmail?.lowercased() && new.rawEmail != nil)
                || (canonicalizePhone(existing.rawPhone) == canonicalizePhone(new.rawPhone) && new.rawPhone != nil)
        }
        if !duplicate {
            result.append(new)
        }
        return result
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

    // MARK: - Communication Recency Check

    /// Check whether a person has communicated since a given date.
    /// Used by sequence trigger evaluation to detect responses.
    func hasRecentCommunication(fromPersonID personID: UUID, since date: Date) -> Bool {
        guard let context = context else { return false }

        do {
            let descriptor = FetchDescriptor<SamEvidenceItem>(
                sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
            )
            let allItems = try context.fetch(descriptor)

            return allItems.contains { item in
                let isCommunication = item.source == .iMessage
                    || item.source == .mail
                    || item.source == .phoneCall
                    || item.source == .faceTime
                    || item.source == .whatsApp
                    || item.source == .whatsAppCall
                guard isCommunication else { return false }
                guard item.occurredAt > date else { return false }
                return item.linkedPeople.contains { $0.id == personID }
            }
        } catch {
            logger.error("hasRecentCommunication check failed: \(error)")
            return false
        }
    }

    // MARK: - Email Bulk Upsert Operations

    /// Bulk upsert email evidence items with optional analysis data.
    /// - Parameter direction: Communication direction for all emails in this batch.
    ///   Defaults to `.inbound` (Inbox). Pass `.outbound` for Sent mailbox emails.
    func bulkUpsertEmails(_ emails: [(EmailDTO, EmailAnalysisDTO?)], direction: CommunicationDirection = .inbound) throws {
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
                existing.direction = direction
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
                evidence.direction = direction
                setLinkedPeople(resolved, on: evidence)
                context.insert(evidence)
                created += 1
            }
        }

        try context.save()
        logger.debug("Mail bulk upsert: \(created) created, \(updated) updated")
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
            let handleHint = buildHandleHint(
                handle: message.handleID,
                displayName: resolved.first?.displayNameCache ?? resolved.first?.displayName,
                isVerified: !resolved.isEmpty
            )

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

            let msgDirection: CommunicationDirection = message.isFromMe ? .outbound : .inbound

            if let existing = try fetch(sourceUID: sourceUID) {
                existing.snippet = snippet
                existing.bodyText = nil
                existing.occurredAt = message.date
                existing.isFromMe = message.isFromMe
                existing.direction = msgDirection
                existing.participantHints = [handleHint]
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
                evidence.isFromMe = message.isFromMe
                evidence.direction = msgDirection
                evidence.participantHints = [handleHint]
                setLinkedPeople(resolved, on: evidence)
                context.insert(evidence)
                created += 1
            }
        }

        try context.save()
        logger.debug("iMessage bulk upsert: \(created) created, \(updated) updated")
    }

    // MARK: - Post-Hoc Analysis Patching

    /// Update an already-persisted email evidence item with LLM analysis results.
    /// Used by the background analysis task after `.success` is set.
    func updateEmailAnalysis(sourceUID: String, analysis: EmailAnalysisDTO) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        guard let existing = try fetch(sourceUID: sourceUID) else {
            logger.debug("updateEmailAnalysis: no evidence found for \(sourceUID)")
            return
        }

        existing.snippet = analysis.summary

        var signals: [EvidenceSignal] = []
        for event in analysis.temporalEvents {
            signals.append(EvidenceSignal(
                type: .lifeEvent,
                message: "\(event.description): \(event.dateString)",
                confidence: event.confidence
            ))
        }
        for entity in analysis.namedEntities where entity.kind == .financialInstrument {
            signals.append(EvidenceSignal(
                type: .financialEvent,
                message: "Product mentioned: \(entity.name)",
                confidence: entity.confidence
            ))
        }
        for rsvp in analysis.rsvpDetections {
            signals.append(EvidenceSignal(
                type: .eventRSVP,
                message: "RSVP \(rsvp.detectedStatus.rawValue): \(rsvp.responseText)",
                confidence: rsvp.confidence
            ))
        }
        existing.signals = signals
        existing.sentimentRaw = EvidenceSentiment(rawValue: analysis.sentiment.rawValue)?.rawValue

        try context.save()

        // Notify EventCoordinator of RSVP signals for matching
        #if canImport(AppKit)
        if !analysis.rsvpDetections.isEmpty {
            Task { @MainActor in
                RSVPMatchingService.shared.processDetections(
                    analysis.rsvpDetections,
                    fromEvidence: existing
                )
            }
        }
        #endif
    }

    /// Update an already-persisted iMessage/WhatsApp evidence item with LLM analysis results.
    /// Used by the background analysis task after `.success` is set.
    func updateMessageAnalysis(sourceUID: String, analysis: MessageAnalysisDTO) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        guard let existing = try fetch(sourceUID: sourceUID) else {
            logger.debug("updateMessageAnalysis: no evidence found for \(sourceUID)")
            return
        }

        existing.snippet = analysis.summary

        var signals: [EvidenceSignal] = []
        for event in analysis.temporalEvents {
            signals.append(EvidenceSignal(
                type: .lifeEvent,
                message: "\(event.description): \(event.dateString)",
                confidence: event.confidence
            ))
        }
        for rsvp in analysis.rsvpDetections {
            signals.append(EvidenceSignal(
                type: .eventRSVP,
                message: "RSVP \(rsvp.detectedStatus.rawValue): \(rsvp.responseText)",
                confidence: rsvp.confidence
            ))
        }
        existing.signals = signals
        existing.sentimentRaw = EvidenceSentiment(rawValue: analysis.sentiment.rawValue)?.rawValue

        try context.save()

        // Notify EventCoordinator of RSVP signals for matching
        #if canImport(AppKit)
        if !analysis.rsvpDetections.isEmpty {
            Task { @MainActor in
                RSVPMatchingService.shared.processDetections(
                    analysis.rsvpDetections,
                    fromEvidence: existing
                )
            }
        }
        #endif
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
            let handleHint = buildHandleHint(
                handle: call.address,
                displayName: personName,
                isVerified: !resolved.isEmpty
            )

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
            let callDirection: CommunicationDirection = call.isOutgoing ? .outbound : .inbound

            if let existing = try fetch(sourceUID: sourceUID) {
                existing.title = title
                existing.snippet = snippet
                existing.occurredAt = call.date
                existing.endedAt = endedAt
                existing.direction = callDirection
                existing.participantHints = [handleHint]
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
                evidence.direction = callDirection
                evidence.participantHints = [handleHint]
                setLinkedPeople(resolved, on: evidence)
                context.insert(evidence)
                created += 1
            }
        }

        try context.save()
        logger.debug("Call record bulk upsert: \(created) created, \(updated) updated")
    }

    // MARK: - WhatsApp Bulk Upsert

    /// Bulk upsert WhatsApp message evidence items with optional analysis data.
    /// Privacy: bodyText is NEVER stored — only the AI summary goes into snippet.
    func bulkUpsertWhatsAppMessages(_ messages: [(WhatsAppMessageDTO, MessageAnalysisDTO?)]) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        var created = 0, updated = 0

        for (message, analysis) in messages {
            let sourceUID = "whatsapp:\(message.stanzaID)"

            // Resolve people by phone extracted from JID
            let phone = whatsAppJIDToPhone(message.contactJID)
            let resolved = resolvePeople(byPhones: [phone])
            let handleHint = buildHandleHint(
                handle: phone,
                displayName: resolved.first?.displayNameCache ?? resolved.first?.displayName ?? message.partnerName,
                isVerified: !resolved.isEmpty
            )

            // Build snippet: use analysis summary if available, otherwise truncated text
            let snippet: String
            if let summary = analysis?.summary {
                snippet = summary
            } else if let text = message.text {
                snippet = String(text.prefix(200))
            } else {
                snippet = messageTypeLabel(message.messageType)
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

            let waDirection: CommunicationDirection = message.isFromMe ? .outbound : .inbound

            if let existing = try fetch(sourceUID: sourceUID) {
                existing.snippet = snippet
                existing.bodyText = nil
                existing.occurredAt = message.date
                existing.isFromMe = message.isFromMe
                existing.direction = waDirection
                existing.participantHints = [handleHint]
                setLinkedPeople(resolved, on: existing)
                existing.signals = signals
                updated += 1
            } else {
                let title: String
                if let name = resolved.first?.displayNameCache ?? resolved.first?.displayName {
                    title = message.isFromMe ? "WhatsApp to \(name)" : "WhatsApp from \(name)"
                } else if let partnerName = message.partnerName {
                    title = message.isFromMe ? "WhatsApp to \(partnerName)" : "WhatsApp from \(partnerName)"
                } else {
                    title = message.isFromMe ? "WhatsApp sent" : "WhatsApp received"
                }

                let evidence = SamEvidenceItem(
                    id: UUID(),
                    state: .needsReview,
                    sourceUID: sourceUID,
                    source: .whatsApp,
                    occurredAt: message.date,
                    title: title,
                    snippet: snippet,
                    signals: signals
                )
                evidence.isFromMe = message.isFromMe
                evidence.direction = waDirection
                evidence.participantHints = [handleHint]
                setLinkedPeople(resolved, on: evidence)
                context.insert(evidence)
                created += 1
            }
        }

        try context.save()
        logger.debug("WhatsApp message bulk upsert: \(created) created, \(updated) updated")
    }

    /// Bulk upsert WhatsApp call evidence items (metadata only, no LLM analysis).
    func bulkUpsertWhatsAppCalls(_ calls: [WhatsAppCallDTO]) throws {
        guard let context = context else { throw RepositoryError.notConfigured }

        var created = 0, updated = 0

        for call in calls {
            let sourceUID = "whatsappcall:\(call.callIDString)"

            // Resolve people by phone from participant JIDs
            let phones = call.participantJIDs.map { whatsAppJIDToPhone($0) }
            let resolved = resolvePeople(byPhones: phones)
            let personName = resolved.first?.displayNameCache ?? resolved.first?.displayName
            let handleHints: [ParticipantHint] = phones.enumerated().map { idx, phone in
                let matched = idx < resolved.count ? resolved[idx] : nil
                let name = matched?.displayNameCache ?? matched?.displayName
                return buildHandleHint(handle: phone, displayName: name, isVerified: matched != nil)
            }

            let wasAnswered = call.outcome == 0

            // Build title
            let title: String
            if !wasAnswered {
                title = personName.map { "Missed WhatsApp call from \($0)" } ?? "Missed WhatsApp call"
            } else {
                title = personName.map { "WhatsApp call with \($0)" } ?? "WhatsApp call"
            }

            // Build snippet
            let snippet: String
            if !wasAnswered {
                snippet = "Missed"
            } else {
                let minutes = Int(call.duration) / 60
                let seconds = Int(call.duration) % 60
                if minutes > 0 {
                    snippet = "\(minutes)m \(seconds)s"
                } else {
                    snippet = "\(seconds)s"
                }
            }

            let endedAt = wasAnswered ? call.date.addingTimeInterval(call.duration) : nil
            // WhatsApp calls: missed = inbound; answered = bidirectional (mutual participation)
            let waCallDirection: CommunicationDirection = wasAnswered ? .bidirectional : .inbound

            if let existing = try fetch(sourceUID: sourceUID) {
                existing.title = title
                existing.snippet = snippet
                existing.occurredAt = call.date
                existing.endedAt = endedAt
                existing.direction = waCallDirection
                existing.participantHints = handleHints
                setLinkedPeople(resolved, on: existing)
                updated += 1
            } else {
                let evidence = SamEvidenceItem(
                    id: UUID(),
                    state: .needsReview,
                    sourceUID: sourceUID,
                    source: .whatsAppCall,
                    occurredAt: call.date,
                    endedAt: endedAt,
                    title: title,
                    snippet: snippet
                )
                evidence.direction = waCallDirection
                evidence.participantHints = handleHints
                setLinkedPeople(resolved, on: evidence)
                context.insert(evidence)
                created += 1
            }
        }

        try context.save()
        logger.debug("WhatsApp call bulk upsert: \(created) created, \(updated) updated")
    }

    /// Convert a WhatsApp JID to canonicalized phone (last 10 digits).
    private func whatsAppJIDToPhone(_ jid: String) -> String {
        let local = jid.split(separator: "@").first.map(String.init) ?? jid
        let digits = local.filter(\.isNumber)
        guard digits.count >= 7 else { return jid.lowercased() }
        return String(digits.suffix(10))
    }

    /// Human-readable label for WhatsApp message types when text is nil.
    private func messageTypeLabel(_ type: Int) -> String {
        switch type {
        case 1: return "[Image]"
        case 2: return "[Video]"
        case 3: return "[Voice message]"
        case 4: return "[Contact]"
        case 5: return "[Location]"
        case 8: return "[Document]"
        case 15: return "[Sticker]"
        default: return "[Media]"
        }
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
            logger.debug("Pruned \(deleted) orphaned mail evidence items")
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
