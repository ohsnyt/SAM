//
//  EventTopicDTO.swift
//  SAM
//
//  Created on March 11, 2026.
//  DTOs for pre-computed event/workshop topic suggestions.
//

import Foundation

// MARK: - Event Topic Analysis

/// Container for event topic suggestions from the EventTopicAdvisorService.
nonisolated public struct EventTopicAnalysis: Codable, Sendable {
    public let suggestions: [SuggestedEventTopic]

    public init(suggestions: [SuggestedEventTopic] = []) {
        self.suggestions = suggestions
    }
}

// MARK: - Suggested Event Topic

/// A pre-computed event/workshop topic suggestion grounded in recent interaction data.
nonisolated public struct SuggestedEventTopic: Codable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let rationale: String
    public let suggestedFormat: String          // "inPerson", "virtual", "hybrid"
    public let targetAudience: [String]         // Role badges: "Client", "Lead", "Agent"
    public let relevantPeopleNames: [String]    // Named contacts who'd be interested
    public let seasonalHook: String?

    public init(
        id: UUID = UUID(),
        title: String,
        rationale: String,
        suggestedFormat: String = "virtual",
        targetAudience: [String] = [],
        relevantPeopleNames: [String] = [],
        seasonalHook: String? = nil
    ) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.suggestedFormat = suggestedFormat
        self.targetAudience = targetAudience
        self.relevantPeopleNames = relevantPeopleNames
        self.seasonalHook = seasonalHook
    }

    /// Resolve the format enum. Falls back to virtual.
    public var format: EventFormat {
        EventFormat(rawValue: suggestedFormat) ?? .virtual
    }
}

// MARK: - LLM Response Types (for lenient JSON parsing)

nonisolated struct LLMEventTopicAnalysis: Codable, Sendable {
    let suggestions: [LLMSuggestedEventTopic]?

    enum CodingKeys: String, CodingKey {
        case suggestions
    }
}

nonisolated struct LLMSuggestedEventTopic: Codable, Sendable {
    let title: String?
    let rationale: String?
    let suggestedFormat: String?
    let targetAudience: [String]?
    let relevantPeopleNames: [String]?
    let seasonalHook: String?

    enum CodingKeys: String, CodingKey {
        case title
        case rationale
        case suggestedFormat = "suggested_format"
        case targetAudience = "target_audience"
        case relevantPeopleNames = "relevant_people_names"
        case seasonalHook = "seasonal_hook"
    }
}
