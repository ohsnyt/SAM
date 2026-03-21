//
//  ContentTopicModelComparison.swift
//  SAM
//
//  Created on March 20, 2026.
//  Debug utility: compares content topic suggestion quality across AI backends.
//
//  Runs the same prompt + data through FoundationModels and MLX (Qwen),
//  logs timing and output for side-by-side comparison.
//  Access via SAM menu > Debug > Compare Content Topic Models.
//

import Foundation
import os.log

actor ContentTopicModelComparison {

    static let shared = ContentTopicModelComparison()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TopicModelComparison")

    private init() {}

    // MARK: - Types

    struct ComparisonResult: Sendable {
        let backend: String
        let durationSeconds: Double
        let rawOutput: String
        let topicCount: Int
        let topics: [TopicSummary]
        let error: String?
    }

    struct TopicSummary: Sendable {
        let topic: String
        let keyPoints: [String]
        let tone: String
    }

    // MARK: - Run Comparison

    /// Run the content topic prompt through both backends and return results.
    /// Uses the user's actual live data from StrategicCoordinator.gatherContentData().
    func runComparison(inputData: String? = nil) async -> [ComparisonResult] {
        let data = inputData ?? sampleData()
        let prompt = "Suggest educational content topics based on this context:\n\n\(data)"
        let systemInstruction = buildSystemInstruction()

        logger.info("=== Content Topic Model Comparison ===")
        logger.info("Input data: \(data.count) chars (~\(data.count / 4) tokens)")

        var results: [ComparisonResult] = []

        // Run FoundationModels
        let fmResult = await runWithBackend(
            name: "FoundationModels",
            prompt: prompt,
            systemInstruction: systemInstruction,
            useMLX: false
        )
        results.append(fmResult)

        // Run MLX (Qwen)
        let mlxReady = await MLXModelManager.shared.isSelectedModelReady()
        if mlxReady {
            let mlxResult = await runWithBackend(
                name: "MLX (Qwen)",
                prompt: prompt,
                systemInstruction: systemInstruction,
                useMLX: true
            )
            results.append(mlxResult)
        } else {
            logger.warning("MLX model not downloaded — skipping MLX comparison")
            results.append(ComparisonResult(
                backend: "MLX (Qwen)",
                durationSeconds: 0,
                rawOutput: "",
                topicCount: 0,
                topics: [],
                error: "MLX model not downloaded or selected"
            ))
        }

        // Log summary
        logger.info("=== Comparison Summary ===")
        for result in results {
            if let error = result.error {
                logger.info("\(result.backend): ERROR — \(error)")
            } else {
                logger.info("\(result.backend): \(result.topicCount) topics in \(String(format: "%.1f", result.durationSeconds))s")
                for (i, topic) in result.topics.enumerated() {
                    logger.info("  \(i + 1). \(topic.topic)")
                    for point in topic.keyPoints.prefix(2) {
                        logger.info("     • \(point)")
                    }
                }
            }
        }

        return results
    }

    // MARK: - Backend Runner

    private func runWithBackend(
        name: String,
        prompt: String,
        systemInstruction: String,
        useMLX: Bool
    ) async -> ComparisonResult {
        logger.info("--- Running \(name) ---")
        let start = ContinuousClock.now

        do {
            let output: String
            if useMLX {
                output = try await AIService.shared.generateNarrative(
                    prompt: prompt,
                    systemInstruction: systemInstruction,
                    maxTokens: 4096
                )
            } else {
                output = try await AIService.shared.generateWithFoundationModels(
                    prompt: prompt,
                    systemInstruction: systemInstruction
                )
            }

            let duration = ContinuousClock.now - start
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18

            logger.info("\(name) completed in \(String(format: "%.1f", seconds))s — \(output.count) chars")
            logger.debug("\(name) raw output:\n\(output)")

            let topics = parseTopics(from: output)

            return ComparisonResult(
                backend: name,
                durationSeconds: seconds,
                rawOutput: output,
                topicCount: topics.count,
                topics: topics,
                error: nil
            )
        } catch {
            let duration = ContinuousClock.now - start
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            logger.error("\(name) failed after \(String(format: "%.1f", seconds))s: \(error.localizedDescription)")
            return ComparisonResult(
                backend: name,
                durationSeconds: seconds,
                rawOutput: "",
                topicCount: 0,
                topics: [],
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Prompt Construction

    private func buildSystemInstruction() -> String {
        """
        Suggest 5 social media post ideas based on the user's recent activities.

        YOUR JOB is to suggest topics that make readers feel something — curiosity, \
        appreciation, inspiration, connection — not just learn something.

        TOPIC TITLE RULES:
        - Write titles as hooks. Ask a question, make a bold claim, or name an emotion.
        - Bad: "Navigating Leadership Transitions: Best Practices."
        - Good: "The Leader Who Built Something That Will Outlast Him."
        - No colons with subtitles. No "Lessons from..." or "Strategies for..." patterns.
        - Each title should make someone stop scrolling.

        KEY POINTS RULES:
        - First key point: a specific, concrete detail from the context data.
        - Include one ready-to-use opening sentence the user could copy into a post.
        - Last key point: an engagement hook — a question, invitation, or call to share.
        - Write from the user's perspective ("I" / "my"), not about the user.

        TONE VARIETY:
        - Vary suggested_tone across topics. Options: "personal", "inspirational", \
        "reflective", "celebratory", "curious". Do NOT default everything to "educational."

        CRITICAL: You MUST respond with ONLY valid JSON.
        - Do NOT wrap the JSON in markdown code blocks
        - Return ONLY the raw JSON object starting with { and ending with }

        The JSON structure must be:
        {
          "topic_suggestions": [
            {
              "topic": "Hook-style topic title",
              "key_points": ["Specific detail from data", "Copy-paste opening sentence", "Engagement question"],
              "suggested_tone": "personal",
              "compliance_notes": null
            }
          ]
        }
        """
    }

    // MARK: - Parsing

    private func parseTopics(from output: String) -> [TopicSummary] {
        var cleaned = JSONExtraction.extractJSON(from: output)
        // Apply the same MLX JSON sanitization as ContentAdvisorService
        cleaned = ContentAdvisorService.sanitizeMLXJSON(cleaned)

        guard let data = cleaned.data(using: .utf8) else { return [] }

        struct LLMTopics: Decodable {
            let topicSuggestions: [LLMTopic]

            enum CodingKeys: String, CodingKey {
                case topicSuggestions = "topic_suggestions"
            }
        }

        struct LLMTopic: Decodable {
            let topic: String?
            let keyPoints: [String]?
            let suggestedTone: String?

            enum CodingKeys: String, CodingKey {
                case topic
                case keyPoints = "key_points"
                case suggestedTone = "suggested_tone"
            }
        }

        guard let parsed = try? JSONDecoder().decode(LLMTopics.self, from: data) else {
            logger.debug("Failed to parse topic JSON")
            return []
        }

        return parsed.topicSuggestions.compactMap { t in
            guard let title = t.topic, !title.isEmpty else { return nil }
            return TopicSummary(
                topic: title,
                keyPoints: t.keyPoints ?? [],
                tone: t.suggestedTone ?? "educational"
            )
        }
    }

    // MARK: - Sample Data

    private func sampleData() -> String {
        """
        RECENT MEETING TOPICS:
          - ABT spring board meeting preparation
          - Aramaic Bible Translation progress review
          - Nonprofit fundraising strategy discussion
          - Community outreach event planning
          - Leadership transition planning for ABT

        DISCUSSION TOPICS (from notes):
          - Bible translation progress, minority language preservation
          - Nonprofit donor engagement, board governance
          - Middle East cultural heritage, diaspora communities
          - Executive director succession planning

        SEASONAL CONTEXT: March 2026 — spring nonprofit board season, Easter approaching

        ACTIVE BUSINESS GOALS (content should support these):
          - Content Posts: 2/8 this month (behind pace)
          - LinkedIn engagement: build awareness of nonprofit involvement
        """
    }
}
