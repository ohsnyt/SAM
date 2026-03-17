// ProfileAnalysisDTO.swift
// SAM
//
// Public Sendable DTOs for LinkedIn profile analysis results,
// private LLM Codable types, and the ProfileAnalysisSnapshot
// used to cache import-time data for on-demand re-analysis.
//
// Storage: JSON in UserDefaults via BusinessProfileService
// (sam.profileAnalysis / sam.profileAnalysisSnapshot)
// No new SwiftData model. No schema bump.

import Foundation

// MARK: - Public DTOs

/// Top-level result of a LinkedIn profile analysis.
nonisolated public struct ProfileAnalysisDTO: Codable, Sendable {
    public var analysisDate: Date
    public var platform: String                             // "linkedIn"
    public var overallScore: Int                            // 1–100
    public var praise: [PraiseItemDTO]
    public var improvements: [ImprovementSuggestionDTO]
    public var contentStrategy: ContentStrategyAssessmentDTO?
    public var networkHealth: NetworkHealthAssessmentDTO
    public var changesSinceLastAnalysis: [ChangeNoteDTO]?
    public var externalPrompt: ExternalAIPromptDTO?
}

/// A genuine strength identified in the profile.
nonisolated public struct PraiseItemDTO: Codable, Sendable, Identifiable {
    public var id: UUID
    public var category: String                             // "Recommendations", "Content", etc.
    public var message: String
    public var metric: String?                              // e.g. "15 recommendations received"

    public init(id: UUID = UUID(), category: String, message: String, metric: String? = nil) {
        self.id = id
        self.category = category
        self.message = message
        self.metric = metric
    }
}

/// A concrete improvement suggestion with priority and rationale.
nonisolated public struct ImprovementSuggestionDTO: Codable, Sendable, Identifiable {
    public var id: UUID
    public var category: String
    public var priority: String                             // "high", "medium", "low"
    public var suggestion: String
    public var rationale: String
    public var exampleOrPrompt: String?

    public init(id: UUID = UUID(), category: String, priority: String,
                suggestion: String, rationale: String, exampleOrPrompt: String? = nil) {
        self.id = id
        self.category = category
        self.priority = priority
        self.suggestion = suggestion
        self.rationale = rationale
        self.exampleOrPrompt = exampleOrPrompt
    }
}

/// Assessment of the user's content publishing activity.
nonisolated public struct ContentStrategyAssessmentDTO: Codable, Sendable {
    public var summary: String
    public var postingFrequency: String?
    public var contentMix: String?
    public var engagementAssessment: String?
    public var topicSuggestions: [String]
}

/// Assessment of the user's LinkedIn network health.
nonisolated public struct NetworkHealthAssessmentDTO: Codable, Sendable {
    public var summary: String
    public var growthTrend: String?
    public var endorsementInsight: String?
    public var recommendationReciprocity: String?
}

/// A note comparing this analysis to a previous one.
nonisolated public struct ChangeNoteDTO: Codable, Sendable, Identifiable {
    public var id: UUID
    public var description: String
    public var isImprovement: Bool

    public init(id: UUID = UUID(), description: String, isImprovement: Bool) {
        self.id = id
        self.description = description
        self.isImprovement = isImprovement
    }
}

/// A pre-composed prompt the user can paste into an external AI for deeper help.
nonisolated public struct ExternalAIPromptDTO: Codable, Sendable {
    public var context: String
    public var prompt: String
    public var copyButtonLabel: String
}

// MARK: - ProfileAnalysisSnapshot

/// Lightweight snapshot of import-time endorsement/recommendation/share data.
/// Cached in UserDefaults at import time so re-analysis never requires folder access.
nonisolated public struct ProfileAnalysisSnapshot: Codable, Sendable {
    public var endorsementsReceivedCount: Int
    public var topEndorsedSkills: [String]                  // top 5 by endorsement frequency
    public var uniqueEndorsers: Int
    public var recommendationsReceivedCount: Int
    public var recommendationsGivenCount: Int
    public var recommendationSamples: [String]              // first ~200 chars of up to 3 received
    public var shareCount: Int
    public var recentShareSnippets: [String]                // last 10 share comments, ≤100 chars each
    /// Full-length share snippets (up to 5, 500 chars each) for voice re-analysis.
    public var voiceShareSnippets: [String]?
    public var reactionsGivenCount: Int
    public var commentsGivenCount: Int
    public var connectionCount: Int
    public var connectionsByYear: [String: Int]             // "2024" → count (String keys for Codable)
    public var snapshotDate: Date
}

// MARK: - Private LLM Types

/// All fields Optional; keys match the JSON schema sent to the AI.
nonisolated private struct LLMProfileAnalysis: Codable {
    var overall_score: Int?
    var praise: [LLMPraiseItem]?
    var improvements: [LLMImprovementSuggestion]?
    var content_strategy: LLMContentStrategyAssessment?
    var network_health: LLMNetworkHealthAssessment?
    var changes_since_last: [LLMChangeNote]?
    var external_prompt: LLMExternalAIPrompt?
}

nonisolated private struct LLMPraiseItem: Codable {
    var category: String?
    var message: String?
    var metric: String?
}

nonisolated private struct LLMImprovementSuggestion: Codable {
    var category: String?
    var priority: String?
    var suggestion: String?
    var rationale: String?
    var example_or_prompt: String?
}

nonisolated private struct LLMContentStrategyAssessment: Codable {
    var summary: String?
    var posting_frequency: String?
    var content_mix: String?
    var engagement_assessment: String?
    var topic_suggestions: [String]?
}

nonisolated private struct LLMNetworkHealthAssessment: Codable {
    var summary: String?
    var growth_trend: String?
    var endorsement_insight: String?
    var recommendation_reciprocity: String?
}

nonisolated private struct LLMChangeNote: Codable {
    var description: String?
    var is_improvement: Bool?
}

nonisolated private struct LLMExternalAIPrompt: Codable {
    var context: String?
    var prompt: String?
    var copy_button_label: String?
}

// MARK: - LLM → DTO Mapping

nonisolated extension LLMProfileAnalysis {
    func toDTO(analysisDate: Date = .now, platform: String = "linkedIn") -> ProfileAnalysisDTO {
        let praiseItems = (praise ?? []).compactMap { item -> PraiseItemDTO? in
            guard let message = item.message, !message.isEmpty else { return nil }
            return PraiseItemDTO(
                category: item.category ?? "Profile",
                message: message,
                metric: item.metric
            )
        }

        let improvements = (improvements ?? []).compactMap { item -> ImprovementSuggestionDTO? in
            guard let suggestion = item.suggestion, !suggestion.isEmpty else { return nil }
            return ImprovementSuggestionDTO(
                category: item.category ?? "General",
                priority: item.priority ?? "medium",
                suggestion: suggestion,
                rationale: item.rationale ?? "",
                exampleOrPrompt: item.example_or_prompt
            )
        }

        let contentStrategy = content_strategy.flatMap { cs -> ContentStrategyAssessmentDTO? in
            guard let summary = cs.summary, !summary.isEmpty else { return nil }
            return ContentStrategyAssessmentDTO(
                summary: summary,
                postingFrequency: cs.posting_frequency,
                contentMix: cs.content_mix,
                engagementAssessment: cs.engagement_assessment,
                topicSuggestions: cs.topic_suggestions ?? []
            )
        }

        let networkHealth: NetworkHealthAssessmentDTO = {
            let nh = network_health
            return NetworkHealthAssessmentDTO(
                summary: nh?.summary ?? "No network data available.",
                growthTrend: nh?.growth_trend,
                endorsementInsight: nh?.endorsement_insight,
                recommendationReciprocity: nh?.recommendation_reciprocity
            )
        }()

        let changes = changes_since_last.flatMap { notes -> [ChangeNoteDTO]? in
            let mapped = notes.compactMap { note -> ChangeNoteDTO? in
                guard let desc = note.description, !desc.isEmpty else { return nil }
                return ChangeNoteDTO(description: desc, isImprovement: note.is_improvement ?? true)
            }
            return mapped.isEmpty ? nil : mapped
        }

        let extPrompt = external_prompt.flatMap { ep -> ExternalAIPromptDTO? in
            guard let prompt = ep.prompt, !prompt.isEmpty else { return nil }
            return ExternalAIPromptDTO(
                context: ep.context ?? "",
                prompt: prompt,
                copyButtonLabel: ep.copy_button_label ?? "Copy Prompt"
            )
        }

        return ProfileAnalysisDTO(
            analysisDate: analysisDate,
            platform: platform,
            overallScore: max(1, min(100, overall_score ?? 50)),
            praise: praiseItems,
            improvements: improvements,
            contentStrategy: contentStrategy,
            networkHealth: networkHealth,
            changesSinceLastAnalysis: changes,
            externalPrompt: extPrompt
        )
    }
}

// MARK: - JSON Parsing Entry Point (used by LinkedInProfileAnalystService, FacebookProfileAnalystService, SubstackProfileAnalystService)

/// Parses a JSON string from the LLM into a `ProfileAnalysisDTO`.
/// All fields are optional-tolerant; the mapping never throws on missing keys.
nonisolated func parseProfileAnalysisJSON(_ jsonString: String, platform: String = "linkedIn") throws -> ProfileAnalysisDTO {
    guard let data = jsonString.data(using: .utf8) else {
        throw ProfileAnalysisParseError.invalidUTF8
    }
    let decoder = JSONDecoder()
    let llm = try decoder.decode(LLMProfileAnalysis.self, from: data)
    return llm.toDTO(platform: platform)
}

nonisolated enum ProfileAnalysisParseError: Error {
    case invalidUTF8
    case decodingFailed(String)
}
