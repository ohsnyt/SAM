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

@MainActor
@Observable
final class PeopleRepository {
    
    // MARK: - Singleton
    
    static let shared = PeopleRepository()
    
    // MARK: - Container
    
    private var container: ModelContainer?
    
    private init() {
        print("📦 [PeopleRepository] Initialized")
    }
    
    /// Configure the repository with the app-wide ModelContainer.
    /// Must be called once at app launch before any operations.
    func configure(container: ModelContainer) {
        self.container = container
        print("📦 [PeopleRepository] Configured with container: \(Unmanaged.passUnretained(container).toOpaque())")
    }
    
    // MARK: - CRUD Operations
    
    /// Fetch all people from SwiftData
    func fetchAll() throws -> [SamPerson] {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<SamPerson>(
            sortBy: [SortDescriptor(\.displayNameCache, order: .forward)]
        )
        
        let people = try context.fetch(descriptor)
        print("📦 [PeopleRepository] Fetched \(people.count) people")
        return people
    }
    
    /// Fetch a single person by UUID
    func fetch(id: UUID) throws -> SamPerson? {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        
        // Swift 6: Can't capture id in predicate, so fetch all and filter
        let descriptor = FetchDescriptor<SamPerson>()
        
        let allPeople = try context.fetch(descriptor)
        return allPeople.first { $0.id == id }
    }
    
    /// Fetch a person by contact identifier
    func fetch(contactIdentifier: String) throws -> SamPerson? {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        
        // Swift 6: Can't capture contactIdentifier in predicate, so fetch all and filter
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        
        let allPeople = try context.fetch(descriptor)
        return allPeople.first { $0.contactIdentifier == contactIdentifier }
    }
    
    /// Upsert a person from a ContactDTO
    /// If person exists (by contactIdentifier), updates cache fields
    /// If person doesn't exist, creates new SamPerson
    func upsert(contact: ContactDTO) throws {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        
        // Swift 6: Can't capture contact.identifier in predicate, so fetch all and filter
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        
        let allPeople = try context.fetch(descriptor)
        let existing = allPeople.first { $0.contactIdentifier == contact.identifier }
        
        if let existing = existing {
            // Update existing person's cache
            existing.displayNameCache = contact.displayName
            existing.emailCache = contact.emailAddresses.first
            existing.photoThumbnailCache = contact.thumbnailImageData
            existing.lastSyncedAt = Date()
            existing.isArchived = false  // Un-archive if it was archived
            
            // Update deprecated fields for backward compatibility
            existing.displayName = contact.displayName
            existing.email = contact.emailAddresses.first
            
            print("📦 [PeopleRepository] Updated: \(contact.displayName) (thumbnail: \(contact.thumbnailImageData?.count ?? 0) bytes)")
        } else {
            // Create new person
            let person = SamPerson(
                id: UUID(),
                displayName: contact.displayName,
                roleBadges: [],  // Empty by default, user can add later
                contactIdentifier: contact.identifier,
                email: contact.emailAddresses.first
            )
            
            // Set cache fields
            person.displayNameCache = contact.displayName
            person.emailCache = contact.emailAddresses.first
            person.photoThumbnailCache = contact.thumbnailImageData
            person.lastSyncedAt = Date()
            person.isArchived = false
            
            context.insert(person)
            print("📦 [PeopleRepository] Created: \(contact.displayName)")
        }
        
        try context.save()
    }
    
    /// Bulk upsert contacts (more efficient for importing many contacts)
    func bulkUpsert(contacts: [ContactDTO]) throws -> (created: Int, updated: Int) {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        var created = 0
        var updated = 0
        
        // Fetch all existing people with contactIdentifiers
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        let existingPeople = try context.fetch(descriptor)
        
        // Create lookup dictionary for fast matching
        let existingByIdentifier = Dictionary(
            uniqueKeysWithValues: existingPeople.compactMap { person in
                person.contactIdentifier.map { ($0, person) }
            }
        )
        
        // Process each contact
        for contact in contacts {
            if let existing = existingByIdentifier[contact.identifier] {
                // Update existing
                existing.displayNameCache = contact.displayName
                existing.emailCache = contact.emailAddresses.first
                existing.photoThumbnailCache = contact.thumbnailImageData
                existing.lastSyncedAt = Date()
                existing.isArchived = false
                
                // Update deprecated fields
                existing.displayName = contact.displayName
                existing.email = contact.emailAddresses.first
                
                updated += 1
            } else {
                // Create new
                let person = SamPerson(
                    id: UUID(),
                    displayName: contact.displayName,
                    roleBadges: [],  // Empty by default, user can add later
                    contactIdentifier: contact.identifier,
                    email: contact.emailAddresses.first
                )
                
                person.displayNameCache = contact.displayName
                person.emailCache = contact.emailAddresses.first
                person.photoThumbnailCache = contact.thumbnailImageData
                person.lastSyncedAt = Date()
                person.isArchived = false
                
                context.insert(person)
                created += 1
            }
        }
        
        try context.save()
        print("📦 [PeopleRepository] Bulk upsert complete: \(created) created, \(updated) updated")
        
        return (created, updated)
    }
    
    /// Delete a person
    func delete(person: SamPerson) throws {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        context.delete(person)
        try context.save()
        
        print("📦 [PeopleRepository] Deleted: \(person.displayName)")
    }
    
    /// Search people by name
    func search(query: String) throws -> [SamPerson] {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        guard !query.isEmpty else {
            return try fetchAll()
        }
        
        let context = ModelContext(container)
        
        // Fetch all and filter in memory (simpler than complex predicate)
        let descriptor = FetchDescriptor<SamPerson>(
            sortBy: [SortDescriptor(\.displayNameCache, order: .forward)]
        )
        
        let allPeople = try context.fetch(descriptor)
        let lowercaseQuery = query.lowercased()
        
        return allPeople.filter { person in
            let nameToSearch = person.displayNameCache ?? person.displayName
            return nameToSearch.lowercased().contains(lowercaseQuery)
        }
    }
    
    /// Get count of all people
    func count() throws -> Int {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<SamPerson>()
        return try context.fetchCount(descriptor)
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

