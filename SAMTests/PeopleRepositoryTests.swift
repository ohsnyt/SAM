//
//  PeopleRepositoryTests.swift
//  SAMTests
//
//  Unit tests for PeopleRepository CRUD, email handling, and search.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("PeopleRepository Tests", .serialized)
@MainActor
struct PeopleRepositoryTests {

    // MARK: - Single Upsert

    @Test("Upsert creates a new person from ContactDTO")
    func upsertCreatesNewPerson() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto = makeContactDTO(
            identifier: "contact-1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["alice@test.com"]
        )

        try PeopleRepository.shared.upsert(contact: dto)

        let all = try PeopleRepository.shared.fetchAll()
        #expect(all.count == 1)

        let person = all[0]
        #expect(person.displayNameCache == "Alice Johnson")
        #expect(person.emailCache == "alice@test.com")
        #expect(person.contactIdentifier == "contact-1")
    }

    @Test("Upsert updates existing person with same contactIdentifier")
    func upsertUpdatesExistingPerson() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto1 = makeContactDTO(
            identifier: "contact-1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["alice@test.com"]
        )
        try PeopleRepository.shared.upsert(contact: dto1)

        let dto2 = makeContactDTO(
            identifier: "contact-1",
            givenName: "Alice",
            familyName: "Smith",
            emailAddresses: ["alice.smith@test.com"]
        )
        try PeopleRepository.shared.upsert(contact: dto2)

        let count = try PeopleRepository.shared.count()
        #expect(count == 1)

        let all = try PeopleRepository.shared.fetchAll()
        #expect(all[0].displayNameCache == "Alice Smith")
        #expect(all[0].emailCache == "alice.smith@test.com")
    }

    @Test("Upsert canonicalizes email addresses")
    func upsertCanonicalizesEmail() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto = makeContactDTO(
            identifier: "contact-1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["  Alice@Example.COM  "]
        )

        try PeopleRepository.shared.upsert(contact: dto)

        let all = try PeopleRepository.shared.fetchAll()
        #expect(all[0].emailCache == "alice@example.com")
    }

    @Test("Upsert sets all email aliases lowercased")
    func upsertSetsAllEmailAliases() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto = makeContactDTO(
            identifier: "contact-1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["Alice@Test.com", "Work@Company.COM", "personal@MAIL.org"]
        )

        try PeopleRepository.shared.upsert(contact: dto)

        let all = try PeopleRepository.shared.fetchAll()
        let aliases = all[0].emailAliases
        #expect(aliases.count == 3)
        #expect(aliases.contains("alice@test.com"))
        #expect(aliases.contains("work@company.com"))
        #expect(aliases.contains("personal@mail.org"))
    }

    @Test("Upsert unarchives a previously archived person")
    func upsertUnarchivesPerson() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto = makeContactDTO(identifier: "contact-1", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: dto)

        // Manually archive the person
        let all = try PeopleRepository.shared.fetchAll()
        all[0].isArchived = true

        // Re-upsert
        try PeopleRepository.shared.upsert(contact: dto)

        let refreshed = try PeopleRepository.shared.fetchAll()
        #expect(refreshed[0].isArchived == false)
    }

    // MARK: - Bulk Upsert

    @Test("Bulk upsert creates multiple new people")
    func bulkUpsertCreatesMultiple() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let contacts = [
            makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "A"),
            makeContactDTO(identifier: "c2", givenName: "Bob", familyName: "B"),
            makeContactDTO(identifier: "c3", givenName: "Carol", familyName: "C"),
        ]

        let result = try PeopleRepository.shared.bulkUpsert(contacts: contacts)

        #expect(result.created == 3)
        #expect(result.updated == 0)
        #expect(try PeopleRepository.shared.count() == 3)
    }

    @Test("Bulk upsert handles mixed create and update")
    func bulkUpsertMixedCreateAndUpdate() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create 2 existing
        let existing = [
            makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "A"),
            makeContactDTO(identifier: "c2", givenName: "Bob", familyName: "B"),
        ]
        _ = try PeopleRepository.shared.bulkUpsert(contacts: existing)

        // Now upsert 2 existing + 1 new
        let mixed = [
            makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Updated"),
            makeContactDTO(identifier: "c2", givenName: "Bob", familyName: "Updated"),
            makeContactDTO(identifier: "c3", givenName: "Carol", familyName: "New"),
        ]
        let result = try PeopleRepository.shared.bulkUpsert(contacts: mixed)

        #expect(result.created == 1)
        #expect(result.updated == 2)
    }

    @Test("Bulk upsert with empty array does nothing")
    func bulkUpsertEmptyArray() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let result = try PeopleRepository.shared.bulkUpsert(contacts: [])

        #expect(result.created == 0)
        #expect(result.updated == 0)
    }

    // MARK: - Fetch

    @Test("Fetch by ID returns matching person")
    func fetchByIdWorks() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto = makeContactDTO(identifier: "contact-1", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: dto)

        let all = try PeopleRepository.shared.fetchAll()
        let personID = all[0].id

        let fetched = try PeopleRepository.shared.fetch(id: personID)
        #expect(fetched != nil)
        #expect(fetched?.displayNameCache == "Alice Johnson")
    }

    @Test("Fetch by ID returns nil for unknown UUID")
    func fetchByIdReturnsNilForUnknown() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let fetched = try PeopleRepository.shared.fetch(id: UUID())
        #expect(fetched == nil)
    }

    @Test("Fetch by contactIdentifier returns matching person")
    func fetchByContactIdentifier() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto = makeContactDTO(identifier: "ABC", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: dto)

        let fetched = try PeopleRepository.shared.fetch(contactIdentifier: "ABC")
        #expect(fetched != nil)
        #expect(fetched?.contactIdentifier == "ABC")
    }

    // MARK: - Search

    @Test("Search by name is case-insensitive")
    func searchByNameCaseInsensitive() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto = makeContactDTO(identifier: "contact-1", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: dto)

        let results = try PeopleRepository.shared.search(query: "alice")
        #expect(results.count == 1)
        #expect(results[0].displayNameCache == "Alice Johnson")
    }

    @Test("Search with no match returns empty array")
    func searchNoMatchReturnsEmpty() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let dto = makeContactDTO(identifier: "contact-1", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: dto)

        let results = try PeopleRepository.shared.search(query: "zzzzz")
        #expect(results.isEmpty)
    }

    // MARK: - Count

    @Test("Count returns correct value")
    func countReturnsCorrectValue() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let contacts = [
            makeContactDTO(identifier: "c1", givenName: "A", familyName: "A"),
            makeContactDTO(identifier: "c2", givenName: "B", familyName: "B"),
            makeContactDTO(identifier: "c3", givenName: "C", familyName: "C"),
        ]
        _ = try PeopleRepository.shared.bulkUpsert(contacts: contacts)

        let count = try PeopleRepository.shared.count()
        #expect(count == 3)
    }
}
