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
        case .person:
            try restorePersonMerge(entry.snapshotData)
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

    private func restorePersonMerge(_ data: Data) throws {
        guard let modelContext else { throw UndoError.notConfigured }

        let snapshot = try JSONDecoder().decode(PersonMergeSnapshot.self, from: data)
        let targetID = snapshot.targetPersonID

        // Find the target person (the one that absorbed the source)
        let allPeople = try modelContext.fetch(FetchDescriptor<SamPerson>())
        guard let target = allPeople.first(where: { $0.id == targetID }) else {
            logger.warning("Cannot restore person merge — target not found: \(targetID)")
            return
        }

        // Re-create source person with original scalar fields
        let source = SamPerson(
            id: snapshot.sourcePersonID,
            displayName: snapshot.displayName,
            roleBadges: snapshot.roleBadges,
            contactIdentifier: snapshot.contactIdentifier,
            email: snapshot.email,
            isMe: snapshot.isMe
        )
        source.displayNameCache = snapshot.displayNameCache
        source.emailCache = snapshot.emailCache
        source.emailAliases = snapshot.emailAliases
        source.phoneAliases = snapshot.phoneAliases
        source.isArchived = snapshot.isArchived
        source.relationshipSummary = snapshot.relationshipSummary
        source.relationshipKeyThemes = snapshot.relationshipKeyThemes
        source.relationshipNextSteps = snapshot.relationshipNextSteps
        source.preferredCadenceDays = snapshot.preferredCadenceDays
        source.preferredChannelRawValue = snapshot.preferredChannelRawValue
        source.inferredChannelRawValue = snapshot.inferredChannelRawValue
        source.linkedInProfileURL = snapshot.linkedInProfileURL
        source.linkedInConnectedOn = snapshot.linkedInConnectedOn
        source.facebookProfileURL = snapshot.facebookProfileURL
        source.facebookFriendedOn = snapshot.facebookFriendedOn
        source.facebookMessageCount = snapshot.facebookMessageCount
        source.facebookLastMessageDate = snapshot.facebookLastMessageDate
        source.facebookTouchScore = snapshot.facebookTouchScore

        modelContext.insert(source)

        // Re-point transferred evidence back to source
        let evidenceIDs = Set(snapshot.evidenceIDs)
        for item in target.linkedEvidence where evidenceIDs.contains(item.id) {
            source.linkedEvidence.append(item)
        }

        // Re-point transferred notes back to source
        let noteIDs = Set(snapshot.noteIDs)
        for note in target.linkedNotes where noteIDs.contains(note.id) {
            source.linkedNotes.append(note)
        }

        // Re-point participations back to source
        let participationIDs = Set(snapshot.participationIDs)
        for p in target.participations where participationIDs.contains(p.id) {
            p.person = source
        }

        // Re-point insights back to source
        let insightIDs = Set(snapshot.insightIDs)
        for insight in target.insights where insightIDs.contains(insight.id) {
            insight.samPerson = source
        }

        // Re-point stage transitions back to source
        let transitionIDs = Set(snapshot.transitionIDs)
        for t in target.stageTransitions where transitionIDs.contains(t.id) {
            t.person = source
        }

        // Re-point recruiting stages back to source
        let recruitingStageIDs = Set(snapshot.recruitingStageIDs)
        for rs in target.recruitingStages where recruitingStageIDs.contains(rs.id) {
            rs.person = source
        }

        // Re-point production records back to source
        let productionRecordIDs = Set(snapshot.productionRecordIDs)
        for pr in target.productionRecords where productionRecordIDs.contains(pr.id) {
            pr.person = source
        }

        // Re-point outcomes back to source
        let outcomeIDs = Set(snapshot.outcomeIDs)
        let allOutcomes = try modelContext.fetch(FetchDescriptor<SamOutcome>())
        for outcome in allOutcomes where outcomeIDs.contains(outcome.id) {
            outcome.linkedPerson = source
        }

        // Re-point deduced relations back to source
        let deducedIDs = Set(snapshot.deducedRelationIDs)
        let allDeduced = try modelContext.fetch(FetchDescriptor<DeducedRelation>())
        for relation in allDeduced where deducedIDs.contains(relation.id) {
            if relation.personAID == targetID {
                relation.personAID = snapshot.sourcePersonID
            }
            if relation.personBID == targetID {
                relation.personBID = snapshot.sourcePersonID
            }
        }

        // Re-point extracted mentions back to source
        let allNotes = try modelContext.fetch(FetchDescriptor<SamNote>())
        for note in allNotes {
            var updated = false
            var mentions = note.extractedMentions
            for i in mentions.indices {
                if mentions[i].matchedPersonID == targetID {
                    // Only revert if this was originally the source's ID
                    // (we can't perfectly distinguish, but best effort)
                    mentions[i].matchedPersonID = snapshot.sourcePersonID
                    updated = true
                }
            }
            if updated {
                note.extractedMentions = mentions
            }
        }

        // Remove unioned scalars from target
        target.emailAliases.removeAll { snapshot.unionedEmails.contains($0) }
        target.phoneAliases.removeAll { snapshot.unionedPhones.contains($0) }
        target.roleBadges.removeAll { snapshot.unionedRoleBadges.contains($0) }

        try modelContext.save()
        logger.info("Restored person merge: re-created '\(snapshot.sourceDisplayName)'")
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
