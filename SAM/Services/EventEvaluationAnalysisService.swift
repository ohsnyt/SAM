//
//  EventEvaluationAnalysisService.swift
//  SAM
//
//  Created on April 7, 2026.
//  Actor-based AI analysis service for post-event evaluation.
//  Analyzes chat participant engagement, cross-references content,
//  and generates event summaries using on-device LLM.
//

import Foundation
import os.log

actor EventEvaluationAnalysisService {

    static let shared = EventEvaluationAnalysisService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EventEvalAnalysis")

    private init() {}

    // MARK: - Participant Analysis

    /// Analyze a single participant's chat activity to determine engagement level,
    /// topic interests, sentiment, conversion signals, and inferred role.
    func analyzeParticipant(_ analysis: ChatParticipantAnalysis) async throws -> ChatParticipantAnalysis {
        var updated = analysis

        // Deterministic heuristics for engagement level
        let total = analysis.messageCount + analysis.reactionCount
        if total >= 8 || analysis.questionsAsked.count >= 2 {
            updated.engagementLevelRawValue = EngagementLevel.high.rawValue
        } else if total >= 4 || analysis.questionsAsked.count >= 1 {
            updated.engagementLevelRawValue = EngagementLevel.medium.rawValue
        } else if total >= 1 {
            updated.engagementLevelRawValue = EngagementLevel.low.rawValue
        } else {
            updated.engagementLevelRawValue = EngagementLevel.observer.rawValue
        }

        // Skip LLM for low-activity participants (< 3 non-reaction messages)
        guard analysis.messageCount >= 3 else { return updated }

        // Build a focused prompt for LLM analysis
        let messagesText = analysis.questionsAsked.prefix(5).joined(separator: "\n- ")
        let prompt = """
        Analyze this workshop participant's chat activity.

        Participant: \(analysis.displayName)
        Messages sent: \(analysis.messageCount)
        Reactions: \(analysis.reactionCount)
        Questions asked:
        - \(messagesText.isEmpty ? "(none)" : messagesText)

        Respond in JSON with these fields:
        {
          "topicInterests": ["topic1", "topic2"],
          "sentiment": "positive" or "neutral" or "negative",
          "conversionSignals": ["signal1"],
          "inferredRole": "attendee" or "cohost" or "host"
        }

        Rules:
        - topicInterests: financial topics they discussed or asked about (e.g., "life insurance", "401k", "debt management", "retirement")
        - sentiment: overall tone of their messages
        - conversionSignals: explicit requests for help, scheduling, or follow-up (e.g., "Yes please", "Let's connect", "Can I get help with...")
        - inferredRole: "host" if they moderate/answer questions for others, "cohost" if they assist the host, "attendee" otherwise

        Return ONLY the JSON, no other text.
        """

        do {
            let response = try await AIService.shared.generate(
                prompt: prompt,
                systemInstruction: "You analyze workshop chat data. Return only valid JSON."
            )
            updated = applyLLMResponse(response, to: updated)
        } catch {
            logger.warning("LLM analysis failed for \(analysis.displayName): \(error.localizedDescription)")
        }

        return updated
    }

    // MARK: - Cross-Reference Analysis

    /// Compare questions asked in chat against presentation content to identify
    /// content gaps and effective sections.
    func crossReferenceAnalysis(
        questions: [String],
        presentationSummary: String,
        talkingPoints: [String],
        eventTitle: String
    ) async throws -> (contentGaps: String, effectiveSections: String) {
        let questionsText = questions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let pointsText = talkingPoints.joined(separator: "\n- ")

        let prompt = """
        Analyze this workshop's effectiveness by comparing what was taught vs what participants asked.

        Workshop: \(eventTitle)

        Presentation summary:
        \(presentationSummary.isEmpty ? "(not available)" : presentationSummary)

        Key talking points:
        - \(pointsText.isEmpty ? "(not available)" : pointsText)

        Questions participants asked during the workshop:
        \(questionsText)

        Provide two analyses:

        1. CONTENT GAPS: Topics where participants asked questions that weren't fully covered, suggesting the presentation needs more depth or clarity. Be specific about what to add or expand.

        2. EFFECTIVE SECTIONS: Topics that resonated well based on engaged discussion and follow-up questions showing comprehension. These are strengths to keep.

        Format as two clear sections. Keep each to 2-4 bullet points. Be specific and actionable.
        """

        let response = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: "You are a workshop effectiveness analyst. Provide specific, actionable feedback."
        )

        // Split response into gaps and effective sections
        let parts = splitAnalysis(response)
        return (contentGaps: parts.gaps, effectiveSections: parts.effective)
    }

    // MARK: - Event Summary

    /// Generate an overall event summary synthesizing all available data.
    func generateEventSummary(
        eventTitle: String,
        participantCount: Int,
        feedbackCount: Int,
        averageRating: Double?,
        conversionRate: Double?,
        topQuestions: [String],
        contentGaps: String?,
        effectiveSections: String?
    ) async throws -> String {
        let ratingStr = averageRating.map { String(format: "%.1f/4.0", $0) } ?? "N/A"
        let conversionStr = conversionRate.map { String(format: "%.0f%%", $0 * 100) } ?? "N/A"
        let questionsStr = topQuestions.prefix(5).joined(separator: "\n- ")

        let prompt = """
        Summarize this workshop's results in 3-4 sentences for the presenter.

        Workshop: \(eventTitle)
        Participants in chat: \(participantCount)
        Feedback responses: \(feedbackCount)
        Average rating: \(ratingStr)
        Conversion rate (want follow-up): \(conversionStr)

        Top questions asked:
        - \(questionsStr.isEmpty ? "(none)" : questionsStr)

        \(contentGaps.map { "Content gaps identified:\n\($0)" } ?? "")
        \(effectiveSections.map { "Effective sections:\n\($0)" } ?? "")

        Write a brief, encouraging summary that highlights what went well and what to improve for next time. Address the presenter directly as "you".
        """

        return try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: "You summarize workshop results for the presenter. Be encouraging but honest. Keep it to 3-4 sentences."
        )
    }

    // MARK: - Helpers

    private func applyLLMResponse(_ response: String, to analysis: ChatParticipantAnalysis) -> ChatParticipantAnalysis {
        var updated = analysis

        // Extract JSON from response
        guard let jsonData = extractJSON(from: response),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return updated
        }

        if let topics = dict["topicInterests"] as? [String] {
            updated.topicInterests = topics
        }
        if let sentiment = dict["sentiment"] as? String {
            updated.sentimentRawValue = sentiment
        }
        if let signals = dict["conversionSignals"] as? [String] {
            updated.conversionSignals = signals
        }
        if let role = dict["inferredRole"] as? String,
           let inferredRole = InferredEventRole(rawValue: role) {
            updated.inferredRoleRawValue = inferredRole.rawValue
        }

        return updated
    }

    private func extractJSON(from text: String) -> Data? {
        // Try to find JSON object in the response
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for code block markers
        var jsonString = trimmed
        if let start = jsonString.range(of: "```json") {
            jsonString = String(jsonString[start.upperBound...])
        } else if let start = jsonString.range(of: "```") {
            jsonString = String(jsonString[start.upperBound...])
        }
        if let end = jsonString.range(of: "```") {
            jsonString = String(jsonString[..<end.lowerBound])
        }

        // Find the JSON object boundaries
        if let braceStart = jsonString.firstIndex(of: "{"),
           let braceEnd = jsonString.lastIndex(of: "}") {
            jsonString = String(jsonString[braceStart...braceEnd])
        }

        return jsonString.data(using: .utf8)
    }

    private func splitAnalysis(_ response: String) -> (gaps: String, effective: String) {
        let lower = response.lowercased()

        // Try to split on section headers
        let gapMarkers = ["content gap", "gap", "need more", "improve"]
        let effectiveMarkers = ["effective", "strength", "went well", "resonated"]

        var gapStart: String.Index?
        var effectiveStart: String.Index?

        for marker in gapMarkers {
            if let range = lower.range(of: marker) {
                if gapStart == nil || range.lowerBound < gapStart! {
                    gapStart = range.lowerBound
                }
            }
        }

        for marker in effectiveMarkers {
            if let range = lower.range(of: marker) {
                if effectiveStart == nil || range.lowerBound < effectiveStart! {
                    effectiveStart = range.lowerBound
                }
            }
        }

        // If we found both sections, split them
        if let gs = gapStart, let es = effectiveStart {
            if gs < es {
                let gaps = String(response[gs..<es]).trimmingCharacters(in: .whitespacesAndNewlines)
                let effective = String(response[es...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (gaps: gaps, effective: effective)
            } else {
                let effective = String(response[es..<gs]).trimmingCharacters(in: .whitespacesAndNewlines)
                let gaps = String(response[gs...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (gaps: gaps, effective: effective)
            }
        }

        // Fallback: return entire response as both
        return (gaps: response, effective: "")
    }
}
