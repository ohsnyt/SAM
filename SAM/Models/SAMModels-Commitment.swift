//
//  SAMModels-Commitment.swift
//  SAM
//
//  Block 3: Commitment tracking.
//  A SamCommitment is a durable record of a promise made during a meeting,
//  a note, or entered manually. Two directions: Sarah committing to a
//  person ("I'll send the illustration Monday") and a person committing
//  to Sarah ("I'll review the proposal by Friday"). Resolved commitments
//  feed a per-person follow-through rate that weights pipeline signals.
//

import SwiftData
import Foundation

// MARK: - CommitmentStatus

public enum CommitmentStatus: String, Codable, Sendable, CaseIterable {
    /// Open, not yet resolved.
    case pending
    /// The committing party delivered.
    case fulfilled
    /// Due date passed without fulfillment (auto-swept or user-marked).
    case missed
    /// User chose to drop this without scoring it (e.g. no longer relevant).
    case dismissed
}

// MARK: - CommitmentDirection

public enum CommitmentDirection: String, Codable, Sendable {
    /// Sarah committed to the linked person.
    case fromUser
    /// The linked person committed to Sarah.
    case toUser
}

// MARK: - CommitmentSource

public enum CommitmentSource: String, Codable, Sendable {
    /// Extracted from a MeetingSummary on a TranscriptSession.
    case meetingTranscript
    /// Extracted from a SamNote's action items.
    case note
    /// Entered directly by Sarah in the UI.
    case manual
}

// MARK: - SamCommitment

/// One recorded commitment. Relationships use nullify so historical
/// follow-through data survives record deletion upstream.
@Model
public final class SamCommitment {
    @Attribute(.unique) public var id: UUID

    /// Plain-text description of what was committed to.
    public var text: String

    /// When the commitment was made (meeting time, note time, or manual entry).
    public var createdAt: Date

    /// Parsed absolute due date. Nil if only a fuzzy hint was given.
    public var dueDate: Date?

    /// Original fuzzy due-date phrase from the LLM, e.g. "Friday", "end of month".
    /// Kept for display even after dueDate is parsed.
    public var dueHint: String?

    /// Raw storage for CommitmentStatus.
    public var statusRawValue: String

    /// Raw storage for CommitmentDirection.
    public var directionRawValue: String

    /// Raw storage for CommitmentSource.
    public var sourceRawValue: String

    /// When the commitment transitioned to .fulfilled.
    public var fulfilledAt: Date?

    /// When the commitment transitioned to .missed (auto-swept or user-marked).
    public var missedAt: Date?

    /// When the commitment transitioned to .dismissed.
    public var dismissedAt: Date?

    /// Free-form note Sarah can add when resolving (e.g. "delivered via email").
    public var resolutionNote: String?

    // MARK: - Relationships

    /// The other party. For `.fromUser`, this is who Sarah owes. For
    /// `.toUser`, this is who owes Sarah. Never Sarah herself.
    @Relationship(deleteRule: .nullify)
    public var linkedPerson: SamPerson?

    /// The transcript this commitment was extracted from. Nil for manual/note sources.
    @Relationship(deleteRule: .nullify)
    public var linkedTranscript: TranscriptSession?

    /// The note this commitment was extracted from. Nil for manual/transcript sources.
    @Relationship(deleteRule: .nullify)
    public var linkedNote: SamNote?

    /// The calendar/meeting event the commitment was made at, if known.
    @Relationship(deleteRule: .nullify)
    public var linkedEvidence: SamEvidenceItem?

    // MARK: - Typed accessors

    @Transient
    public var status: CommitmentStatus {
        get { CommitmentStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    @Transient
    public var direction: CommitmentDirection {
        get { CommitmentDirection(rawValue: directionRawValue) ?? .fromUser }
        set { directionRawValue = newValue.rawValue }
    }

    @Transient
    public var source: CommitmentSource {
        get { CommitmentSource(rawValue: sourceRawValue) ?? .manual }
        set { sourceRawValue = newValue.rawValue }
    }

    /// True once the commitment has reached any terminal status.
    @Transient
    public var isResolved: Bool {
        status != .pending
    }

    /// True if pending and the due date has passed.
    @Transient
    public var isOverdue: Bool {
        guard status == .pending, let due = dueDate else { return false }
        return due < .now
    }

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = .now,
        dueDate: Date? = nil,
        dueHint: String? = nil,
        status: CommitmentStatus = .pending,
        direction: CommitmentDirection,
        source: CommitmentSource,
        linkedPerson: SamPerson? = nil,
        linkedTranscript: TranscriptSession? = nil,
        linkedNote: SamNote? = nil,
        linkedEvidence: SamEvidenceItem? = nil,
        resolutionNote: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.dueDate = dueDate
        self.dueHint = dueHint
        self.statusRawValue = status.rawValue
        self.directionRawValue = direction.rawValue
        self.sourceRawValue = source.rawValue
        self.linkedPerson = linkedPerson
        self.linkedTranscript = linkedTranscript
        self.linkedNote = linkedNote
        self.linkedEvidence = linkedEvidence
        self.resolutionNote = resolutionNote
    }
}
