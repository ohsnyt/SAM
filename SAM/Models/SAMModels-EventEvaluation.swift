//
//  SAMModels-EventEvaluation.swift
//  SAM
//
//  Created on April 7, 2026.
//  Post-event evaluation model for workshop analysis and follow-up generation.
//

import Foundation
import SwiftData

// MARK: - EventEvaluation

/// Stores post-event evaluation data for a completed workshop/event.
/// Contains imported chat analysis, feedback responses, and AI-generated insights.
@Model
public final class EventEvaluation {
    @Attribute(.unique) public var id: UUID

    // MARK: Relationships

    public var event: SamEvent?

    // MARK: Import Metadata

    public var chatImportedAt: Date?
    public var feedbackImportedAt: Date?
    public var transcriptImportedAt: Date?
    public var analysisCompletedAt: Date?

    /// "pending", "importing", "analyzing", "complete", "failed"
    public var statusRawValue: String

    @Transient
    public var status: EvaluationStatus {
        get { EvaluationStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    // MARK: Aggregate Metrics

    public var totalAttendeeCount: Int = 0
    public var chatParticipantCount: Int = 0
    public var feedbackResponseCount: Int = 0
    public var averageOverallRating: Double?
    public var conversionRate: Double?

    // MARK: Chat Analysis (stored as JSON arrays)

    /// Per-participant engagement analysis from chat transcript.
    public var participantAnalyses: [ChatParticipantAnalysis] = []

    /// Top questions extracted from chat, ranked by significance.
    public var topQuestions: [String] = []

    // MARK: Feedback Data

    /// Parsed feedback form responses.
    public var feedbackResponses: [FeedbackResponse] = []

    /// Column mapping used for this event's feedback CSV import.
    public var feedbackColumnMappingData: Data?

    // MARK: AI-Generated Summaries

    /// LLM-generated content gap analysis (what topics generated confusion/questions).
    public var contentGapSummary: String?

    /// LLM-generated analysis of what sections worked well.
    public var effectiveSectionsSummary: String?

    /// LLM-generated overall event summary and recommendations.
    public var overallSummary: String?

    // MARK: Timestamps

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: Init

    public init(
        id: UUID = UUID(),
        event: SamEvent? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.event = event
        self.statusRawValue = EvaluationStatus.pending.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - ChatParticipantAnalysis

/// Per-participant analysis from a chat transcript import.
public struct ChatParticipantAnalysis: Codable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var matchedPersonID: UUID?
    public var isNewPerson: Bool
    public var needsReview: Bool

    // Chat metrics
    public var messageCount: Int
    public var reactionCount: Int

    // LLM-derived analysis
    public var engagementLevelRawValue: String
    public var questionsAsked: [String]
    public var topicInterests: [String]
    public var sentimentRawValue: String
    public var conversionSignals: [String]
    public var inferredRoleRawValue: String

    public var engagementLevel: EngagementLevel {
        EngagementLevel(rawValue: engagementLevelRawValue) ?? .observer
    }

    public var inferredRole: InferredEventRole {
        InferredEventRole(rawValue: inferredRoleRawValue) ?? .attendee
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        matchedPersonID: UUID? = nil,
        isNewPerson: Bool = false,
        needsReview: Bool = false,
        messageCount: Int = 0,
        reactionCount: Int = 0,
        engagementLevel: EngagementLevel = .observer,
        questionsAsked: [String] = [],
        topicInterests: [String] = [],
        sentiment: String = "neutral",
        conversionSignals: [String] = [],
        inferredRole: InferredEventRole = .attendee
    ) {
        self.id = id
        self.displayName = displayName
        self.matchedPersonID = matchedPersonID
        self.isNewPerson = isNewPerson
        self.needsReview = needsReview
        self.messageCount = messageCount
        self.reactionCount = reactionCount
        self.engagementLevelRawValue = engagementLevel.rawValue
        self.questionsAsked = questionsAsked
        self.topicInterests = topicInterests
        self.sentimentRawValue = sentiment
        self.conversionSignals = conversionSignals
        self.inferredRoleRawValue = inferredRole.rawValue
    }
}

// MARK: - FeedbackResponse

/// A single feedback form response from a workshop participant.
public struct FeedbackResponse: Codable, Sendable, Identifiable {
    public var id: UUID
    public var respondentName: String?
    public var respondentEmail: String?
    public var respondentPhone: String?
    public var matchedPersonID: UUID?

    // Form responses
    public var mostHelpful: String?
    public var areasToStrengthen: [String]
    public var deeperUnderstanding: String?
    public var overallRatingRawValue: String?
    public var wouldContinueRawValue: String?
    public var currentSituation: String?
    public var otherTopics: String?

    public var overallRating: FeedbackRating? {
        overallRatingRawValue.flatMap { FeedbackRating(rawValue: $0) }
    }

    public var wouldContinue: FollowUpInterest? {
        wouldContinueRawValue.flatMap { FollowUpInterest(rawValue: $0) }
    }

    public init(
        id: UUID = UUID(),
        respondentName: String? = nil,
        respondentEmail: String? = nil,
        respondentPhone: String? = nil,
        matchedPersonID: UUID? = nil,
        mostHelpful: String? = nil,
        areasToStrengthen: [String] = [],
        deeperUnderstanding: String? = nil,
        overallRating: FeedbackRating? = nil,
        wouldContinue: FollowUpInterest? = nil,
        currentSituation: String? = nil,
        otherTopics: String? = nil
    ) {
        self.id = id
        self.respondentName = respondentName
        self.respondentEmail = respondentEmail
        self.respondentPhone = respondentPhone
        self.matchedPersonID = matchedPersonID
        self.mostHelpful = mostHelpful
        self.areasToStrengthen = areasToStrengthen
        self.deeperUnderstanding = deeperUnderstanding
        self.overallRatingRawValue = overallRating?.rawValue
        self.wouldContinueRawValue = wouldContinue?.rawValue
        self.currentSituation = currentSituation
        self.otherTopics = otherTopics
    }
}

// MARK: - FeedbackColumnMapping

/// Maps CSV column headers to known feedback form fields.
/// Saved per-presentation so the same mapping can be reused across events.
public struct FeedbackColumnMapping: Codable, Sendable {
    public var nameColumn: String?
    public var emailColumn: String?
    public var phoneColumn: String?
    public var mostHelpfulColumn: String?
    public var areasToStrengthenColumn: String?
    public var deeperUnderstandingColumn: String?
    public var overallRatingColumn: String?
    public var wouldContinueColumn: String?
    public var currentSituationColumn: String?
    public var otherTopicsColumn: String?

    public init() {}
}

// MARK: - Enums

public enum EvaluationStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case importing
    case analyzing
    case complete
    case failed

    public var displayName: String {
        switch self {
        case .pending:   return "Pending"
        case .importing: return "Importing"
        case .analyzing: return "Analyzing"
        case .complete:  return "Complete"
        case .failed:    return "Failed"
        }
    }

    public var icon: String {
        switch self {
        case .pending:   return "clock"
        case .importing: return "arrow.down.doc"
        case .analyzing: return "brain"
        case .complete:  return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle"
        }
    }
}

public enum EngagementLevel: String, Codable, Sendable, CaseIterable {
    case high
    case medium
    case low
    case observer

    public var displayName: String {
        switch self {
        case .high:     return "High"
        case .medium:   return "Medium"
        case .low:      return "Low"
        case .observer: return "Observer"
        }
    }

    public var color: String {
        switch self {
        case .high:     return "green"
        case .medium:   return "blue"
        case .low:      return "orange"
        case .observer: return "gray"
        }
    }
}

public enum InferredEventRole: String, Codable, Sendable, CaseIterable {
    case host
    case cohost
    case attendee

    public var displayName: String {
        switch self {
        case .host:     return "Host"
        case .cohost:   return "Co-host"
        case .attendee: return "Attendee"
        }
    }
}

public enum FeedbackRating: String, Codable, Sendable, CaseIterable {
    case extremelyValuable = "extremely_valuable"
    case helpful = "helpful"
    case neutral = "neutral"
    case notHelpful = "not_helpful"

    public var displayName: String {
        switch self {
        case .extremelyValuable: return "Extremely Valuable"
        case .helpful:           return "Helpful"
        case .neutral:           return "Neutral"
        case .notHelpful:        return "Not Helpful"
        }
    }

    /// Numeric score for averaging (4=best, 1=worst).
    public var numericScore: Double {
        switch self {
        case .extremelyValuable: return 4.0
        case .helpful:           return 3.0
        case .neutral:           return 2.0
        case .notHelpful:        return 1.0
        }
    }
}

public enum FollowUpInterest: String, Codable, Sendable, CaseIterable {
    case yes = "yes"
    case maybe = "maybe"
    case notNow = "not_now"

    public var displayName: String {
        switch self {
        case .yes:    return "Yes — Schedule"
        case .maybe:  return "Maybe — More Info"
        case .notNow: return "Not Right Now"
        }
    }

    public var isWarmLead: Bool {
        self == .yes
    }
}
