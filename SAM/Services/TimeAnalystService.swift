//
//  TimeAnalystService.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  Actor-isolated specialist that analyzes time allocation data and
//  generates recommendations for better work-life balance.
//

import Foundation
import os.log

actor TimeAnalystService {

    // MARK: - Singleton

    static let shared = TimeAnalystService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TimeAnalystService")

    private init() {}

    // MARK: - Analysis

    func analyze(data: String) async throws -> TimeAnalysis {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let businessContext = await BusinessProfileService.shared.fullContextBlock()

        let instructions = """
            You analyze how an independent financial strategist allocates their work time. \
            Identify imbalances, suggest improvements, and highlight trends. \
            Common categories: Prospecting, Client Meeting, Policy Review, Recruiting, \
            Training/Mentoring, Admin, Deep Work, Personal Development, Travel, Other.

            \(businessContext)

            CRITICAL: You MUST respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            The JSON structure must be:
            {
              "balance_summary": "1-2 sentence assessment of time allocation health",
              "recommendations": [
                {
                  "title": "Short actionable title",
                  "rationale": "Why this matters and what to change",
                  "priority": 0.7,
                  "category": "time",
                  "approaches": [
                    {
                      "title": "Short approach name",
                      "summary": "2-3 sentence description of this approach",
                      "steps": ["Step 1", "Step 2", "Step 3"],
                      "effort": "moderate"
                    }
                  ]
                }
              ],
              "imbalances": ["Specific imbalance description"]
            }

            Rules:
            - balance_summary should reference specific percentages from the data
            - Include 2-3 recommendations maximum
            - priority is 0.0 to 1.0 (1.0 = most urgent)
            - imbalances should be specific observations (e.g., "Only 15% client-facing time")
            - Financial advisors should typically spend 40-60% on client-facing activities
            - If data is sparse, note that and keep recommendations conservative
            - Each recommendation should include 2-3 approaches (alternative ways to implement it)
            - effort is "quick" (< 30 min), "moderate" (1-2 hours), or "substantial" (half-day+)
            """

        let prompt = """
            Analyze this time allocation data for a financial strategist:

            \(data)
            """

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        return try parseResponse(responseText)
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> TimeAnalysis {
        let cleaned = extractJSON(from: jsonString)
        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMTimeAnalysis.self, from: data)
            return TimeAnalysis(
                balanceSummary: llm.balanceSummary ?? "",
                recommendations: (llm.recommendations ?? []).compactMap { rec in
                    guard let title = rec.title, let rationale = rec.rationale else { return nil }
                    return StrategicRec(
                        title: title,
                        rationale: rationale,
                        priority: rec.priority ?? 0.5,
                        category: rec.category ?? "time",
                        approaches: parseApproaches(rec.approaches)
                    )
                },
                imbalances: llm.imbalances ?? []
            )
        } catch {
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.info("Time analysis returned plain text, using as summary")
                return TimeAnalysis(balanceSummary: String(plainText.prefix(500)))
            }
            logger.error("Time analysis JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func parseApproaches(_ llmApproaches: [LLMImplementationApproach]?) -> [ImplementationApproach] {
        (llmApproaches ?? []).compactMap { a in
            guard let title = a.title, let summary = a.summary else { return nil }
            return ImplementationApproach(
                title: title,
                summary: summary,
                steps: a.steps ?? [],
                effort: EffortLevel(rawValue: a.effort ?? "moderate") ?? .moderate
            )
        }
    }
}
