//
//  SAMModels-Undo.swift
//  SAM
//
//  Created by Assistant on 2/25/26.
//  Phase P: Universal Undo System
//
//  Persisted undo entries with JSON-encoded snapshots for 30-day undo history.
//

import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Undo Entry
// ─────────────────────────────────────────────────────────────────────

/// A single undoable operation with its snapshot data.
/// Entries auto-expire after 30 days and are pruned at launch.
@Model
public final class SamUndoEntry {
    @Attribute(.unique) public var id: UUID

    /// "deleted" or "statusChanged"
    public var operationRawValue: String

    /// "note", "outcome", "context", "participation", "insight"
    public var entityTypeRawValue: String

    /// ID of the affected entity
    public var entityID: UUID

    /// Human-readable label for the toast (e.g., "Meeting notes with Sarah")
    public var entityDisplayName: String

    /// JSON-encoded snapshot struct for restoration
    public var snapshotData: Data

    public var capturedAt: Date
    public var expiresAt: Date

    /// Whether this entry has been restored (undo was performed)
    public var isRestored: Bool = false
    public var restoredAt: Date?

    // ── Transient computed properties ───────────────────────────────

    @Transient
    public var operation: UndoOperation {
        get { UndoOperation(rawValue: operationRawValue) ?? .deleted }
        set { operationRawValue = newValue.rawValue }
    }

    @Transient
    public var entityType: UndoEntityType {
        get { UndoEntityType(rawValue: entityTypeRawValue) ?? .note }
        set { entityTypeRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        operation: UndoOperation,
        entityType: UndoEntityType,
        entityID: UUID,
        entityDisplayName: String,
        snapshotData: Data,
        capturedAt: Date = .now,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.operationRawValue = operation.rawValue
        self.entityTypeRawValue = entityType.rawValue
        self.entityID = entityID
        self.entityDisplayName = entityDisplayName
        self.snapshotData = snapshotData
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt ?? Calendar.current.date(byAdding: .day, value: 30, to: capturedAt) ?? capturedAt
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Enums
// ─────────────────────────────────────────────────────────────────────

public enum UndoOperation: String, Codable, Sendable {
    case deleted
    case statusChanged
    case merged
}

public enum UndoEntityType: String, Codable, Sendable {
    case note
    case outcome
    case context
    case participation
    case insight
    case person
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Snapshot Structs
// ─────────────────────────────────────────────────────────────────────

/// Snapshot of a deleted note — captures all fields needed for full restoration.
/// Images are NOT included (too large); restored notes lose images.
public struct NoteSnapshot: Codable, Sendable {
    public let id: UUID
    public let content: String
    public let summary: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let sourceTypeRawValue: String
    public let sourceImportUID: String?
    public let isAnalyzed: Bool
    public let analysisVersion: Int
    public let extractedMentions: [ExtractedPersonMention]
    public let extractedActionItems: [NoteActionItem]
    public let extractedTopics: [String]
    public let discoveredRelationships: [DiscoveredRelationship]
    public let lifeEvents: [LifeEvent]
    public let followUpDraft: String?
    public let linkedPeopleIDs: [UUID]
    public let linkedContextIDs: [UUID]
    public let linkedEvidenceIDs: [UUID]
}

/// Snapshot of an outcome status change — captures previous state for reversal.
public struct OutcomeSnapshot: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let previousStatusRawValue: String
    public let previousDismissedAt: Date?
    public let previousCompletedAt: Date?
    public let previousWasActedOn: Bool
}

/// Snapshot of a deleted context — includes all participations for cascade restore.
public struct ContextSnapshot: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let kindRawValue: String
    public let consentAlertCount: Int
    public let reviewAlertCount: Int
    public let followUpAlertCount: Int
    public let participations: [ParticipationSnapshot]
}

/// Snapshot of a participation (person ↔ context link).
/// Used both standalone (participant removal) and embedded in ContextSnapshot.
public struct ParticipationSnapshot: Codable, Sendable {
    public let id: UUID
    public let personID: UUID
    public let contextID: UUID
    public let roleBadges: [String]
    public let isPrimary: Bool
    public let note: String?
    public let startDate: Date
    public let endDate: Date?
    public let personDisplayName: String
    public let contextName: String
}

/// Snapshot of a dismissed insight — lightweight, just needs ID + title.
public struct InsightSnapshot: Codable, Sendable {
    public let id: UUID
    public let title: String
}

/// Snapshot of a lifecycle status change — captures previous status for reversal.
public struct LifecycleChangeSnapshot: Codable, Sendable {
    public let personID: UUID
    public let personName: String
    public let previousStatusRawValue: String
    public let newStatusRawValue: String
}

/// Snapshot of a person merge — captures source person's state for full reversal.
public struct PersonMergeSnapshot: Codable, Sendable {
    public let sourcePersonID: UUID
    public let targetPersonID: UUID
    public let sourceDisplayName: String

    // Scalar fields from source (for re-creation)
    public let displayName: String
    public let email: String?
    public let displayNameCache: String?
    public let emailCache: String?
    public let emailAliases: [String]
    public let phoneAliases: [String]
    public let roleBadges: [String]
    public let contactIdentifier: String?
    public let isMe: Bool
    public let isArchived: Bool // legacy
    public let lifecycleStatusRawValue: String
    public let relationshipSummary: String?
    public let relationshipKeyThemes: [String]
    public let relationshipNextSteps: [String]
    public let preferredCadenceDays: Int?
    public let preferredChannelRawValue: String?
    public let inferredChannelRawValue: String?
    public let linkedInProfileURL: String?
    public let linkedInConnectedOn: Date?
    public let facebookProfileURL: String?
    public let facebookFriendedOn: Date?
    public let facebookMessageCount: Int
    public let facebookLastMessageDate: Date?
    public let facebookTouchScore: Int

    // Relationship IDs that were transferred (for re-pointing on undo)
    public let evidenceIDs: [UUID]
    public let noteIDs: [UUID]
    public let participationIDs: [UUID]
    public let outcomeIDs: [UUID]
    public let insightIDs: [UUID]
    public let transitionIDs: [UUID]
    public let recruitingStageIDs: [UUID]
    public let productionRecordIDs: [UUID]
    public let deducedRelationIDs: [UUID]

    // Scalars that were unioned into target (for removal on undo)
    public let unionedEmails: [String]
    public let unionedPhones: [String]
    public let unionedRoleBadges: [String]
}
