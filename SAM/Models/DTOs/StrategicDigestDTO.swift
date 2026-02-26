//
//  StrategicDigestDTO.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  Sendable DTOs for specialist analyst outputs and synthesis.
//  Cross actor boundaries from specialist services -> StrategicCoordinator.
//

import Foundation

// MARK: - Pipeline Analysis

nonisolated public struct PipelineAnalysis: Codable, Sendable {
    /// 1-2 sentence health assessment
    public let healthSummary: String
    /// 2-3 actionable recommendations
    public let recommendations: [StrategicRec]
    /// Urgent issues requiring attention
    public let riskAlerts: [String]

    public init(
        healthSummary: String = "",
        recommendations: [StrategicRec] = [],
        riskAlerts: [String] = []
    ) {
        self.healthSummary = healthSummary
        self.recommendations = recommendations
        self.riskAlerts = riskAlerts
    }
}

// MARK: - Time Analysis

nonisolated public struct TimeAnalysis: Codable, Sendable {
    /// Overall time balance assessment
    public let balanceSummary: String
    /// Recommendations for better allocation
    public let recommendations: [StrategicRec]
    /// Specific imbalances detected
    public let imbalances: [String]

    public init(
        balanceSummary: String = "",
        recommendations: [StrategicRec] = [],
        imbalances: [String] = []
    ) {
        self.balanceSummary = balanceSummary
        self.recommendations = recommendations
        self.imbalances = imbalances
    }
}

// MARK: - Pattern Analysis

nonisolated public struct PatternAnalysis: Codable, Sendable {
    /// Correlations and patterns found
    public let patterns: [DiscoveredPattern]
    /// Recommendations based on patterns
    public let recommendations: [StrategicRec]

    public init(
        patterns: [DiscoveredPattern] = [],
        recommendations: [StrategicRec] = []
    ) {
        self.patterns = patterns
        self.recommendations = recommendations
    }
}

// MARK: - Content Analysis

nonisolated public struct ContentAnalysis: Codable, Sendable {
    /// 3-5 educational content topic ideas
    public let topicSuggestions: [ContentTopic]

    public init(topicSuggestions: [ContentTopic] = []) {
        self.topicSuggestions = topicSuggestions
    }
}

// MARK: - Strategic Recommendation

nonisolated public struct StrategicRec: Codable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let rationale: String
    public let priority: Double
    public let category: String
    public var feedback: RecommendationFeedback?

    public init(
        id: UUID = UUID(),
        title: String,
        rationale: String,
        priority: Double = 0.5,
        category: String,
        feedback: RecommendationFeedback? = nil
    ) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.priority = priority
        self.category = category
        self.feedback = feedback
    }
}

// MARK: - Recommendation Feedback

public enum RecommendationFeedback: String, Codable, Sendable {
    case actedOn
    case dismissed
    case ignored
}

// MARK: - Discovered Pattern

nonisolated public struct DiscoveredPattern: Codable, Sendable {
    public let description: String
    public let confidence: String
    public let dataPoints: Int

    public init(
        description: String,
        confidence: String = "medium",
        dataPoints: Int = 0
    ) {
        self.description = description
        self.confidence = confidence
        self.dataPoints = dataPoints
    }
}

// MARK: - Content Topic

nonisolated public struct ContentTopic: Codable, Sendable, Identifiable {
    public let id: UUID
    public let topic: String
    public let keyPoints: [String]
    public let suggestedTone: String
    public let complianceNotes: String?

    public init(
        id: UUID = UUID(),
        topic: String,
        keyPoints: [String] = [],
        suggestedTone: String = "educational",
        complianceNotes: String? = nil
    ) {
        self.id = id
        self.topic = topic
        self.keyPoints = keyPoints
        self.suggestedTone = suggestedTone
        self.complianceNotes = complianceNotes
    }
}

// MARK: - Internal LLM Response Types (for JSON parsing)

nonisolated struct LLMPipelineAnalysis: Codable, Sendable {
    let healthSummary: String?
    let recommendations: [LLMStrategicRec]?
    let riskAlerts: [String]?

    enum CodingKeys: String, CodingKey {
        case healthSummary = "health_summary"
        case recommendations
        case riskAlerts = "risk_alerts"
    }
}

nonisolated struct LLMTimeAnalysis: Codable, Sendable {
    let balanceSummary: String?
    let recommendations: [LLMStrategicRec]?
    let imbalances: [String]?

    enum CodingKeys: String, CodingKey {
        case balanceSummary = "balance_summary"
        case recommendations
        case imbalances
    }
}

nonisolated struct LLMPatternAnalysis: Codable, Sendable {
    let patterns: [LLMDiscoveredPattern]?
    let recommendations: [LLMStrategicRec]?
}

nonisolated struct LLMContentAnalysis: Codable, Sendable {
    let topicSuggestions: [LLMContentTopic]?

    enum CodingKeys: String, CodingKey {
        case topicSuggestions = "topic_suggestions"
    }
}

nonisolated struct LLMStrategicRec: Codable, Sendable {
    let title: String?
    let rationale: String?
    let priority: Double?
    let category: String?
}

nonisolated struct LLMDiscoveredPattern: Codable, Sendable {
    let description: String?
    let confidence: String?
    let dataPoints: Int?

    enum CodingKeys: String, CodingKey {
        case description
        case confidence
        case dataPoints = "data_points"
    }
}

nonisolated struct LLMContentTopic: Codable, Sendable {
    let topic: String?
    let keyPoints: [String]?
    let suggestedTone: String?
    let complianceNotes: String?

    enum CodingKeys: String, CodingKey {
        case topic
        case keyPoints = "key_points"
        case suggestedTone = "suggested_tone"
        case complianceNotes = "compliance_notes"
    }
}
