// LinkedInProfileAnalystService.swift
// SAM
//
// Phase 7: LinkedIn Profile Analysis Agent (Spec §10)
//
// Actor-isolated specialist that analyzes a user's LinkedIn profile,
// endorsements, recommendations, content activity, and network health.
// Returns constructive, encouraging feedback — praise first, then improvements.
//
// Follows the 9-step specialist pattern (see PipelineAnalystService for reference).
// Platform-specific siblings: FacebookProfileAnalystService, SubstackProfileAnalystService.

import Foundation
import os.log

actor LinkedInProfileAnalystService {

    // MARK: - Singleton

    static let shared = LinkedInProfileAnalystService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LinkedInProfileAnalystService")

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
            LinkedIn profile advisor for \(persona). Encouraging tone: praise first, then improvements. \
            Cite actual data (counts, snippets). No generic advice.
            \(businessContext)
            \(followUpClause)
            Respond with ONLY raw JSON (no markdown, no explanation).
            {"overall_score":1-100,"praise":[{"category":"...","message":"1-2 sentences","metric":"..."}],\
            "improvements":[{"category":"...","priority":"high|medium|low","suggestion":"...","rationale":"2-3 sentences",\
            "example_or_prompt":"ready-to-paste LinkedIn text"}],\
            "content_strategy":{"summary":"...","posting_frequency":"...","content_mix":"...","engagement_assessment":"...","topic_suggestions":["..."]},\
            "network_health":{"summary":"...","growth_trend":"...","endorsement_insight":"...","recommendation_reciprocity":"..."},\
            "changes_since_last":[{"description":"...","is_improvement":true}],\
            "external_prompt":{"context":"...","prompt":"ready-to-paste prompt for another AI","copy_button_label":"Copy Content Strategy Prompt"}}
            Dimensions: 1) PRAISE: 2-4 specific strengths with metrics. \
            2) IMPROVEMENTS: high-impact changes; example_or_prompt = complete paste-ready text, not instructions. \
            3) CONTENT STRATEGY: publishing activity, 2-3 topic suggestions. \
            4) NETWORK HEALTH: connections, growth, endorsements, recommendation reciprocity. \
            5) EXTERNAL PROMPT: prompt for deeper AI strategy help. \
            changes_since_last: omit if no prior analysis. Be specific to this person's data, not generic.
            """

        // Step 4: Build user prompt — truncate data to fit context window
        let budget = await AIService.shared.contextBudgetChars()
        let maxDataChars = max(2000, budget - instructions.count)
        let truncatedData = data.count > maxDataChars ? String(data.prefix(maxDataChars)) + "\n[... truncated for context limit]" : data

        let prompt = """
            Analyze this LinkedIn profile for \(persona):

            \(truncatedData)
            """

        // Step 5: Log prompt sizes
        let systemSize = instructions.count
        let promptSize = prompt.count
        logger.info("LinkedInProfileAnalyst prompt — system: \(systemSize)ch (~\(systemSize/4)t), user: \(promptSize)ch (~\(promptSize/4)t), total: \((systemSize+promptSize)/4)t")

        // Step 6: Generate
        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        logger.info("LinkedInProfileAnalyst response — \(responseText.count)ch (~\(responseText.count/4)t)")

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
                logger.info("LinkedInProfileAnalyst returned plain text, wrapping as summary")
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
            logger.error("LinkedInProfileAnalyst JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
}
