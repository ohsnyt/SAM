// ProfileAnalystService.swift
// SAM
//
// Phase 7: LinkedIn Profile Analysis Agent (Spec §10)
//
// Actor-isolated specialist that analyzes a user's LinkedIn profile,
// endorsements, recommendations, content activity, and network health.
// Returns constructive, encouraging feedback — praise first, then improvements.
//
// Follows the 9-step specialist pattern (see PipelineAnalystService for reference).

import Foundation
import os.log

actor ProfileAnalystService {

    // MARK: - Singleton

    static let shared = ProfileAnalystService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ProfileAnalystService")

    private init() {}

    // MARK: - Analysis

    /// Analyzes the user's LinkedIn profile data and returns structured feedback.
    /// - Parameters:
    ///   - data: Pre-assembled text block from `LinkedInImportCoordinator.buildProfileAnalysisInput()`
    ///   - previousAnalysisJSON: JSON-encoded prior `ProfileAnalysisDTO` for follow-up comparisons, or nil
    func analyze(data: String, previousAnalysisJSON: String?) async throws -> ProfileAnalysisDTO {
        // Step 1: Check AI availability
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        // Step 2: Get business context
        let businessContext = await BusinessProfileService.shared.fullContextBlock()

        // Step 3: Build system instructions
        let followUpClause: String
        if let prevJSON = previousAnalysisJSON {
            followUpClause = """

            A previous analysis is provided for comparison:
            \(String(prevJSON.prefix(2000)))

            In your response, populate changes_since_last to note meaningful changes \
            (improvements made, new gaps that appeared). Acknowledge progress and flag \
            any previously identified issues that remain unaddressed.
            """
        } else {
            followUpClause = ""
        }

        let instructions = """
            You are a LinkedIn profile optimization advisor for an independent financial services professional. \
            Your tone is encouraging and constructive — always lead with genuine praise before suggesting improvements. \
            Be specific: cite the user's actual data (endorsement counts, recommendation snippets, posting activity). \
            Do not give generic advice; tailor every suggestion to their actual profile content.

            \(businessContext)

            \(followUpClause)

            Analyze the profile across five dimensions:

            1. PRAISE — What is genuinely strong about this profile? Lead with 2–4 specific strengths. \
            Include a metric where possible (e.g. "15 recommendations received").

            2. PROFILE IMPROVEMENTS — What specific changes would most improve discoverability, \
            credibility, and engagement? Prioritize high-impact items. Provide an example or prompt \
            for each suggestion where helpful.

            3. CONTENT STRATEGY — Assess the user's publishing activity. If they post regularly, \
            evaluate themes and engagement. If they don't post, suggest a starting strategy specific \
            to their audience. Include 2–3 topic suggestions.

            4. NETWORK HEALTH — Comment on connection volume, growth trend, endorsement pattern, \
            and recommendation reciprocity. Identify any gaps.

            5. EXTERNAL PROMPT — Compose a prompt the user can paste into ChatGPT, Claude, or \
            another AI for deeper content strategy help. The context field should summarize their \
            situation; the prompt field should be ready to paste. Make copy_button_label specific, \
            e.g. "Copy Content Strategy Prompt".

            CRITICAL: respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            JSON schema:
            {
              "overall_score": 72,
              "praise": [
                { "category": "Recommendations", "message": "...", "metric": "15 recommendations received" }
              ],
              "improvements": [
                {
                  "category": "Headline",
                  "priority": "high",
                  "suggestion": "...",
                  "rationale": "...",
                  "example_or_prompt": "..."
                }
              ],
              "content_strategy": {
                "summary": "...",
                "posting_frequency": "...",
                "content_mix": "...",
                "engagement_assessment": "...",
                "topic_suggestions": ["...", "..."]
              },
              "network_health": {
                "summary": "...",
                "growth_trend": "...",
                "endorsement_insight": "...",
                "recommendation_reciprocity": "..."
              },
              "changes_since_last": [
                { "description": "...", "is_improvement": true }
              ],
              "external_prompt": {
                "context": "...",
                "prompt": "...",
                "copy_button_label": "Copy Content Strategy Prompt"
              }
            }

            Rules:
            - overall_score is 1–100 (honest assessment — 72 is good, not perfect)
            - priority is exactly "high", "medium", or "low"
            - changes_since_last may be omitted (null/absent) if no prior analysis provided
            - Keep each praise message to 1–2 sentences; each improvement rationale to 2–3 sentences
            - Do NOT include generic LinkedIn advice ("make sure your photo is professional") — be specific to this person's actual data
            - If a section has no meaningful data (e.g. zero posts), still include the section with honest commentary
            """

        // Step 4: Build user prompt
        let prompt = """
            Analyze this LinkedIn profile for a financial services professional:

            \(data)
            """

        // Step 5: Log prompt sizes
        let systemSize = instructions.count
        let promptSize = prompt.count
        logger.info("📏 ProfileAnalyst prompt — system: \(systemSize)ch (~\(systemSize/4)t), user: \(promptSize)ch (~\(promptSize/4)t), total: \((systemSize+promptSize)/4)t")

        // Step 6: Generate
        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        logger.info("📏 ProfileAnalyst response — \(responseText.count)ch (~\(responseText.count/4)t)")

        // Step 7: Parse
        return try parseResponse(responseText)
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> ProfileAnalysisDTO {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)

        do {
            let result = try parseProfileAnalysisJSON(cleaned)
            return result
        } catch {
            // If response is plain text (model unavailable fallback), surface a minimal result
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.info("ProfileAnalyst returned plain text, wrapping as summary")
                return ProfileAnalysisDTO(
                    analysisDate: .now,
                    platform: "linkedIn",
                    overallScore: 50,
                    praise: [],
                    improvements: [],
                    contentStrategy: nil,
                    networkHealth: NetworkHealthAssessmentDTO(
                        summary: String(plainText.prefix(500)),
                        growthTrend: nil,
                        endorsementInsight: nil,
                        recommendationReciprocity: nil
                    ),
                    changesSinceLastAnalysis: nil,
                    externalPrompt: nil
                )
            }
            logger.error("ProfileAnalyst JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
}
