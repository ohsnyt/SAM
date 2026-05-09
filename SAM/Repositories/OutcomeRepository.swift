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

    /// Flush pending changes to the persistent store.
    func save() throws {
        guard let context else { throw RepositoryError.notConfigured }
        try context.save()
    }

    // MARK: - Fetch Operations

    /// Fetch active outcomes (pending + inProgress), sorted by priority descending.
    /// Excludes outcomes awaiting a sequence trigger (hidden until activated).
    func fetchActive() throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>(
            sortBy: [SortDescriptor(\.priorityScore, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter {
            ($0.status == .pending || $0.status == .inProgress) && !$0.isAwaitingTrigger
        }
    }

    /// Fetch the top active outcome linked to a specific person.
    /// Returns the highest-priority active outcome for the person, or nil.
    func fetchTopActiveOutcome(forPersonID personID: UUID) -> SamOutcome? {
        guard let active = try? fetchActive() else { return nil }
        return active.first { outcome in
            guard let person = outcome.linkedPerson,
                  !person.isDeleted else { return false }
            return person.id == personID
        }
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

    /// Fetch outcomes the user explicitly dismissed.
    /// Most recent dismissals first. Used by the Missed Nudges lens to surface
    /// coaching the user passed on.
    func fetchDismissed(limit: Int = 200) throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>(
            sortBy: [SortDescriptor(\.dismissedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return Array(all.lazy.filter { $0.statusRawValue == OutcomeStatus.dismissed.rawValue }.prefix(limit))
    }

    /// Fetch a single outcome by ID.
    func fetch(id: UUID) throws -> SamOutcome? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    /// Fetch the first non-completed outcome whose `sourceInsightSummary` matches the given key.
    /// Used for "consolidated" outcomes that upsert against a stable sentinel string instead of a UUID
    /// (e.g., the "Meetings awaiting review" row that rolls up every pending post-meeting capture).
    func fetchBySourceInsightSummary(_ key: String) throws -> SamOutcome? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        return all.first { $0.sourceInsightSummary == key && $0.status != .completed && $0.status != .dismissed }
    }

    // MARK: - Search

    /// Search outcomes by title, rationale, and suggestedNextStep (case-insensitive).
    func search(query: String) throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }
        guard !query.isEmpty else { return try fetchActive() }

        let lowercaseQuery = query.lowercased()
        let descriptor = FetchDescriptor<SamOutcome>(
            sortBy: [SortDescriptor(\.priorityScore, order: .reverse)]
        )
        let all = try context.fetch(descriptor)

        return all.filter { outcome in
            outcome.title.lowercased().contains(lowercaseQuery) ||
            outcome.rationale.lowercased().contains(lowercaseQuery) ||
            outcome.suggestedNextStep?.lowercased().contains(lowercaseQuery) == true
        }
    }

    // MARK: - Sequence Queries

    /// Fetch outcomes that are awaiting a sequence trigger and still pending.
    func fetchAwaitingTrigger() throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        return all.filter { $0.isAwaitingTrigger && $0.status == .pending }
    }

    /// Fetch the previous step in a sequence (sequenceIndex - 1).
    func fetchPreviousStep(for outcome: SamOutcome) throws -> SamOutcome? {
        guard let seqID = outcome.sequenceID, outcome.sequenceIndex > 0, let context else { return nil }

        let targetIndex = outcome.sequenceIndex - 1
        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        return all.first { $0.sequenceID == seqID && $0.sequenceIndex == targetIndex }
    }

    /// Dismiss all steps in a sequence at or after the given index.
    func dismissRemainingSteps(sequenceID: UUID, fromIndex: Int) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        var dismissed = 0

        for outcome in all {
            guard outcome.sequenceID == sequenceID,
                  outcome.sequenceIndex >= fromIndex,
                  outcome.status == .pending || outcome.status == .inProgress else { continue }

            outcome.statusRawValue = OutcomeStatus.dismissed.rawValue
            outcome.dismissedAt = .now
            dismissed += 1
        }

        if dismissed > 0 {
            try context.save()
            logger.debug("Dismissed \(dismissed) remaining sequence steps for sequence \(sequenceID)")
        }
    }

    /// Count total steps in a sequence.
    func sequenceStepCount(sequenceID: UUID) throws -> Int {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        return all.filter { $0.sequenceID == sequenceID }.count
    }

    /// Fetch the next visible step hint for a sequence (the first awaiting-trigger step).
    func fetchNextAwaitingStep(sequenceID: UUID, afterIndex: Int) throws -> SamOutcome? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        return all
            .filter { $0.sequenceID == sequenceID && $0.sequenceIndex > afterIndex && $0.isAwaitingTrigger && $0.status == .pending }
            .sorted(by: { $0.sequenceIndex < $1.sequenceIndex })
            .first
    }

    // MARK: - Upsert

    /// Insert or update an outcome. Returns the persisted outcome.
    @discardableResult
    func upsert(outcome: SamOutcome) throws -> SamOutcome {
        guard let context else { throw RepositoryError.notConfigured }

        // Re-resolve relationships from THIS context to avoid cross-context insertion errors.
        // The incoming outcome may have linkedPerson/linkedContext fetched from a different context.
        let localPerson: SamPerson? = try resolveInContext(outcome.linkedPerson)
        let localContext: SamContext? = try resolveInContext(outcome.linkedContext)

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
            existing.linkedPerson = localPerson
            existing.linkedContext = localContext
            try context.save()
            return existing
        } else {
            outcome.linkedPerson = localPerson
            outcome.linkedContext = localContext
            context.insert(outcome)
            try context.save()
            return outcome
        }
    }

    /// Re-fetch a SamPerson from this repository's context to avoid cross-context errors.
    func resolveInContext(_ person: SamPerson?) throws -> SamPerson? {
        guard let person, let context else { return nil }
        let personID = person.id
        let descriptor = FetchDescriptor<SamPerson>(predicate: #Predicate { $0.id == personID })
        return try context.fetch(descriptor).first
    }

    /// Re-fetch a SamContext from this repository's context to avoid cross-context errors.
    private func resolveInContext(_ samContext: SamContext?) throws -> SamContext? {
        guard let samContext, let context else { return nil }
        let contextID = samContext.id
        let descriptor = FetchDescriptor<SamContext>(predicate: #Predicate { $0.id == contextID })
        return try context.fetch(descriptor).first
    }

    // MARK: - Status Updates

    /// Mark an outcome as completed (captures undo snapshot before mutation).
    func markCompleted(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        // Capture snapshot before mutation
        let snapshot = OutcomeSnapshot(
            id: outcome.id,
            title: outcome.title,
            previousStatusRawValue: outcome.statusRawValue,
            previousDismissedAt: outcome.dismissedAt,
            previousCompletedAt: outcome.completedAt,
            previousWasActedOn: outcome.wasActedOn
        )

        outcome.statusRawValue = OutcomeStatus.completed.rawValue
        outcome.completedAt = .now
        outcome.wasActedOn = true
        try context.save()
        logger.debug("Outcome completed: \(outcome.title)")

        if let entry = try? UndoRepository.shared.capture(
            operation: .statusChanged,
            entityType: .outcome,
            entityID: outcome.id,
            entityDisplayName: outcome.title,
            snapshot: snapshot
        ) {
            UndoCoordinator.shared.showToast(for: entry)
        }
    }

    /// Mark an outcome as dismissed (user clicked Skip).
    /// Captures undo snapshot before mutation.
    /// If the outcome is part of a sequence, also dismisses all subsequent steps.
    func markDismissed(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        // Capture snapshot before mutation
        let snapshot = OutcomeSnapshot(
            id: outcome.id,
            title: outcome.title,
            previousStatusRawValue: outcome.statusRawValue,
            previousDismissedAt: outcome.dismissedAt,
            previousCompletedAt: outcome.completedAt,
            previousWasActedOn: outcome.wasActedOn
        )

        outcome.statusRawValue = OutcomeStatus.dismissed.rawValue
        outcome.dismissedAt = .now
        try context.save()
        logger.debug("Outcome dismissed: \(outcome.title)")

        // Auto-dismiss subsequent sequence steps
        if let seqID = outcome.sequenceID {
            try dismissRemainingSteps(sequenceID: seqID, fromIndex: outcome.sequenceIndex + 1)
        }

        if let entry = try? UndoRepository.shared.capture(
            operation: .statusChanged,
            entityType: .outcome,
            entityID: outcome.id,
            entityDisplayName: outcome.title,
            snapshot: snapshot
        ) {
            UndoCoordinator.shared.showToast(for: entry)
        }
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
        logger.debug("Outcome rated \(rating): \(outcome.title)")
    }

    /// Update the lastSurfacedAt timestamp for an outcome.
    func markSurfaced(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        outcome.lastSurfacedAt = .now
        try context.save()
    }

    // MARK: - Snooze

    /// Snooze an outcome until a future date. Captures undo snapshot.
    func markSnoozed(id: UUID, until date: Date) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let outcome = try fetch(id: id) else { return }

        let snapshot = OutcomeSnapshot(
            id: outcome.id,
            title: outcome.title,
            previousStatusRawValue: outcome.statusRawValue,
            previousDismissedAt: outcome.dismissedAt,
            previousCompletedAt: outcome.completedAt,
            previousWasActedOn: outcome.wasActedOn,
            previousSnoozedAt: outcome.snoozedAt,
            previousSnoozeUntil: outcome.snoozeUntil,
            previousSnoozeCount: outcome.snoozeCount
        )

        outcome.statusRawValue = OutcomeStatus.snoozed.rawValue
        outcome.snoozedAt = .now
        outcome.snoozeUntil = date
        outcome.snoozeCount += 1
        try context.save()
        logger.debug("Outcome snoozed until \(date.formatted(.dateTime.month().day())): \(outcome.title)")

        if let entry = try? UndoRepository.shared.capture(
            operation: .statusChanged,
            entityType: .outcome,
            entityID: outcome.id,
            entityDisplayName: outcome.title,
            snapshot: snapshot
        ) {
            UndoCoordinator.shared.showToast(for: entry)
        }
    }

    /// Fetch all snoozed outcomes, sorted by wake date ascending.
    func fetchSnoozed() throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamOutcome>(
            sortBy: [SortDescriptor(\.snoozeUntil)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.status == .snoozed }
    }

    /// Wake snoozed outcomes whose snoozeUntil date has passed.
    /// Sets them back to .pending and clears snooze timestamps.
    /// Returns the woken outcomes for the engine to evaluate.
    func wakeExpiredSnoozes() throws -> [SamOutcome] {
        guard let context else { throw RepositoryError.notConfigured }

        let now = Date.now
        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)
        var woken: [SamOutcome] = []

        for outcome in all where outcome.status == .snoozed {
            if let wakeDate = outcome.snoozeUntil, wakeDate <= now {
                outcome.statusRawValue = OutcomeStatus.pending.rawValue
                // Keep snoozedAt for auto-resolve evidence window; clear snoozeUntil
                outcome.snoozeUntil = nil
                woken.append(outcome)
            }
        }

        if !woken.isEmpty {
            try context.save()
            logger.debug("Woke \(woken.count) snoozed outcomes")
        }

        return woken
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
            // Never auto-expire user-created tasks — let the user manage them
            guard outcome.outcomeKind != .userTask else { continue }
            if let deadline = outcome.deadlineDate, deadline < now {
                outcome.statusRawValue = OutcomeStatus.expired.rawValue
                expiredCount += 1
            }
        }

        if expiredCount > 0 {
            try context.save()
            logger.debug("Pruned \(expiredCount) expired outcomes")
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
            logger.debug("Purged \(purgedCount) old outcomes")
        }
    }

    // MARK: - Bulk Insert (no per-item save)

    /// Insert a new outcome without saving. The caller MUST call `save()`
    /// after a batch of inserts. Resolves cross-context relationships first.
    /// Used by OutcomeEngine.persistOutcomes to avoid O(N) save overhead.
    func insertWithoutSave(outcome: SamOutcome) throws {
        guard let context else { throw RepositoryError.notConfigured }
        outcome.linkedPerson = try resolveInContext(outcome.linkedPerson)
        outcome.linkedContext = try resolveInContext(outcome.linkedContext)
        context.insert(outcome)
    }

    // MARK: - Dedup Index

    /// Pre-computed lookup tables for kind+person duplicate detection.
    /// Built from a single full-table fetch — drastically faster than calling
    /// `hasSimilarOutcome` / `hasRecentlyActedOutcome` per candidate (each of
    /// those does its own full-table fetch).
    struct DedupIndex {
        /// Keys for active (pending/inProgress/snoozed) outcomes within the window.
        let activeKeys: Set<String>
        /// Keys for recently dismissed/completed outcomes within the window.
        let actedOnKeys: Set<String>

        static func key(kindRaw: String, personID: UUID?) -> String {
            "\(kindRaw)|\(personID?.uuidString ?? "nil")"
        }

        func isDuplicate(kindRaw: String, personID: UUID?) -> Bool {
            activeKeys.contains(Self.key(kindRaw: kindRaw, personID: personID))
        }

        func wasActedOn(kindRaw: String, personID: UUID?) -> Bool {
            actedOnKeys.contains(Self.key(kindRaw: kindRaw, personID: personID))
        }
    }

    /// Build a `DedupIndex` from one full-table fetch.
    /// Use the same windows that `hasSimilarOutcome` / `hasRecentlyActedOutcome` use.
    func buildDedupIndex(
        activeWindowHours: Int = 24,
        actedOnWindowDays: Int = 7
    ) throws -> DedupIndex {
        guard let context else { throw RepositoryError.notConfigured }

        let activeCutoff = Calendar.current.date(byAdding: .hour, value: -activeWindowHours, to: .now) ?? .now
        let actedCutoff = Calendar.current.date(byAdding: .day, value: -actedOnWindowDays, to: .now) ?? .now

        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)

        var active = Set<String>()
        var acted = Set<String>()
        active.reserveCapacity(all.count)
        acted.reserveCapacity(all.count)

        for outcome in all {
            let key = DedupIndex.key(kindRaw: outcome.outcomeKindRawValue, personID: outcome.linkedPerson?.id)
            switch outcome.status {
            case .pending, .inProgress, .snoozed:
                if outcome.createdAt >= activeCutoff {
                    active.insert(key)
                }
            case .dismissed, .completed:
                let actedAt = (outcome.dismissedAt ?? outcome.completedAt) ?? outcome.createdAt
                if actedAt >= actedCutoff {
                    acted.insert(key)
                }
            case .expired:
                break
            }
        }

        return DedupIndex(activeKeys: active, actedOnKeys: acted)
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
            (outcome.status == .pending || outcome.status == .inProgress || outcome.status == .snoozed)
        }
    }

    /// Check if a similar outcome was recently dismissed or completed.
    /// Prevents re-suggesting outcomes the user already acted on. Uses a longer
    /// suppression window (default 7 days) so "Skip" and "Done" choices persist
    /// across app restarts and outcome regeneration cycles.
    func hasRecentlyActedOutcome(
        kind: OutcomeKind,
        personID: UUID?,
        withinDays days: Int = 7
    ) throws -> Bool {
        guard let context else { throw RepositoryError.notConfigured }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)

        return all.contains { outcome in
            outcome.outcomeKindRawValue == kindRaw &&
            outcome.linkedPerson?.id == personID &&
            (outcome.status == .dismissed || outcome.status == .completed) &&
            ((outcome.dismissedAt ?? outcome.completedAt) ?? outcome.createdAt) >= cutoff
        }
    }

    /// Check if a pending/inProgress outcome with the same title exists within a time window.
    /// Used by feature adoption coaching to avoid blocking on unrelated setup outcomes.
    func hasSimilarOutcome(
        title: String,
        withinHours hours: Int = 24
    ) throws -> Bool {
        guard let context else { throw RepositoryError.notConfigured }

        let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: .now) ?? .now
        let descriptor = FetchDescriptor<SamOutcome>()
        let all = try context.fetch(descriptor)

        let lowercaseTitle = title.lowercased()
        return all.contains { outcome in
            outcome.title.lowercased() == lowercaseTitle &&
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
