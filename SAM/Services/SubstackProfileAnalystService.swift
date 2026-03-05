//
//  SubstackProfileAnalystService.swift
//  SAM
//
//  Specialist analyst for Substack publication profile analysis.
//  Produces a ProfileAnalysisDTO with platform "substack" assessing
//  publication quality, content strategy, posting cadence, and audience reach.
//

import Foundation
import os.log

actor SubstackProfileAnalystService {

    // MARK: - Singleton

    static let shared = SubstackProfileAnalystService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SubstackProfileAnalystService")

    private init() {}

    // MARK: - Analysis

    /// Analyzes the user's Substack publication and returns structured feedback.
    func analyze(data: String, previousAnalysisJSON: String?) async throws -> ProfileAnalysisDTO {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let businessContext = await BusinessProfileService.shared.fullContextBlock()

        let followUpClause: String
        if let prevJSON = previousAnalysisJSON {
            followUpClause = """

            A previous analysis is provided for comparison:
            \(String(prevJSON.prefix(2000)))

            In your response, populate changes_since_last to note meaningful changes \
            (new articles published, topic shifts, cadence improvements). Acknowledge progress.
            """
        } else {
            followUpClause = ""
        }

        let instructions = """
            You are a Substack publication advisor for an independent financial services professional \
            who uses their newsletter to build thought leadership, nurture client relationships, and \
            attract warm leads. Your tone is encouraging and constructive — always lead with genuine \
            praise before suggesting improvements. Be specific: cite actual article titles, posting \
            frequency, and topic patterns.

            \(businessContext)

            \(followUpClause)

            Analyze the publication across five dimensions:

            1. PRAISE — What is genuinely strong about this publication? Lead with 2–4 specific \
            strengths. Reference actual article titles and topics.

            2. PUBLICATION IMPROVEMENTS — What changes would improve subscriber growth, engagement, \
            and content quality? Prioritize high-impact items. For EVERY improvement, provide \
            ready-to-use text in example_or_prompt — an actual article title, subtitle, or \
            opening paragraph the user can use directly.

            3. CONTENT STRATEGY — Assess topic coverage, posting frequency, and consistency. \
            Identify gaps: topics the user should cover given their expertise and audience. \
            Include 2–3 specific article topic suggestions with working titles.

            4. AUDIENCE & REACH — Comment on the publication's positioning for the financial \
            services audience. Assess whether the content serves existing clients (retention), \
            attracts new leads (growth), or both. Note the subscriber value proposition.

            5. EXTERNAL PROMPT — Compose a prompt the user can paste into ChatGPT, Claude, or \
            another AI for deeper content strategy help. Make it specific to their Substack.

            CRITICAL: respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            JSON schema:
            {
              "overall_score": 72,
              "praise": [
                { "category": "Content Quality", "message": "...", "metric": "12 articles published" }
              ],
              "improvements": [
                {
                  "category": "Posting Cadence",
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
                "copy_button_label": "Copy Substack Strategy Prompt"
              }
            }

            Adaptation notes for Substack context:
            - network_health.summary → use for audience/reach assessment
            - network_health.growth_trend → subscriber growth trajectory
            - network_health.endorsement_insight → reader engagement signals (comments, shares)
            - network_health.recommendation_reciprocity → cross-promotion opportunities

            Rules:
            - overall_score is 1–100 (honest assessment)
            - priority is exactly "high", "medium", or "low"
            - changes_since_last may be omitted if no prior analysis provided
            - Keep each praise message to 1–2 sentences
            - Do NOT give generic newsletter advice — be specific to this person's actual publication
            - If posting cadence is irregular, be honest but encouraging about it
            """

        let prompt = """
            Analyze this Substack publication for a financial services professional:

            \(data)
            """

        let systemSize = instructions.count
        let promptSize = prompt.count
        logger.info("SubstackProfileAnalyst prompt — system: \(systemSize)ch, user: \(promptSize)ch")

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        logger.info("SubstackProfileAnalyst response — \(responseText.count)ch")

        return try parseResponse(responseText)
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> ProfileAnalysisDTO {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)

        do {
            return try parseProfileAnalysisJSON(cleaned, platform: "substack")
        } catch {
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.info("SubstackProfileAnalyst returned plain text, wrapping as summary")
                return ProfileAnalysisDTO(
                    analysisDate: .now,
                    platform: "substack",
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
            logger.error("SubstackProfileAnalyst JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
}
