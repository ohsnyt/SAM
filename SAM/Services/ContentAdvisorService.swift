//
//  ContentAdvisorService.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  Actor-isolated specialist that suggests educational content topics
//  for a WFG financial strategist based on recent interactions and seasonal context.
//

import Foundation
import os.log

actor ContentAdvisorService {

    // MARK: - Singleton

    static let shared = ContentAdvisorService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContentAdvisorService")

    private init() {}

    // MARK: - Analysis

    func analyze(data: String) async throws -> ContentAnalysis {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let instructions = """
            You suggest educational content topics for a WFG (World Financial Group) financial strategist. \
            Topics should be relevant to their client base, timely for the season, and compliant with \
            financial services regulations. Content is for social media posts, newsletters, or client education.

            CRITICAL: You MUST respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            The JSON structure must be:
            {
              "topic_suggestions": [
                {
                  "topic": "Clear topic title",
                  "key_points": ["Point 1", "Point 2", "Point 3"],
                  "suggested_tone": "educational",
                  "compliance_notes": "Any regulatory considerations or null"
                }
              ]
            }

            Rules:
            - Suggest 3-5 topics, most relevant first
            - suggested_tone options: "educational", "motivational", "seasonal", "technical"
            - Include compliance_notes for topics touching investments, insurance, or guarantees
            - Topics should connect to recent client conversations when possible
            - Seasonal context matters (tax season, open enrollment, year-end planning, etc.)
            - Never suggest specific product recommendations or guarantees
            """

        let prompt = """
            Suggest educational content topics based on this context:

            \(data)
            """

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        return try parseResponse(responseText)
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> ContentAnalysis {
        let cleaned = extractJSON(from: jsonString)
        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMContentAnalysis.self, from: data)
            return ContentAnalysis(
                topicSuggestions: (llm.topicSuggestions ?? []).compactMap { t in
                    guard let topic = t.topic else { return nil }
                    return ContentTopic(
                        topic: topic,
                        keyPoints: t.keyPoints ?? [],
                        suggestedTone: t.suggestedTone ?? "educational",
                        complianceNotes: t.complianceNotes
                    )
                }
            )
        } catch {
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.info("Content analysis returned plain text, using as single topic")
                return ContentAnalysis(
                    topicSuggestions: [ContentTopic(topic: String(plainText.prefix(200)))]
                )
            }
            logger.error("Content analysis JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
}
