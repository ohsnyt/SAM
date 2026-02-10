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
#if DEBUG
        // In DEBUG builds, allow a fallback container but include the full schema
        // to avoid schema mismatches during ad-hoc testing.
        if let container {
            self.container = container
        } else {
            // Use the full schema to match SAMModelContainer
            let schema = Schema(SAMSchema.allModels)
            let config = ModelConfiguration(
                "SAM_v2",
                schema: schema,
                isStoredInMemoryOnly: false
            )
            self.container = try! ModelContainer(for: schema, configurations: config)
        }
#else
        // In production, the repository must be configured with the app-wide container
        precondition(container != nil, "EvidenceRepository must be configured with the app-wide ModelContainer before use.")
        self.container = container!
#endif
    }

    /// Replaces the container with the app-wide one.  Must be called
    /// once at launch — before any calendar import or query — so that
    /// this repository's writes land in the same store that SwiftUI's
    /// `@Query` properties observe.
    func configure(container: ModelContainer) {
        print("[EvidenceRepository] configure(container:) with:", Unmanaged.passUnretained(container).toOpaque())
        self.container = container
    }

    // MARK: - Fetching Items

    @MainActor
    func newestIDs() -> (needs: UUID?, done: UUID?) {
        print("[EvidenceRepository] newestIDs() using container:", Unmanaged.passUnretained(container).toOpaque())
        let ctx = ModelContext(container)
        do {
            let needsPredicate = #Predicate<SamEvidenceItem> { $0.stateRawValue == "needsReview" }
            let needsFetch = FetchDescriptor<SamEvidenceItem>(
                predicate: needsPredicate,
                sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
            )
            let needs = try ctx.fetch(needsFetch).first?.id

            let donePredicate = #Predicate<SamEvidenceItem> { $0.stateRawValue == "done" }
            let doneFetch = FetchDescriptor<SamEvidenceItem>(
                predicate: donePredicate,
                sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
            )
            let done = try ctx.fetch(doneFetch).first?.id

            return (needs, done)
        } catch {
            return (nil, nil)
        }
    }

    @MainActor
    func needsReview() throws -> [SamEvidenceItem] {
        let ctx = ModelContext(container)
        // Use stored property directly to avoid predicate macro issues
        let targetState = "needsReview"
        let predicate = #Predicate<SamEvidenceItem> {
            $0.stateRawValue == targetState
        }
        let fetchDescriptor = FetchDescriptor<SamEvidenceItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        return try ctx.fetch(fetchDescriptor)
    }

    @MainActor
    func done() throws -> [SamEvidenceItem] {
        let ctx = ModelContext(container)
        // Use stored property directly to avoid predicate macro issues
        let targetState = "done"
        let predicate = #Predicate<SamEvidenceItem> {
            $0.stateRawValue == targetState
        }
        let fetchDescriptor = FetchDescriptor<SamEvidenceItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        return try ctx.fetch(fetchDescriptor)
    }

    @MainActor
    func item(id: UUID?) throws -> SamEvidenceItem? {
        guard let id else { return nil }
        let ctx = ModelContext(container)
        let fetchDescriptor = FetchDescriptor<SamEvidenceItem>(
            predicate: #Predicate { $0.id == id }
        )
        return try ctx.fetch(fetchDescriptor).first
    }

    // MARK: - Upsert & Prune (Calendar import)

    /// Inserts or updates a SamEvidenceItem by sourceUID when present; otherwise inserts.
    func upsert(_ newItem: SamEvidenceItem) throws {
        let ctx = ModelContext(container)
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
        let ctx = ModelContext(container)
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

    @MainActor
    func markDone(_ evidenceID: UUID) throws {
        let ctx = ModelContext(container)
        let fetch = FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.id == evidenceID })
        guard let item = try ctx.fetch(fetch).first else { return }
        item.state = .done
        try ctx.save()
    }

    @MainActor
    func reopen(_ evidenceID: UUID) throws {
        let ctx = ModelContext(container)
        let fetch = FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.id == evidenceID })
        guard let item = try ctx.fetch(fetch).first else { return }
        item.state = .needsReview
        try ctx.save()
    }

    @MainActor
    func linkToPerson(evidenceID: UUID, personID: UUID) throws {
        let ctx = ModelContext(container)
        // Fetch item
        let itemFetch = FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.id == evidenceID })
        guard let item = try ctx.fetch(itemFetch).first else { return }
        // Fetch person
        let personFetch = FetchDescriptor<SamPerson>(predicate: #Predicate { $0.id == personID })
        guard let person = try ctx.fetch(personFetch).first else { return }
        // Avoid duplicates by id
        if !item.linkedPeople.contains(where: { $0.id == person.id }) {
            item.linkedPeople.append(person)
            try ctx.save()
        }
    }

    @MainActor
    func linkToContext(evidenceID: UUID, contextID: UUID) throws {
        let ctx = ModelContext(container)
        // Fetch item
        let itemFetch = FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.id == evidenceID })
        guard let item = try ctx.fetch(itemFetch).first else { return }
        // Fetch context
        let contextFetch = FetchDescriptor<SamContext>(predicate: #Predicate { $0.id == contextID })
        guard let context = try ctx.fetch(contextFetch).first else { return }
        if !item.linkedContexts.contains(where: { $0.id == context.id }) {
            item.linkedContexts.append(context)
            try ctx.save()
        }
    }

    @MainActor
    func acceptSuggestion(evidenceID: UUID, suggestionID: UUID) throws {
        let ctx = ModelContext(container)
        let itemFetch = FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.id == evidenceID })
        guard let item = try ctx.fetch(itemFetch).first else { return }
        guard let sIdx = item.proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }

        // Create updated copy with new status
        let updatedLink = item.proposedLinks[sIdx].withStatus(.accepted, decidedAt: Date())
        item.proposedLinks[sIdx] = updatedLink

        let s = item.proposedLinks[sIdx]
        
        // Extract targetID before using in predicate to avoid KeyPath<ProposedLink, UUID> issues
        let targetID = s.targetID

        switch s.target {
        case .person:
            let fetch = FetchDescriptor<SamPerson>(predicate: #Predicate { $0.id == targetID })
            if let person = try? ctx.fetch(fetch).first {
                if !item.linkedPeople.contains(where: { $0.id == person.id }) {
                    item.linkedPeople.append(person)
                }
            }
        case .context:
            let fetch = FetchDescriptor<SamContext>(predicate: #Predicate { $0.id == targetID })
            if let context = try? ctx.fetch(fetch).first {
                if !item.linkedContexts.contains(where: { $0.id == context.id }) {
                    item.linkedContexts.append(context)
                }
            }
        }

        try ctx.save()
    }

    @MainActor
    func declineSuggestion(evidenceID: UUID, suggestionID: UUID) throws {
        let ctx = ModelContext(container)
        let fetch = FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.id == evidenceID })
        guard let item = try ctx.fetch(fetch).first else { return }
        guard let sIdx = item.proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }

        // Create updated copy with new status
        let updatedLink = item.proposedLinks[sIdx].withStatus(.declined, decidedAt: Date())
        item.proposedLinks[sIdx] = updatedLink

        try ctx.save()
    }

    @MainActor
    func resetSuggestionToPending(evidenceID: UUID, suggestionID: UUID) throws {
        let ctx = ModelContext(container)
        let fetch = FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.id == evidenceID })
        guard let item = try ctx.fetch(fetch).first else { return }
        guard let sIdx = item.proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }

        // Create updated copy with new status
        let updatedLink = item.proposedLinks[sIdx].withStatus(.pending, decidedAt: Date())
        item.proposedLinks[sIdx] = updatedLink

        try ctx.save()
    }

    @MainActor
    func removeConfirmedLink(
        evidenceID: UUID,
        target: EvidenceLinkTarget,
        targetID: UUID,
        revertSuggestionTo: LinkSuggestionStatus = .pending
    ) throws {
        let ctx = ModelContext(container)
        let fetch = FetchDescriptor<SamEvidenceItem>(predicate: #Predicate { $0.id == evidenceID })
        guard let item = try ctx.fetch(fetch).first else { return }

        switch target {
        case .person:
            item.linkedPeople.removeAll { $0.id == targetID }
        case .context:
            item.linkedContexts.removeAll { $0.id == targetID }
        }

        if let sIdx = item.proposedLinks.firstIndex(where: {
            $0.target == target && $0.targetID == targetID
        }) {
            // Create updated copy with new status
            let updatedLink = item.proposedLinks[sIdx].withStatus(revertSuggestionTo, decidedAt: Date())
            item.proposedLinks[sIdx] = updatedLink
        }

        try ctx.save()
    }

    /// Wholesale replace — used by backup restore. Bypasses upsert/prune
    /// logic; the payload is authoritative.
    func replaceAll(with newItems: [SamEvidenceItem]) throws {
        let ctx = ModelContext(container)
        // Delete all existing items
        let fetchDescriptor = FetchDescriptor<SamEvidenceItem>()
        let existingItems = try ctx.fetch(fetchDescriptor)
        for item in existingItems {
            ctx.delete(item)
        }
        // Insert new items
        for newItem in newItems {
            ctx.insert(newItem)
        }
        try ctx.save()
    }

    // Seeding is handled exclusively by FixtureSeeder at app launch.
    // No seed logic lives here.
}

