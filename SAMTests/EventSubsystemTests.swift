//
//  EventSubsystemTests.swift
//  SAMTests
//
//  Unit tests for the Event subsystem: EventRepository CRUD, participation management,
//  RSVP matching logic, undo round-trip, and presentation model.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

// MARK: - EventRepository CRUD

@Suite("EventRepository CRUD", .serialized)
@MainActor
struct EventRepositoryCRUDTests {

    @Test("Create event with all fields")
    func createEvent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let start = Date().addingTimeInterval(86400) // tomorrow
        let end = start.addingTimeInterval(7200)

        let event = try EventRepository.shared.createEvent(
            title: "Financial Planning Workshop",
            eventDescription: "A workshop for pre-retirees",
            format: .inPerson,
            startDate: start,
            endDate: end,
            venue: "Conference Room A",
            joinLink: nil,
            targetParticipantCount: 25
        )

        #expect(event.title == "Financial Planning Workshop")
        #expect(event.eventDescription == "A workshop for pre-retirees")
        #expect(event.format == .inPerson)
        #expect(event.venue == "Conference Room A")
        #expect(event.targetParticipantCount == 25)
        #expect(event.status == .draft)
        #expect(event.participations.isEmpty)
    }

    @Test("Fetch by ID returns correct event")
    func fetchByID() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Test Event",
            format: .virtual,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let fetched = try EventRepository.shared.fetch(id: event.id)
        #expect(fetched != nil)
        #expect(fetched?.title == "Test Event")
        #expect(fetched?.format == .virtual)
    }

    @Test("Fetch by ID returns nil for unknown ID")
    func fetchByIDNotFound() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let fetched = try EventRepository.shared.fetch(id: UUID())
        #expect(fetched == nil)
    }

    @Test("FetchUpcoming returns only future non-cancelled events")
    func fetchUpcoming() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Future event
        try EventRepository.shared.createEvent(
            title: "Future Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        // Past event
        try EventRepository.shared.createEvent(
            title: "Past Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(-86400),
            endDate: Date().addingTimeInterval(-82800)
        )

        // Cancelled future event
        let cancelled = try EventRepository.shared.createEvent(
            title: "Cancelled Workshop",
            format: .virtual,
            startDate: Date().addingTimeInterval(172800),
            endDate: Date().addingTimeInterval(176400)
        )
        cancelled.status = .cancelled

        let upcoming = try EventRepository.shared.fetchUpcoming()
        #expect(upcoming.count == 1)
        #expect(upcoming[0].title == "Future Workshop")
    }

    @Test("FetchPast returns past and completed events")
    func fetchPast() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Past event (start date has passed)
        try EventRepository.shared.createEvent(
            title: "Yesterday's Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(-86400),
            endDate: Date().addingTimeInterval(-82800)
        )

        // Completed event (even if date is future somehow)
        let completed = try EventRepository.shared.createEvent(
            title: "Completed Workshop",
            format: .virtual,
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(-1800)
        )
        completed.status = .completed

        // Future event — should NOT appear
        try EventRepository.shared.createEvent(
            title: "Future Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let past = try EventRepository.shared.fetchPast()
        #expect(past.count == 2)
        let titles = Set(past.map(\.title))
        #expect(titles.contains("Yesterday's Workshop"))
        #expect(titles.contains("Completed Workshop"))
    }

    @Test("FetchAll returns every event")
    func fetchAll() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        try EventRepository.shared.createEvent(title: "A", format: .inPerson, startDate: Date(), endDate: Date())
        try EventRepository.shared.createEvent(title: "B", format: .virtual, startDate: Date(), endDate: Date())
        try EventRepository.shared.createEvent(title: "C", format: .hybrid, startDate: Date(), endDate: Date())

        let all = try EventRepository.shared.fetchAll()
        #expect(all.count == 3)
    }

    @Test("UpdateEvent modifies fields")
    func updateEvent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Original",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        try EventRepository.shared.updateEvent(
            id: event.id,
            title: "Updated Title",
            venue: "New Venue",
            status: .inviting
        )

        let fetched = try EventRepository.shared.fetch(id: event.id)!
        #expect(fetched.title == "Updated Title")
        #expect(fetched.venue == "New Venue")
        #expect(fetched.status == .inviting)
    }

    @Test("DeleteEvent removes event from store")
    func deleteEvent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Doomed Event",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        try EventRepository.shared.deleteEvent(id: event.id)

        let fetched = try EventRepository.shared.fetch(id: event.id)
        #expect(fetched == nil)
    }
}

// MARK: - Participation Management

@Suite("Event Participation", .serialized)
@MainActor
struct EventParticipationTests {

    @Test("Add participant to event")
    func addParticipant() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let contact = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Smith")
        try PeopleRepository.shared.upsert(contact: contact)
        let person = try PeopleRepository.shared.fetchAll().first!

        let participation = try EventRepository.shared.addParticipant(
            event: event,
            person: person,
            priority: .key,
            eventRole: "Speaker"
        )

        #expect(participation.person?.id == person.id)
        #expect(participation.event?.id == event.id)
        #expect(participation.priority == .key)
        #expect(participation.eventRole == "Speaker")
        #expect(participation.rsvpStatus == .pending)
        #expect(participation.inviteStatus == .notInvited)
    }

    @Test("Duplicate participant is prevented")
    func duplicateParticipant() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let contact = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Smith")
        try PeopleRepository.shared.upsert(contact: contact)
        let person = try PeopleRepository.shared.fetchAll().first!

        let first = try EventRepository.shared.addParticipant(event: event, person: person)
        let second = try EventRepository.shared.addParticipant(event: event, person: person)

        // Should return the same participation, not create a duplicate
        #expect(first.id == second.id)
        #expect(event.participations.count == 1)
    }

    @Test("Remove participant from event")
    func removeParticipant() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let contact = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Smith")
        try PeopleRepository.shared.upsert(contact: contact)
        let person = try PeopleRepository.shared.fetchAll().first!

        let participation = try EventRepository.shared.addParticipant(event: event, person: person)
        try EventRepository.shared.removeParticipant(participationID: participation.id, from: event)

        let remaining = EventRepository.shared.fetchParticipations(for: event)
        #expect(remaining.isEmpty)
    }

    @Test("RSVP update changes status and records metadata")
    func updateRSVP() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let contact = makeContactDTO(identifier: "c1", givenName: "Bob", familyName: "Jones")
        try PeopleRepository.shared.upsert(contact: contact)
        let person = try PeopleRepository.shared.fetchAll().first!

        let participation = try EventRepository.shared.addParticipant(event: event, person: person)

        try EventRepository.shared.updateRSVP(
            participationID: participation.id,
            status: .accepted,
            responseQuote: "Count me in!",
            detectionConfidence: 0.9,
            userConfirmed: false
        )

        let fetched = try EventRepository.shared.fetchParticipation(id: participation.id)!
        #expect(fetched.rsvpStatus == .accepted)
        #expect(fetched.rsvpResponseQuote == "Count me in!")
        #expect(fetched.rsvpDetectionConfidence == 0.9)
        #expect(fetched.rsvpUserConfirmed == false)
    }

    @Test("Mark invite sent updates status and channel")
    func markInviteSent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let contact = makeContactDTO(identifier: "c1", givenName: "Carol", familyName: "Lee")
        try PeopleRepository.shared.upsert(contact: contact)
        let person = try PeopleRepository.shared.fetchAll().first!

        let participation = try EventRepository.shared.addParticipant(event: event, person: person)
        try EventRepository.shared.markInviteSent(participationID: participation.id, channel: .email)

        let fetched = try EventRepository.shared.fetchParticipation(id: participation.id)!
        #expect(fetched.inviteStatus == .invited)
        #expect(fetched.inviteChannel == .email)
        #expect(fetched.rsvpStatus == .invited)
    }

    @Test("AcceptedCount computed property")
    func acceptedCount() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        // Add 3 participants
        for i in 1...3 {
            let c = makeContactDTO(identifier: "c\(i)", givenName: "Person\(i)", familyName: "Test")
            try PeopleRepository.shared.upsert(contact: c)
        }
        let people = try PeopleRepository.shared.fetchAll()

        var participations: [EventParticipation] = []
        for person in people {
            let p = try EventRepository.shared.addParticipant(event: event, person: person)
            participations.append(p)
        }

        // Accept 2 of 3
        try EventRepository.shared.updateRSVP(participationID: participations[0].id, status: .accepted)
        try EventRepository.shared.updateRSVP(participationID: participations[1].id, status: .accepted)
        try EventRepository.shared.updateRSVP(participationID: participations[2].id, status: .declined)

        let acceptedCount = event.participations.filter { $0.rsvpStatus == .accepted }.count
        let pendingCount = event.participations.filter { $0.rsvpStatus == .pending }.count
        #expect(acceptedCount == 2)
        #expect(pendingCount == 0)
    }

    @Test("Participation sort order: VIP first, then key, then standard")
    func participationSortOrder() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let c1 = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Standard")
        let c2 = makeContactDTO(identifier: "c2", givenName: "Bob", familyName: "VIP")
        let c3 = makeContactDTO(identifier: "c3", givenName: "Carol", familyName: "Key")
        try PeopleRepository.shared.upsert(contact: c1)
        try PeopleRepository.shared.upsert(contact: c2)
        try PeopleRepository.shared.upsert(contact: c3)

        let people = try PeopleRepository.shared.fetchAll()
        let alice = people.first { $0.displayNameCache == "Alice Standard" }!
        let bob = people.first { $0.displayNameCache == "Bob VIP" }!
        let carol = people.first { $0.displayNameCache == "Carol Key" }!

        try EventRepository.shared.addParticipant(event: event, person: alice, priority: .standard)
        try EventRepository.shared.addParticipant(event: event, person: bob, priority: .vip)
        try EventRepository.shared.addParticipant(event: event, person: carol, priority: .key)

        let sorted = EventRepository.shared.fetchParticipations(for: event)
        #expect(sorted.count == 3)
        #expect(sorted[0].priority == .vip)
        #expect(sorted[1].priority == .key)
        #expect(sorted[2].priority == .standard)
    }

    @Test("Filter participations by RSVP status")
    func filterByRSVP() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        for i in 1...4 {
            let c = makeContactDTO(identifier: "c\(i)", givenName: "P\(i)", familyName: "Test")
            try PeopleRepository.shared.upsert(contact: c)
        }
        let people = try PeopleRepository.shared.fetchAll()

        var parts: [EventParticipation] = []
        for person in people {
            parts.append(try EventRepository.shared.addParticipant(event: event, person: person))
        }

        try EventRepository.shared.updateRSVP(participationID: parts[0].id, status: .accepted)
        try EventRepository.shared.updateRSVP(participationID: parts[1].id, status: .accepted)
        try EventRepository.shared.updateRSVP(participationID: parts[2].id, status: .declined)
        try EventRepository.shared.updateRSVP(participationID: parts[3].id, status: .tentative)

        let accepted = EventRepository.shared.fetchParticipations(for: event, rsvpStatus: .accepted)
        let declined = EventRepository.shared.fetchParticipations(for: event, rsvpStatus: .declined)
        let tentative = EventRepository.shared.fetchParticipations(for: event, rsvpStatus: .tentative)

        #expect(accepted.count == 2)
        #expect(declined.count == 1)
        #expect(tentative.count == 1)
    }

    @Test("Unconfirmed RSVPs filter detects low-confidence detections")
    func unconfirmedRSVPs() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let c1 = makeContactDTO(identifier: "c1", givenName: "High", familyName: "Confidence")
        let c2 = makeContactDTO(identifier: "c2", givenName: "Low", familyName: "Confidence")
        try PeopleRepository.shared.upsert(contact: c1)
        try PeopleRepository.shared.upsert(contact: c2)
        let people = try PeopleRepository.shared.fetchAll()

        let p1 = try EventRepository.shared.addParticipant(event: event, person: people[0])
        let p2 = try EventRepository.shared.addParticipant(event: event, person: people[1])

        // High confidence — should not appear in unconfirmed
        try EventRepository.shared.updateRSVP(
            participationID: p1.id,
            status: .accepted,
            detectionConfidence: 0.95,
            userConfirmed: false
        )

        // Low confidence — should appear
        try EventRepository.shared.updateRSVP(
            participationID: p2.id,
            status: .accepted,
            detectionConfidence: 0.5,
            userConfirmed: false
        )

        let unconfirmed = EventRepository.shared.fetchUnconfirmedRSVPs(for: event)
        #expect(unconfirmed.count == 1)
        #expect(unconfirmed[0].person?.displayNameCache == "Low Confidence")
    }

    @Test("Auto-ack eligibility respects priority and confirmation")
    func autoAckEligibility() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        event.autoAcknowledgeEnabled = true

        let c1 = makeContactDTO(identifier: "c1", givenName: "Standard", familyName: "Person")
        let c2 = makeContactDTO(identifier: "c2", givenName: "VIP", familyName: "Person")
        try PeopleRepository.shared.upsert(contact: c1)
        try PeopleRepository.shared.upsert(contact: c2)
        let people = try PeopleRepository.shared.fetchAll()

        let pStandard = try EventRepository.shared.addParticipant(
            event: event, person: people[0], priority: .standard)
        let pVIP = try EventRepository.shared.addParticipant(
            event: event, person: people[1], priority: .vip)

        // Both accepted and confirmed
        try EventRepository.shared.updateRSVP(
            participationID: pStandard.id, status: .accepted, userConfirmed: true)
        try EventRepository.shared.updateRSVP(
            participationID: pVIP.id, status: .accepted, userConfirmed: true)

        let eligible = EventRepository.shared.fetchPendingAutoAcks(for: event)
        // Only standard should be eligible (VIP requires personal ack)
        #expect(eligible.count == 1)
        #expect(eligible[0].priority == .standard)
    }

    @Test("Auto-ack disabled returns empty list")
    func autoAckDisabled() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        // autoAcknowledgeEnabled defaults to false

        let c = makeContactDTO(identifier: "c1", givenName: "Test", familyName: "Person")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!

        let p = try EventRepository.shared.addParticipant(event: event, person: person)
        try EventRepository.shared.updateRSVP(
            participationID: p.id, status: .accepted, userConfirmed: true)

        let eligible = EventRepository.shared.fetchPendingAutoAcks(for: event)
        #expect(eligible.isEmpty)
    }
}

// MARK: - Message Log

@Suite("Event Message Log", .serialized)
@MainActor
struct EventMessageLogTests {

    @Test("Append message to participation")
    func appendMessage() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let c = makeContactDTO(identifier: "c1", givenName: "Test", familyName: "Person")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!
        let p = try EventRepository.shared.addParticipant(event: event, person: person)

        try EventRepository.shared.appendMessage(
            participationID: p.id,
            kind: .invitation,
            channel: .email,
            body: "You're invited to our workshop!"
        )

        let fetched = try EventRepository.shared.fetchParticipation(id: p.id)!
        #expect(fetched.messageLog.count == 1)
        #expect(fetched.messageLog[0].kind == .invitation)
        #expect(fetched.messageLog[0].isDraft == true)
        #expect(fetched.messageLog[0].body == "You're invited to our workshop!")
    }

    @Test("Mark message as sent")
    func markMessageSent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let c = makeContactDTO(identifier: "c1", givenName: "Test", familyName: "Person")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!
        let p = try EventRepository.shared.addParticipant(event: event, person: person)

        try EventRepository.shared.appendMessage(
            participationID: p.id,
            kind: .invitation,
            channel: .email,
            body: "Draft invitation"
        )

        let msgID = p.messageLog[0].id
        try EventRepository.shared.markMessageSent(participationID: p.id, messageID: msgID)

        let fetched = try EventRepository.shared.fetchParticipation(id: p.id)!
        #expect(fetched.messageLog[0].isDraft == false)
        #expect(fetched.messageLog[0].sentAt != nil)
    }
}

// MARK: - Social Promotion

@Suite("Event Social Promotion", .serialized)
@MainActor
struct EventSocialPromotionTests {

    @Test("Upsert social promotion creates new entry")
    func upsertCreatesNew() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        try EventRepository.shared.upsertSocialPromotion(
            eventID: event.id,
            platform: "linkedin",
            draftText: "Join us for an amazing workshop!"
        )

        let fetched = try EventRepository.shared.fetch(id: event.id)!
        #expect(fetched.socialPromotions.count == 1)
        #expect(fetched.socialPromotions[0].platform == "linkedin")
        #expect(fetched.socialPromotions[0].draftText == "Join us for an amazing workshop!")
        #expect(fetched.socialPromotions[0].isPosted == false)
    }

    @Test("Upsert social promotion updates existing entry")
    func upsertUpdatesExisting() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        try EventRepository.shared.upsertSocialPromotion(
            eventID: event.id, platform: "linkedin", draftText: "Version 1")
        try EventRepository.shared.upsertSocialPromotion(
            eventID: event.id, platform: "linkedin", draftText: "Version 2")

        let fetched = try EventRepository.shared.fetch(id: event.id)!
        #expect(fetched.socialPromotions.count == 1)
        #expect(fetched.socialPromotions[0].draftText == "Version 2")
    }

    @Test("Mark social promotion as posted")
    func markPosted() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        try EventRepository.shared.upsertSocialPromotion(
            eventID: event.id, platform: "facebook", draftText: "Come join us!")
        try EventRepository.shared.markSocialPromotionPosted(eventID: event.id, platform: "facebook")

        let fetched = try EventRepository.shared.fetch(id: event.id)!
        #expect(fetched.socialPromotions[0].isPosted == true)
        #expect(fetched.socialPromotions[0].postedAt != nil)
    }
}

// MARK: - Cross-Event Queries

@Suite("Cross-Event Queries", .serialized)
@MainActor
struct CrossEventQueryTests {

    @Test("Active event participations for person")
    func activeParticipationsForPerson() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let c = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Test")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!

        // Upcoming event with invitation sent
        let event1 = try EventRepository.shared.createEvent(
            title: "Workshop A",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        let p1 = try EventRepository.shared.addParticipant(event: event1, person: person)
        try EventRepository.shared.markInviteSent(participationID: p1.id, channel: .email)

        // Past event (should not appear)
        let event2 = try EventRepository.shared.createEvent(
            title: "Workshop B",
            format: .inPerson,
            startDate: Date().addingTimeInterval(-86400),
            endDate: Date().addingTimeInterval(-82800)
        )
        let p2 = try EventRepository.shared.addParticipant(event: event2, person: person)
        try EventRepository.shared.markInviteSent(participationID: p2.id, channel: .email)

        // Upcoming event but not invited (should not appear)
        let event3 = try EventRepository.shared.createEvent(
            title: "Workshop C",
            format: .virtual,
            startDate: Date().addingTimeInterval(172800),
            endDate: Date().addingTimeInterval(176400)
        )
        try EventRepository.shared.addParticipant(event: event3, person: person)

        let active = try EventRepository.shared.activeEventParticipations(for: person.id)
        #expect(active.count == 1)
        #expect(active[0].event?.title == "Workshop A")
    }

    @Test("Events for person returns all events sorted by date")
    func eventsForPerson() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let c = makeContactDTO(identifier: "c1", givenName: "Bob", familyName: "Test")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!

        let event1 = try EventRepository.shared.createEvent(
            title: "Earlier",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        let event2 = try EventRepository.shared.createEvent(
            title: "Later",
            format: .virtual,
            startDate: Date().addingTimeInterval(172800),
            endDate: Date().addingTimeInterval(176400)
        )

        try EventRepository.shared.addParticipant(event: event1, person: person)
        try EventRepository.shared.addParticipant(event: event2, person: person)

        let events = try EventRepository.shared.events(for: person.id)
        #expect(events.count == 2)
        #expect(events[0].title == "Earlier")
        #expect(events[1].title == "Later")
    }
}

// MARK: - Event Undo Round-Trip

@Suite("Event Undo", .serialized)
@MainActor
struct EventUndoTests {

    @Test("Delete event creates undo entry and restore recreates it")
    func deleteAndRestore() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Create event with a participant
        let event = try EventRepository.shared.createEvent(
            title: "Undoable Workshop",
            eventDescription: "Will be deleted then restored",
            format: .hybrid,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000),
            venue: "Room 101",
            targetParticipantCount: 30
        )

        let c = makeContactDTO(identifier: "c1", givenName: "Survivor", familyName: "Person")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!
        try EventRepository.shared.addParticipant(event: event, person: person)

        let eventID = event.id

        // Delete it
        try EventRepository.shared.deleteEvent(id: eventID)

        // Verify it's gone
        #expect(try EventRepository.shared.fetch(id: eventID) == nil)

        // Find the undo entry
        let undoEntries = try UndoRepository.shared.fetchRecent()
        let eventUndo = undoEntries.first { $0.entityType == .event }
        #expect(eventUndo != nil)
        #expect(eventUndo?.entityDisplayName == "Undoable Workshop")

        // Restore it
        try UndoRepository.shared.restore(entry: eventUndo!)

        // Verify restoration — note: the restored event gets a new ID
        let allEvents = try EventRepository.shared.fetchAll()
        let restored = allEvents.first { $0.title == "Undoable Workshop" }
        #expect(restored != nil)
        #expect(restored?.eventDescription == "Will be deleted then restored")
        #expect(restored?.format == .hybrid)
        #expect(restored?.venue == "Room 101")
        #expect(restored?.targetParticipantCount == 30)

        // Participant should be re-linked
        #expect(restored?.participations.count == 1)
        #expect(restored?.participations.first?.person?.displayNameCache == "Survivor Person")
    }
}

// MARK: - RSVP Matching Logic

@Suite("RSVP Matching", .serialized)
@MainActor
struct RSVPMatchingTests {

    // Note: RSVPMatchingService.matchEvent is private, so we test its effects
    // through the public processDetections method indirectly, and test the
    // scoring logic via the observable outcomes on EventRepository.

    @Test("RSVP detection updates existing participant status")
    func rsvpUpdatesExistingParticipant() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Finance Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        event.status = .inviting

        let c = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Responder",
                               emailAddresses: ["alice@test.com"])
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!

        let participation = try EventRepository.shared.addParticipant(event: event, person: person)
        try EventRepository.shared.markInviteSent(participationID: participation.id, channel: .email)

        // Create evidence linked to this person
        let evidence = try EvidenceRepository.shared.create(
            sourceUID: "msg:alice-reply",
            source: .iMessage,
            occurredAt: Date(),
            title: "Message from Alice",
            snippet: "Count me in!"
        )
        evidence.linkedPeople.append(person)

        let detection = RSVPDetectionDTO(
            responseText: "Count me in for the workshop!",
            detectedStatus: .accepted,
            confidence: 0.92
        )

        RSVPMatchingService.shared.processDetections([detection], fromEvidence: evidence)

        // Verify the participation was updated
        let fetched = try EventRepository.shared.fetchParticipation(id: participation.id)!
        #expect(fetched.rsvpStatus == .accepted)
        #expect(fetched.rsvpResponseQuote == "Count me in for the workshop!")
    }

    @Test("RSVP from non-participant auto-adds to nearest event")
    func rsvpAutoAddsNonParticipant() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Financial Planning Seminar",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        event.status = .inviting

        let c = makeContactDTO(identifier: "c1", givenName: "New", familyName: "Attendee",
                               emailAddresses: ["new@test.com"])
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!

        // Person is NOT added to the event yet
        #expect(event.participations.isEmpty)

        let evidence = try EvidenceRepository.shared.create(
            sourceUID: "msg:new-rsvp",
            source: .iMessage,
            occurredAt: Date(),
            title: "Message from new attendee",
            snippet: "I'll be there!"
        )
        evidence.linkedPeople.append(person)

        let detection = RSVPDetectionDTO(
            responseText: "I'll be there for the seminar!",
            detectedStatus: .accepted,
            confidence: 0.85
        )

        RSVPMatchingService.shared.processDetections([detection], fromEvidence: evidence)

        // Should have been auto-added
        let participations = EventRepository.shared.fetchParticipations(for: event)
        #expect(participations.count == 1)
        #expect(participations[0].person?.id == person.id)
        #expect(participations[0].rsvpStatus == .accepted)
        #expect(participations[0].rsvpUserConfirmed == false) // Flagged for review
    }

    @Test("RSVP decline does not auto-add non-participant")
    func declineDoesNotAutoAdd() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        event.status = .inviting

        let c = makeContactDTO(identifier: "c1", givenName: "Declining", familyName: "Person")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!

        let evidence = try EvidenceRepository.shared.create(
            sourceUID: "msg:decline",
            source: .iMessage,
            occurredAt: Date(),
            title: "Decline message",
            snippet: "Can't make it"
        )
        evidence.linkedPeople.append(person)

        let detection = RSVPDetectionDTO(
            responseText: "Sorry, can't make it",
            detectedStatus: .declined,
            confidence: 0.9
        )

        RSVPMatchingService.shared.processDetections([detection], fromEvidence: evidence)

        // Should NOT have been auto-added (only accepted/tentative triggers auto-add)
        let participations = EventRepository.shared.fetchParticipations(for: event)
        #expect(participations.isEmpty)
    }

    @Test("RSVP skips already-confirmed participation")
    func skipsAlreadyConfirmed() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        event.status = .inviting

        let c = makeContactDTO(identifier: "c1", givenName: "Already", familyName: "Confirmed")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!

        let p = try EventRepository.shared.addParticipant(event: event, person: person)
        try EventRepository.shared.markInviteSent(participationID: p.id, channel: .email)

        // Mark as accepted AND user-confirmed
        try EventRepository.shared.updateRSVP(
            participationID: p.id, status: .accepted, userConfirmed: true)

        let evidence = try EvidenceRepository.shared.create(
            sourceUID: "msg:repeat-rsvp",
            source: .iMessage,
            occurredAt: Date(),
            title: "Repeat RSVP",
            snippet: "Just confirming again!"
        )
        evidence.linkedPeople.append(person)

        let detection = RSVPDetectionDTO(
            responseText: "Just confirming I'll be there",
            detectedStatus: .accepted,
            confidence: 0.88
        )

        // Should not crash or change the status
        RSVPMatchingService.shared.processDetections([detection], fromEvidence: evidence)

        let fetched = try EventRepository.shared.fetchParticipation(id: p.id)!
        #expect(fetched.rsvpStatus == .accepted)
        #expect(fetched.rsvpUserConfirmed == true) // Still user-confirmed
    }

    @Test("RSVP detection ignores evidence with no linked people")
    func ignoresUnlinkedEvidence() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )

        let evidence = try EvidenceRepository.shared.create(
            sourceUID: "msg:anonymous",
            source: .iMessage,
            occurredAt: Date(),
            title: "Anonymous message",
            snippet: "I'll be there"
        )
        // No linked people

        let detection = RSVPDetectionDTO(
            responseText: "I'll be there",
            detectedStatus: .accepted,
            confidence: 0.9
        )

        // Should not crash
        RSVPMatchingService.shared.processDetections([detection], fromEvidence: evidence)
    }

    @Test("Highest confidence detection wins when multiple present")
    func highestConfidenceWins() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let event = try EventRepository.shared.createEvent(
            title: "Workshop",
            format: .inPerson,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        event.status = .inviting

        let c = makeContactDTO(identifier: "c1", givenName: "Multi", familyName: "Signal")
        try PeopleRepository.shared.upsert(contact: c)
        let person = try PeopleRepository.shared.fetchAll().first!

        let p = try EventRepository.shared.addParticipant(event: event, person: person)
        try EventRepository.shared.markInviteSent(participationID: p.id, channel: .email)

        let evidence = try EvidenceRepository.shared.create(
            sourceUID: "msg:multi-signal",
            source: .iMessage,
            occurredAt: Date(),
            title: "Ambiguous message",
            snippet: "Maybe... actually yes I'll come"
        )
        evidence.linkedPeople.append(person)

        let detections = [
            RSVPDetectionDTO(responseText: "Maybe", detectedStatus: .tentative, confidence: 0.4),
            RSVPDetectionDTO(responseText: "Yes I'll come", detectedStatus: .accepted, confidence: 0.85)
        ]

        RSVPMatchingService.shared.processDetections(detections, fromEvidence: evidence)

        let fetched = try EventRepository.shared.fetchParticipation(id: p.id)!
        // Should use the 0.85 confidence (accepted), not the 0.4 (tentative)
        #expect(fetched.rsvpStatus == .accepted)
    }
}

// MARK: - RSVPDetectionDTO

@Suite("RSVPDetectionDTO", .serialized)
@MainActor
struct RSVPDetectionDTOTests {

    @Test("Default values for optional fields")
    func defaultValues() {
        let dto = RSVPDetectionDTO(
            responseText: "Count me in",
            detectedStatus: .accepted,
            confidence: 0.9
        )

        #expect(dto.additionalGuestCount == 0)
        #expect(dto.additionalGuestNames.isEmpty)
        #expect(dto.eventReference == nil)
        #expect(dto.senderName == nil)
        #expect(dto.senderEmail == nil)
    }

    @Test("Guest fields populated correctly")
    func guestFields() {
        let dto = RSVPDetectionDTO(
            responseText: "I'll bring Mike and Lisa",
            detectedStatus: .accepted,
            confidence: 0.8,
            additionalGuestCount: 2,
            additionalGuestNames: ["Mike", "Lisa"],
            eventReference: "Thursday finance workshop"
        )

        #expect(dto.additionalGuestCount == 2)
        #expect(dto.additionalGuestNames == ["Mike", "Lisa"])
        #expect(dto.eventReference == "Thursday finance workshop")
    }
}

// MARK: - Presentation Model

@Suite("Presentation Model", .serialized)
@MainActor
struct PresentationModelTests {

    @Test("Create presentation with all fields")
    func createPresentation() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = ModelContext(container)
        let presentation = SamPresentation(
            title: "Retirement Planning 101",
            presentationDescription: "Comprehensive overview of retirement strategies",
            topicTags: ["retirement", "planning", "IRA"],
            estimatedDurationMinutes: 60,
            targetAudience: "Pre-retirees 55-65"
        )
        ctx.insert(presentation)
        try ctx.save()

        let descriptor = FetchDescriptor<SamPresentation>()
        let all = try ctx.fetch(descriptor)
        #expect(all.count == 1)
        #expect(all[0].title == "Retirement Planning 101")
        #expect(all[0].topicTags.count == 3)
        #expect(all[0].estimatedDurationMinutes == 60)
        #expect(all[0].targetAudience == "Pre-retirees 55-65")
    }

    @Test("Presentation linked to events tracks delivery")
    func deliveryTracking() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = ModelContext(container)
        let presentation = SamPresentation(title: "Finance 101")
        ctx.insert(presentation)

        // Completed event
        let pastEvent = SamEvent(
            title: "Past Delivery",
            format: .inPerson,
            startDate: Date().addingTimeInterval(-86400),
            endDate: Date().addingTimeInterval(-82800)
        )
        pastEvent.statusRawValue = EventStatus.completed.rawValue
        pastEvent.presentation = presentation
        ctx.insert(pastEvent)

        // Upcoming event
        let futureEvent = SamEvent(
            title: "Next Delivery",
            format: .virtual,
            startDate: Date().addingTimeInterval(86400),
            endDate: Date().addingTimeInterval(90000)
        )
        futureEvent.presentation = presentation
        ctx.insert(futureEvent)

        try ctx.save()

        #expect(presentation.deliveryCount == 1)
        #expect(presentation.lastDeliveredAt != nil)
        #expect(presentation.nextScheduledAt != nil)
    }

    @Test("PresentationFile embedded struct round-trips")
    func presentationFileRoundTrip() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = ModelContext(container)
        let presentation = SamPresentation(title: "With Files")

        let file = PresentationFile(
            fileName: "slides.pdf",
            fileType: "pdf",
            bookmarkData: Data([0x01, 0x02, 0x03]),
            fileSizeBytes: 1_024_000
        )
        presentation.fileAttachments = [file]

        ctx.insert(presentation)
        try ctx.save()

        let descriptor = FetchDescriptor<SamPresentation>()
        let fetched = try ctx.fetch(descriptor).first!
        #expect(fetched.fileAttachments.count == 1)
        #expect(fetched.fileAttachments[0].fileName == "slides.pdf")
        #expect(fetched.fileAttachments[0].fileType == "pdf")
        #expect(fetched.fileAttachments[0].fileSizeBytes == 1_024_000)
        #expect(fetched.fileAttachments[0].bookmarkData == Data([0x01, 0x02, 0x03]))
    }

    @Test("AI content fields stored and retrieved")
    func aiContentFields() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = ModelContext(container)
        let presentation = SamPresentation(title: "Analyzed Presentation")
        presentation.contentSummary = "This presentation covers retirement planning strategies."
        presentation.keyTalkingPoints = ["IRA contribution limits", "Roth vs Traditional", "Required distributions"]
        presentation.contentAnalyzedAt = Date()

        ctx.insert(presentation)
        try ctx.save()

        let descriptor = FetchDescriptor<SamPresentation>()
        let fetched = try ctx.fetch(descriptor).first!
        #expect(fetched.contentSummary?.contains("retirement") == true)
        #expect(fetched.keyTalkingPoints.count == 3)
        #expect(fetched.contentAnalyzedAt != nil)
    }
}

// MARK: - Enum Behavior

@Suite("Event Enums", .serialized)
struct EventEnumTests {

    @Test("EventFormat all cases have display names and icons")
    func eventFormatCoverage() {
        for format in EventFormat.allCases {
            #expect(!format.displayName.isEmpty)
            #expect(!format.icon.isEmpty)
        }
    }

    @Test("EventStatus all cases have display names and icons")
    func eventStatusCoverage() {
        for status in EventStatus.allCases {
            #expect(!status.displayName.isEmpty)
            #expect(!status.icon.isEmpty)
        }
    }

    @Test("RSVPStatus all cases have display names, icons, and colors")
    func rsvpStatusCoverage() {
        for status in RSVPStatus.allCases {
            #expect(!status.displayName.isEmpty)
            #expect(!status.icon.isEmpty)
            #expect(!status.color.isEmpty)
        }
    }

    @Test("ParticipantPriority auto-ack rules")
    func priorityAutoAck() {
        #expect(ParticipantPriority.standard.allowsAutoAcknowledge == true)
        #expect(ParticipantPriority.key.allowsAutoAcknowledge == false)
        #expect(ParticipantPriority.vip.allowsAutoAcknowledge == false)
    }

    @Test("ParticipantPriority sort order: VIP < key < standard")
    func prioritySortOrder() {
        #expect(ParticipantPriority.vip.sortOrder < ParticipantPriority.key.sortOrder)
        #expect(ParticipantPriority.key.sortOrder < ParticipantPriority.standard.sortOrder)
    }
}
