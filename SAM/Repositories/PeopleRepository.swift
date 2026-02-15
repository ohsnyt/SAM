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

    /// Upsert a person from a ContactDTO
    /// If person exists (by contactIdentifier), updates cache fields
    /// If person doesn't exist, creates new SamPerson
    func upsert(contact: ContactDTO) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let canonicalEmails = contact.emailAddresses.compactMap { canonicalizeEmail($0) }
        let primaryEmail = canonicalEmails.first

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
            existing.photoThumbnailCache = contact.thumbnailImageData
            existing.lastSyncedAt = Date()
            existing.isArchived = false  // Un-archive if it was archived

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
            person.photoThumbnailCache = contact.thumbnailImageData
            person.lastSyncedAt = Date()
            person.isArchived = false

            modelContext.insert(person)
        }

        try modelContext.save()
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

            if let existing = existingByIdentifier[contact.identifier] {
                // Update existing
                existing.displayNameCache = contact.displayName
                existing.emailCache = primaryEmail
                existing.emailAliases = canonicalEmails
                existing.photoThumbnailCache = contact.thumbnailImageData
                existing.lastSyncedAt = Date()
                existing.isArchived = false

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
                person.photoThumbnailCache = contact.thumbnailImageData
                person.lastSyncedAt = Date()
                person.isArchived = false

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

    /// Upsert the Me contact, ensuring only one person has isMe = true
    func upsertMe(contact: ContactDTO) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let canonicalEmails = contact.emailAddresses.compactMap { canonicalizeEmail($0) }
        let primaryEmail = canonicalEmails.first

        // Clear any existing Me flags first
        let meDescriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.isMe == true }
        )
        for existing in try modelContext.fetch(meDescriptor) {
            existing.isMe = false
        }

        // Find or create the person by contactIdentifier
        let allDescriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        let allPeople = try modelContext.fetch(allDescriptor)
        let person: SamPerson

        if let existing = allPeople.first(where: { $0.contactIdentifier == contact.identifier }) {
            existing.displayNameCache = contact.displayName
            existing.emailCache = primaryEmail
            existing.emailAliases = canonicalEmails
            existing.photoThumbnailCache = contact.thumbnailImageData
            existing.lastSyncedAt = Date()
            existing.isArchived = false
            existing.isMe = true

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
            newPerson.photoThumbnailCache = contact.thumbnailImageData
            newPerson.lastSyncedAt = Date()
            newPerson.isArchived = false

            modelContext.insert(newPerson)
            person = newPerson
        }

        try modelContext.save()
        logger.info("Upserted Me contact: \(person.displayNameCache ?? person.displayName, privacy: .public)")
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
