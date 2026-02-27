//
//  ContextsRepositoryTests.swift
//  SAMTests
//
//  Unit tests for ContextsRepository CRUD, search, filtering, and participants.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("ContextsRepository Tests", .serialized)
@MainActor
struct ContextsRepositoryTests {

    // MARK: - Create

    @Test("Create context returns context with correct properties")
    func createContextReturnsContext() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = try ContextsRepository.shared.create(name: "Smith Group", kind: .business)

        #expect(ctx.name == "Smith Group")
        #expect(ctx.kind == .business)
        #expect(try ContextsRepository.shared.count() == 1)
    }

    // MARK: - Fetch

    @Test("Fetch by ID returns matching context")
    func fetchByIdReturnsContext() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let created = try ContextsRepository.shared.create(name: "Test Context", kind: .business)
        let fetched = try ContextsRepository.shared.fetch(id: created.id)

        #expect(fetched != nil)
        #expect(fetched?.name == "Test Context")
    }

    @Test("Fetch by ID returns nil for unknown UUID")
    func fetchByIdReturnsNilForUnknown() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let fetched = try ContextsRepository.shared.fetch(id: UUID())
        #expect(fetched == nil)
    }

    // MARK: - Search & Filter

    @Test("Search by name finds matching context")
    func searchByName() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        _ = try ContextsRepository.shared.create(name: "Smith Group", kind: .business)
        _ = try ContextsRepository.shared.create(name: "Johnson Associates", kind: .business)

        let results = try ContextsRepository.shared.search(query: "smith")
        #expect(results.count == 1)
        #expect(results[0].name == "Smith Group")
    }

    @Test("Filter by kind returns matching contexts")
    func filterByKind() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        _ = try ContextsRepository.shared.create(name: "Group 1", kind: .business)
        _ = try ContextsRepository.shared.create(name: "Group 2", kind: .business)
        _ = try ContextsRepository.shared.create(name: "Recruiting 1", kind: .recruiting)

        let businesses = try ContextsRepository.shared.filter(by: .business)
        #expect(businesses.count == 2)
    }

    // MARK: - Update

    @Test("Update name changes context name")
    func updateName() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = try ContextsRepository.shared.create(name: "Old Name", kind: .business)
        try ContextsRepository.shared.update(context: ctx, name: "New Name")

        #expect(ctx.name == "New Name")
    }

    @Test("Update kind changes context kind")
    func updateKind() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = try ContextsRepository.shared.create(name: "Test", kind: .business)
        try ContextsRepository.shared.update(context: ctx, kind: .recruiting)

        #expect(ctx.kind == .recruiting)
    }

    // MARK: - Delete

    @Test("Delete removes context")
    func deleteRemovesContext() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = try ContextsRepository.shared.create(name: "To Delete", kind: .business)
        try ContextsRepository.shared.delete(context: ctx)

        #expect(try ContextsRepository.shared.count() == 0)
    }

    // MARK: - Participants

    @Test("Add participant creates participation")
    func addParticipant() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create person
        let contactDTO = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: contactDTO)
        let person = try PeopleRepository.shared.fetchAll()[0]

        // Create context
        let ctx = try ContextsRepository.shared.create(name: "Test Group", kind: .business)

        // Add participant
        try ContextsRepository.shared.addParticipant(person: person, to: ctx)

        #expect(ctx.participations.count == 1)
        #expect(ctx.participations[0].person?.id == person.id)
    }

    @Test("Remove participant clears participation")
    func removeParticipant() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let contactDTO = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: contactDTO)
        let person = try PeopleRepository.shared.fetchAll()[0]

        let ctx = try ContextsRepository.shared.create(name: "Test Group", kind: .business)
        try ContextsRepository.shared.addParticipant(person: person, to: ctx)
        try ContextsRepository.shared.removeParticipant(person: person, from: ctx)

        // Participation should be deleted
        let allContexts = try ContextsRepository.shared.fetchAll()
        let refreshedCtx = allContexts.first { $0.id == ctx.id }
        #expect(refreshedCtx?.participations.isEmpty ?? true)
    }

    @Test("Add participant with role badges")
    func addParticipantWithRoles() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let contactDTO = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: contactDTO)
        let person = try PeopleRepository.shared.fetchAll()[0]

        let ctx = try ContextsRepository.shared.create(name: "Test Group", kind: .business)
        try ContextsRepository.shared.addParticipant(
            person: person,
            to: ctx,
            roleBadges: ["Client", "Primary"]
        )

        #expect(ctx.participations[0].roleBadges == ["Client", "Primary"])
    }

    // MARK: - Count

    @Test("Count returns correct value")
    func countReturnsCorrectValue() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        _ = try ContextsRepository.shared.create(name: "A", kind: .business)
        _ = try ContextsRepository.shared.create(name: "B", kind: .business)
        _ = try ContextsRepository.shared.create(name: "C", kind: .business)
        _ = try ContextsRepository.shared.create(name: "D", kind: .recruiting)

        #expect(try ContextsRepository.shared.count() == 4)
    }
}
