//
//  DeducedRelationRepository.swift
//  SAM
//
//  Created on February 26, 2026.
//  Deduced Relationships from Apple Contacts related names.
//
//  SwiftData CRUD for DeducedRelation records.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DeducedRelationRepository")

@MainActor
@Observable
final class DeducedRelationRepository {

    // MARK: - Singleton

    static let shared = DeducedRelationRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Fetch

    func fetchAll() throws -> [DeducedRelation] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<DeducedRelation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func fetchUnconfirmed() throws -> [DeducedRelation] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<DeducedRelation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { !$0.isConfirmed }
    }

    // MARK: - Upsert

    /// Insert or update a deduced relation, deduplicating by (personAID, personBID, relationType).
    @discardableResult
    func upsert(personAID: UUID, personBID: UUID, relationType: DeducedRelationType, sourceLabel: String) throws -> DeducedRelation {
        guard let context else { throw RepositoryError.notConfigured }

        // Check for existing (either direction)
        let all = try fetchAll()
        if let existing = all.first(where: {
            ($0.personAID == personAID && $0.personBID == personBID && $0.relationType == relationType) ||
            ($0.personAID == personBID && $0.personBID == personAID && $0.relationType == relationType)
        }) {
            existing.sourceLabel = sourceLabel
            try context.save()
            return existing
        }

        let relation = DeducedRelation(
            personAID: personAID,
            personBID: personBID,
            relationType: relationType,
            sourceLabel: sourceLabel
        )
        context.insert(relation)
        try context.save()
        logger.info("Created deduced relation: \(sourceLabel) between \(personAID) and \(personBID)")
        return relation
    }

    // MARK: - Confirm

    func confirm(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        let all = try fetchAll()
        guard let relation = all.first(where: { $0.id == id }) else { return }
        relation.isConfirmed = true
        relation.confirmedAt = .now
        try context.save()
        logger.info("Confirmed deduced relation \(id)")
    }

    // MARK: - Delete

    func deleteAll() throws {
        guard let context else { throw RepositoryError.notConfigured }
        let all = try fetchAll()
        for relation in all {
            context.delete(relation)
        }
        try context.save()
        logger.info("Deleted all deduced relations")
    }

    // MARK: - Error

    enum RepositoryError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "DeducedRelationRepository not configured. Call configure(container:) first."
            }
        }
    }
}
