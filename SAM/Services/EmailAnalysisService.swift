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
        let instructions = custom.isEmpty ? Self.defaultEmailPrompt : custom

        let prompt = """
        Subject: \(subject)
        \(senderName.map { "From: \($0)" } ?? "")

        \(body)
        """

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        return try parseResponse(responseText)
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
        let cleaned = extractJSON(from: jsonString)

        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMEmailResponse.self, from: data)

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .long

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
                sentiment: EmailAnalysisDTO.Sentiment(rawValue: llm.sentiment ?? "neutral") ?? .neutral,
                analysisVersion: Self.currentAnalysisVersion
            )
        } catch {
            // MLX models may return plain text — use as summary
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                logger.info("Email analysis returned plain text, using as summary")
                return EmailAnalysisDTO(
                    summary: String(plainText.prefix(500)),
                    namedEntities: [],
                    topics: [],
                    temporalEvents: [],
                    sentiment: .neutral,
                    analysisVersion: Self.currentAnalysisVersion
                )
            }
            throw error
        }
    }

    static let defaultEmailPrompt = """
        You are analyzing a professional email received by an independent financial strategist.
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
          "sentiment": "positive|neutral|negative|urgent"
        }

        Rules:
        - Only extract explicitly stated information
        - For entities, distinguish people from organizations from financial products
        - For temporal events, extract any mentioned dates, deadlines, or scheduled events
        - Sentiment reflects the overall tone (urgent if action is required immediately)
        - If the email is too short or generic, return empty arrays
        """
}

// MARK: - Internal LLM Response Types
nonisolated private struct LLMEmailResponse: Codable {
    let summary: String
    let entities: [LLMEntity]?
    let topics: [String]?
    let temporal_events: [LLMTemporalEvent]?
    let sentiment: String?
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