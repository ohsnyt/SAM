//
//  EvidenceRepositoryTests.swift
//  SAMTests
//
//  Unit tests for EvidenceRepository CRUD, participant matching, and the isVerified bug.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("EvidenceRepository Tests", .serialized)
@MainActor
struct EvidenceRepositoryTests {

    // MARK: - CRUD

    @Test("Create evidence from event DTO")
    func createEvidenceFromEvent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Team Standup",
            startDate: Date()
        )
        try EvidenceRepository.shared.upsert(event: event)

        let all = try EvidenceRepository.shared.fetchAll()
        #expect(all.count == 1)
        #expect(all[0].title == "Team Standup")
        #expect(all[0].sourceUID == "eventkit:evt-1")
        #expect(all[0].state == .needsReview)
    }

    @Test("Upsert is idempotent for same sourceUID")
    func upsertIsIdempotent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event1 = makeEventDTO(identifier: "evt-1", title: "Original Title")
        try EvidenceRepository.shared.upsert(event: event1)

        let event2 = makeEventDTO(identifier: "evt-1", title: "Updated Title")
        try EvidenceRepository.shared.upsert(event: event2)

        let all = try EvidenceRepository.shared.fetchAll()
        #expect(all.count == 1)
        #expect(all[0].title == "Updated Title")
    }

    @Test("Bulk upsert creates multiple evidence items")
    func bulkUpsertMultipleEvents() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let events = [
            makeEventDTO(identifier: "evt-1", title: "Meeting 1"),
            makeEventDTO(identifier: "evt-2", title: "Meeting 2"),
            makeEventDTO(identifier: "evt-3", title: "Meeting 3"),
        ]
        try EvidenceRepository.shared.bulkUpsert(events: events)

        let all = try EvidenceRepository.shared.fetchAll()
        #expect(all.count == 3)
    }

    @Test("fetchNeedsReview filters correctly")
    func fetchNeedsReviewFilters() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let events = [
            makeEventDTO(identifier: "evt-1", title: "Meeting 1"),
            makeEventDTO(identifier: "evt-2", title: "Meeting 2"),
            makeEventDTO(identifier: "evt-3", title: "Meeting 3"),
        ]
        try EvidenceRepository.shared.bulkUpsert(events: events)

        // Mark one as done
        let all = try EvidenceRepository.shared.fetchAll()
        try EvidenceRepository.shared.markAsReviewed(item: all[0])

        let needsReview = try EvidenceRepository.shared.fetchNeedsReview()
        #expect(needsReview.count == 2)
    }

    @Test("fetchDone filters correctly")
    func fetchDoneFilters() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let events = [
            makeEventDTO(identifier: "evt-1", title: "Meeting 1"),
            makeEventDTO(identifier: "evt-2", title: "Meeting 2"),
            makeEventDTO(identifier: "evt-3", title: "Meeting 3"),
        ]
        try EvidenceRepository.shared.bulkUpsert(events: events)

        let all = try EvidenceRepository.shared.fetchAll()
        try EvidenceRepository.shared.markAsReviewed(item: all[0])
        try EvidenceRepository.shared.markAsReviewed(item: all[1])

        let done = try EvidenceRepository.shared.fetchDone()
        #expect(done.count == 2)
    }

    @Test("Fetch by sourceUID returns matching item")
    func fetchBySourceUID() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = makeEventDTO(identifier: "evt-1", title: "My Meeting")
        try EvidenceRepository.shared.upsert(event: event)

        let fetched = try EvidenceRepository.shared.fetch(sourceUID: "eventkit:evt-1")
        #expect(fetched != nil)
        #expect(fetched?.title == "My Meeting")
    }

    @Test("markAsReviewed sets state to done")
    func markAsReviewed() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = makeEventDTO(identifier: "evt-1", title: "Meeting")
        try EvidenceRepository.shared.upsert(event: event)

        let item = try EvidenceRepository.shared.fetchAll()[0]
        try EvidenceRepository.shared.markAsReviewed(item: item)

        #expect(item.state == .done)
    }

    @Test("markAsNeedsReview sets state back to needsReview")
    func markAsNeedsReview() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = makeEventDTO(identifier: "evt-1", title: "Meeting")
        try EvidenceRepository.shared.upsert(event: event)

        let item = try EvidenceRepository.shared.fetchAll()[0]
        try EvidenceRepository.shared.markAsReviewed(item: item)
        try EvidenceRepository.shared.markAsNeedsReview(item: item)

        #expect(item.state == .needsReview)
    }

    @Test("Delete removes evidence item")
    func deleteRemovesItem() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = makeEventDTO(identifier: "evt-1", title: "Meeting")
        try EvidenceRepository.shared.upsert(event: event)

        let item = try EvidenceRepository.shared.fetchAll()[0]
        try EvidenceRepository.shared.delete(item: item)

        let all = try EvidenceRepository.shared.fetchAll()
        #expect(all.isEmpty)
    }

    @Test("deleteAll clears all evidence items")
    func deleteAllClearsEverything() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let events = [
            makeEventDTO(identifier: "evt-1", title: "Meeting 1"),
            makeEventDTO(identifier: "evt-2", title: "Meeting 2"),
            makeEventDTO(identifier: "evt-3", title: "Meeting 3"),
        ]
        try EvidenceRepository.shared.bulkUpsert(events: events)
        try EvidenceRepository.shared.deleteAll()

        let all = try EvidenceRepository.shared.fetchAll()
        #expect(all.isEmpty)
    }

    // MARK: - Pruning

    @Test("pruneOrphans removes stale calendar evidence")
    func pruneOrphansRemovesStale() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let events = [
            makeEventDTO(identifier: "A", title: "Event A"),
            makeEventDTO(identifier: "B", title: "Event B"),
            makeEventDTO(identifier: "C", title: "Event C"),
        ]
        try EvidenceRepository.shared.bulkUpsert(events: events)

        // Only A and C are still valid
        try EvidenceRepository.shared.pruneOrphans(validSourceUIDs: Set(["eventkit:A", "eventkit:C"]))

        let remaining = try EvidenceRepository.shared.fetchAll()
        #expect(remaining.count == 2)
        let titles = Set(remaining.map(\.title))
        #expect(titles.contains("Event A"))
        #expect(titles.contains("Event C"))
    }

    @Test("pruneOrphans ignores non-calendar evidence")
    func pruneOrphansIgnoresNonCalendar() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create one calendar event
        let event = makeEventDTO(identifier: "evt-1", title: "Calendar Event")
        try EvidenceRepository.shared.upsert(event: event)

        // Create one note evidence
        _ = try EvidenceRepository.shared.create(
            sourceUID: "note:1",
            source: .note,
            occurredAt: Date(),
            title: "Note Evidence",
            snippet: "A note"
        )

        // Prune with empty valid set - should only delete calendar evidence
        try EvidenceRepository.shared.pruneOrphans(validSourceUIDs: Set())

        let remaining = try EvidenceRepository.shared.fetchAll()
        #expect(remaining.count == 1)
        #expect(remaining[0].title == "Note Evidence")
    }

    // MARK: - Participant Resolution

    @Test("linkedPeople resolved by primary email")
    func linkedPeopleResolvedByPrimaryEmail() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create a person with email
        let contact = makeContactDTO(
            identifier: "c1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["alice@test.com"]
        )
        try PeopleRepository.shared.upsert(contact: contact)

        // Create an event with Alice as attendee
        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Meeting with Alice",
            attendees: [makeAttendeeDTO(name: "Alice", email: "alice@test.com")]
        )
        try EvidenceRepository.shared.upsert(event: event)

        let evidence = try EvidenceRepository.shared.fetchAll()[0]
        #expect(evidence.linkedPeople.count == 1)
        #expect(evidence.linkedPeople[0].displayNameCache == "Alice Johnson")
    }

    @Test("linkedPeople resolved by email alias")
    func linkedPeopleResolvedByAlias() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create a person with multiple emails
        let contact = makeContactDTO(
            identifier: "c1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["alice@personal.com", "work@test.com"]
        )
        try PeopleRepository.shared.upsert(contact: contact)

        // Event uses the alias email
        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Work Meeting",
            attendees: [makeAttendeeDTO(name: "Alice", email: "work@test.com")]
        )
        try EvidenceRepository.shared.upsert(event: event)

        let evidence = try EvidenceRepository.shared.fetchAll()[0]
        #expect(evidence.linkedPeople.count == 1)
    }

    @Test("linkedPeople empty for unknown email")
    func linkedPeopleEmptyForUnknownEmail() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Meeting with Stranger",
            attendees: [makeAttendeeDTO(name: "Unknown Person", email: "stranger@nowhere.com")]
        )
        try EvidenceRepository.shared.upsert(event: event)

        let evidence = try EvidenceRepository.shared.fetchAll()[0]
        #expect(evidence.linkedPeople.isEmpty)
    }

    @Test("Email resolution is case-insensitive")
    func emailResolutionCaseInsensitive() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let contact = makeContactDTO(
            identifier: "c1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["Alice@Test.COM"]
        )
        try PeopleRepository.shared.upsert(contact: contact)

        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Meeting",
            attendees: [makeAttendeeDTO(name: "Alice", email: "alice@test.com")]
        )
        try EvidenceRepository.shared.upsert(event: event)

        let evidence = try EvidenceRepository.shared.fetchAll()[0]
        #expect(evidence.linkedPeople.count == 1)
    }

    @Test("reresolve links evidence to people added after import")
    func reresolveLinksAfterContactImport() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create event FIRST (no matching person yet)
        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Meeting",
            attendees: [makeAttendeeDTO(name: "Alice", email: "alice@test.com")]
        )
        try EvidenceRepository.shared.upsert(event: event)

        // Verify no linked people
        let beforeResolve = try EvidenceRepository.shared.fetchAll()[0]
        #expect(beforeResolve.linkedPeople.isEmpty)

        // Now create the person
        let contact = makeContactDTO(
            identifier: "c1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["alice@test.com"]
        )
        try PeopleRepository.shared.upsert(contact: contact)

        // Re-resolve
        try EvidenceRepository.shared.reresolveParticipantsForUnlinkedEvidence()

        let afterResolve = try EvidenceRepository.shared.fetchAll()[0]
        #expect(afterResolve.linkedPeople.count == 1)
    }

    @Test("reresolve skips evidence already linked to people")
    func reresolveSkipsAlreadyLinked() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create person first
        let contact = makeContactDTO(
            identifier: "c1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["alice@test.com"]
        )
        try PeopleRepository.shared.upsert(contact: contact)

        // Create event that resolves Alice
        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Meeting",
            attendees: [makeAttendeeDTO(name: "Alice", email: "alice@test.com")]
        )
        try EvidenceRepository.shared.upsert(event: event)

        let before = try EvidenceRepository.shared.fetchAll()[0]
        #expect(before.linkedPeople.count == 1)

        // Re-resolve should not change anything
        try EvidenceRepository.shared.reresolveParticipantsForUnlinkedEvidence()

        let after = try EvidenceRepository.shared.fetchAll()[0]
        #expect(after.linkedPeople.count == 1)
    }

    // MARK: - ParticipantHints

    @Test("participantHints built from attendees")
    func participantHintsBuiltFromAttendees() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Team Meeting",
            attendees: [
                makeAttendeeDTO(name: "Alice", email: "alice@test.com"),
                makeAttendeeDTO(name: "Bob", email: "bob@test.com"),
            ]
        )
        try EvidenceRepository.shared.upsert(event: event)

        let evidence = try EvidenceRepository.shared.fetchAll()[0]
        #expect(evidence.participantHints.count == 2)

        let names = Set(evidence.participantHints.map(\.displayName))
        #expect(names.contains("Alice"))
        #expect(names.contains("Bob"))

        let emails = Set(evidence.participantHints.compactMap(\.rawEmail))
        #expect(emails.contains("alice@test.com"))
        #expect(emails.contains("bob@test.com"))
    }

    @Test("organizer merged into matching attendee hint")
    func participantHintOrganizerMerged() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Organized Meeting",
            attendees: [
                makeAttendeeDTO(name: "Alice", email: "alice@test.com"),
                makeAttendeeDTO(name: "Bob", email: "bob@test.com"),
            ],
            organizer: makeAttendeeDTO(name: "Alice", email: "alice@test.com")
        )
        try EvidenceRepository.shared.upsert(event: event)

        let evidence = try EvidenceRepository.shared.fetchAll()[0]
        // Should still have 2 hints (organizer merged, not added)
        #expect(evidence.participantHints.count == 2)

        let aliceHint = evidence.participantHints.first { $0.rawEmail == "alice@test.com" }
        #expect(aliceHint?.isOrganizer == true)
    }

    // MARK: - isVerified Bug Tests

    @Test("Unknown email is NOT verified when no matching contact exists")
    func unknownEmailNotVerified() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // No people in the database - stranger's email won't match anyone
        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Meeting with Stranger",
            attendees: [makeAttendeeDTO(name: "Stranger", email: "stranger@nowhere.com")]
        )
        try EvidenceRepository.shared.upsert(event: event)

        let evidence = try EvidenceRepository.shared.fetchAll()[0]
        let strangerHint = evidence.participantHints.first { $0.rawEmail == "stranger@nowhere.com" }

        // isVerified should be false because no matching contact exists
        #expect(strangerHint?.isVerified == false)
    }

    @Test("Mixed attendees: known contact verified, unknown not verified")
    func mixedAttendeesVerifiedCorrectly() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create only one known person
        let contact = makeContactDTO(
            identifier: "c1",
            givenName: "Alice",
            familyName: "Johnson",
            emailAddresses: ["alice@test.com"]
        )
        try PeopleRepository.shared.upsert(contact: contact)

        let event = makeEventDTO(
            identifier: "evt-1",
            title: "Mixed Meeting",
            attendees: [
                makeAttendeeDTO(name: "Alice", email: "alice@test.com"),
                makeAttendeeDTO(name: "Unknown Person", email: "unknown@nowhere.com"),
            ]
        )
        try EvidenceRepository.shared.upsert(event: event)

        let evidence = try EvidenceRepository.shared.fetchAll()[0]
        let aliceHint = evidence.participantHints.first { $0.rawEmail == "alice@test.com" }
        let unknownHint = evidence.participantHints.first { $0.rawEmail == "unknown@nowhere.com" }

        // Alice is verified (has matching contact)
        #expect(aliceHint?.isVerified == true)

        // Unknown person is NOT verified (no matching contact)
        #expect(unknownHint?.isVerified == false)
    }
}
