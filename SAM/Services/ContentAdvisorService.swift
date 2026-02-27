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

        let businessContext = await BusinessProfileService.shared.fullContextBlock()

        let instructions = """
            You suggest educational content topics for an independent financial strategist. \
            Topics should be relevant to their client base, timely for the season, and compliant with \
            financial services regulations. Content is for social media posts, newsletters, or client education.

            \(businessContext)

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

    // MARK: - Draft Generation (Phase W)

    /// Generate a platform-aware social media draft from a topic.
    func generateDraft(
        topic: String,
        keyPoints: [String],
        platform: ContentPlatform,
        tone: String,
        complianceNotes: String?
    ) async throws -> ContentDraft {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let platformGuidelines: String
        switch platform {
        case .linkedin:
            platformGuidelines = """
                Platform: LinkedIn
                - Professional, educational tone
                - 150-250 words
                - Open with a hook question or bold statement
                - Include 1-3 relevant hashtags at the end
                - End with a call-to-action or thought-provoking question
                """
        case .facebook:
            platformGuidelines = """
                Platform: Facebook
                - Conversational, relatable tone
                - 100-150 words
                - Make it personal — share a lesson or observation
                - End with an engagement question
                - No hashtags (or 1-2 at most)
                """
        case .instagram:
            platformGuidelines = """
                Platform: Instagram
                - Brief, hook-focused
                - 50-100 words for caption
                - Start with a strong hook line
                - Include 5-10 relevant hashtags
                - Use line breaks for readability
                """
        case .other:
            platformGuidelines = """
                Platform: General
                - Clear, educational tone
                - 100-200 words
                - Focus on providing value
                """
        }

        let complianceSection = complianceNotes.map { "Compliance considerations: \($0)" } ?? ""
        let keyPointsText = keyPoints.isEmpty ? "" : "Key points to cover: \(keyPoints.joined(separator: "; "))"
        let businessContext = await BusinessProfileService.shared.contextFragment()

        let instructions = """
            You write social media posts for an independent financial strategist. \
            The content must be educational and compliant with financial services regulations.

            \(businessContext)

            STRICT COMPLIANCE RULES:
            - NEVER mention specific product names, company names, or fund names
            - NEVER promise returns, guarantees, or specific financial outcomes
            - NEVER make comparative claims against competitors
            - NEVER give specific financial advice (e.g., "You should invest in X")
            - Always use educational framing: "Consider...", "Many people find...", "A common strategy is..."
            - If the topic is sensitive, add a disclaimer

            \(platformGuidelines)

            Tone: \(tone)
            \(keyPointsText)
            \(complianceSection)

            CRITICAL: Respond with ONLY valid JSON (no markdown code blocks):
            {
              "draft_text": "The full post text ready to copy-paste",
              "compliance_flags": ["Any compliance concerns about this specific post"]
            }

            If there are no compliance concerns, return an empty array for compliance_flags.
            """

        let prompt = "Write a social media post about: \(topic)"
        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        return try parseDraftResponse(responseText)
    }

    private func parseDraftResponse(_ jsonString: String) throws -> ContentDraft {
        let cleaned = extractJSON(from: jsonString)
        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMContentDraft.self, from: data)
            return ContentDraft(
                draftText: llm.draftText ?? "",
                complianceFlags: llm.complianceFlags ?? []
            )
        } catch {
            // If JSON parsing fails, treat the entire response as the draft text
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                logger.info("Draft generation returned plain text, using as draft body")
                return ContentDraft(draftText: String(plainText.prefix(2000)))
            }
            logger.error("Draft generation JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
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
