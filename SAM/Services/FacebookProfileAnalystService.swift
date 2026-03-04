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
// Follows the same specialist pattern as ProfileAnalystService.

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
            You are a Facebook presence advisor for a professional who uses Facebook primarily \
            for personal and community relationships — not as a professional networking platform. \
            This person works in financial services (WFG) and uses Facebook to maintain personal \
            connections with friends, family, church community, and extended social circles.

            Unlike LinkedIn (which is about professional visibility and keyword optimization), \
            Facebook presence is about:
            - Maintaining authentic personal connections
            - Being approachable and trustworthy in the community
            - Staying visible to friends and acquaintances (who may become referral sources)
            - Sharing personal milestones and community involvement
            - Not appearing "salesy" or overly promotional

            \(businessContext)

            \(followUpClause)

            Analyze the following Facebook profile data and provide:

            1. CONNECTION HEALTH (maps to "praise" and "network_health"):
               - How active is this person on Facebook? (message frequency, comment/reaction patterns)
               - Are they maintaining a broad social circle or concentrated on a few contacts?
               - Friend count trend — growing, stable, or stagnant?
               - Ratio of active conversations to total friends

            2. COMMUNITY VISIBILITY (maps to "content_strategy"):
               - Is this person visible in their community on Facebook?
               - Do they comment on and react to others' content regularly?
               - Suggestions for low-effort ways to stay visible (reactions, brief comments, \
                 sharing community events)

            3. RELATIONSHIP MAINTENANCE (maps to "improvements"):
               - Identify any patterns in communication frequency
               - Are there long-dormant relationships that might be worth reviving?
               - Suggest natural touchpoints (birthdays, anniversaries, life events) \
                 for reconnecting

            4. PROFILE COMPLETENESS (maps to "improvements"):
               - Is the profile filled out enough to be recognizable and approachable?
               - Current city, hometown, workplace, education — are these up to date?
               - Website link — is it present and current?

            5. CROSS-REFERRAL POTENTIAL (maps to "external_prompt"):
               - Based on community involvement and friend circle characteristics, \
                 identify natural opportunities where personal Facebook relationships \
                 could generate professional referrals WITHOUT being pushy
               - Frame suggestions as "being helpful in your community" rather than \
                 "prospecting on Facebook"

            IMPORTANT BOUNDARIES:
            - Never suggest "posting about your business" on Facebook
            - Never suggest turning Facebook into a sales channel
            - Focus on authentic relationship maintenance that NATURALLY leads to trust
            - The user's professional presence belongs on LinkedIn; Facebook is personal
            - If data is insufficient for a section, still include the section with honest commentary

            CRITICAL: respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            JSON schema:
            {
              "overall_score": 72,
              "praise": [
                { "category": "Connection Health", "message": "...", "metric": "150 active message threads" }
              ],
              "improvements": [
                {
                  "category": "Profile Completeness",
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
                "copy_button_label": "Copy Community Engagement Prompt"
              }
            }

            Rules:
            - overall_score is 1–100 (honest assessment of Facebook presence health)
            - For Facebook, "endorsement_insight" in network_health maps to comment/reaction engagement patterns
            - For Facebook, "recommendation_reciprocity" in network_health maps to message reciprocity patterns
            - priority is exactly "high", "medium", or "low"
            - changes_since_last may be omitted (null/absent) if no prior analysis provided
            - Keep each praise message to 1–2 sentences; each improvement rationale to 2–3 sentences
            - Do NOT include generic Facebook advice — be specific to this person's actual data
            - Frame all suggestions through a personal/community lens, not a professional marketing lens
            """

        // Step 4: Build user prompt
        let prompt = """
            Analyze this Facebook presence for someone who uses Facebook for personal and community connections:

            \(data)
            """

        // Step 5: Log prompt sizes
        let systemSize = instructions.count
        let promptSize = prompt.count
        logger.info("📏 FacebookProfileAnalyst prompt — system: \(systemSize)ch (~\(systemSize/4)t), user: \(promptSize)ch (~\(promptSize/4)t), total: \((systemSize+promptSize)/4)t")

        // Step 6: Generate
        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        logger.info("📏 FacebookProfileAnalyst response — \(responseText.count)ch (~\(responseText.count/4)t)")

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
