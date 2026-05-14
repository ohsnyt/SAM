//
//  EmailAnalysisService.swift
//  SAM_crm
//
//  Created by Assistant on 2/13/26.
//  Email Integration - LLM Analysis Service
//
//  Actor-isolated service for analyzing email content with on-device LLM.
//

import Foundation
import os.log

/// Actor-isolated service for analyzing email content with on-device LLM.
/// Extracts summaries, entities, topics, and temporal events.
actor EmailAnalysisService {
    static let shared = EmailAnalysisService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EmailAnalysisService")

    private init() {}

    static let currentAnalysisVersion = 1

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

    /// Analyze an email body and extract structured intelligence.
    func analyzeEmail(subject: String, body: String, senderName: String?) async throws -> EmailAnalysisDTO {
        guard case .available = await checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let custom = UserDefaults.standard.string(forKey: "sam.ai.emailPrompt") ?? ""
        let instructions = custom.isEmpty ? await Self.defaultEmailPrompt() : custom

        // Truncate body to ~2500 characters to stay within the 4096-token context window.
        // The system instruction + subject/from use ~800–1000 tokens; body gets the rest.
        let maxBodyChars = 2500
        let trimmedBody = body.count > maxBodyChars
            ? String(body.prefix(maxBodyChars)) + "\n[…truncated]"
            : body

        let prompt = """
        Subject: \(subject)
        \(senderName.map { "From: \($0)" } ?? "")

        \(trimmedBody)
        """

        let responseText = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: instructions,
            task: InferenceTask(label: "Email analysis", icon: "envelope.badge.shield.half.filled", source: "EmailAnalysisService")
        )
        return try parseResponse(responseText)
    }

    private static func mapRSVPStatus(_ status: String) -> RSVPDetectionDTO.RSVPResponse {
        switch status.lowercased() {
        case "accepted":  return .accepted
        case "declined":  return .declined
        case "tentative": return .tentative
        case "question":  return .question
        default:          return .tentative
        }
    }

    private static func mapEntityKind(_ raw: String) -> EmailEntityDTO.EntityKind {
        switch raw {
        case "person": .person
        case "organization": .organization
        case "product": .product
        case "financial_instrument": .financialInstrument
        default: .person
        }
    }

    private func parseResponse(_ jsonString: String) throws -> EmailAnalysisDTO {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)

        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMEmailResponse.self, from: data)

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .long

            let rsvpDetections = (llm.rsvp_detections ?? []).map { rsvp in
                RSVPDetectionDTO(
                    responseText: rsvp.response_text,
                    detectedStatus: Self.mapRSVPStatus(rsvp.status),
                    confidence: rsvp.confidence,
                    additionalGuestCount: rsvp.additional_guest_count ?? 0,
                    additionalGuestNames: rsvp.additional_guest_names ?? [],
                    eventReference: rsvp.event_reference
                )
            }

            return EmailAnalysisDTO(
                summary: llm.summary,
                namedEntities: (llm.entities ?? []).map { e in
                    EmailEntityDTO(
                        id: UUID(),
                        name: e.name,
                        kind: Self.mapEntityKind(e.kind),
                        confidence: e.confidence ?? 0.5
                    )
                },
                topics: llm.topics ?? [],
                temporalEvents: (llm.temporal_events ?? []).compactMap { t in
                    guard let dateString = t.date_string else { return nil }
                    return TemporalEventDTO(
                        id: UUID(),
                        description: t.description ?? "",
                        dateString: dateString,
                        parsedDate: dateFormatter.date(from: dateString),
                        confidence: t.confidence ?? 0.5
                    )
                },
                rsvpDetections: rsvpDetections,
                sentiment: EmailAnalysisDTO.Sentiment(rawValue: llm.sentiment ?? "neutral") ?? .neutral,
                analysisVersion: Self.currentAnalysisVersion
            )
        } catch {
            // MLX models may return plain text — use as summary
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                logger.debug("Email analysis returned plain text, using as summary")
                return EmailAnalysisDTO(
                    summary: String(plainText.prefix(500)),
                    namedEntities: [],
                    topics: [],
                    temporalEvents: [],
                    rsvpDetections: [],
                    sentiment: .neutral,
                    analysisVersion: Self.currentAnalysisVersion
                )
            }
            throw error
        }
    }

    static func defaultEmailPrompt() async -> String {
        let persona = await BusinessProfileService.shared.personaFragment()
        return """
        You are analyzing a professional email received by \(persona).
        Extract structured intelligence from the email.

        CRITICAL: Respond with ONLY valid JSON. No markdown, no explanation.

        {
          "summary": "1-2 sentence summary",
          "entities": [
            { "name": "Full Name", "kind": "person|organization|product|financial_instrument", "confidence": 0.0-1.0 }
          ],
          "topics": ["retirement planning", ...],
          "temporal_events": [
            { "description": "What is happening", "date_string": "March 15, 2026", "confidence": 0.0-1.0 }
          ],
          "sentiment": "positive|neutral|negative|urgent",
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
        - Only extract explicitly stated information
        - For entities, distinguish people from organizations from financial products
        - For temporal events, extract any mentioned dates, deadlines, or scheduled events
        - Sentiment reflects the overall tone (urgent if action is required immediately)
        - If the email is too short or generic, return empty arrays

        RSVP Detection Rules (BE VERY CONSERVATIVE — false positives are worse than missed RSVPs):
        - ONLY detect an RSVP when the email is a DIRECT RESPONSE to an event invitation and the sender explicitly confirms, declines, or tentatively responds
        - The sender must reference the event BY NAME or BY DATE in the email
        - Do NOT detect an RSVP from generic affirmatives ("sounds good", "thank you") unless they explicitly mention the event
        - Set confidence to 0.95+ only when the sender names the specific event
        - Set confidence below 0.80 for anything ambiguous — these will be filtered out
        - The event_reference field is REQUIRED — set it to the exact event name referenced
        - If you cannot identify a specific event being referenced, do NOT add an rsvp_detection
        - When in doubt, omit — missing an RSVP is far better than a false one
        """
    }
}

// MARK: - Internal LLM Response Types
nonisolated private struct LLMEmailResponse: Codable {
    let summary: String
    let entities: [LLMEntity]?
    let topics: [String]?
    let temporal_events: [LLMTemporalEvent]?
    let rsvp_detections: [LLMRSVPDetection]?
    let sentiment: String?
}

nonisolated private struct LLMRSVPDetection: Codable {
    let response_text: String
    let status: String
    let confidence: Double
    let additional_guest_count: Int?
    let additional_guest_names: [String]?
    let event_reference: String?
}

nonisolated private struct LLMEntity: Codable {
    let name: String
    let kind: String
    let confidence: Double?
}

nonisolated private struct LLMTemporalEvent: Codable {
    let description: String?
    let date_string: String?
    let confidence: Double?
}