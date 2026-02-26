//
//  PatternDetectorService.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  Actor-isolated specialist that identifies behavioral patterns and
//  correlations in business relationship data.
//

import Foundation
import os.log

actor PatternDetectorService {

    // MARK: - Singleton

    static let shared = PatternDetectorService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PatternDetectorService")

    private init() {}

    // MARK: - Analysis

    func analyze(data: String) async throws -> PatternAnalysis {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let instructions = """
            You identify behavioral patterns and correlations in business relationship data \
            for an independent financial strategist (World Financial Group). \
            Look for patterns in engagement, referral networks, meeting quality, and role transitions.

            CRITICAL: You MUST respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            The JSON structure must be:
            {
              "patterns": [
                {
                  "description": "Clear description of the pattern observed",
                  "confidence": "high",
                  "data_points": 5
                }
              ],
              "recommendations": [
                {
                  "title": "Short actionable title",
                  "rationale": "Why this pattern matters and what to do about it",
                  "priority": 0.6,
                  "category": "pattern"
                }
              ]
            }

            Rules:
            - Only report patterns supported by multiple data points
            - confidence is "high" (5+ data points), "medium" (3-4), or "low" (2)
            - Include 2-3 patterns maximum, most significant first
            - Include 1-2 recommendations based on patterns found
            - priority is 0.0 to 1.0 (1.0 = most actionable)
            - Do not fabricate patterns — if data is sparse, report fewer patterns
            """

        let prompt = """
            Identify patterns in this business relationship data:

            \(data)
            """

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        return try parseResponse(responseText)
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> PatternAnalysis {
        let cleaned = extractJSON(from: jsonString)
        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMPatternAnalysis.self, from: data)
            return PatternAnalysis(
                patterns: (llm.patterns ?? []).compactMap { p in
                    guard let desc = p.description else { return nil }
                    return DiscoveredPattern(
                        description: desc,
                        confidence: p.confidence ?? "medium",
                        dataPoints: p.dataPoints ?? 0
                    )
                },
                recommendations: (llm.recommendations ?? []).compactMap { rec in
                    guard let title = rec.title, let rationale = rec.rationale else { return nil }
                    return StrategicRec(
                        title: title,
                        rationale: rationale,
                        priority: rec.priority ?? 0.5,
                        category: rec.category ?? "pattern"
                    )
                }
            )
        } catch {
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.info("Pattern analysis returned plain text, treating as single pattern")
                return PatternAnalysis(
                    patterns: [DiscoveredPattern(description: String(plainText.prefix(500)))]
                )
            }
            logger.error("Pattern analysis JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
}
