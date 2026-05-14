//
//  DraftPersistenceService.swift
//  SAM
//
//  Phase 1 of the sheet-tear-down work loss fix.
//
//  CRUD for `FormDraft` rows, keyed by (formKind, subjectID). One draft
//  per (kind, subject) pair — writes upsert, reads return the latest.
//
//  Uses `container.mainContext` for the same reason every other
//  @MainActor repository should — private contexts crash later at fault
//  resolution time when SwiftUI tries to render a model fetched on a
//  different context. See feedback_swiftdata_single_context. FormDraft
//  itself has no relationships, so the rule is less load-bearing here,
//  but matching the pattern keeps the codebase consistent.
//
//  Decode tolerance: callers pass a `Codable` payload type; if a stored
//  draft fails to decode (schema drift, version skew, corruption) the
//  service logs and returns nil rather than throwing. The caller then
//  proceeds as if no draft existed. A separate path surfaces the
//  undecodable draft in the user-facing auto-discard notice (Phase 4).
//

import Foundation
import SwiftData
import os.log

@MainActor @Observable
final class DraftPersistenceService {

    static let shared = DraftPersistenceService()

    private var container: ModelContainer?
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DraftPersistenceService")

    private init() {}

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.container = container
    }

    private var context: ModelContext {
        guard let container else {
            fatalError("DraftPersistenceService: configure(container:) not called")
        }
        return container.mainContext
    }

    // MARK: - Typed Payload API

    /// Save a draft for a typed coordinator. Upserts on (kind, subjectID).
    /// `displayTitle` / `displaySubtitle` populate the Today restore
    /// banner without forcing it to decode the JSON payload for every
    /// row. Returns the stored row's id for diagnostics.
    @discardableResult
    func save<Payload: Encodable>(
        kind: FormKind,
        subjectID: UUID,
        payload: Payload,
        payloadVersion: Int = 1,
        displayTitle: String? = nil,
        displaySubtitle: String? = nil
    ) throws -> UUID {
        let data = try JSONEncoder().encode(payload)
        return try upsert(
            kind: kind,
            legacyKind: nil,
            subjectID: subjectID,
            payloadJSON: data,
            payloadVersion: payloadVersion,
            displayTitle: displayTitle,
            displaySubtitle: displaySubtitle
        )
    }

    /// Load a typed draft. Returns nil if no draft exists OR if the draft
    /// is undecodable (schema drift, version skew). Undecodable drafts
    /// are logged but not thrown — the caller proceeds as if blank, and
    /// the auto-discard surface (Phase 4) reports them to the user.
    func load<Payload: Decodable>(
        _ payloadType: Payload.Type,
        kind: FormKind,
        subjectID: UUID
    ) -> Payload? {
        guard let row = fetchRow(kind: kind, legacyKind: nil, subjectID: subjectID) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(payloadType, from: row.payloadJSON)
        } catch {
            logger.warning("Undecodable draft \(row.id) for kind=\(kind.rawValue) subject=\(subjectID); will surface in auto-discard")
            return nil
        }
    }

    /// Delete a draft for a typed coordinator. No-op if none exists.
    func delete(kind: FormKind, subjectID: UUID) {
        deleteRow(kind: kind, legacyKind: nil, subjectID: subjectID)
    }

    // MARK: - Legacy Field-Map API (DraftStore backing)

    /// Save a `[String: String]` field map. Used by DraftStore to back
    /// its in-memory cache with on-disk persistence.
    @discardableResult
    func saveLegacy(
        legacyKind: String,
        subjectID: UUID,
        fields: [String: String]
    ) throws -> UUID {
        let data = try JSONEncoder().encode(fields)
        return try upsert(
            kind: .legacyFieldMap,
            legacyKind: legacyKind,
            subjectID: subjectID,
            payloadJSON: data,
            payloadVersion: 1
        )
    }

    func loadLegacy(legacyKind: String, subjectID: UUID) -> [String: String]? {
        guard let row = fetchRow(kind: .legacyFieldMap, legacyKind: legacyKind, subjectID: subjectID) else {
            return nil
        }
        return (try? JSONDecoder().decode([String: String].self, from: row.payloadJSON))
    }

    func deleteLegacy(legacyKind: String, subjectID: UUID) {
        deleteRow(kind: .legacyFieldMap, legacyKind: legacyKind, subjectID: subjectID)
    }

    // MARK: - External Gates

    /// True if there is an unfinished draft for `(kind, subjectID)`.
    /// Used by `RetentionService` to defer audio purge while a post-
    /// meeting capture is still in flight — Sarah hasn't yet confirmed
    /// the derived outputs for that meeting, so it would be wrong to
    /// destroy the source material under her.
    func hasUnfinishedDraft(kind: FormKind, subjectID: UUID) -> Bool {
        fetchRow(kind: kind, legacyKind: nil, subjectID: subjectID) != nil
    }

    // MARK: - Banner descriptors

    /// Lightweight summary of an unfinished draft, suitable for the
    /// Today restore banner. Keep this struct small — we only show
    /// `formKind`, `displayTitle`, `updatedAt`, and the subjectID needed
    /// to drive the Resume action.
    struct Descriptor: Identifiable, Hashable, Sendable {
        let id: UUID            // FormDraft.id
        let formKind: FormKind
        let subjectID: UUID
        let displayTitle: String?
        let displaySubtitle: String?
        let updatedAt: Date
    }

    /// Returns active (non-stale) drafts as `Descriptor`s for the
    /// restore banner. Drafts without a `displayTitle` are still
    /// returned — the banner falls back to a generic label.
    func unfinishedDraftDescriptors(
        olderThan ttl: TimeInterval = 60 * 60 * 24 * 7,
        now: Date = .now
    ) -> [Descriptor] {
        allActive(olderThan: ttl, now: now).map {
            Descriptor(
                id: $0.id,
                formKind: $0.formKind,
                subjectID: $0.subjectID,
                displayTitle: $0.displayTitle,
                displaySubtitle: $0.displaySubtitle,
                updatedAt: $0.updatedAt
            )
        }
    }

    // MARK: - Auto-discard pass
    //
    // Drafts older than 7 days get cleaned up on launch. The count of
    // discarded drafts is added to a pending-notice counter in
    // UserDefaults so the next Today banner can plainly tell Sarah
    // what happened. Acknowledging the notice clears the counter.

    private enum DefaultsKey {
        static let pendingDiscardCount = "sam.draftAutoDiscard.pendingCount"
        static let lastDiscardAt = "sam.draftAutoDiscard.lastAt"
    }

    /// Run a single auto-discard pass. Returns the number of drafts
    /// purged in this call; the cumulative pending-notice counter (read
    /// via `pendingAutoDiscardNotice()`) reflects every purge since the
    /// last user acknowledgement.
    @discardableResult
    func runAutoDiscardIfNeeded(
        ttl: TimeInterval = 60 * 60 * 24 * 7,
        now: Date = .now
    ) -> Int {
        let stale = allStale(olderThan: ttl, now: now)
        guard !stale.isEmpty else { return 0 }
        let purged = deleteAll(matching: stale)
        let defaults = UserDefaults.standard
        let prior = defaults.integer(forKey: DefaultsKey.pendingDiscardCount)
        defaults.set(prior + purged, forKey: DefaultsKey.pendingDiscardCount)
        defaults.set(now, forKey: DefaultsKey.lastDiscardAt)
        logger.notice("Auto-discarded \(purged) draft(s) older than \(Int(ttl / 86400)) day(s)")
        return purged
    }

    /// Returns the (count, when) pair that should drive the auto-discard
    /// notice in the Today banner. `count == 0` means nothing pending.
    func pendingAutoDiscardNotice() -> (count: Int, when: Date?) {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: DefaultsKey.pendingDiscardCount)
        let when = defaults.object(forKey: DefaultsKey.lastDiscardAt) as? Date
        return (count, when)
    }

    /// Called when the user dismisses the auto-discard notice.
    func acknowledgePendingAutoDiscardNotice() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.pendingDiscardCount)
        defaults.removeObject(forKey: DefaultsKey.lastDiscardAt)
    }

    // MARK: - Cleanup & Inspection

    /// Drafts older than `olderThan` based on `updatedAt`. Used by the
    /// 7-day TTL cleanup job and the Today restore banner (Phase 4).
    func allStale(olderThan: TimeInterval, now: Date = .now) -> [FormDraft] {
        let cutoff = now.addingTimeInterval(-olderThan)
        let descriptor = FetchDescriptor<FormDraft>(
            predicate: #Predicate { $0.updatedAt < cutoff },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// All non-stale drafts, newest first. Used by the Today restore
    /// banner to list resumable work.
    func allActive(olderThan: TimeInterval, now: Date = .now) -> [FormDraft] {
        let cutoff = now.addingTimeInterval(-olderThan)
        let descriptor = FetchDescriptor<FormDraft>(
            predicate: #Predicate { $0.updatedAt >= cutoff },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Delete every draft matching the predicate. Returns the count
    /// deleted so the caller can shape the user-facing message.
    @discardableResult
    func deleteAll(matching rows: [FormDraft]) -> Int {
        let ctx = context
        for row in rows {
            ctx.delete(row)
        }
        do {
            try ctx.save()
        } catch {
            logger.error("Failed to save after bulk delete: \(error.localizedDescription)")
        }
        return rows.count
    }

    // MARK: - Internals

    private func fetchRow(kind: FormKind, legacyKind: String?, subjectID: UUID) -> FormDraft? {
        let rawValue = kind.rawValue
        // SwiftData predicates can't reliably match on optional Strings
        // inside compound conditions without falling out of the supported
        // subset; fetch by the indexable fields and filter the legacyKind
        // tiebreaker in Swift.
        let descriptor = FetchDescriptor<FormDraft>(
            predicate: #Predicate {
                $0.formKindRawValue == rawValue && $0.subjectID == subjectID
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.first(where: { $0.legacyKind == legacyKind })
    }

    private func upsert(
        kind: FormKind,
        legacyKind: String?,
        subjectID: UUID,
        payloadJSON: Data,
        payloadVersion: Int,
        displayTitle: String? = nil,
        displaySubtitle: String? = nil
    ) throws -> UUID {
        let ctx = context
        if let existing = fetchRow(kind: kind, legacyKind: legacyKind, subjectID: subjectID) {
            existing.payloadJSON = payloadJSON
            existing.payloadVersion = payloadVersion
            existing.updatedAt = .now
            // Only overwrite display fields when the caller supplied
            // values — preserves a meaningful title across saves where
            // a coordinator only updates the user-typed payload.
            if let displayTitle { existing.displayTitle = displayTitle }
            if let displaySubtitle { existing.displaySubtitle = displaySubtitle }
            try ctx.save()
            return existing.id
        }
        let row = FormDraft(
            formKind: kind,
            subjectID: subjectID,
            payloadJSON: payloadJSON,
            payloadVersion: payloadVersion,
            legacyKind: legacyKind,
            displayTitle: displayTitle,
            displaySubtitle: displaySubtitle
        )
        ctx.insert(row)
        try ctx.save()
        return row.id
    }

    private func deleteRow(kind: FormKind, legacyKind: String?, subjectID: UUID) {
        guard let row = fetchRow(kind: kind, legacyKind: legacyKind, subjectID: subjectID) else { return }
        let ctx = context
        ctx.delete(row)
        do {
            try ctx.save()
        } catch {
            logger.error("Failed to save after delete: \(error.localizedDescription)")
        }
    }
}
