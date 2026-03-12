//
//  PeopleRepository.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//
//  SwiftData CRUD operations for SamPerson.
//  No direct CNContact access - receives DTOs from ContactsService.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PeopleRepository")

@MainActor
@Observable
final class PeopleRepository {

    private func canonicalizeEmail(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else { return nil }
        return email.lowercased()
    }

    private func canonicalizePhone(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    // MARK: - Singleton

    static let shared = PeopleRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var modelContext: ModelContext?

    private init() {}

    /// Configure the repository with the app-wide ModelContainer.
    /// Must be called once at app launch before any operations.
    func configure(container: ModelContainer) {
        self.container = container
        self.modelContext = ModelContext(container)
    }

    // MARK: - CRUD Operations

    /// Fetch all people from SwiftData
    func fetchAll() throws -> [SamPerson] {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamPerson>(
            sortBy: [SortDescriptor(\.displayNameCache, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }

    /// Fetch a single person by UUID
    func fetch(id: UUID) throws -> SamPerson? {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Swift 6: Can't capture id in predicate, so fetch all and filter
        let descriptor = FetchDescriptor<SamPerson>()

        let allPeople = try modelContext.fetch(descriptor)
        return allPeople.first { $0.id == id }
    }

    /// Fetch a person by contact identifier
    func fetch(contactIdentifier: String) throws -> SamPerson? {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Swift 6: Can't capture contactIdentifier in predicate, so fetch all and filter
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )

        let allPeople = try modelContext.fetch(descriptor)
        return allPeople.first { $0.contactIdentifier == contactIdentifier }
    }

    /// Link an existing SamPerson to an Apple Contact (by contactIdentifier) and update cache fields.
    /// Use this when a SamPerson already exists (e.g. from social import or triage) and the user
    /// confirms which Apple Contact it should be linked to — avoids creating a duplicate SamPerson.
    func linkPerson(_ person: SamPerson, toContact contact: ContactDTO) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let canonicalEmails = contact.emailAddresses.compactMap { canonicalizeEmail($0) }
        let primaryEmail = canonicalEmails.first
        let canonicalPhones = contact.phoneNumbers.compactMap { canonicalizePhone($0.number) }

        person.contactIdentifier = contact.identifier
        person.displayNameCache = contact.displayName
        person.emailCache = primaryEmail
        person.emailAliases = canonicalEmails
        person.phoneAliases = canonicalPhones
        person.photoThumbnailCache = contact.thumbnailImageData
        person.lastSyncedAt = Date()

        // Update deprecated fields for backward compatibility
        person.displayName = contact.displayName
        person.email = primaryEmail

        try modelContext.save()
    }

    /// Insert a standalone SamPerson without an Apple Contact.
    /// Used when adding unknown senders (e.g., iMessage RSVP) who aren't yet in Contacts.
    @discardableResult
    func insertStandalone(
        displayName: String,
        phone: String? = nil,
        email: String? = nil
    ) throws -> SamPerson {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let person = SamPerson(
            id: UUID(),
            displayName: displayName,
            roleBadges: []
        )
        person.displayNameCache = displayName

        if let phone = phone {
            let canonical = canonicalizePhone(phone)
            person.phoneAliases = canonical.map { [$0] } ?? []
        }
        if let email = canonicalizeEmail(email) {
            person.emailCache = email
            person.emailAliases = [email]
            person.email = email
        }

        modelContext.insert(person)
        try modelContext.save()
        logger.info("Inserted standalone SamPerson '\(displayName)' (no Apple Contact)")
        return person
    }

    /// Upsert a person from a ContactDTO
    /// If person exists (by contactIdentifier), updates cache fields
    /// If person doesn't exist, creates new SamPerson
    func upsert(contact: ContactDTO) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let canonicalEmails = contact.emailAddresses.compactMap { canonicalizeEmail($0) }
        let primaryEmail = canonicalEmails.first
        let canonicalPhones = contact.phoneNumbers.compactMap { canonicalizePhone($0.number) }

        // Swift 6: Can't capture contact.identifier in predicate, so fetch all and filter
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )

        let allPeople = try modelContext.fetch(descriptor)
        let existing = allPeople.first { $0.contactIdentifier == contact.identifier }

        if let existing = existing {
            // Update existing person's cache
            existing.displayNameCache = contact.displayName
            existing.emailCache = primaryEmail
            existing.emailAliases = canonicalEmails
            existing.phoneAliases = canonicalPhones
            existing.photoThumbnailCache = contact.thumbnailImageData
            existing.lastSyncedAt = Date()
            // Reactivate only if previously archived (contact reappeared).
            // Don't override DNC or deceased — those are intentional user choices.
            if existing.lifecycleStatus == .archived {
                existing.lifecycleStatus = .active
            }

            // Update deprecated fields for backward compatibility
            existing.displayName = contact.displayName
            existing.email = primaryEmail
        } else {
            // Create new person
            let person = SamPerson(
                id: UUID(),
                displayName: contact.displayName,
                roleBadges: [],  // Empty by default, user can add later
                contactIdentifier: contact.identifier,
                email: primaryEmail
            )

            // Set cache fields
            person.displayNameCache = contact.displayName
            person.emailCache = primaryEmail
            person.emailAliases = canonicalEmails
            person.phoneAliases = canonicalPhones
            person.photoThumbnailCache = contact.thumbnailImageData
            person.lastSyncedAt = Date()

            modelContext.insert(person)
        }

        try modelContext.save()
    }

    /// Create or update a standalone SamPerson from a social platform import (Facebook, LinkedIn).
    /// Unlike `upsert(contact:)`, this does NOT require or create an Apple Contact.
    /// Returns the SamPerson ID for further enrichment.
    @discardableResult
    func upsertFromSocialImport(
        displayName: String,
        linkedInProfileURL: String? = nil,
        linkedInConnectedOn: Date? = nil,
        linkedInEmail: String? = nil,
        facebookFriendedOn: Date? = nil,
        facebookMessageCount: Int = 0,
        facebookLastMessageDate: Date? = nil,
        facebookTouchScore: Int = 0
    ) throws -> UUID {
        guard let modelContext else { throw RepositoryError.notConfigured }

        // Search for existing SamPerson by name (case-insensitive), LinkedIn URL, or email
        let allPeople = try modelContext.fetch(FetchDescriptor<SamPerson>())
        let normalizedName = displayName.lowercased().trimmingCharacters(in: .whitespaces)

        let existing = allPeople.first { person in
            // Match by LinkedIn profile URL
            if let url = linkedInProfileURL, !url.isEmpty,
               let existingURL = person.linkedInProfileURL, !existingURL.isEmpty {
                if existingURL.lowercased().contains(url.lowercased()) ||
                   url.lowercased().contains(existingURL.lowercased()) {
                    return true
                }
            }
            // Match by email
            if let email = linkedInEmail, !email.isEmpty {
                if person.emailAliases.contains(where: { $0.lowercased() == email.lowercased() }) {
                    return true
                }
            }
            // Match by exact display name
            let personName = (person.displayNameCache ?? person.displayName).lowercased()
                .trimmingCharacters(in: .whitespaces)
            return personName == normalizedName
        }

        if let person = existing {
            // Enrich existing person
            if let url = linkedInProfileURL, !url.isEmpty, person.linkedInProfileURL == nil {
                person.linkedInProfileURL = url
            }
            if let date = linkedInConnectedOn, person.linkedInConnectedOn == nil {
                person.linkedInConnectedOn = date
            }
            if let date = facebookFriendedOn, person.facebookFriendedOn == nil {
                person.facebookFriendedOn = date
            }
            if facebookMessageCount > 0 {
                person.facebookMessageCount = facebookMessageCount
            }
            if let date = facebookLastMessageDate {
                person.facebookLastMessageDate = date
            }
            if facebookTouchScore > 0 {
                person.facebookTouchScore = facebookTouchScore
            }
            if let email = linkedInEmail, !email.isEmpty, person.emailCache == nil {
                person.emailCache = canonicalizeEmail(email)
                person.email = canonicalizeEmail(email)
                if !person.emailAliases.contains(where: { $0.lowercased() == email.lowercased() }) {
                    person.emailAliases.append(canonicalizeEmail(email) ?? email.lowercased())
                }
            }
            person.lastSyncedAt = Date()
            try modelContext.save()
            return person.id
        } else {
            // Create new standalone SamPerson (no Apple Contact link)
            let person = SamPerson(
                id: UUID(),
                displayName: displayName,
                roleBadges: [],
                contactIdentifier: nil,
                email: linkedInEmail.flatMap { canonicalizeEmail($0) }
            )
            person.displayNameCache = displayName
            person.emailCache = linkedInEmail.flatMap { canonicalizeEmail($0) }
            if let email = linkedInEmail {
                person.emailAliases = [canonicalizeEmail(email) ?? email.lowercased()]
            }
            person.linkedInProfileURL = linkedInProfileURL
            person.linkedInConnectedOn = linkedInConnectedOn
            person.facebookFriendedOn = facebookFriendedOn
            person.facebookMessageCount = facebookMessageCount
            person.facebookLastMessageDate = facebookLastMessageDate
            person.facebookTouchScore = facebookTouchScore
            person.lastSyncedAt = Date()

            modelContext.insert(person)
            try modelContext.save()
            return person.id
        }
    }

    /// Bulk upsert contacts (more efficient for importing many contacts)
    func bulkUpsert(contacts: [ContactDTO]) throws -> (created: Int, updated: Int) {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        var created = 0
        var updated = 0

        // Fetch all existing people with contactIdentifiers
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        let existingPeople = try modelContext.fetch(descriptor)

        // Create lookup dictionary for fast matching
        let existingByIdentifier = Dictionary(
            uniqueKeysWithValues: existingPeople.compactMap { person in
                person.contactIdentifier.map { ($0, person) }
            }
        )

        // Process each contact
        for contact in contacts {
            let canonicalEmails = contact.emailAddresses.compactMap { canonicalizeEmail($0) }
            let primaryEmail = canonicalEmails.first
            let canonicalPhones = contact.phoneNumbers.compactMap { canonicalizePhone($0.number) }

            if let existing = existingByIdentifier[contact.identifier] {
                // Update existing
                existing.displayNameCache = contact.displayName
                existing.emailCache = primaryEmail
                existing.emailAliases = canonicalEmails
                existing.phoneAliases = canonicalPhones
                existing.photoThumbnailCache = contact.thumbnailImageData
                existing.lastSyncedAt = Date()
                // Reactivate only if archived (contact reappeared)
                if existing.lifecycleStatus == .archived {
                    existing.lifecycleStatus = .active
                }

                // Update deprecated fields
                existing.displayName = contact.displayName
                existing.email = primaryEmail

                updated += 1
            } else {
                // Create new
                let person = SamPerson(
                    id: UUID(),
                    displayName: contact.displayName,
                    roleBadges: [],  // Empty by default, user can add later
                    contactIdentifier: contact.identifier,
                    email: primaryEmail
                )

                person.displayNameCache = contact.displayName
                person.emailCache = primaryEmail
                person.emailAliases = canonicalEmails
                person.phoneAliases = canonicalPhones
                person.photoThumbnailCache = contact.thumbnailImageData
                person.lastSyncedAt = Date()

                modelContext.insert(person)
                created += 1
            }
        }

        try modelContext.save()
        logger.info("Bulk upsert complete: \(created) created, \(updated) updated")

        return (created, updated)
    }

    /// Delete a person
    func delete(person: SamPerson) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        modelContext.delete(person)
        try modelContext.save()
    }

    /// Search people by name
    func search(query: String) throws -> [SamPerson] {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        guard !query.isEmpty else {
            return try fetchAll()
        }

        // Fetch all and filter in memory (simpler than complex predicate)
        let descriptor = FetchDescriptor<SamPerson>(
            sortBy: [SortDescriptor(\.displayNameCache, order: .forward)]
        )

        let allPeople = try modelContext.fetch(descriptor)
        let lowercaseQuery = query.lowercased()

        return allPeople.filter { person in
            let nameToSearch = person.displayNameCache ?? person.displayName
            return nameToSearch.lowercased().contains(lowercaseQuery)
        }
    }

    // MARK: - Me Contact

    /// Fetch the person marked as the user's "Me" contact
    func fetchMe() throws -> SamPerson? {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.isMe == true }
        )
        return try modelContext.fetch(descriptor).first
    }

    /// Set the isMe flag on a person identified by contactIdentifier.
    /// Called when the Me contact was already imported via bulkUpsert (same identifier).
    func setMeFlag(contactIdentifier: String) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Clear any existing Me flags first
        let meDescriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.isMe == true }
        )
        for existing in try modelContext.fetch(meDescriptor) {
            existing.isMe = false
        }

        // Find the person by contactIdentifier and set isMe
        let allDescriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        let allPeople = try modelContext.fetch(allDescriptor)
        if let match = allPeople.first(where: { $0.contactIdentifier == contactIdentifier }) {
            match.isMe = true
            try modelContext.save()
            logger.info("Set isMe flag on existing person: \(match.displayNameCache ?? match.displayName, privacy: .public)")
        }
    }

    /// Upsert the Me contact, ensuring only one person has isMe = true.
    /// Matches by contactIdentifier first, then falls back to name+email matching
    /// (the "Me" card can return a different unified identifier than the same person
    /// fetched through a group).
    func upsertMe(contact: ContactDTO) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let canonicalEmails = contact.emailAddresses.compactMap { canonicalizeEmail($0) }
        let primaryEmail = canonicalEmails.first
        let canonicalPhones = contact.phoneNumbers.compactMap { canonicalizePhone($0.number) }

        // Clear any existing Me flags first
        let meDescriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.isMe == true }
        )
        for existing in try modelContext.fetch(meDescriptor) {
            existing.isMe = false
        }

        // Find existing person — first by contactIdentifier, then by name+email fallback
        let allDescriptor = FetchDescriptor<SamPerson>()
        let allPeople = try modelContext.fetch(allDescriptor)

        let existing: SamPerson? = {
            // 1. Exact contactIdentifier match
            if let match = allPeople.first(where: { $0.contactIdentifier == contact.identifier }) {
                return match
            }
            // 2. Name + email fallback (handles different unified identifiers for same person)
            let meEmails = Set(canonicalEmails)
            let meName = contact.displayName.lowercased()
            if !meEmails.isEmpty {
                if let match = allPeople.first(where: { person in
                    let nameMatch = (person.displayNameCache ?? person.displayName).lowercased() == meName
                    let emailMatch = !person.emailAliases.filter({ meEmails.contains($0) }).isEmpty
                    return nameMatch && emailMatch
                }) {
                    return match
                }
            }
            return nil
        }()

        let person: SamPerson
        if let existing {
            existing.displayNameCache = contact.displayName
            existing.emailCache = primaryEmail
            existing.emailAliases = canonicalEmails
            existing.phoneAliases = canonicalPhones
            existing.photoThumbnailCache = contact.thumbnailImageData
            existing.lastSyncedAt = Date()
            if existing.lifecycleStatus == .archived {
                existing.lifecycleStatus = .active
            }
            existing.isMe = true
            // Update contactIdentifier if it was a fallback match (different unified ID)
            if existing.contactIdentifier != contact.identifier {
                logger.info("Me contact identifier updated: \(existing.contactIdentifier ?? "nil") → \(contact.identifier)")
                existing.contactIdentifier = contact.identifier
            }
            existing.displayName = contact.displayName
            existing.email = primaryEmail
            person = existing
        } else {
            let newPerson = SamPerson(
                id: UUID(),
                displayName: contact.displayName,
                roleBadges: [],
                contactIdentifier: contact.identifier,
                email: primaryEmail,
                isMe: true
            )
            newPerson.displayNameCache = contact.displayName
            newPerson.emailCache = primaryEmail
            newPerson.emailAliases = canonicalEmails
            newPerson.phoneAliases = canonicalPhones
            newPerson.photoThumbnailCache = contact.thumbnailImageData
            newPerson.lastSyncedAt = Date()

            modelContext.insert(newPerson)
            person = newPerson
        }

        try modelContext.save()
        logger.info("Upserted Me contact: \(person.displayNameCache ?? person.displayName, privacy: .public)")
    }

    /// Clear stale contactIdentifiers for people whose Apple Contact no longer exists.
    /// Called during contacts sync to detect deleted contacts.
    /// Returns the number of identifiers cleared.
    @discardableResult
    func clearStaleContactIdentifiers(validIdentifiers: Set<String>) throws -> Int {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        let peopleWithContacts = try modelContext.fetch(descriptor)

        var clearedCount = 0
        for person in peopleWithContacts {
            guard let identifier = person.contactIdentifier else { continue }
            if !validIdentifiers.contains(identifier) {
                person.contactIdentifier = nil
                clearedCount += 1
                logger.info("Cleared stale contactIdentifier for \(person.displayNameCache ?? person.displayName, privacy: .public)")
            }
        }

        if clearedCount > 0 {
            try modelContext.save()
        }

        return clearedCount
    }

    /// Nil out contactIdentifier for SamPerson records whose contact is not in the SAM group.
    /// Skips the "Me" contact. Returns count of unlinked records.
    @discardableResult
    func unlinkNonGroupContacts(groupIdentifiers: Set<String>) throws -> Int {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil && $0.isMe == false }
        )
        let peopleWithContacts = try modelContext.fetch(descriptor)

        var unlinkedCount = 0
        for person in peopleWithContacts {
            guard let identifier = person.contactIdentifier else { continue }
            if !groupIdentifiers.contains(identifier) {
                person.contactIdentifier = nil
                unlinkedCount += 1
                logger.info("Unlinked non-group contact for \(person.displayNameCache ?? person.displayName, privacy: .public)")
            }
        }

        if unlinkedCount > 0 {
            try modelContext.save()
        }

        return unlinkedCount
    }

    /// Collect all known email addresses across all SamPerson records.
    /// Returns a Set of lowercased, trimmed emails for fast O(1) lookup.
    func allKnownEmails() throws -> Set<String> {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamPerson>()
        let allPeople = try modelContext.fetch(descriptor)

        var emails = Set<String>()
        for person in allPeople {
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

    /// Collect all known phone numbers across all SamPerson records.
    /// Returns a Set of canonicalized phone numbers (last 10 digits) for fast O(1) lookup.
    func allKnownPhones() throws -> Set<String> {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamPerson>()
        let allPeople = try modelContext.fetch(descriptor)

        var phones = Set<String>()
        for person in allPeople {
            for alias in person.phoneAliases {
                if let canonical = canonicalizePhone(alias) {
                    phones.insert(canonical)
                }
            }
        }
        return phones
    }

    /// Bulk-update LinkedIn profile data on matching people.
    /// Matches by email first, then full display name.
    /// Returns the number of records updated.
    @discardableResult
    func updateLinkedInData(
        profileURL: String,
        connectedOn: Date?,
        email: String?,
        fullName: String
    ) throws -> Bool {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamPerson>()
        let allPeople = try modelContext.fetch(descriptor)

        let normalizedURL  = profileURL.lowercased()
        let normalizedName = fullName.lowercased().trimmingCharacters(in: .whitespaces)
        let normalizedEmail = email?.lowercased()

        // 1. Exact LinkedIn URL match
        if let match = allPeople.first(where: { ($0.linkedInProfileURL ?? "").lowercased() == normalizedURL && !normalizedURL.isEmpty }) {
            applyLinkedIn(match, profileURL: profileURL, connectedOn: connectedOn)
            try modelContext.save()
            return true
        }

        // 2. Email match
        if let em = normalizedEmail, !em.isEmpty {
            let emailMatch = allPeople.first { p in
                p.emailCache?.lowercased() == em || p.emailAliases.contains { $0.lowercased() == em }
            }
            if let match = emailMatch {
                applyLinkedIn(match, profileURL: profileURL, connectedOn: connectedOn)
                try modelContext.save()
                return true
            }
        }

        // 3. Full name match
        if !normalizedName.isEmpty {
            let nameMatch = allPeople.first {
                ($0.displayNameCache ?? $0.displayName).lowercased() == normalizedName
            }
            if let match = nameMatch {
                applyLinkedIn(match, profileURL: profileURL, connectedOn: connectedOn)
                try modelContext.save()
                return true
            }
        }

        return false
    }

    private func applyLinkedIn(_ person: SamPerson, profileURL: String, connectedOn: Date?) {
        if person.linkedInProfileURL != profileURL {
            person.linkedInProfileURL = profileURL
        }
        if let date = connectedOn, person.linkedInConnectedOn == nil {
            person.linkedInConnectedOn = date
        }
    }

    /// Persist any pending changes to the model context.
    func save() throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        try modelContext.save()
    }

    // MARK: - Lifecycle Management

    /// Set the contact lifecycle status for a person.
    func setLifecycleStatus(_ status: ContactLifecycleStatus, for person: SamPerson) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        person.lifecycleStatus = status
        try modelContext.save()
    }

    /// Set the LinkedIn profile URL on a SamPerson by their Apple Contact identifier.
    /// Used after promoting an unknown LinkedIn contact from the triage screen.
    func setLinkedInProfileURL(contactIdentifier: String, profileURL: String) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<SamPerson>()
        let all = try modelContext.fetch(descriptor)
        guard let person = all.first(where: { $0.contactIdentifier == contactIdentifier }) else {
            return
        }
        if person.linkedInProfileURL != profileURL {
            person.linkedInProfileURL = profileURL
            try modelContext.save()
        }
    }

    // MARK: - Person Merge

    /// Merge source person into target person: transfer all relationships,
    /// merge scalar fields (target wins), update external references, delete source.
    /// Returns a snapshot for undo support.
    func mergePerson(sourceID: UUID, targetID: UUID) throws -> PersonMergeSnapshot {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let allPeople = try modelContext.fetch(FetchDescriptor<SamPerson>())
        guard let source = allPeople.first(where: { $0.id == sourceID }) else {
            throw RepositoryError.personNotFound
        }
        guard let target = allPeople.first(where: { $0.id == targetID }) else {
            throw RepositoryError.personNotFound
        }

        // ── Capture IDs for undo before transfer ─────────────────────
        let evidenceIDs = source.linkedEvidence.map(\.id)
        let noteIDs = source.linkedNotes.map(\.id)
        let participationIDs = source.participations.map(\.id)
        let insightIDs = source.insights.map(\.id)
        let transitionIDs = source.stageTransitions.map(\.id)
        let recruitingStageIDs = source.recruitingStages.map(\.id)
        let productionRecordIDs = source.productionRecords.map(\.id)

        // ── Transfer linkedEvidence (skip duplicates) ────────────────
        let targetEvidenceIDs = Set(target.linkedEvidence.map(\.id))
        for item in source.linkedEvidence where !targetEvidenceIDs.contains(item.id) {
            target.linkedEvidence.append(item)
        }

        // ── Transfer linkedNotes (skip duplicates) ───────────────────
        let targetNoteIDs = Set(target.linkedNotes.map(\.id))
        for note in source.linkedNotes where !targetNoteIDs.contains(note.id) {
            target.linkedNotes.append(note)
        }

        // ── Transfer participations (skip if target already in same context)
        let targetContextIDs = Set(target.participations.compactMap { $0.context?.id })
        for participation in source.participations {
            if let ctxID = participation.context?.id, !targetContextIDs.contains(ctxID) {
                participation.person = target
            }
        }

        // ── Re-point responsibilities ────────────────────────────────
        for resp in source.responsibilitiesAsGuardian {
            resp.guardian = target
        }
        for resp in source.responsibilitiesAsDependent {
            resp.dependent = target
        }

        // ── Transfer jointInterests ──────────────────────────────────
        for interest in source.jointInterests {
            if !target.jointInterests.contains(where: { $0.id == interest.id }) {
                // Replace source with target in the parties
                target.jointInterests.append(interest)
            }
        }

        // ── Re-point coverages ───────────────────────────────────────
        for coverage in source.coverages {
            coverage.person = target
        }

        // ── Re-point consentRequirements ─────────────────────────────
        for consent in source.consentRequirements {
            consent.person = target
        }

        // ── Re-point stageTransitions ────────────────────────────────
        for transition in source.stageTransitions {
            transition.person = target
        }

        // ── Re-point recruitingStages ────────────────────────────────
        for stage in source.recruitingStages {
            stage.person = target
        }

        // ── Re-point productionRecords ───────────────────────────────
        for record in source.productionRecords {
            record.person = target
        }

        // ── Re-point insights ────────────────────────────────────────
        for insight in source.insights {
            insight.samPerson = target
        }

        // ── Transfer referrals ───────────────────────────────────────
        for referral in source.referrals {
            referral.referredBy = target
        }
        if target.referredBy == nil, let sourceReferrer = source.referredBy {
            target.referredBy = sourceReferrer
        }

        // ── Update SamOutcome.linkedPerson ───────────────────────────
        let allOutcomes = try modelContext.fetch(FetchDescriptor<SamOutcome>())
        var outcomeIDs: [UUID] = []
        for outcome in allOutcomes where outcome.linkedPerson?.id == sourceID {
            outcome.linkedPerson = target
            outcomeIDs.append(outcome.id)
        }

        // ── Update DeducedRelation ───────────────────────────────────
        let allDeduced = try modelContext.fetch(FetchDescriptor<DeducedRelation>())
        var deducedRelationIDs: [UUID] = []
        for relation in allDeduced {
            var changed = false
            if relation.personAID == sourceID {
                relation.personAID = targetID
                changed = true
            }
            if relation.personBID == sourceID {
                relation.personBID = targetID
                changed = true
            }
            // If both sides now point to same person, delete the relation
            if relation.personAID == relation.personBID {
                modelContext.delete(relation)
            } else if changed {
                deducedRelationIDs.append(relation.id)
            }
        }

        // Deduplicate DeducedRelation records that now share the same pair+type
        struct DeducedKey: Hashable { let aID: UUID; let bID: UUID; let type: String }
        var seenDeduced = Set<DeducedKey>()
        for relation in allDeduced where relation.modelContext != nil {
            let key = DeducedKey(aID: relation.personAID, bID: relation.personBID, type: relation.relationTypeRawValue)
            if seenDeduced.contains(key) {
                modelContext.delete(relation)
                deducedRelationIDs.removeAll { $0 == relation.id }
            } else {
                seenDeduced.insert(key)
            }
        }

        // ── Update SamNote.extractedMentions ─────────────────────────
        let allNotes = try modelContext.fetch(FetchDescriptor<SamNote>())
        for note in allNotes {
            var updated = false
            var mentions = note.extractedMentions
            for i in mentions.indices {
                if mentions[i].matchedPersonID == sourceID {
                    mentions[i].matchedPersonID = targetID
                    updated = true
                }
            }
            if updated {
                note.extractedMentions = mentions
            }
        }

        // ── Merge scalar fields (fill-gaps: target wins) ─────────────
        let unionedEmails = source.emailAliases.filter { !target.emailAliases.contains($0) }
        target.emailAliases.append(contentsOf: unionedEmails)

        let unionedPhones = source.phoneAliases.filter { !target.phoneAliases.contains($0) }
        target.phoneAliases.append(contentsOf: unionedPhones)

        let unionedRoleBadges = source.roleBadges.filter { !target.roleBadges.contains($0) }
        target.roleBadges.append(contentsOf: unionedRoleBadges)

        if target.contactIdentifier == nil {
            target.contactIdentifier = source.contactIdentifier
        }
        if target.linkedInProfileURL == nil {
            target.linkedInProfileURL = source.linkedInProfileURL
        }
        if target.linkedInConnectedOn == nil {
            target.linkedInConnectedOn = source.linkedInConnectedOn
        }
        if target.facebookProfileURL == nil {
            target.facebookProfileURL = source.facebookProfileURL
        }
        if target.facebookFriendedOn == nil {
            target.facebookFriendedOn = source.facebookFriendedOn
        }
        target.facebookMessageCount = max(target.facebookMessageCount, source.facebookMessageCount)
        if target.facebookLastMessageDate == nil {
            target.facebookLastMessageDate = source.facebookLastMessageDate
        }
        target.facebookTouchScore = max(target.facebookTouchScore, source.facebookTouchScore)

        if (target.relationshipSummary ?? "").isEmpty {
            target.relationshipSummary = source.relationshipSummary
        }
        if target.relationshipKeyThemes.isEmpty {
            target.relationshipKeyThemes = source.relationshipKeyThemes
        }
        if target.relationshipNextSteps.isEmpty {
            target.relationshipNextSteps = source.relationshipNextSteps
        }
        if target.preferredCadenceDays == nil {
            target.preferredCadenceDays = source.preferredCadenceDays
        }
        if target.preferredChannelRawValue == nil {
            target.preferredChannelRawValue = source.preferredChannelRawValue
        }
        if target.preferredQuickChannelRawValue == nil {
            target.preferredQuickChannelRawValue = source.preferredQuickChannelRawValue
        }
        if target.preferredDetailedChannelRawValue == nil {
            target.preferredDetailedChannelRawValue = source.preferredDetailedChannelRawValue
        }
        if target.preferredSocialChannelRawValue == nil {
            target.preferredSocialChannelRawValue = source.preferredSocialChannelRawValue
        }

        // ── Build snapshot before deleting source ────────────────────
        let snapshot = PersonMergeSnapshot(
            sourcePersonID: source.id,
            targetPersonID: target.id,
            sourceDisplayName: source.displayNameCache ?? source.displayName,
            displayName: source.displayName,
            email: source.email,
            displayNameCache: source.displayNameCache,
            emailCache: source.emailCache,
            emailAliases: source.emailAliases,
            phoneAliases: source.phoneAliases,
            roleBadges: source.roleBadges,
            contactIdentifier: source.contactIdentifier,
            isMe: source.isMe,
            isArchived: source.isArchivedLegacy,
            lifecycleStatusRawValue: source.lifecycleStatusRawValue,
            relationshipSummary: source.relationshipSummary,
            relationshipKeyThemes: source.relationshipKeyThemes,
            relationshipNextSteps: source.relationshipNextSteps,
            preferredCadenceDays: source.preferredCadenceDays,
            preferredChannelRawValue: source.preferredChannelRawValue,
            inferredChannelRawValue: source.inferredChannelRawValue,
            preferredQuickChannelRawValue: source.preferredQuickChannelRawValue,
            preferredDetailedChannelRawValue: source.preferredDetailedChannelRawValue,
            preferredSocialChannelRawValue: source.preferredSocialChannelRawValue,
            inferredQuickChannelRawValue: source.inferredQuickChannelRawValue,
            inferredDetailedChannelRawValue: source.inferredDetailedChannelRawValue,
            inferredSocialChannelRawValue: source.inferredSocialChannelRawValue,
            linkedInProfileURL: source.linkedInProfileURL,
            linkedInConnectedOn: source.linkedInConnectedOn,
            facebookProfileURL: source.facebookProfileURL,
            facebookFriendedOn: source.facebookFriendedOn,
            facebookMessageCount: source.facebookMessageCount,
            facebookLastMessageDate: source.facebookLastMessageDate,
            facebookTouchScore: source.facebookTouchScore,
            evidenceIDs: evidenceIDs,
            noteIDs: noteIDs,
            participationIDs: participationIDs,
            outcomeIDs: outcomeIDs,
            insightIDs: insightIDs,
            transitionIDs: transitionIDs,
            recruitingStageIDs: recruitingStageIDs,
            productionRecordIDs: productionRecordIDs,
            deducedRelationIDs: deducedRelationIDs,
            unionedEmails: unionedEmails,
            unionedPhones: unionedPhones,
            unionedRoleBadges: unionedRoleBadges
        )

        // ── Delete source ────────────────────────────────────────────
        modelContext.delete(source)
        try modelContext.save()

        logger.info("Merged person '\(snapshot.sourceDisplayName)' → '\(target.displayNameCache ?? target.displayName)'")
        return snapshot
    }

    /// Get count of all people
    func count() throws -> Int {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamPerson>()
        return try modelContext.fetchCount(descriptor)
    }
}
// MARK: - Errors

enum RepositoryError: LocalizedError {
    case notConfigured
    case personNotFound
    case invalidData

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Repository not configured with ModelContainer"
        case .personNotFound:
            return "Person not found in database"
        case .invalidData:
            return "Invalid data provided"
        }
    }
}
