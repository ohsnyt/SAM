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

        let instructions = await buildSystemInstructions()
        let prompt = buildPrompt(messages: messages, contactName: contactName, contactRole: contactRole)

        let responseText = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: instructions,
            task: InferenceTask(label: "Message analysis", icon: "message.badge", source: "MessageAnalysisService")
        )
        let analysis = try parseResponse(responseText)

        logger.debug("Analyzed conversation with \(messages.count) messages: \(analysis.topics.count) topics")
        return analysis
    }

    // MARK: - Prompt Construction

    private func buildSystemInstructions() async -> String {
        let custom = UserDefaults.standard.string(forKey: "sam.ai.messagePrompt") ?? ""
        if !custom.isEmpty { return custom }
        return await Self.defaultPrompt()
    }

    static func defaultPrompt() async -> String {
        let persona = await BusinessProfileService.shared.personaFragment()
        return """
        You are analyzing an iMessage conversation between \(persona) and one of their contacts. \
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
          "action_items": ["action1", "action2"],
          "rsvp_detections": [
            {
              "response_text": "the exact quote indicating RSVP",
              "status": "accepted | declined | tentative | question",
              "confidence": 0.9,
              "additional_guest_count": 0,
              "additional_guest_names": [],
              "event_reference": "Thursday workshop"
            }
          ]
        }

        Rules:
        - Summary should focus on what was discussed and any outcomes/decisions
        - ONLY reference people, topics, and events that are explicitly present in the conversation text — never invent or infer names, topics, or actions not stated
        - Topics should be business-relevant (insurance, financial planning, meetings, etc.)
        - Only include temporal_events for dates/deadlines explicitly mentioned
        - Sentiment reflects the overall tone of the conversation
        - Action items are things that need follow-up
        - If the conversation is too short or trivial, keep the summary brief

        RSVP Detection Rules (BE VERY CONSERVATIVE — false positives are worse than missed RSVPs):
        - ONLY detect an RSVP when the contact's message is a DIRECT RESPONSE to an explicit invitation or event-specific question
        - The contact must reference the event BY NAME or BY DATE in the SAME message as their response — a "yes" or "sounds good" in a conversation that ALSO mentions an event elsewhere is NOT an RSVP
        - NEVER detect an RSVP from a "yes", "ok", "sounds good", "great", or other generic affirmative UNLESS it is IMMEDIATELY following an invitation with a specific event name and date
        - Do NOT treat these as RSVPs: casual agreement ("yes" to any question), social conversation ("let's meet up"), scheduling a 1-on-1 meeting, agreeing to a phone call, confirming receipt of information
        - DO treat these as RSVPs: "I'll be at the Thursday workshop", "count me in for the March 20 seminar", "can't make the Saturday training", "we'll be there for the Financial Foundations event"
        - Set confidence to 0.95+ only when the contact explicitly names the event in their response
        - Set confidence to 0.80-0.94 when the event is implied but not named (e.g., reply to an invitation message)
        - Set confidence BELOW 0.80 for anything ambiguous — these will be filtered out
        - The event_reference field is REQUIRED — set it to the EXACT event name or date the contact referenced
        - If you cannot identify a specific event being referenced, do NOT add an rsvp_detection
        - When in doubt, omit the rsvp_detection entirely — it is FAR better to miss an RSVP than to falsely flag one
        - The response MUST be raw JSON with no markdown formatting
        """
    }

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

    private static func mapRSVPStatus(_ status: String) -> RSVPDetectionDTO.RSVPResponse {
        switch status.lowercased() {
        case "accepted":  return .accepted
        case "declined":  return .declined
        case "tentative": return .tentative
        case "question":  return .question
        default:          return .tentative
        }
    }

    private func parseResponse(_ jsonString: String) throws -> MessageAnalysisDTO {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)

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

            let rsvpDetections = (decoded.rsvp_detections ?? []).map { rsvp in
                RSVPDetectionDTO(
                    responseText: rsvp.response_text,
                    detectedStatus: Self.mapRSVPStatus(rsvp.status),
                    confidence: rsvp.confidence,
                    additionalGuestCount: rsvp.additional_guest_count ?? 0,
                    additionalGuestNames: rsvp.additional_guest_names ?? [],
                    eventReference: rsvp.event_reference
                )
            }

            return MessageAnalysisDTO(
                summary: decoded.summary ?? "No summary available",
                topics: decoded.topics ?? [],
                temporalEvents: temporalEvents,
                sentiment: sentiment,
                actionItems: decoded.action_items ?? [],
                rsvpDetections: rsvpDetections,
                analysisVersion: Self.currentAnalysisVersion
            )
        } catch {
            // MLX models may return plain text — use as summary
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                logger.debug("Message analysis returned plain text, using as summary")
                return MessageAnalysisDTO(
                    summary: String(plainText.prefix(500)),
                    topics: [],
                    temporalEvents: [],
                    sentiment: .neutral,
                    actionItems: [],
                    rsvpDetections: [],
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
    let rsvp_detections: [LLMRSVPDetection]?
}

nonisolated private struct LLMTemporalEvent: Codable, Sendable {
    let description: String
    let date_string: String
    let confidence: Double
}

nonisolated private struct LLMRSVPDetection: Codable, Sendable {
    let response_text: String
    let status: String          // "accepted", "declined", "tentative", "question"
    let confidence: Double
    let additional_guest_count: Int?
    let additional_guest_names: [String]?
    let event_reference: String?
}
