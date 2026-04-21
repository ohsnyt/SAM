//
//  CommitmentRepository.swift
//  SAM
//
//  Block 3: Commitment tracking.
//  SwiftData CRUD for SamCommitment records. Handles auto-sweep of
//  overdue-and-unresolved commitments into `.missed` and exposes a
//  per-person follow-through rate for coaching.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CommitmentRepository")

@MainActor
@Observable
final class CommitmentRepository {

    // MARK: - Singleton

    static let shared = CommitmentRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    /// Grace period past `dueDate` before a pending commitment is swept to `.missed`.
    private let missedGracePeriod: TimeInterval = 24 * 60 * 60

    /// Minimum resolved commitments before we report a follow-through rate.
    /// Below this threshold the signal is too noisy to coach on.
    private let minResolvedForRate = 3

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Create

    /// Insert a commitment. Callers should have already done duplicate checks
    /// (see `findExistingFromTranscript` for the summary-ingest path).
    @discardableResult
    func save(_ commitment: SamCommitment) throws -> SamCommitment {
        guard let context else { throw RepositoryError.notConfigured }
        context.insert(commitment)
        try context.save()
        return commitment
    }

    // MARK: - Fetch

    /// All commitments in the store. Use sparingly — most callers want a filtered fetch.
    func fetchAll() throws -> [SamCommitment] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<SamCommitment>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Commitments involving a specific person, regardless of direction/status.
    func fetch(forPerson personID: UUID) throws -> [SamCommitment] {
        try fetchAll().filter { $0.linkedPerson?.id == personID }
    }

    /// Pending-only commitments that Sarah made and owes. Sorted by due date (nil last),
    /// then by creation. Use for Today-view surfacing.
    func fetchOpenFromSarah(dueWithin days: Int? = nil) throws -> [SamCommitment] {
        let all = try fetchAll()
        let base = all.filter {
            $0.direction == .fromUser && $0.status == .pending
        }
        guard let days else { return base.sorted(by: byDueThenCreated) }
        let cutoff = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
        return base.filter { commitment in
            guard let due = commitment.dueDate else { return true }
            return due <= cutoff
        }.sorted(by: byDueThenCreated)
    }

    /// Pending commitments the person has made to Sarah. Use for "they owe you" nudges.
    func fetchOpenToSarah(forPerson personID: UUID) throws -> [SamCommitment] {
        try fetch(forPerson: personID).filter {
            $0.direction == .toUser && $0.status == .pending
        }
    }

    /// Look up an existing commitment from a transcript by session + text, used to
    /// prevent duplicates when a meeting summary is regenerated.
    func findExistingFromTranscript(
        sessionID: UUID,
        text: String
    ) throws -> SamCommitment? {
        guard let context else { throw RepositoryError.notConfigured }
        let needle = normalize(text)
        let descriptor = FetchDescriptor<SamCommitment>()
        let all = try context.fetch(descriptor)
        return all.first {
            $0.linkedTranscript?.id == sessionID && normalize($0.text) == needle
        }
    }

    // MARK: - Resolve

    func markFulfilled(_ id: UUID, note: String? = nil) throws {
        try resolve(id: id, to: .fulfilled, note: note)
    }

    func markMissed(_ id: UUID, note: String? = nil) throws {
        try resolve(id: id, to: .missed, note: note)
    }

    func markDismissed(_ id: UUID, note: String? = nil) throws {
        try resolve(id: id, to: .dismissed, note: note)
    }

    func reopen(_ id: UUID) throws {
        guard let context, let commitment = try fetch(id: id) else {
            throw RepositoryError.notConfigured
        }
        commitment.status = .pending
        commitment.fulfilledAt = nil
        commitment.missedAt = nil
        commitment.dismissedAt = nil
        commitment.resolutionNote = nil
        try context.save()
    }

    private func resolve(id: UUID, to status: CommitmentStatus, note: String?) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let commitment = try fetch(id: id) else { return }
        commitment.status = status
        let now = Date.now
        switch status {
        case .fulfilled: commitment.fulfilledAt = now
        case .missed:    commitment.missedAt = now
        case .dismissed: commitment.dismissedAt = now
        case .pending:   break
        }
        if let note, !note.isEmpty {
            commitment.resolutionNote = note
        }
        try context.save()
        logger.debug("Commitment \(id) → \(status.rawValue)")
    }

    private func fetch(id: UUID) throws -> SamCommitment? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<SamCommitment>()
        return try context.fetch(descriptor).first { $0.id == id }
    }

    // MARK: - Auto-sweep

    /// Move pending commitments past their due date (plus grace period) into `.missed`.
    /// Safe to call on every app foreground; skips commitments without a parsed dueDate.
    @discardableResult
    func sweepMissed(now: Date = .now) throws -> Int {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<SamCommitment>()
        let all = try context.fetch(descriptor)
        var count = 0
        for commitment in all where commitment.status == .pending {
            guard let due = commitment.dueDate else { continue }
            if now.timeIntervalSince(due) > missedGracePeriod {
                commitment.status = .missed
                commitment.missedAt = now
                count += 1
            }
        }
        if count > 0 {
            try context.save()
            logger.debug("Swept \(count) commitments to .missed")
        }
        return count
    }

    // MARK: - Follow-through rate

    /// Follow-through rate for a person's own commitments to Sarah.
    /// Returns nil when resolved commitment count is below the confidence threshold.
    /// `(fulfilled) / (fulfilled + missed)` — dismissed commitments don't count either way.
    func followThroughRate(forPerson personID: UUID) throws -> FollowThroughRate? {
        let commitments = try fetch(forPerson: personID).filter { $0.direction == .toUser }
        let fulfilled = commitments.filter { $0.status == .fulfilled }.count
        let missed = commitments.filter { $0.status == .missed }.count
        let total = fulfilled + missed
        guard total >= minResolvedForRate else { return nil }
        return FollowThroughRate(
            personID: personID,
            fulfilled: fulfilled,
            missed: missed,
            rate: Double(fulfilled) / Double(total)
        )
    }

    // MARK: - Delete

    func delete(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let commitment = try fetch(id: id) else { return }
        context.delete(commitment)
        try context.save()
    }

    // MARK: - Helpers

    private func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func byDueThenCreated(_ a: SamCommitment, _ b: SamCommitment) -> Bool {
        switch (a.dueDate, b.dueDate) {
        case let (ad?, bd?): return ad < bd
        case (_?, nil):      return true
        case (nil, _?):      return false
        default:             return a.createdAt > b.createdAt
        }
    }

    // MARK: - Types

    struct FollowThroughRate: Sendable {
        let personID: UUID
        let fulfilled: Int
        let missed: Int
        /// 0.0 ... 1.0
        let rate: Double

        /// Qualitative bucket for coaching prompts.
        var tier: Tier {
            if rate >= 0.8 { return .reliable }
            if rate >= 0.5 { return .mixed }
            return .flaky
        }

        enum Tier: Sendable {
            case reliable
            case mixed
            case flaky
        }
    }

    enum RepositoryError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "CommitmentRepository not configured. Call configure(container:) first."
            }
        }
    }
}
