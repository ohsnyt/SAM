//
//  NotesRepository.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase H: Notes & Note Intelligence
//
//  SwiftData CRUD operations for SamNote with LLM analysis support.
//

import SwiftData
import Foundation

@MainActor
@Observable
final class NotesRepository {

    // MARK: - Singleton

    static let shared = NotesRepository()

    private init() {}

    // MARK: - Configuration

    private var container: ModelContainer?
    private var modelContext: ModelContext?

    /// Configure the repository with the shared ModelContainer.
    /// Must be called at app launch before any data operations.
    func configure(container: ModelContainer) {
        self.container = container
        self.modelContext = ModelContext(container)
    }

    // MARK: - CRUD Operations

    /// Fetch all notes, sorted by most recently updated first.
    func fetchAll() throws -> [SamNote] {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamNote>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    /// Fetch a single note by ID
    func fetch(id: UUID) throws -> SamNote? {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamNote>(
            predicate: #Predicate { note in
                note.id == id
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    /// Create a new note
    @discardableResult
    func create(
        content: String,
        sourceType: SamNote.SourceType = .typed,
        linkedPeopleIDs: [UUID] = [],
        linkedContextIDs: [UUID] = [],
        linkedEvidenceIDs: [UUID] = []
    ) throws -> SamNote {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Re-fetch objects in this context
        let allPeople = try modelContext.fetch(FetchDescriptor<SamPerson>())
        let allContexts = try modelContext.fetch(FetchDescriptor<SamContext>())
        let allEvidence = try modelContext.fetch(FetchDescriptor<SamEvidenceItem>())

        let linkedPeople = allPeople.filter { linkedPeopleIDs.contains($0.id) }
        let linkedContexts = allContexts.filter { linkedContextIDs.contains($0.id) }
        let linkedEvidence = allEvidence.filter { linkedEvidenceIDs.contains($0.id) }

        let note = SamNote(
            content: content,
            sourceType: sourceType
        )

        // Establish relationships
        note.linkedPeople = linkedPeople
        note.linkedContexts = linkedContexts
        note.linkedEvidence = linkedEvidence

        modelContext.insert(note)
        try modelContext.save()

        return note
    }

    /// Update an existing note's content (marks as unanalyzed)
    func update(note: SamNote, content: String) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        note.content = content
        note.updatedAt = .now
        note.isAnalyzed = false  // Trigger re-analysis

        try modelContext.save()
    }

    /// Update note links (people, contexts, evidence)
    func updateLinks(
        note: SamNote,
        peopleIDs: [UUID]? = nil,
        contextIDs: [UUID]? = nil,
        evidenceIDs: [UUID]? = nil
    ) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Re-fetch objects in this context
        if let peopleIDs = peopleIDs {
            let allPeople = try modelContext.fetch(FetchDescriptor<SamPerson>())
            note.linkedPeople = allPeople.filter { peopleIDs.contains($0.id) }
        }
        if let contextIDs = contextIDs {
            let allContexts = try modelContext.fetch(FetchDescriptor<SamContext>())
            note.linkedContexts = allContexts.filter { contextIDs.contains($0.id) }
        }
        if let evidenceIDs = evidenceIDs {
            let allEvidence = try modelContext.fetch(FetchDescriptor<SamEvidenceItem>())
            note.linkedEvidence = allEvidence.filter { evidenceIDs.contains($0.id) }
        }

        note.updatedAt = .now
        try modelContext.save()
    }

    /// Store LLM analysis results
    func storeAnalysis(
        note: SamNote,
        summary: String?,
        extractedMentions: [ExtractedPersonMention],
        extractedActionItems: [NoteActionItem],
        extractedTopics: [String],
        discoveredRelationships: [DiscoveredRelationship] = [],
        analysisVersion: Int
    ) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        note.summary = summary
        note.extractedMentions = extractedMentions
        note.extractedActionItems = extractedActionItems
        note.extractedTopics = extractedTopics
        note.discoveredRelationships = discoveredRelationships
        note.isAnalyzed = true
        note.analysisVersion = analysisVersion
        note.updatedAt = .now

        try modelContext.save()
    }

    /// Update action item status
    func updateActionItem(
        note: SamNote,
        actionItemID: UUID,
        status: NoteActionItem.ActionStatus
    ) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        guard let index = note.extractedActionItems.firstIndex(where: { $0.id == actionItemID }) else {
            throw NSError(domain: "NotesRepository", code: 404, userInfo: [NSLocalizedDescriptionKey: "Action item not found"])
        }

        var updatedItem = note.extractedActionItems[index]
        updatedItem.status = status
        note.extractedActionItems[index] = updatedItem

        try modelContext.save()
    }

    /// Delete a note
    func delete(note: SamNote) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        modelContext.delete(note)
        try modelContext.save()
    }

    // MARK: - Query Operations

    /// Fetch notes linked to a specific person
    func fetchNotes(forPerson person: SamPerson) throws -> [SamNote] {
        let personID = person.id
        let all = try fetchAll()
        return all.filter { note in
            note.linkedPeople.contains(where: { $0.id == personID })
        }
    }

    /// Fetch notes linked to a specific context
    func fetchNotes(forContext samContext: SamContext) throws -> [SamNote] {
        let contextID = samContext.id
        let all = try fetchAll()
        return all.filter { note in
            note.linkedContexts.contains(where: { $0.id == contextID })
        }
    }

    /// Fetch notes linked to a specific evidence item
    func fetchNotes(forEvidence evidence: SamEvidenceItem) throws -> [SamNote] {
        let evidenceID = evidence.id
        let all = try fetchAll()
        return all.filter { note in
            note.linkedEvidence.contains(where: { $0.id == evidenceID })
        }
    }

    /// Search notes by content or summary
    func search(query: String) throws -> [SamNote] {
        guard !query.isEmpty else {
            return try fetchAll()
        }

        let lowercaseQuery = query.lowercased()
        let all = try fetchAll()

        return all.filter { note in
            note.content.lowercased().contains(lowercaseQuery) ||
            note.summary?.lowercased().contains(lowercaseQuery) == true
        }
    }

    /// Fetch notes that need analysis (not analyzed or content changed)
    func fetchUnanalyzedNotes() throws -> [SamNote] {
        let all = try fetchAll()
        return all.filter { !$0.isAnalyzed }
    }

    /// Fetch notes with pending action items
    func fetchNotesWithPendingActions() throws -> [SamNote] {
        let all = try fetchAll()
        return all.filter { note in
            note.extractedActionItems.contains(where: { $0.status == .pending })
        }
    }

    // MARK: - Import Operations (Phase L)

    /// Create a note from an external import (e.g., Evernote ENEX)
    @discardableResult
    func createFromImport(
        sourceImportUID: String,
        content: String,
        createdAt: Date,
        updatedAt: Date,
        linkedPeopleIDs: [UUID] = []
    ) throws -> SamNote {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let note = SamNote(
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourceImportUID: sourceImportUID
        )

        if !linkedPeopleIDs.isEmpty {
            let allPeople = try modelContext.fetch(FetchDescriptor<SamPerson>())
            note.linkedPeople = allPeople.filter { linkedPeopleIDs.contains($0.id) }
        }

        modelContext.insert(note)
        try modelContext.save()

        return note
    }

    /// Find a note by its source import UID (for dedup)
    func fetchBySourceImportUID(_ uid: String) throws -> SamNote? {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let all = try modelContext.fetch(FetchDescriptor<SamNote>())
        return all.first { $0.sourceImportUID == uid }
    }
}
