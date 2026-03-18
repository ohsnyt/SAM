//
//  EnrichmentRepository.swift
//  SAM
//
//  SwiftData CRUD for PendingEnrichment records.
//  Accumulates enrichment candidates from all import sources;
//  ContactEnrichmentCoordinator orchestrates the review and write-back flow.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EnrichmentRepository")

/// Lightweight Sendable DTO used to submit candidates from import coordinators.
struct EnrichmentCandidate: Sendable {
    let personID: UUID
    let field: EnrichmentField
    let proposedValue: String
    let currentValue: String?
    let source: EnrichmentSource
    let sourceDetail: String?
}

@MainActor
@Observable
final class EnrichmentRepository {

    // MARK: - Singleton

    static let shared = EnrichmentRepository()

    // MARK: - Container

    private var modelContext: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.modelContext = ModelContext(container)
    }

    // MARK: - Fetch

    /// Fetch all pending enrichments for a specific person, sorted by field name.
    func fetchPending(for personID: UUID) throws -> [PendingEnrichment] {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<PendingEnrichment>()
        let all = try modelContext.fetch(descriptor)
        return all
            .filter { $0.personID == personID && $0.status == .pending }
            .sorted { $0.fieldRawValue < $1.fieldRawValue }
    }

    /// IDs of all people who have at least one pending enrichment.
    func fetchPeopleWithPendingEnrichment() throws -> Set<UUID> {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<PendingEnrichment>()
        let all = try modelContext.fetch(descriptor)
        return Set(all.filter { $0.status == .pending }.map(\.personID))
    }

    /// Count of all pending enrichments across all people.
    func pendingCount() throws -> Int {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<PendingEnrichment>()
        let all = try modelContext.fetch(descriptor)
        return all.filter { $0.status == .pending }.count
    }

    // MARK: - Bulk Record

    /// Upsert enrichment candidates from an import run.
    ///
    /// Dedup rule: skip insertion if a pending record with the same
    /// (personID, fieldRawValue, proposedValue) already exists.
    /// If an approved or dismissed record matches, a new pending record is still
    /// inserted (the data may have been updated since last review).
    ///
    /// Returns the number of net-new records inserted.
    @discardableResult
    func bulkRecord(_ candidates: [EnrichmentCandidate]) throws -> Int {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<PendingEnrichment>()
        let existing = try modelContext.fetch(descriptor)

        // Build a set of (personID, field, proposedValue) for existing records (any status).
        // This prevents re-creating enrichments that were already approved/dismissed.
        let existingKeys = Set(
            existing.map { "\($0.personID)|\($0.fieldRawValue)|\($0.proposedValue)" }
        )

        var inserted = 0
        for candidate in candidates {
            // Skip empty values
            let value = candidate.proposedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            let key = "\(candidate.personID)|\(candidate.field.rawValue)|\(value)"
            guard !existingKeys.contains(key) else { continue }

            let record = PendingEnrichment(
                personID: candidate.personID,
                field: candidate.field,
                proposedValue: value,
                currentValue: candidate.currentValue,
                source: candidate.source,
                sourceDetail: candidate.sourceDetail
            )
            modelContext.insert(record)
            inserted += 1
        }

        if inserted > 0 {
            try modelContext.save()
            logger.debug("EnrichmentRepository: inserted \(inserted) new enrichment candidates")
        }
        return inserted
    }

    // MARK: - Status Updates

    /// Mark enrichments as approved and set resolvedAt.
    func approve(_ items: [PendingEnrichment]) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        let now = Date()
        for item in items {
            item.statusRawValue = EnrichmentStatus.approved.rawValue
            item.resolvedAt = now
        }
        try modelContext.save()
    }

    /// Mark enrichments as dismissed and set resolvedAt.
    func dismiss(_ items: [PendingEnrichment]) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        let now = Date()
        for item in items {
            item.statusRawValue = EnrichmentStatus.dismissed.rawValue
            item.resolvedAt = now
        }
        try modelContext.save()
    }
}
