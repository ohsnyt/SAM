//
//  MessageAnalysisService.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Actor-isolated service that analyzes iMessage conversation threads using
//  on-device LLM. Receives chronological messages, returns structured analysis.
//  Raw message text is discarded after analysis — only the summary is persisted.
//

import Foundation
import os.log

actor MessageAnalysisService {

    static let shared = MessageAnalysisService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MessageAnalysisService")

    static let currentAnalysisVersion = 1

    private init() {}

    // MARK: - Availability

    func checkAvailability() async -> ModelAvailability {
        let availability = await AIService.shared.checkAvailability()
        switch availability {
        case .available:
            return .available
        case .downloading:
            return .unavailable(reason: "Model is downloading")
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }

    // MARK: - Analysis

    /// Analyze a conversation thread and extract structured data.
    /// Messages are formatted chronologically and sent to the on-device LLM.
    /// After analysis, the raw text should be discarded — only the DTO is persisted.
    func analyzeConversation(
        messages: [(text: String, date: Date, isFromMe: Bool)],
        contactName: String?,
        contactRole: String?
    ) async throws -> MessageAnalysisDTO {
        guard case .available = await checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        guard !messages.isEmpty else {
            throw AnalysisError.invalidResponse
        }

        let instructions = buildSystemInstructions()
        let prompt = buildPrompt(messages: messages, contactName: contactName, contactRole: contactRole)

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        let analysis = try parseResponse(responseText)

        logger.info("Analyzed conversation with \(messages.count) messages: \(analysis.topics.count) topics")
        return analysis
    }

    // MARK: - Prompt Construction

    private func buildSystemInstructions() -> String {
        let custom = UserDefaults.standard.string(forKey: "sam.ai.messagePrompt") ?? ""
        if !custom.isEmpty { return custom }
        return Self.defaultPrompt
    }

    static let defaultPrompt = """
        You are analyzing an iMessage conversation between a financial strategist and one of their contacts. \
        Extract structured data about the conversation thread.

        CRITICAL: You MUST respond with ONLY valid JSON.
        - Do NOT wrap the JSON in markdown code blocks
        - Return ONLY the raw JSON object starting with { and ending with }

        The JSON structure must be:
        {
          "summary": "2-3 sentence summary of the conversation suitable for a CRM activity log",
          "topics": ["topic1", "topic2"],
          "temporal_events": [
            { "description": "event described", "date_string": "March 15", "confidence": 0.8 }
          ],
          "sentiment": "positive | neutral | negative | urgent",
          "action_items": ["action1", "action2"]
        }

        Rules:
        - Summary should focus on what was discussed and any outcomes/decisions
        - Topics should be business-relevant (insurance, financial planning, meetings, etc.)
        - Only include temporal_events for dates/deadlines explicitly mentioned
        - Sentiment reflects the overall tone of the conversation
        - Action items are things that need follow-up
        - If the conversation is too short or trivial, keep the summary brief
        - The response MUST be raw JSON with no markdown formatting
        """

    private func buildPrompt(
        messages: [(text: String, date: Date, isFromMe: Bool)],
        contactName: String?,
        contactRole: String?
    ) -> String {
        var contextLine = ""
        if let name = contactName {
            contextLine = "This conversation is with \(name)"
            if let role = contactRole {
                contextLine += ", who is a \(role)"
            }
            contextLine += ".\n\n"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"

        let thread = messages.map { msg in
            let timestamp = formatter.string(from: msg.date)
            let sender = msg.isFromMe ? "Me" : (contactName ?? "Them")
            return "[\(timestamp)] \(sender): \(msg.text)"
        }.joined(separator: "\n")

        return """
            \(contextLine)Analyze this iMessage conversation:

            \(thread)
            """
    }

    // MARK: - Response Parsing

    private func parseResponse(_ jsonString: String) throws -> MessageAnalysisDTO {
        let cleaned = extractJSON(from: jsonString)

        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let decoded = try JSONDecoder().decode(LLMMessageResponse.self, from: data)

            let temporalEvents = (decoded.temporal_events ?? []).map { event in
                TemporalEventDTO(
                    id: UUID(),
                    description: event.description,
                    dateString: event.date_string,
                    parsedDate: nil,
                    confidence: event.confidence
                )
            }

            let sentiment: MessageAnalysisDTO.Sentiment
            switch decoded.sentiment?.lowercased() {
            case "positive": sentiment = .positive
            case "negative": sentiment = .negative
            case "urgent": sentiment = .urgent
            default: sentiment = .neutral
            }

            return MessageAnalysisDTO(
                summary: decoded.summary ?? "No summary available",
                topics: decoded.topics ?? [],
                temporalEvents: temporalEvents,
                sentiment: sentiment,
                actionItems: decoded.action_items ?? [],
                analysisVersion: Self.currentAnalysisVersion
            )
        } catch {
            // MLX models may return plain text — use as summary
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                logger.info("Message analysis returned plain text, using as summary")
                return MessageAnalysisDTO(
                    summary: String(plainText.prefix(500)),
                    topics: [],
                    temporalEvents: [],
                    sentiment: .neutral,
                    actionItems: [],
                    analysisVersion: Self.currentAnalysisVersion
                )
            }
            throw error
        }
    }
}

// MARK: - LLM Response Types (internal)

nonisolated private struct LLMMessageResponse: Codable, Sendable {
    let summary: String?
    let topics: [String]?
    let temporal_events: [LLMTemporalEvent]?
    let sentiment: String?
    let action_items: [String]?
}

nonisolated private struct LLMTemporalEvent: Codable, Sendable {
    let description: String
    let date_string: String
    let confidence: Double
}
