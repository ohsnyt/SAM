//
//  BackupDocument.swift
//  SAM
//
//  Top-level Codable container for SAM backup/restore.
//  Contains metadata, user preferences, and flat DTO arrays
//  for all core models. Relationships expressed as UUID references.
//

import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Top-Level Document
// ─────────────────────────────────────────────────────────────────────

struct BackupDocument: Codable {
    var metadata: BackupMetadata
    var preferences: [String: AnyCodableValue]

    // Core entities
    var people: [PersonBackup]
    var contexts: [ContextBackup]
    var participations: [ParticipationBackup]
    var responsibilities: [ResponsibilityBackup]
    var jointInterests: [JointInterestBackup]
    var consentRequirements: [ConsentRequirementBackup]
    var products: [ProductBackup]
    var coverages: [CoverageBackup]
    var evidenceItems: [EvidenceBackup]
    var notes: [NoteBackup]
    var noteImages: [NoteImageBackup]
    var analysisArtifacts: [AnalysisArtifactBackup]
    var coachingProfile: CoachingProfileBackup?
    var timeEntries: [TimeEntryBackup]
    var stageTransitions: [StageTransitionBackup]
    var recruitingStages: [RecruitingStageBackup]
    var productionRecords: [ProductionRecordBackup]
    var contentPosts: [ContentPostBackup]
    var businessGoals: [BusinessGoalBackup]
    var complianceAuditEntries: [ComplianceAuditBackup]
    var deducedRelations: [DeducedRelationBackup]
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Metadata
// ─────────────────────────────────────────────────────────────────────

struct BackupMetadata: Codable {
    var exportDate: Date
    var schemaVersion: String
    var appVersion: String
    var buildNumber: String
    var backupFormatVersion: Int
    var counts: BackupCounts
}

struct BackupCounts: Codable {
    var people: Int
    var notes: Int
    var evidence: Int
    var contexts: Int
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Import Preview
// ─────────────────────────────────────────────────────────────────────

struct ImportPreview {
    var metadata: BackupMetadata
    var schemaMatch: Bool
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - AnyCodableValue
// ─────────────────────────────────────────────────────────────────────

/// Heterogeneous value wrapper for UserDefaults serialization.
enum AnyCodableValue: Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    private enum TypeKey: String, Codable {
        case bool, int, double, string
    }

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeKey.self, forKey: .type)
        switch type {
        case .bool:   self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int:    self = .int(try container.decode(Int.self, forKey: .value))
        case .double: self = .double(try container.decode(Double.self, forKey: .value))
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):
            try container.encode(TypeKey.bool, forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode(TypeKey.int, forKey: .type)
            try container.encode(v, forKey: .value)
        case .double(let v):
            try container.encode(TypeKey.double, forKey: .type)
            try container.encode(v, forKey: .value)
        case .string(let v):
            try container.encode(TypeKey.string, forKey: .type)
            try container.encode(v, forKey: .value)
        }
    }

    /// Read a UserDefaults value and wrap it.
    static func from(userDefaults: UserDefaults, key: String) -> AnyCodableValue? {
        guard let obj = userDefaults.object(forKey: key) else { return nil }
        if let b = obj as? Bool   { return .bool(b) }
        if let i = obj as? Int    { return .int(i) }
        if let d = obj as? Double { return .double(d) }
        if let s = obj as? String { return .string(s) }
        return nil
    }

    /// Write the wrapped value back to UserDefaults.
    func apply(to userDefaults: UserDefaults, key: String) {
        switch self {
        case .bool(let v):   userDefaults.set(v, forKey: key)
        case .int(let v):    userDefaults.set(v, forKey: key)
        case .double(let v): userDefaults.set(v, forKey: key)
        case .string(let v): userDefaults.set(v, forKey: key)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 1. PersonBackup
// ─────────────────────────────────────────────────────────────────────

struct PersonBackup: Codable {
    var id: UUID
    var contactIdentifier: String?
    var displayNameCache: String?
    var emailCache: String?
    var emailAliases: [String]
    var phoneAliases: [String]
    var photoThumbnailBase64: String?
    var lastSyncedAt: Date?
    var isArchived: Bool
    var isMe: Bool
    var relationshipSummary: String?
    var relationshipKeyThemes: [String]
    var relationshipNextSteps: [String]
    var summaryUpdatedAt: Date?
    var inferredChannelRawValue: String?
    var preferredChannelRawValue: String?
    var preferredCadenceDays: Int?
    var displayName: String
    var email: String?
    var roleBadges: [String]
    var consentAlertsCount: Int
    var reviewAlertsCount: Int
    var responsibilityNotes: [String]
    var recentInteractions: [InteractionChip]
    var contextChips: [ContextChip]
    var referredByID: UUID?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 2. ContextBackup
// ─────────────────────────────────────────────────────────────────────

struct ContextBackup: Codable {
    var id: UUID
    var name: String
    var kind: ContextKind
    var consentAlertCount: Int
    var reviewAlertCount: Int
    var followUpAlertCount: Int
    var productCards: [ContextProductModel]
    var recentInteractions: [InteractionModel]
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 3. ParticipationBackup
// ─────────────────────────────────────────────────────────────────────

struct ParticipationBackup: Codable {
    var id: UUID
    var personID: UUID?
    var contextID: UUID?
    var roleBadges: [String]
    var isPrimary: Bool
    var note: String?
    var startDate: Date
    var endDate: Date?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 4. ResponsibilityBackup
// ─────────────────────────────────────────────────────────────────────

struct ResponsibilityBackup: Codable {
    var id: UUID
    var guardianID: UUID?
    var dependentID: UUID?
    var reason: String
    var startDate: Date
    var endDate: Date?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 5. JointInterestBackup
// ─────────────────────────────────────────────────────────────────────

struct JointInterestBackup: Codable {
    var id: UUID
    var partyIDs: [UUID]
    var type: JointInterestType
    var survivorshipRights: Bool
    var startDate: Date
    var endDate: Date?
    var notes: String?
    var productIDs: [UUID]
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 6. ConsentRequirementBackup
// ─────────────────────────────────────────────────────────────────────

struct ConsentRequirementBackup: Codable {
    var id: UUID
    var personID: UUID?
    var contextID: UUID?
    var productID: UUID?
    var title: String
    var reason: String
    var jurisdiction: String?
    var status: ConsentStatus
    var requestedAt: Date
    var satisfiedAt: Date?
    var revokedAt: Date?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 7. ProductBackup
// ─────────────────────────────────────────────────────────────────────

struct ProductBackup: Codable {
    var id: UUID
    var contextID: UUID?
    var type: ProductType
    var name: String
    var subtitle: String?
    var statusDisplay: String
    var icon: String
    var issuedDate: Date?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 8. CoverageBackup
// ─────────────────────────────────────────────────────────────────────

struct CoverageBackup: Codable {
    var id: UUID
    var personID: UUID?
    var productID: UUID?
    var role: CoverageRole
    var survivorshipRights: Bool
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 9. EvidenceBackup
// ─────────────────────────────────────────────────────────────────────

struct EvidenceBackup: Codable {
    var id: UUID
    var sourceUID: String?
    var source: EvidenceSource
    var stateRawValue: String
    var occurredAt: Date
    var endedAt: Date?
    var title: String
    var snippet: String
    var bodyText: String?
    var signals: [EvidenceSignal]
    var participantHints: [ParticipantHint]
    var proposedLinks: [ProposedLink]
    var linkedPeopleIDs: [UUID]
    var linkedContextIDs: [UUID]
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 10. NoteBackup
// ─────────────────────────────────────────────────────────────────────

struct NoteBackup: Codable {
    var id: UUID
    var content: String
    var summary: String?
    var createdAt: Date
    var updatedAt: Date
    var sourceTypeRawValue: String
    var sourceImportUID: String?
    var isAnalyzed: Bool
    var analysisVersion: Int
    var linkedPeopleIDs: [UUID]
    var linkedContextIDs: [UUID]
    var linkedEvidenceIDs: [UUID]
    var extractedMentions: [ExtractedPersonMention]
    var extractedActionItems: [NoteActionItem]
    var extractedTopics: [String]
    var discoveredRelationships: [DiscoveredRelationship]
    var lifeEvents: [LifeEvent]
    var followUpDraft: String?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 11. NoteImageBackup
// ─────────────────────────────────────────────────────────────────────

struct NoteImageBackup: Codable {
    var id: UUID
    var noteID: UUID?
    var imageDataBase64: String?
    var mimeType: String
    var displayOrder: Int
    var textInsertionPoint: Int?
    var createdAt: Date
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 12. AnalysisArtifactBackup
// ─────────────────────────────────────────────────────────────────────

struct AnalysisArtifactBackup: Codable {
    var id: UUID
    var noteID: UUID?
    var sourceType: AnalysisSourceType
    var analyzedAt: Date
    var peopleJSON: String?
    var topicsJSON: String?
    var factsJSON: String?
    var implicationsJSON: String?
    var actions: [String]
    var affect: String?
    var usedLLM: Bool
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 13. CoachingProfileBackup
// ─────────────────────────────────────────────────────────────────────

struct CoachingProfileBackup: Codable {
    var id: UUID
    var encouragementStyle: String
    var preferredOutcomeKinds: [String]
    var dismissPatterns: [String]
    var avgResponseTimeMinutes: Double
    var totalActedOn: Int
    var totalDismissed: Int
    var totalRated: Int
    var avgRating: Double
    var updatedAt: Date
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 14. TimeEntryBackup
// ─────────────────────────────────────────────────────────────────────

struct TimeEntryBackup: Codable {
    var id: UUID
    var categoryRawValue: String
    var title: String
    var durationMinutes: Int
    var startedAt: Date
    var endedAt: Date
    var isManualOverride: Bool
    var isManualEntry: Bool
    var sourceEvidenceID: UUID?
    var linkedPeopleIDs: [UUID]
    var createdAt: Date
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 15. StageTransitionBackup
// ─────────────────────────────────────────────────────────────────────

struct StageTransitionBackup: Codable {
    var id: UUID
    var personID: UUID?
    var fromStage: String
    var toStage: String
    var transitionDate: Date
    var pipelineTypeRawValue: String
    var notes: String?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 16. RecruitingStageBackup
// ─────────────────────────────────────────────────────────────────────

struct RecruitingStageBackup: Codable {
    var id: UUID
    var personID: UUID?
    var stageRawValue: String
    var enteredDate: Date
    var mentoringLastContact: Date?
    var notes: String?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 17. ProductionRecordBackup
// ─────────────────────────────────────────────────────────────────────

struct ProductionRecordBackup: Codable {
    var id: UUID
    var personID: UUID?
    var productTypeRawValue: String
    var statusRawValue: String
    var carrierName: String
    var annualPremium: Double
    var submittedDate: Date
    var resolvedDate: Date?
    var policyNumber: String?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 18. ContentPostBackup
// ─────────────────────────────────────────────────────────────────────

struct ContentPostBackup: Codable {
    var id: UUID
    var platformRawValue: String
    var topic: String
    var postedAt: Date
    var sourceOutcomeID: UUID?
    var createdAt: Date
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 19. BusinessGoalBackup
// ─────────────────────────────────────────────────────────────────────

struct BusinessGoalBackup: Codable {
    var id: UUID
    var goalTypeRawValue: String
    var title: String
    var targetValue: Double
    var startDate: Date
    var endDate: Date
    var isActive: Bool
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 20. ComplianceAuditBackup
// ─────────────────────────────────────────────────────────────────────

struct ComplianceAuditBackup: Codable {
    var id: UUID
    var channelRawValue: String
    var recipientName: String?
    var recipientAddress: String?
    var originalDraft: String
    var finalDraft: String?
    var wasModified: Bool
    var complianceFlagsJSON: String?
    var outcomeID: UUID?
    var createdAt: Date
    var sentAt: Date?
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - 21. DeducedRelationBackup
// ─────────────────────────────────────────────────────────────────────

struct DeducedRelationBackup: Codable {
    var id: UUID
    var personAID: UUID
    var personBID: UUID
    var relationTypeRawValue: String
    var sourceLabel: String
    var isConfirmed: Bool
    var createdAt: Date
    var confirmedAt: Date?
}
