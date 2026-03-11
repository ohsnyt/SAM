//
//  EventTopicAdvisorService.swift
//  SAM
//
//  Created on March 11, 2026.
//  Specialist analyst: suggests event/workshop topics based on recent
//  interaction data, seasonal context, and contact role distribution.
//

import Foundation
import os.log

actor EventTopicAdvisorService {

    // MARK: - Singleton

    static let shared = EventTopicAdvisorService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EventTopicAdvisorService")

    private init() {}

    // MARK: - Analysis

    /// Suggest 3-5 event topics grounded in recent interaction data.
    func analyze(data: String, eventHistory: String) async throws -> EventTopicAnalysis {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let businessContext = await BusinessProfileService.shared.fullContextBlock()

        let customPrompt = await MainActor.run {
            UserDefaults.standard.string(forKey: PromptSite.eventTopics.userDefaultsKey) ?? ""
        }

        let instructions: String
        if !customPrompt.isEmpty {
            instructions = customPrompt + "\n\n" + businessContext
        } else {
            instructions = """
                You suggest workshop and event topics for an independent financial strategist \
                to host for their clients, leads, and professional network. Topics should be \
                educational, compliant with financial services regulations, timely, and grounded \
                in actual recent interactions.

                \(businessContext)

                CRITICAL: You MUST respond with ONLY valid JSON.
                - Do NOT wrap the JSON in markdown code blocks
                - Return ONLY the raw JSON object starting with { and ending with }

                The JSON structure must be:
                {
                  "suggestions": [
                    {
                      "title": "Workshop title (compelling, educational framing)",
                      "rationale": "Why this topic now — reference specific data points",
                      "suggested_format": "virtual or inPerson or hybrid",
                      "target_audience": ["Client", "Lead"],
                      "relevant_people_names": ["John Smith", "Sarah Martinez"],
                      "seasonal_hook": "Tax season relevance" or null
                    }
                  ]
                }

                Rules:
                - Suggest 3-5 topics, most relevant first
                - Every rationale MUST reference specific people or meeting topics from the data
                - Do NOT invent interactions or people — only reference what appears in the data
                - target_audience uses SAM role badges: "Client", "Lead", "Applicant", "Agent", "Vendor"
                - relevant_people_names: name 2-5 specific contacts from the data who would benefit
                - suggested_format: "inPerson" for local community topics, "virtual" for broader reach, \
                  "hybrid" for high-value topics
                - Never suggest specific product recommendations or guarantee outcomes
                - seasonal_hook is optional — only include when genuinely timely
                - Topics should be educational workshops, not sales pitches
                - Avoid repeating topics from recent event history
                """
        }

        let prompt = """
            Suggest workshop/event topics based on this context:

            \(data)

            \(eventHistory)
            """

        let responseText = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: instructions,
            maxTokens: 2048
        )

        return try parseResponse(responseText)
    }

    /// Generate a compelling event description from a title.
    func generateDescription(title: String, rationale: String?, audience: [String], format: EventFormat) async throws -> String {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let audienceStr = audience.isEmpty ? "professionals" : audience.joined(separator: ", ").lowercased() + "s"
        let rationaleContext = rationale.map { "\nContext: \($0)" } ?? ""

        let prompt = """
            Write a compelling 2-3 sentence event description for this workshop:

            Title: \(title)
            Format: \(format.displayName)\(rationaleContext)
            Target audience: \(audienceStr)

            The description should:
            - Make someone want to attend
            - Use educational framing (what they'll learn/gain)
            - Be warm and professional, not salesy
            - Never promise financial returns or specific outcomes
            - Be concise enough for an event listing

            Return ONLY the description text, nothing else.
            """

        return try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: "You write compelling event descriptions for financial education workshops. " +
                "Educational tone, compliant with financial services regulations, warm and inviting.",
            maxTokens: 256
        )
    }

    // MARK: - Response Parsing

    private func parseResponse(_ text: String) throws -> EventTopicAnalysis {
        // Try direct JSON parse
        if let data = text.data(using: .utf8),
           let llm = try? JSONDecoder().decode(LLMEventTopicAnalysis.self, from: data) {
            return mapToAnalysis(llm)
        }

        // Try stripping markdown fencing
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = stripped.data(using: .utf8),
           let llm = try? JSONDecoder().decode(LLMEventTopicAnalysis.self, from: data) {
            return mapToAnalysis(llm)
        }

        logger.warning("Failed to parse event topic response — returning empty")
        return EventTopicAnalysis()
    }

    private func mapToAnalysis(_ llm: LLMEventTopicAnalysis) -> EventTopicAnalysis {
        let topics = (llm.suggestions ?? []).compactMap { raw -> SuggestedEventTopic? in
            guard let title = raw.title, !title.isEmpty else { return nil }
            return SuggestedEventTopic(
                title: title,
                rationale: raw.rationale ?? "",
                suggestedFormat: raw.suggestedFormat ?? "virtual",
                targetAudience: raw.targetAudience ?? [],
                relevantPeopleNames: raw.relevantPeopleNames ?? [],
                seasonalHook: raw.seasonalHook
            )
        }
        return EventTopicAnalysis(suggestions: topics)
    }

    // MARK: - Errors

    enum AnalysisError: Error {
        case modelUnavailable
    }
}
