//
//  NotesRepositoryTests.swift
//  SAMTests
//
//  Unit tests for NotesRepository CRUD, search, analysis, and action items.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("NotesRepository Tests", .serialized)
@MainActor
struct NotesRepositoryTests {

    // MARK: - Create

    @Test("Create note returns note with correct properties")
    func createNoteReturnsNote() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note = try NotesRepository.shared.create(content: "Met with client today about retirement planning.")

        #expect(note.content == "Met with client today about retirement planning.")
        #expect(note.isAnalyzed == false)
    }

    @Test("Create note with linked people")
    func createNoteWithLinkedPeople() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let contactDTO = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Johnson")
        try PeopleRepository.shared.upsert(contact: contactDTO)
        let person = try PeopleRepository.shared.fetchAll()[0]

        let note = try NotesRepository.shared.create(
            content: "Discussed insurance options with Alice.",
            linkedPeopleIDs: [person.id]
        )

        #expect(note.linkedPeople.count == 1)
        #expect(note.linkedPeople[0].id == person.id)
    }

    @Test("Create note with linked contexts")
    func createNoteWithLinkedContexts() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx = try ContextsRepository.shared.create(name: "Smith Group", kind: .business)

        let note = try NotesRepository.shared.create(
            content: "Household review notes.",
            linkedContextIDs: [ctx.id]
        )

        #expect(note.linkedContexts.count == 1)
        #expect(note.linkedContexts[0].id == ctx.id)
    }

    // MARK: - Fetch

    @Test("Fetch by ID returns matching note")
    func fetchByIdReturnsNote() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let created = try NotesRepository.shared.create(content: "Test note content")
        let fetched = try NotesRepository.shared.fetch(id: created.id)

        #expect(fetched != nil)
        #expect(fetched?.content == "Test note content")
    }

    // MARK: - Update

    @Test("Update content changes text")
    func updateContentChangesText() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note = try NotesRepository.shared.create(content: "Original content")
        try NotesRepository.shared.update(note: note, content: "Updated content")

        #expect(note.content == "Updated content")
    }

    @Test("Update content resets analysis flag")
    func updateContentResetsAnalysis() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note = try NotesRepository.shared.create(content: "Some content")

        // Manually mark as analyzed
        note.isAnalyzed = true

        try NotesRepository.shared.update(note: note, content: "Changed content")

        #expect(note.isAnalyzed == false)
    }

    // MARK: - Delete

    @Test("Delete removes note")
    func deleteRemovesNote() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note = try NotesRepository.shared.create(content: "To delete")
        try NotesRepository.shared.delete(note: note)

        let all = try NotesRepository.shared.fetchAll()
        #expect(all.isEmpty)
    }

    // MARK: - Query by Person/Context

    @Test("Fetch notes for person returns linked notes")
    func fetchNotesForPerson() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let contact1 = makeContactDTO(identifier: "c1", givenName: "Alice", familyName: "Johnson")
        let contact2 = makeContactDTO(identifier: "c2", givenName: "Bob", familyName: "Smith")
        try PeopleRepository.shared.upsert(contact: contact1)
        try PeopleRepository.shared.upsert(contact: contact2)
        let people = try PeopleRepository.shared.fetchAll()
        let alice = people.first { $0.contactIdentifier == "c1" }!
        let bob = people.first { $0.contactIdentifier == "c2" }!

        _ = try NotesRepository.shared.create(content: "Note about Alice", linkedPeopleIDs: [alice.id])
        _ = try NotesRepository.shared.create(content: "Note about Bob", linkedPeopleIDs: [bob.id])
        _ = try NotesRepository.shared.create(content: "Unrelated note")

        let aliceNotes = try NotesRepository.shared.fetchNotes(forPerson: alice)
        #expect(aliceNotes.count == 1)
        #expect(aliceNotes[0].content == "Note about Alice")

        let allNotes = try NotesRepository.shared.fetchAll()
        #expect(allNotes.count == 3)
    }

    @Test("Fetch notes for context returns linked notes")
    func fetchNotesForContext() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let ctx1 = try ContextsRepository.shared.create(name: "Smith Group", kind: .business)
        let ctx2 = try ContextsRepository.shared.create(name: "Johnson Business", kind: .business)

        _ = try NotesRepository.shared.create(content: "Household note", linkedContextIDs: [ctx1.id])
        _ = try NotesRepository.shared.create(content: "Business note", linkedContextIDs: [ctx2.id])
        _ = try NotesRepository.shared.create(content: "Unrelated note")

        let householdNotes = try NotesRepository.shared.fetchNotes(forContext: ctx1)
        #expect(householdNotes.count == 1)
        #expect(householdNotes[0].content == "Household note")

        let allNotes = try NotesRepository.shared.fetchAll()
        #expect(allNotes.count == 3)
    }

    // MARK: - Search

    @Test("Search by content finds matching note")
    func searchByContent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        _ = try NotesRepository.shared.create(content: "Discussed life insurance options and retirement planning.")
        _ = try NotesRepository.shared.create(content: "Quick follow-up call about scheduling.")

        let results = try NotesRepository.shared.search(query: "insurance")
        #expect(results.count == 1)
    }

    @Test("Search by summary finds matching note")
    func searchBySummary() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note = try NotesRepository.shared.create(content: "Long detailed note about financial planning.")
        note.summary = "retirement planning discussion with client"

        _ = try NotesRepository.shared.create(content: "Unrelated note")

        let results = try NotesRepository.shared.search(query: "retirement")
        #expect(results.count == 1)
    }

    // MARK: - Analysis

    @Test("Fetch unanalyzed notes returns only unanalyzed")
    func fetchUnanalyzedNotes() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note1 = try NotesRepository.shared.create(content: "Note 1")
        _ = try NotesRepository.shared.create(content: "Note 2")
        _ = try NotesRepository.shared.create(content: "Note 3")

        // Mark one as analyzed
        note1.isAnalyzed = true

        let unanalyzed = try NotesRepository.shared.fetchUnanalyzedNotes()
        #expect(unanalyzed.count == 2)
    }

    @Test("storeAnalysis sets summary, topics, and isAnalyzed")
    func storeAnalysisSetsFields() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note = try NotesRepository.shared.create(content: "Met with John about his 401k rollover options.")

        try NotesRepository.shared.storeAnalysis(
            note: note,
            summary: "Discussion about 401k rollover",
            extractedMentions: [],
            extractedActionItems: [
                NoteActionItem(
                    type: .generalFollowUp,
                    description: "Send 401k rollover paperwork",
                    status: .pending
                )
            ],
            extractedTopics: ["401k", "rollover"],
            analysisVersion: 1
        )

        #expect(note.isAnalyzed == true)
        #expect(note.summary == "Discussion about 401k rollover")
        #expect(note.extractedTopics == ["401k", "rollover"])
        #expect(note.extractedActionItems.count == 1)
    }

    @Test("Update action item changes status")
    func updateActionItemChangesStatus() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note = try NotesRepository.shared.create(content: "Follow up needed.")

        let actionItem = NoteActionItem(
            type: .generalFollowUp,
            description: "Send documents",
            status: .pending
        )

        try NotesRepository.shared.storeAnalysis(
            note: note,
            summary: nil,
            extractedMentions: [],
            extractedActionItems: [actionItem],
            extractedTopics: [],
            analysisVersion: 1
        )

        let actionID = note.extractedActionItems[0].id
        try NotesRepository.shared.updateActionItem(note: note, actionItemID: actionID, status: .completed)

        #expect(note.extractedActionItems[0].status == .completed)
    }

    @Test("Fetch notes with pending actions returns correct notes")
    func fetchNotesWithPendingActions() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        let note1 = try NotesRepository.shared.create(content: "Note with pending action")
        let note2 = try NotesRepository.shared.create(content: "Note with completed action")

        try NotesRepository.shared.storeAnalysis(
            note: note1,
            summary: nil,
            extractedMentions: [],
            extractedActionItems: [
                NoteActionItem(type: .generalFollowUp, description: "Do something", status: .pending)
            ],
            extractedTopics: [],
            analysisVersion: 1
        )

        try NotesRepository.shared.storeAnalysis(
            note: note2,
            summary: nil,
            extractedMentions: [],
            extractedActionItems: [
                NoteActionItem(type: .generalFollowUp, description: "Done thing", status: .completed)
            ],
            extractedTopics: [],
            analysisVersion: 1
        )

        let pending = try NotesRepository.shared.fetchNotesWithPendingActions()
        #expect(pending.count == 1)
        #expect(pending[0].content == "Note with pending action")
    }
}
