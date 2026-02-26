//
//  UndoRepository.swift
//  SAM
//
//  Created by Assistant on 2/25/26.
//  Phase P: Universal Undo System
//
//  Captures and restores undo snapshots using SwiftData-persisted entries.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "UndoRepository")

@MainActor
@Observable
final class UndoRepository {

    // MARK: - Singleton

    static let shared = UndoRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var modelContext: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.modelContext = ModelContext(container)
    }

    // MARK: - Capture

    /// Capture an undo snapshot before a destructive operation.
    /// Returns the persisted entry (used by coordinator for toast display).
    @discardableResult
    func capture<T: Encodable>(
        operation: UndoOperation,
        entityType: UndoEntityType,
        entityID: UUID,
        entityDisplayName: String,
        snapshot: T
    ) throws -> SamUndoEntry {
        guard let modelContext else { throw UndoError.notConfigured }

        let data = try JSONEncoder().encode(snapshot)

        let entry = SamUndoEntry(
            operation: operation,
            entityType: entityType,
            entityID: entityID,
            entityDisplayName: entityDisplayName,
            snapshotData: data
        )

        modelContext.insert(entry)
        try modelContext.save()
        logger.info("Captured undo: \(operation.rawValue) \(entityType.rawValue) '\(entityDisplayName)'")
        return entry
    }

    // MARK: - Restore

    /// Restore an entity from its undo entry. Dispatches to entity-specific helpers.
    func restore(entry: SamUndoEntry) throws {
        switch entry.entityType {
        case .note:
            try restoreNote(entry.snapshotData)
        case .outcome:
            try restoreOutcomeStatus(entry.snapshotData)
        case .context:
            try restoreContext(entry.snapshotData)
        case .participation:
            try restoreParticipation(entry.snapshotData)
        case .insight:
            try restoreInsight(entry.snapshotData)
        }

        entry.isRestored = true
        entry.restoredAt = .now
        try modelContext?.save()
        logger.info("Restored undo: \(entry.entityType.rawValue) '\(entry.entityDisplayName)'")
    }

    // MARK: - Queries

    /// Fetch recent undo entries, newest first.
    func fetchRecent(limit: Int = 50) throws -> [SamUndoEntry] {
        guard let modelContext else { throw UndoError.notConfigured }

        let descriptor = FetchDescriptor<SamUndoEntry>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        let all = try modelContext.fetch(descriptor)
        return Array(all.filter { !$0.isRestored }.prefix(limit))
    }

    // MARK: - Pruning

    /// Delete entries past their expiresAt date.
    func pruneExpired() throws {
        guard let modelContext else { throw UndoError.notConfigured }

        let now = Date.now
        let descriptor = FetchDescriptor<SamUndoEntry>()
        let all = try modelContext.fetch(descriptor)

        var pruned = 0
        for entry in all where entry.expiresAt < now {
            modelContext.delete(entry)
            pruned += 1
        }

        if pruned > 0 {
            try modelContext.save()
            logger.info("Pruned \(pruned) expired undo entries")
        }
    }

    // MARK: - Private Restore Helpers

    private func restoreNote(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(NoteSnapshot.self, from: data)

        try NotesRepository.shared.createForRestore(
            id: snapshot.id,
            content: snapshot.content,
            summary: snapshot.summary,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            sourceTypeRawValue: snapshot.sourceTypeRawValue,
            sourceImportUID: snapshot.sourceImportUID,
            isAnalyzed: snapshot.isAnalyzed,
            analysisVersion: snapshot.analysisVersion,
            extractedMentions: snapshot.extractedMentions,
            extractedActionItems: snapshot.extractedActionItems,
            extractedTopics: snapshot.extractedTopics,
            discoveredRelationships: snapshot.discoveredRelationships,
            lifeEvents: snapshot.lifeEvents,
            followUpDraft: snapshot.followUpDraft,
            linkedPeopleIDs: snapshot.linkedPeopleIDs,
            linkedContextIDs: snapshot.linkedContextIDs,
            linkedEvidenceIDs: snapshot.linkedEvidenceIDs
        )

        logger.info("Restored note '\(snapshot.content.prefix(40))…'")
    }

    private func restoreOutcomeStatus(_ data: Data) throws {
        guard let modelContext else { throw UndoError.notConfigured }

        let snapshot = try JSONDecoder().decode(OutcomeSnapshot.self, from: data)
        let outcomeID = snapshot.id

        let descriptor = FetchDescriptor<SamOutcome>(
            predicate: #Predicate { $0.id == outcomeID }
        )
        guard let outcome = try modelContext.fetch(descriptor).first else {
            logger.warning("Cannot restore outcome — not found: \(outcomeID)")
            return
        }

        outcome.statusRawValue = snapshot.previousStatusRawValue
        outcome.dismissedAt = snapshot.previousDismissedAt
        outcome.completedAt = snapshot.previousCompletedAt
        outcome.wasActedOn = snapshot.previousWasActedOn
        try modelContext.save()

        logger.info("Restored outcome status: '\(snapshot.title)'")
    }

    private func restoreContext(_ data: Data) throws {
        guard let modelContext else { throw UndoError.notConfigured }

        let snapshot = try JSONDecoder().decode(ContextSnapshot.self, from: data)

        guard let kind = ContextKind(rawValue: snapshot.kindRawValue) else {
            logger.warning("Cannot restore context — unknown kind: \(snapshot.kindRawValue)")
            return
        }

        let newContext = SamContext(
            id: snapshot.id,
            name: snapshot.name,
            kind: kind,
            consentAlertCount: snapshot.consentAlertCount,
            reviewAlertCount: snapshot.reviewAlertCount,
            followUpAlertCount: snapshot.followUpAlertCount
        )

        modelContext.insert(newContext)

        // Re-create participations
        for pSnap in snapshot.participations {
            let personID = pSnap.personID
            let personDescriptor = FetchDescriptor<SamPerson>(
                predicate: #Predicate { $0.id == personID }
            )
            guard let person = try modelContext.fetch(personDescriptor).first else {
                logger.warning("Cannot restore participation — person not found: \(pSnap.personID)")
                continue
            }

            let participation = ContextParticipation(
                id: pSnap.id,
                person: person,
                context: newContext,
                roleBadges: pSnap.roleBadges,
                isPrimary: pSnap.isPrimary,
                note: pSnap.note,
                startDate: pSnap.startDate
            )
            participation.endDate = pSnap.endDate
            newContext.participations.append(participation)
        }

        try modelContext.save()
        logger.info("Restored context '\(snapshot.name)' with \(snapshot.participations.count) participations")
    }

    private func restoreParticipation(_ data: Data) throws {
        guard let modelContext else { throw UndoError.notConfigured }

        let snapshot = try JSONDecoder().decode(ParticipationSnapshot.self, from: data)

        let personID = snapshot.personID
        let contextID = snapshot.contextID

        let personDescriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.id == personID }
        )
        let contextDescriptor = FetchDescriptor<SamContext>(
            predicate: #Predicate { $0.id == contextID }
        )

        guard let person = try modelContext.fetch(personDescriptor).first else {
            logger.warning("Cannot restore participation — person not found: \(snapshot.personID)")
            return
        }
        guard let samContext = try modelContext.fetch(contextDescriptor).first else {
            logger.warning("Cannot restore participation — context not found: \(snapshot.contextID)")
            return
        }

        try ContextsRepository.shared.addParticipant(
            person: person,
            to: samContext,
            roleBadges: snapshot.roleBadges,
            isPrimary: snapshot.isPrimary,
            note: snapshot.note
        )

        logger.info("Restored participation: \(snapshot.personDisplayName) in \(snapshot.contextName)")
    }

    private func restoreInsight(_ data: Data) throws {
        guard let modelContext else { throw UndoError.notConfigured }

        let snapshot = try JSONDecoder().decode(InsightSnapshot.self, from: data)
        let insightID = snapshot.id

        let descriptor = FetchDescriptor<SamInsight>(
            predicate: #Predicate { $0.id == insightID }
        )
        guard let insight = try modelContext.fetch(descriptor).first else {
            logger.warning("Cannot restore insight — not found: \(insightID)")
            return
        }

        insight.dismissedAt = nil
        try modelContext.save()

        logger.info("Restored insight: '\(snapshot.title)'")
    }

    // MARK: - Errors

    enum UndoError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "UndoRepository not configured — call configure(container:) first"
            }
        }
    }
}
