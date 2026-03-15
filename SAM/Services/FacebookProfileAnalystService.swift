// FacebookProfileAnalystService.swift
// SAM
//
// Phase FB-3: Facebook Profile Analysis Agent (Spec §8)
//
// Actor-isolated specialist that analyzes a user's Facebook presence,
// friend activity, messenger patterns, and community engagement.
// Returns constructive, personal-tone feedback — praise first, then improvements.
//
// Reuses the same ProfileAnalysisDTO structure as LinkedIn but with
// Facebook-specific analysis categories:
//   1. Connection Health
//   2. Community Visibility
//   3. Relationship Maintenance
//   4. Profile Completeness
//   5. Cross-Referral Potential
//
// Follows the same specialist pattern as LinkedInProfileAnalystService.

import Foundation
import os.log

actor FacebookProfileAnalystService {

    // MARK: - Singleton

    static let shared = FacebookProfileAnalystService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FacebookProfileAnalystService")

    private init() {}

    // MARK: - Analysis

    /// Analyzes the user's Facebook profile data and returns structured feedback.
    /// - Parameters:
    ///   - data: Pre-assembled text block from `FacebookImportCoordinator.buildFacebookAnalysisInput()`
    ///   - previousAnalysisJSON: JSON-encoded prior `ProfileAnalysisDTO` for follow-up comparisons, or nil
    func analyze(data: String, previousAnalysisJSON: String?) async throws -> ProfileAnalysisDTO {
        // Step 1: Check AI availability
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        // Step 2: Get compact business context (no social profile fragments — we already have the data as input)
        let businessContext = await BusinessProfileService.shared.compactContextBlock()

        // Step 3: Build system instructions
        let followUpClause: String
        if let prevJSON = previousAnalysisJSON {
            let budget = await AIService.shared.contextBudgetChars()
            let prevLimit = budget > 20000 ? 2000 : 800
            followUpClause = "\nPrior analysis (populate changes_since_last):\n\(String(prevJSON.prefix(prevLimit)))"
        } else {
            followUpClause = ""
        }

        let persona = await BusinessProfileService.shared.personaFragment()

        let instructions = """
            Facebook presence advisor for \(persona). Facebook is personal/community — NOT a sales channel. \
            Focus: authentic connections, community visibility, relationship maintenance. Never suggest business promotion. \
            Encouraging tone: praise first. Cite actual data. No generic advice.
            \(businessContext)
            \(followUpClause)
            Respond with ONLY raw JSON (no markdown, no explanation).
            {"overall_score":1-100,"praise":[{"category":"...","message":"1-2 sentences","metric":"..."}],\
            "improvements":[{"category":"...","priority":"high|medium|low","suggestion":"...","rationale":"2-3 sentences",\
            "example_or_prompt":"ready-to-paste Facebook text"}],\
            "content_strategy":{"summary":"...","posting_frequency":"...","content_mix":"...","engagement_assessment":"...","topic_suggestions":["..."]},\
            "network_health":{"summary":"...","growth_trend":"...","endorsement_insight":"comment/reaction patterns","recommendation_reciprocity":"message reciprocity"},\
            "changes_since_last":[{"description":"...","is_improvement":true}],\
            "external_prompt":{"context":"...","prompt":"...","copy_button_label":"Copy Community Engagement Prompt"}}
            Analyze: 1) CONNECTION HEALTH: activity level, social circle breadth, friend count trend, active conversation ratio. \
            2) COMMUNITY VISIBILITY: are they visible? Comment/reaction habits? Low-effort suggestions to stay visible. \
            3) RELATIONSHIP MAINTENANCE: communication patterns, dormant relationships, natural touchpoints. \
            4) PROFILE COMPLETENESS: city, hometown, work, education, website — what's missing? example_or_prompt = paste-ready text. \
            5) CROSS-REFERRAL: natural referral opportunities through community helpfulness, not prospecting. \
            changes_since_last: omit if no prior analysis. Be specific to this person's data.
            """

        // Step 4: Build user prompt — truncate data to fit context window
        let budget = await AIService.shared.contextBudgetChars()
        let maxDataChars = max(2000, budget - instructions.count)
        let truncatedData = data.count > maxDataChars ? String(data.prefix(maxDataChars)) + "\n[... truncated for context limit]" : data

        let prompt = """
            Analyze this Facebook presence for someone who uses Facebook for personal and community connections:

            \(truncatedData)
            """

        // Step 5: Log prompt sizes
        let systemSize = instructions.count
        let promptSize = prompt.count
        logger.info("FacebookProfileAnalyst prompt — system: \(systemSize)ch (~\(systemSize/4)t), user: \(promptSize)ch (~\(promptSize/4)t), total: \((systemSize+promptSize)/4)t")

        // Step 6: Generate
        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        logger.info("FacebookProfileAnalyst response — \(responseText.count)ch (~\(responseText.count/4)t)")

        // Step 7: Parse
        return try parseResponse(responseText)
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> ProfileAnalysisDTO {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)

        do {
            let result = try parseProfileAnalysisJSON(cleaned, platform: "facebook")
            return result
        } catch {
            // If response is plain text (model unavailable fallback), surface a minimal result
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.info("FacebookProfileAnalyst returned plain text, wrapping as summary")
                return ProfileAnalysisDTO(
                    analysisDate: .now,
                    platform: "facebook",
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
            logger.error("FacebookProfileAnalyst JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
}
