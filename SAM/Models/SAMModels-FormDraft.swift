//
//  SAMModels-FormDraft.swift
//  SAM
//
//  Phase 1 of the sheet-tear-down work loss fix.
//
//  A FormDraft is a per-form, per-subject snapshot of in-progress user
//  input. Coordinators flush their @Observable state to a FormDraft on a
//  debounced interval; on coordinator init they hydrate from any existing
//  draft for the same (formKind, subjectID) pair. This makes a typed form
//  survive three failure modes that local @State cannot:
//    • View unmount during sheet displacement by ModalCoordinator
//    • App lock / SwiftUI re-render that tears the sheet down
//    • App crash, force-quit, power loss
//
//  Two layers consume this table:
//    • DraftPersistenceService — the SwiftData CRUD layer used by typed
//      coordinators (e.g. PostMeetingCaptureCoordinator) with structured
//      Codable payloads.
//    • DraftStore — the legacy [String: String] field map used by ~9
//      existing edit sheets. Phase 1 backs DraftStore by this same table
//      so every existing caller picks up crash recovery without API
//      changes.
//
//  Uniqueness on (formKind, subjectID) is enforced by the service layer
//  via upsert — SwiftData does not support compound unique constraints.
//

import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - FormKind
// ─────────────────────────────────────────────────────────────────────

/// Identifies the kind of form a draft belongs to. Stored as a raw
/// string so new kinds can be added without a schema migration; consumers
/// that don't recognize a kind treat it as opaque and leave it alone.
public enum FormKind: String, Codable, Sendable {
    case postMeetingCapture
    case enrichmentReview
    case contentDraft
    case noteEdit
    case compose
    case goalEntry
    case productionEntry
    case correction
    case manualTask
    case eventForm
    /// Catch-all bucket for DraftStore string-map callers that haven't
    /// been migrated to a typed coordinator yet. The raw `kind` string
    /// from the legacy API is recorded in `legacyKind`.
    case legacyFieldMap
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - FormDraft
// ─────────────────────────────────────────────────────────────────────

@Model
public final class FormDraft {
    @Attribute(.unique) public var id: UUID

    /// Raw value of `FormKind`. Stored as a string so we can evolve the
    /// enum without a SwiftData migration.
    public var formKindRawValue: String

    /// For `legacyFieldMap` drafts, the original DraftStore `kind` string
    /// (e.g. "note-edit"). Nil for typed drafts.
    public var legacyKind: String?

    /// Identity of the subject the draft is about: a meeting UUID, a
    /// person UUID, an outcome UUID, etc. For new entities that don't
    /// have a UUID yet (e.g. a brand-new note), the form must allocate a
    /// stable UUID at first edit and reuse it on restore.
    public var subjectID: UUID

    /// JSON-encoded payload. For typed drafts this is the encoded form
    /// coordinator's `Codable` snapshot; for legacy drafts it is a
    /// JSON-encoded `[String: String]`.
    public var payloadJSON: Data

    /// Monotonic version of the payload schema for this `formKind`.
    /// Coordinators bump this when they add fields; decode paths use
    /// `decodeIfPresent` + defaults so old drafts still decode after a
    /// bump. If the version is far enough ahead of what the running app
    /// understands, the draft is treated as undecodable and surfaces in
    /// the auto-discard notice rather than crashing.
    public var payloadVersion: Int

    /// Optional human-readable label for the Today restore banner.
    /// Stored as a flat column so the banner can render without
    /// decoding the JSON payload. Coordinators set this on save
    /// (e.g. PostMeetingCaptureCoordinator sets `payload.eventTitle`).
    public var displayTitle: String?

    /// Optional secondary label (date, person, etc). Same rationale —
    /// keep it flat so the banner doesn't pay decode cost per row.
    public var displaySubtitle: String?

    public var createdAt: Date
    public var updatedAt: Date

    // ── Transient computed properties ───────────────────────────────

    @Transient
    public var formKind: FormKind {
        get { FormKind(rawValue: formKindRawValue) ?? .legacyFieldMap }
        set { formKindRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        formKind: FormKind,
        subjectID: UUID,
        payloadJSON: Data,
        payloadVersion: Int = 1,
        legacyKind: String? = nil,
        displayTitle: String? = nil,
        displaySubtitle: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.formKindRawValue = formKind.rawValue
        self.legacyKind = legacyKind
        self.subjectID = subjectID
        self.payloadJSON = payloadJSON
        self.payloadVersion = payloadVersion
        self.displayTitle = displayTitle
        self.displaySubtitle = displaySubtitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
