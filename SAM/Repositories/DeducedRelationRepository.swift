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
        return all.filter { !$0.isConfirmed && !$0.isRejected }
    }

    // MARK: - Upsert

    /// Insert or update a deduced relation, deduplicating by (personAID, personBID, relationType).
    /// Also deduplicates complementary types: parent↔child describe the same relationship from
    /// opposite directions. When a more specific label exists (e.g., "father" vs "parent"),
    /// the specific label is kept.
    @discardableResult
    func upsert(personAID: UUID, personBID: UUID, relationType: DeducedRelationType, sourceLabel: String) throws -> DeducedRelation {
        guard let context else { throw RepositoryError.notConfigured }

        let all = try fetchAll()

        // Check for existing with same type (either direction)
        if let existing = all.first(where: {
            ($0.personAID == personAID && $0.personBID == personBID && $0.relationType == relationType) ||
            ($0.personAID == personBID && $0.personBID == personAID && $0.relationType == relationType)
        }) {
            // If rejected, don't resurrect — honor the user's decision
            guard !existing.isRejected else { return existing }
            // Keep the more specific label (e.g., "father" over "parent")
            if Self.isMoreSpecificLabel(sourceLabel, than: existing.sourceLabel) {
                existing.sourceLabel = sourceLabel
                try context.save()
            }
            return existing
        }

        // Check for existing with complementary type (parent↔child in opposite direction)
        if let complementary = Self.complementaryType(relationType) {
            if let existing = all.first(where: {
                ($0.personAID == personBID && $0.personBID == personAID && $0.relationType == complementary) ||
                ($0.personAID == personAID && $0.personBID == personBID && $0.relationType == complementary)
            }) {
                // If rejected, don't resurrect
                guard !existing.isRejected else { return existing }
                // Complementary record exists — update label if the new one is more specific
                if Self.isMoreSpecificLabel(sourceLabel, than: existing.sourceLabel) {
                    existing.sourceLabel = sourceLabel
                    try context.save()
                }
                return existing
            }
        }

        // Check if this pair was previously rejected with any type
        let isRejectedPair = all.contains(where: {
            $0.isRejected && (
                ($0.personAID == personAID && $0.personBID == personBID) ||
                ($0.personAID == personBID && $0.personBID == personAID)
            )
        })
        guard !isRejectedPair else {
            logger.debug("Skipping upsert for rejected pair \(personAID) / \(personBID)")
            // Return the rejected record so callers don't error
            return all.first(where: {
                $0.isRejected && (
                    ($0.personAID == personAID && $0.personBID == personBID) ||
                    ($0.personAID == personBID && $0.personBID == personAID)
                )
            })!
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

    /// Returns the complementary relationship type, if any.
    /// Parent↔child are inverses describing the same relationship from opposite directions.
    private static func complementaryType(_ type: DeducedRelationType) -> DeducedRelationType? {
        switch type {
        case .parent: return .child
        case .child:  return .parent
        default:      return nil  // spouse↔spouse, sibling↔sibling are same-type
        }
    }

    /// Returns true if `newLabel` is more specific than `existingLabel`.
    /// Specific labels (father, mother, son, daughter, etc.) win over generic ones (parent, child).
    private static func isMoreSpecificLabel(_ newLabel: String, than existingLabel: String) -> Bool {
        let genericLabels: Set<String> = ["parent", "child", "spouse", "sibling", "other"]
        let newIsGeneric = genericLabels.contains(newLabel.lowercased())
        let existingIsGeneric = genericLabels.contains(existingLabel.lowercased())
        // New is specific and existing is generic → new wins
        return !newIsGeneric && existingIsGeneric
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

    /// Confirm all unconfirmed deduced relations at once. Returns the number confirmed.
    @discardableResult
    func confirmAll() throws -> Int {
        guard let context else { throw RepositoryError.notConfigured }
        let unconfirmed = try fetchUnconfirmed()
        guard !unconfirmed.isEmpty else { return 0 }
        for relation in unconfirmed {
            relation.isConfirmed = true
            relation.confirmedAt = .now
        }
        try context.save()
        logger.info("Confirmed all \(unconfirmed.count) deduced relations")
        return unconfirmed.count
    }

    // MARK: - Reject

    /// Reject a deduced relation. Keeps the record (to prevent re-creation) but marks it rejected.
    /// Clears isConfirmed if it was previously confirmed.
    func reject(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        let all = try fetchAll()
        guard let relation = all.first(where: { $0.id == id }) else { return }
        relation.isRejected = true
        relation.isConfirmed = false
        relation.confirmedAt = nil
        try context.save()
        logger.info("Rejected deduced relation \(id)")
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
