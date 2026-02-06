//
//  EvidenceRepository.swift
//  SAM_crm
//
//  Evidence Inbox Repository.
//  This is the substrate for “intelligence”: evidence → proposed links/signals → user confirmation.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class EvidenceRepository {
    static let shared = EvidenceRepository()

    /// The container is injected once at app launch via `configure(container:)`.
    /// The fallback closure is a safety net for unit tests that construct
    /// the repository in isolation; production always goes through the
    /// app-level container (which includes *all* models and the
    /// FixtureSeeder).
    private var container: ModelContainer

    init(container: ModelContainer? = nil) {
        self.container = container ?? (try! ModelContainer(for: SamEvidenceItem.self))
    }

    /// Replaces the container with the app-wide one.  Must be called
    /// once at launch — before any calendar import or query — so that
    /// this repository's writes land in the same store that SwiftUI's
    /// `@Query` properties observe.
    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Fetching Items

    func needsReview() throws -> [SamEvidenceItem] {
        let fetchDescriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        return try container.mainContext.fetch(fetchDescriptor)
            .filter { $0.state == .needsReview }
    }

    func done() throws -> [SamEvidenceItem] {
        let fetchDescriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        return try container.mainContext.fetch(fetchDescriptor)
            .filter { $0.state == .done }
    }

    func item(id: UUID?) throws -> SamEvidenceItem? {
        guard let id else { return nil }
        let fetchDescriptor = FetchDescriptor<SamEvidenceItem>(
            predicate: #Predicate { $0.id == id }
        )
        return try container.mainContext.fetch(fetchDescriptor).first
    }

    // MARK: - Upsert & Prune (Calendar import)

    /// Inserts or updates a SamEvidenceItem by sourceUID when present; otherwise inserts.
    func upsert(_ newItem: SamEvidenceItem) throws {
        let ctx = container.mainContext
        if let uid = newItem.sourceUID {
            let fetch = FetchDescriptor<SamEvidenceItem>(
                predicate: #Predicate { $0.sourceUID == uid }
            )
            if let existing = try ctx.fetch(fetch).first {
                existing.state            = newItem.state
                existing.occurredAt       = newItem.occurredAt
                existing.title            = newItem.title
                existing.snippet          = newItem.snippet
                existing.bodyText         = newItem.bodyText
                existing.participantHints = newItem.participantHints
                existing.signals          = newItem.signals
                existing.proposedLinks    = newItem.proposedLinks
                existing.linkedPeople     = newItem.linkedPeople
                existing.linkedContexts   = newItem.linkedContexts
                try ctx.save()
                return
            }
        }
        ctx.insert(newItem)
        try ctx.save()
    }

    /// Deletes calendar-sourced evidence in the given window whose sourceUID is not in currentUIDs.
    func pruneCalendarEvidenceNotIn(_ currentUIDs: Set<String>, windowStart: Date, windowEnd: Date) {
        let ctx = container.mainContext
        // Date comparisons are fine in #Predicate; source is a
        // RawRepresentable enum so we filter that in Swift after fetch.
        let fetch = FetchDescriptor<SamEvidenceItem>(
            predicate: #Predicate {
                $0.occurredAt >= windowStart &&
                $0.occurredAt <= windowEnd
            }
        )
        guard let items = try? ctx.fetch(fetch) else { return }
        for item in items where item.source == .calendar {
            if let uid = item.sourceUID, !currentUIDs.contains(uid) {
                ctx.delete(item)
            }
        }
        try? ctx.save()
    }

    // MARK: - Mutations

    func markDone(_ evidenceID: UUID) throws {
        guard let item = try item(id: evidenceID) else { return }
        item.state = .done
        try container.mainContext.save()
    }

    func reopen(_ evidenceID: UUID) throws {
        guard let item = try item(id: evidenceID) else { return }
        item.state = .needsReview
        try container.mainContext.save()
    }

    func linkToPerson(evidenceID: UUID, personID: UUID) throws {
        guard let item = try item(id: evidenceID) else { return }
        // Fetch person
        let fetch = FetchDescriptor<SamPerson>(predicate: #Predicate { $0.id == personID })
        guard let person = try container.mainContext.fetch(fetch).first else { return }
        // Avoid duplicates by id
        if !item.linkedPeople.contains(where: { $0.id == person.id }) {
            item.linkedPeople.append(person)
            try container.mainContext.save()
        }
    }

    func linkToContext(evidenceID: UUID, contextID: UUID) throws {
        guard let item = try item(id: evidenceID) else { return }
        // Fetch context
        let fetch = FetchDescriptor<SamContext>(predicate: #Predicate { $0.id == contextID })
        guard let context = try container.mainContext.fetch(fetch).first else { return }
        if !item.linkedContexts.contains(where: { $0.id == context.id }) {
            item.linkedContexts.append(context)
            try container.mainContext.save()
        }
    }

    func acceptSuggestion(evidenceID: UUID, suggestionID: UUID) throws {
        guard let item = try item(id: evidenceID) else { return }
        guard let sIdx = item.proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }

        item.proposedLinks[sIdx].status = .accepted
        item.proposedLinks[sIdx].decidedAt = Date()

        let s = item.proposedLinks[sIdx]

        switch s.target {
        case .person:
            let fetch = FetchDescriptor<SamPerson>(predicate: #Predicate { $0.id == s.targetID })
            if let person = try? container.mainContext.fetch(fetch).first {
                if !item.linkedPeople.contains(where: { $0.id == person.id }) {
                    item.linkedPeople.append(person)
                }
            }
        case .context:
            let fetch = FetchDescriptor<SamContext>(predicate: #Predicate { $0.id == s.targetID })
            if let context = try? container.mainContext.fetch(fetch).first {
                if !item.linkedContexts.contains(where: { $0.id == context.id }) {
                    item.linkedContexts.append(context)
                }
            }
        }

        try container.mainContext.save()
    }

    func declineSuggestion(evidenceID: UUID, suggestionID: UUID) throws {
        guard let item = try item(id: evidenceID) else { return }
        guard let sIdx = item.proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }

        item.proposedLinks[sIdx].status = .declined
        item.proposedLinks[sIdx].decidedAt = Date()

        try container.mainContext.save()
    }

    func resetSuggestionToPending(evidenceID: UUID, suggestionID: UUID) throws {
        guard let item = try item(id: evidenceID) else { return }
        guard let sIdx = item.proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }

        item.proposedLinks[sIdx].status = .pending
        item.proposedLinks[sIdx].decidedAt = Date()

        try container.mainContext.save()
    }

    func removeConfirmedLink(
        evidenceID: UUID,
        target: EvidenceLinkTarget,
        targetID: UUID,
        revertSuggestionTo: LinkSuggestionStatus = .pending
    ) throws {
        guard let item = try item(id: evidenceID) else { return }

        switch target {
        case .person:
            item.linkedPeople.removeAll { $0.id == targetID }
        case .context:
            item.linkedContexts.removeAll { $0.id == targetID }
        }

        if let sIdx = item.proposedLinks.firstIndex(where: {
            $0.target == target && $0.targetID == targetID
        }) {
            item.proposedLinks[sIdx].status = revertSuggestionTo
            item.proposedLinks[sIdx].decidedAt = Date()
        }

        try container.mainContext.save()
    }

    /// Wholesale replace — used by backup restore. Bypasses upsert/prune
    /// logic; the payload is authoritative.
    func replaceAll(with newItems: [SamEvidenceItem]) throws {
        // Delete all existing items
        let fetchDescriptor = FetchDescriptor<SamEvidenceItem>()
        let existingItems = try container.mainContext.fetch(fetchDescriptor)
        for item in existingItems {
            container.mainContext.delete(item)
        }
        // Insert new items
        for newItem in newItems {
            container.mainContext.insert(newItem)
        }
        try container.mainContext.save()
    }

    // Seeding is handled exclusively by FixtureSeeder at app launch.
    // No seed logic lives here.
}

