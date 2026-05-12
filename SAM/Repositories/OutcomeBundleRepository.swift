//
//  OutcomeBundleRepository.swift
//  SAM
//
//  CRUD for per-person OutcomeBundle, OutcomeSubItem, and OutcomeDismissalRecord.
//  This repository owns its own ModelContext; callers pass personID (Sendable
//  UUID) rather than SamPerson references to keep relationship endpoints inside
//  one context (see feedback_swiftdata_single_context.md).
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "OutcomeBundleRepository")

@MainActor
@Observable
final class OutcomeBundleRepository {

    // MARK: - Singleton

    static let shared = OutcomeBundleRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    func save() throws {
        guard let context else { throw RepositoryError.notConfigured }
        try context.save()
    }

    // MARK: - Bundle Fetches

    /// All open bundles (closedAt == nil), highest priority first.
    func fetchActive() throws -> [OutcomeBundle] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<OutcomeBundle>(
            sortBy: [SortDescriptor(\.priorityScore, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.closedAt == nil }
    }

    /// The one open bundle for a person (if any). Multiple open bundles for the
    /// same person are a bug — the older one is returned and the newer wins on
    /// reconciliation in `ensureBundle`.
    func fetchActiveBundle(forPersonID personID: UUID) throws -> OutcomeBundle? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<OutcomeBundle>(
            predicate: #Predicate { $0.personID == personID && $0.closedAt == nil }
        )
        let matches = try context.fetch(descriptor)
        return matches.sorted { $0.createdAt < $1.createdAt }.first
    }

    func fetch(id: UUID) throws -> OutcomeBundle? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<OutcomeBundle>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    /// All bundles for a person (open + closed), newest first. Diagnostic surface.
    func fetchAllForPerson(personID: UUID, limit: Int = 50) throws -> [OutcomeBundle] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<OutcomeBundle>(
            predicate: #Predicate { $0.personID == personID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return Array(try context.fetch(descriptor).prefix(limit))
    }

    // MARK: - Sub-Item Fetches

    func fetchSubItem(id: UUID) throws -> OutcomeSubItem? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<OutcomeSubItem>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    // MARK: - Bundle Lifecycle

    /// Return the open bundle for the person, creating a fresh one if none
    /// exists. Resolves SamPerson inside this repository's context so the
    /// relationship endpoint is single-context-safe.
    @discardableResult
    func ensureBundle(forPersonID personID: UUID) throws -> OutcomeBundle {
        guard let context else { throw RepositoryError.notConfigured }
        if let existing = try fetchActiveBundle(forPersonID: personID) {
            return existing
        }
        let personDescriptor = FetchDescriptor<SamPerson>(predicate: #Predicate { $0.id == personID })
        guard let person = try context.fetch(personDescriptor).first else {
            throw RepositoryError.personNotFound
        }
        let bundle = OutcomeBundle(person: person)
        context.insert(bundle)
        try context.save()
        return bundle
    }

    /// Mark bundle closed and timestamp it. Caller is responsible for deciding
    /// when the bundle is "done" (all sub-items closed) — this just persists.
    func closeBundle(_ bundle: OutcomeBundle) throws {
        guard let context else { throw RepositoryError.notConfigured }
        bundle.closedAt = .now
        bundle.updatedAt = .now
        try context.save()
        logger.debug("Bundle closed for person \(bundle.personID): \(bundle.subItems.count) sub-items in history")
    }

    /// Close the bundle if every sub-item is either completed or skipped.
    /// Returns true if it was closed by this call.
    @discardableResult
    func closeBundleIfDone(_ bundle: OutcomeBundle) throws -> Bool {
        guard bundle.closedAt == nil else { return false }
        let allDone = bundle.subItems.allSatisfy { $0.completedAt != nil || $0.skippedAt != nil }
        guard allDone, !bundle.subItems.isEmpty else { return false }
        try closeBundle(bundle)
        return true
    }

    // MARK: - Sub-Item Upsert

    /// Find an existing open sub-item of the same kind in the bundle, or insert
    /// a new one. Updates title / rationale / priority / dueDate / isMilestone
    /// on the existing row. Returns the persisted sub-item.
    @discardableResult
    func upsertSubItem(
        in bundle: OutcomeBundle,
        kind: OutcomeSubItemKind,
        title: String,
        rationale: String,
        priorityScore: Double,
        dueDate: Date? = nil,
        isMilestone: Bool = false
    ) throws -> OutcomeSubItem {
        guard let context else { throw RepositoryError.notConfigured }
        let kindRaw = kind.rawValue

        if let existing = bundle.subItems.first(where: {
            $0.kindRawValue == kindRaw && $0.completedAt == nil && $0.skippedAt == nil
        }) {
            existing.title = title
            existing.rationale = rationale
            existing.priorityScore = priorityScore
            existing.dueDate = dueDate
            existing.isMilestone = isMilestone
            bundle.updatedAt = .now
            try context.save()
            return existing
        }

        let item = OutcomeSubItem(
            kind: kind,
            title: title,
            rationale: rationale,
            priorityScore: priorityScore,
            dueDate: dueDate,
            isMilestone: isMilestone
        )
        item.bundle = bundle
        bundle.subItems.append(item)
        bundle.updatedAt = .now
        context.insert(item)
        try context.save()
        return item
    }

    /// Drop any open sub-items whose kind is no longer in the generator's
    /// current output set. Keeps closed sub-items (completed/skipped) for
    /// history. Returns the number of sub-items removed.
    @discardableResult
    func removeStaleOpenSubItems(from bundle: OutcomeBundle, keepingKinds keep: Set<OutcomeSubItemKind>) throws -> Int {
        guard let context else { throw RepositoryError.notConfigured }
        let keepRaw = Set(keep.map(\.rawValue))
        var removed = 0
        for item in bundle.subItems where item.completedAt == nil && item.skippedAt == nil {
            if !keepRaw.contains(item.kindRawValue) {
                context.delete(item)
                removed += 1
            }
        }
        if removed > 0 {
            bundle.updatedAt = .now
            try context.save()
        }
        return removed
    }

    // MARK: - Priority Math (max + bump)

    /// Recompute and persist `priorityScore` and `nearestDueDate`. Priority is
    /// max(open sub-item priorities) plus a +0.1 bump (capped at 1.0) when two
    /// or more *distinct topic groups* are open at once.
    func recomputePriority(_ bundle: OutcomeBundle) throws {
        guard let context else { throw RepositoryError.notConfigured }
        let open = bundle.openSubItems
        guard !open.isEmpty else {
            bundle.priorityScore = 0
            bundle.nearestDueDate = nil
            bundle.updatedAt = .now
            try context.save()
            return
        }
        let maxPriority = open.map(\.priorityScore).max() ?? 0
        let groups = Set(open.map { $0.kind.topicGroup })
        let bump = groups.count >= 2 ? 0.1 : 0.0
        bundle.priorityScore = min(1.0, maxPriority + bump)
        bundle.nearestDueDate = open.compactMap(\.dueDate).min()
        bundle.updatedAt = .now
        try context.save()
    }

    // MARK: - Sub-Item Status

    /// User ticked the sub-item. Records completion timestamp and asks the
    /// recurrence rule for the next firing date (stored on the sub-item).
    /// Caller should subsequently call `recomputePriority` and `closeBundleIfDone`.
    func markSubItemCompleted(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let item = try fetchSubItem(id: id) else { return }
        item.completedAt = .now
        item.nextDueAt = OutcomeRecurrence.nextDueAt(for: item.kind, after: .now, isMilestone: item.isMilestone)
        item.bundle?.updatedAt = .now
        try context.save()

        // Record a suppression so the scanner doesn't re-spawn the same sub-item
        // until the next firing window. nil suppressUntil means open-ended.
        if let bundle = item.bundle {
            try recordSuppression(
                personID: bundle.personID,
                kindRawValue: item.kindRawValue,
                suppressUntil: item.nextDueAt,
                migratedFromLegacy: false
            )
        }
    }

    /// User skipped the sub-item (didn't act on it, but doesn't want it now).
    /// Same as completed for suppression purposes — uses the recurrence rule
    /// to choose when it can fire again.
    func markSubItemSkipped(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let item = try fetchSubItem(id: id) else { return }
        item.skippedAt = .now
        item.nextDueAt = OutcomeRecurrence.nextDueAt(for: item.kind, after: .now, isMilestone: item.isMilestone)
        item.bundle?.updatedAt = .now
        try context.save()

        if let bundle = item.bundle {
            try recordSuppression(
                personID: bundle.personID,
                kindRawValue: item.kindRawValue,
                suppressUntil: item.nextDueAt,
                migratedFromLegacy: false
            )
        }
    }

    // MARK: - Dismissal Records

    /// Insert or refresh a suppression record for (personID, kindRawValue).
    /// Idempotent — overwrites suppressUntil if the new value is later.
    func recordSuppression(
        personID: UUID,
        kindRawValue: String,
        suppressUntil: Date?,
        migratedFromLegacy: Bool = false
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<OutcomeDismissalRecord>(
            predicate: #Predicate { $0.personID == personID && $0.kindRawValue == kindRawValue }
        )
        if let existing = try context.fetch(descriptor).first {
            // Take the later suppressUntil (longer suppression wins). If either
            // is nil (open-ended), keep nil.
            if existing.suppressUntil == nil || suppressUntil == nil {
                existing.suppressUntil = nil
            } else if let new = suppressUntil, let old = existing.suppressUntil, new > old {
                existing.suppressUntil = new
            }
            existing.dismissedAt = .now
        } else {
            let record = OutcomeDismissalRecord(
                personID: personID,
                kindRawValue: kindRawValue,
                suppressUntil: suppressUntil,
                migratedFromLegacy: migratedFromLegacy
            )
            context.insert(record)
        }
        try context.save()
    }

    /// True when (personID, kind) is currently suppressed — either suppressUntil
    /// is in the future, or it's open-ended (nil). Scanners consult this before
    /// emitting a sub-item.
    func isSuppressed(personID: UUID, kind: OutcomeSubItemKind, now: Date = .now) throws -> Bool {
        guard let context else { throw RepositoryError.notConfigured }
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<OutcomeDismissalRecord>(
            predicate: #Predicate { $0.personID == personID && $0.kindRawValue == kindRaw }
        )
        guard let record = try context.fetch(descriptor).first else { return false }
        if let until = record.suppressUntil {
            return until > now
        }
        return true   // open-ended suppression
    }

    /// Bulk variant — returns the set of suppressed (personID, kind) pairs in
    /// one fetch. Scanners that iterate every person use this to avoid N
    /// round trips.
    func suppressedPairs(now: Date = .now) throws -> Set<SuppressionKey> {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<OutcomeDismissalRecord>()
        let all = try context.fetch(descriptor)
        var result: Set<SuppressionKey> = []
        for record in all {
            let stillSuppressed = record.suppressUntil.map { $0 > now } ?? true
            if stillSuppressed {
                result.insert(SuppressionKey(personID: record.personID, kindRawValue: record.kindRawValue))
            }
        }
        return result
    }

    /// Clear a suppression (e.g. user manually requests "remind me again").
    func clearSuppression(personID: UUID, kindRawValue: String) throws {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<OutcomeDismissalRecord>(
            predicate: #Predicate { $0.personID == personID && $0.kindRawValue == kindRawValue }
        )
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }
}

// MARK: - SuppressionKey

struct SuppressionKey: Hashable, Sendable {
    let personID: UUID
    let kindRawValue: String
}

// MARK: - Recurrence Rules (P6 placeholder — refined when scanners wire up)

/// Per-sub-item recurrence rules. Returns the next due date the sub-item
/// should fire after the given completion/skip moment. nil means "do not
/// auto-refire" (the scanner will decide based on fresh evidence).
enum OutcomeRecurrence {
    static func nextDueAt(for kind: OutcomeSubItemKind, after date: Date, isMilestone: Bool) -> Date? {
        let cal = Calendar.current
        switch kind {
        case .birthday, .anniversary, .annualReview:
            return cal.date(byAdding: .day, value: 365, to: date)
        case .cadenceReconnect:
            // Cadence scanner will recompute against person.preferredCadenceDays
            // on next pass; suppress for 7 days to debounce.
            return cal.date(byAdding: .day, value: 7, to: date)
        case .stalledPipeline:
            return cal.date(byAdding: .day, value: 30, to: date)
        case .stewardshipArc, .openCommitment, .openActionItem, .proposalPrep, .recruitTouch:
            // Evidence-driven — let the next save reopen if still relevant.
            return cal.date(byAdding: .day, value: 14, to: date)
        case .lifeEventTouch:
            // One-shot. Don't auto-refire.
            return nil
        }
    }
}
