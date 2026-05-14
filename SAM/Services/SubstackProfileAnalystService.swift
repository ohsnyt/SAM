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

        let businessContext = await BusinessProfileService.shared.compactContextBlock()

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
            Substack publication advisor for \(persona). \
            Encouraging tone: praise first. Cite actual article titles and posting patterns. No generic advice.
            \(businessContext)
            \(followUpClause)
            Respond with ONLY raw JSON (no markdown, no explanation).
            {"overall_score":1-100,"praise":[{"category":"...","message":"1-2 sentences","metric":"..."}],\
            "improvements":[{"category":"...","priority":"high|medium|low","suggestion":"...","rationale":"2-3 sentences",\
            "example_or_prompt":"ready-to-use article title, subtitle, or opening paragraph"}],\
            "content_strategy":{"summary":"...","posting_frequency":"...","content_mix":"...","engagement_assessment":"...","topic_suggestions":["..."]},\
            "network_health":{"summary":"audience/reach","growth_trend":"subscriber trajectory","endorsement_insight":"reader engagement","recommendation_reciprocity":"cross-promotion"},\
            "changes_since_last":[{"description":"...","is_improvement":true}],\
            "external_prompt":{"context":"...","prompt":"...","copy_button_label":"Copy Substack Strategy Prompt"}}
            Dimensions: 1) PRAISE: 2-4 strengths referencing actual articles. \
            2) IMPROVEMENTS: high-impact changes; example_or_prompt = paste-ready text (titles, opening paragraphs). \
            3) CONTENT STRATEGY: topic coverage, frequency, gaps, 2-3 specific article topic suggestions. \
            4) AUDIENCE & REACH: does content serve retention, growth, or both? \
            5) EXTERNAL PROMPT: AI prompt specific to their Substack. \
            changes_since_last: omit if no prior analysis. Be specific to this publication.
            """

        let budget = await AIService.shared.contextBudgetChars()
        let maxDataChars = max(2000, budget - instructions.count)
        let truncatedData = data.count > maxDataChars ? String(data.prefix(maxDataChars)) + "\n[... truncated for context limit]" : data

        let prompt = """
            Analyze this Substack publication for \(persona):

            \(truncatedData)
            """

        let systemSize = instructions.count
        let promptSize = prompt.count
        logger.debug("SubstackProfileAnalyst prompt — system: \(systemSize)ch, user: \(promptSize)ch")

        let responseText = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: instructions,
            task: InferenceTask(label: "Substack profile", icon: "newspaper", source: "SubstackProfileAnalystService")
        )
        logger.debug("SubstackProfileAnalyst response — \(responseText.count)ch")

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
                logger.debug("SubstackProfileAnalyst returned plain text, wrapping as summary")
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
