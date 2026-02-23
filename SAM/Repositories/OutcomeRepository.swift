//
//  OutcomeRepository.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  SwiftData CRUD operations for SamOutcome.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "OutcomeRepository")

@MainActor
@Observable
final class OutcomeRepository {

    // MARK: - Singleton

    static let shared = OutcomeRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    /// Configure the repository with the app-wide ModelContainer.
    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Fetch Operations

    /// Fetch active outcomes (pending + inProgress), sorted by priority descending.
    func fetchActive() throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>(
            sortBy: [SortDescriptor(\.priorityScore, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.status == .pending || $0.status == .inProgress }
    }

    /// Fetch completed outcomes, most recent first.
    func fetchCompleted(limit: Int = 20) throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return Array(all.filter { $0.status == .completed }.prefix(limit))
    }

    /// Fetch outcomes completed today.
    func fetchCompletedToday() throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }

        let startOfDay = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<SamOutcome>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter {
            $0.status == .completed &&
            $0.completedAt != nil &&
            $0.completedAt! >= startOfDay
        }
    }

    /// Fetch a single outcome by ID.
    func fetch(id: UUID) throws -> SamOutcome? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    // MARK: - Upsert

    /// Insert or update an outcome. Returns the persisted outcome.
    @discardableResult
    func upsert(outcome: SamOutcome) throws -> SamOutcome {
        guard let context else { throw RepositoryError.notConfigured }

        if let existing = try fetch(id: outcome.id) {
            // Update existing
            existing.title = outcome.title
            existing.rationale = outcome.rationale
            existing.outcomeKindRawValue = outcome.outcomeKindRawValue
            existing.priorityScore = outcome.priorityScore
            existing.deadlineDate = outcome.deadlineDate
            existing.sourceInsightSummary = outcome.sourceInsightSummary
            existing.suggestedNextStep = outcome.suggestedNextStep
            existing.encouragementNote = outcome.encouragementNote
            existing.linkedPerson = outcome.linkedPerson
            existing.linkedContext = outcome.linkedContext
            try context.save()
            return existing
        } else {
            context.insert(outcome)
            try context.save()
            return outcome
        }
    }

    // MARK: - Status Updates

    /// Mark an outcome as completed.
    func markCompleted(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        outcome.statusRawValue = OutcomeStatus.completed.rawValue
        outcome.completedAt = .now
        outcome.wasActedOn = true
        try context.save()
        logger.info("Outcome completed: \(outcome.title)")
    }

    /// Mark an outcome as dismissed (user clicked Skip).
    func markDismissed(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        outcome.statusRawValue = OutcomeStatus.dismissed.rawValue
        outcome.dismissedAt = .now
        try context.save()
        logger.info("Outcome dismissed: \(outcome.title)")
    }

    /// Mark an outcome as in-progress.
    func markInProgress(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        outcome.statusRawValue = OutcomeStatus.inProgress.rawValue
        try context.save()
    }

    /// Record a user helpfulness rating (1–5).
    func recordRating(id: UUID, rating: Int) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        outcome.userRating = max(1, min(5, rating))
        try context.save()
        logger.info("Outcome rated \(rating): \(outcome.title)")
    }

    /// Update the lastSurfacedAt timestamp for an outcome.
    func markSurfaced(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        outcome.lastSurfacedAt = .now
        try context.save()
    }

    // MARK: - Pruning

    /// Auto-expire outcomes past their deadline that are still pending.
    func pruneExpired() throws {
        guard let context else { throw RepositoryError.notConfigured }

        let now = Date.now
        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)

        var expiredCount = 0
        for outcome in all where outcome.status == .pending || outcome.status == .inProgress {
            if let deadline = outcome.deadlineDate, deadline < now {
                outcome.statusRawValue = OutcomeStatus.expired.rawValue
                expiredCount += 1
            }
        }

        if expiredCount > 0 {
            try context.save()
            logger.info("Pruned \(expiredCount) expired outcomes")
        }
    }

    /// Delete dismissed and expired outcomes older than the given number of days.
    func purgeOld(olderThanDays days: Int = 30) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)

        var purgedCount = 0
        for outcome in all {
            let isDismissedOrExpired = outcome.status == .dismissed || outcome.status == .expired
            if isDismissedOrExpired && outcome.createdAt < cutoff {
                context.delete(outcome)
                purgedCount += 1
            }
        }

        if purgedCount > 0 {
            try context.save()
            logger.info("Purged \(purgedCount) old outcomes")
        }
    }

    // MARK: - Deduplication Helpers

    /// Check if a similar outcome already exists within a time window.
    /// Used by OutcomeEngine to avoid creating duplicate suggestions.
    func hasSimilarOutcome(
        kind: OutcomeKind,
        personID: UUID?,
        withinHours hours: Int = 24
    ) throws -> Bool {
        guard let context else { throw RepositoryError.notConfigured }

        let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: .now) ?? .now
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)

        return all.contains { outcome in
            outcome.outcomeKindRawValue == kindRaw &&
            outcome.linkedPerson?.id == personID &&
            outcome.createdAt >= cutoff &&
            (outcome.status == .pending || outcome.status == .inProgress)
        }
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "OutcomeRepository not configured — call configure(container:) first"
            }
        }
    }
}
