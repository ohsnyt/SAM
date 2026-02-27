//
//  PipelineAnalystService.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  Actor-isolated specialist that analyzes pipeline health data and
//  generates actionable recommendations for a financial services practice.
//

import Foundation
import os.log

actor PipelineAnalystService {

    // MARK: - Singleton

    static let shared = PipelineAnalystService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PipelineAnalystService")

    private init() {}

    // MARK: - Analysis

    func analyze(data: String) async throws -> PipelineAnalysis {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let instructions = """
            You are a pipeline analyst for an independent financial services practice (World Financial Group). \
            Analyze the pipeline data provided and generate strategic recommendations. \
            Focus on conversion bottlenecks, stuck prospects, production gaps, and recruiting health.

            CRITICAL: You MUST respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            The JSON structure must be:
            {
              "health_summary": "1-2 sentence overall pipeline health assessment",
              "recommendations": [
                {
                  "title": "Short actionable title",
                  "rationale": "Why this matters and what to do",
                  "priority": 0.8,
                  "category": "pipeline",
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
              "risk_alerts": ["Urgent issue description"]
            }

            Rules:
            - health_summary should be specific to the numbers provided, not generic
            - Include 2-3 recommendations maximum, focused on highest impact
            - priority is 0.0 to 1.0 (1.0 = most urgent)
            - risk_alerts only for truly urgent issues (stuck people, zero conversion, etc.)
            - If data is sparse, keep recommendations brief rather than speculating
            - Each recommendation should include 2-3 approaches (alternative ways to implement it)
            - effort is "quick" (< 30 min), "moderate" (1-2 hours), or "substantial" (half-day+)
            """

        let prompt = """
            Analyze this pipeline data for a financial strategist:

            \(data)
            """

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        return try parseResponse(responseText)
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> PipelineAnalysis {
        let cleaned = extractJSON(from: jsonString)
        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMPipelineAnalysis.self, from: data)
            return PipelineAnalysis(
                healthSummary: llm.healthSummary ?? "",
                recommendations: (llm.recommendations ?? []).compactMap { rec in
                    guard let title = rec.title, let rationale = rec.rationale else { return nil }
                    return StrategicRec(
                        title: title,
                        rationale: rationale,
                        priority: rec.priority ?? 0.5,
                        category: rec.category ?? "pipeline",
                        approaches: parseApproaches(rec.approaches)
                    )
                },
                riskAlerts: llm.riskAlerts ?? []
            )
        } catch {
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.info("Pipeline analysis returned plain text, using as summary")
                return PipelineAnalysis(healthSummary: String(plainText.prefix(500)))
            }
            logger.error("Pipeline analysis JSON parsing failed: \(error.localizedDescription)")
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
