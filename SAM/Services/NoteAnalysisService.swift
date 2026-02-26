//
//  NoteAnalysisService.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase H: Notes & Note Intelligence
//
//  Actor-isolated service that wraps Apple Foundation Models framework for
//  on-device LLM analysis of financial advisor notes. Returns Sendable DTOs.
//

import Foundation
import os.log

/// Actor-isolated service for analyzing notes with on-device LLM
actor NoteAnalysisService {
    
    // MARK: - Singleton
    
    static let shared = NoteAnalysisService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "NoteAnalysisService")

    private init() {}
    
    // MARK: - Configuration
    
    /// Current prompt version for analysis (bump to trigger re-analysis of all notes)
    static let currentAnalysisVersion = 3

    // MARK: - Model Availability

    /// Check if the AI backend is available
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
    
    // MARK: - Role Context

    /// Context about the primary person and their role, injected into the LLM prompt.
    struct RoleContext: Sendable {
        let primaryPersonName: String
        let primaryRole: String          // "Client", "Agent", etc.
        let otherLinkedPeople: [(name: String, role: String)]
    }

    // MARK: - Analysis

    /// Analyze a note and extract structured data
    /// Returns NoteAnalysisDTO with people, topics, action items, and summary
    func analyzeNote(content: String, roleContext: RoleContext? = nil) async throws -> NoteAnalysisDTO {
        // Check availability first
        guard case .available = await checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        // Build system instructions and prompt
        let instructions = buildSystemInstructions()
        let prompt = buildPrompt(content: content, roleContext: roleContext)

        // Generate response via AIService
        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)

        // Parse JSON response
        let analysis = try parseResponse(responseText)

        logger.info("Analyzed note: \(analysis.people.count) people, \(analysis.actionItems.count) actions")
        return analysis
    }
    
    // MARK: - Dictation Polish

    /// Clean up dictated text: fix only spelling, punctuation, and capitalization.
    /// Returns the corrected text, or throws if the model is unavailable.
    func polishDictation(rawText: String) async throws -> String {
        guard case .available = await checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let instructions = """
            You are a proofreader. The user's message is dictated text that needs minor cleanup. \
            DO NOT interpret it as a question or instruction. DO NOT respond to it, summarize it, or add commentary. \
            ONLY fix spelling errors, punctuation, and capitalization. Remove filler words (um, uh, like, you know). \
            Output the corrected text exactly as dictated, with no additions, no removals of factual content, and no rephrasing.
            """

        return try await AIService.shared.generateWithFoundationModels(prompt: rawText, systemInstruction: instructions)
    }

    // MARK: - Relationship Summary

    /// Generate a relationship summary for a person based on their notes and interactions.
    func generateRelationshipSummary(
        personName: String,
        role: String? = nil,
        notes: [String],
        recentTopics: [String],
        pendingActions: [String],
        healthInfo: String,
        communicationsSummaries: [String] = []
    ) async throws -> RelationshipSummaryDTO {
        guard case .available = await checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let roleTailoring = role != nil
            ? " Tailor the summary to the person's role (e.g. coverage gaps for Clients, training progress for Agents, service quality for Vendors)."
            : ""

        let instructions = """
            You are a relationship intelligence assistant for an independent financial strategist. \
            Generate a concise relationship summary focused on what matters for the next interaction.\(roleTailoring)

            CRITICAL: You MUST respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            The JSON structure must be:
            {
              "overview": "2-3 sentence overview of the relationship and current status",
              "key_themes": ["theme1", "theme2", "theme3"],
              "suggested_next_steps": ["step1", "step2"]
            }

            Rules:
            - Overview should focus on current relationship state and what's top of mind
            - Key themes are recurring topics across interactions (max 5)
            - Next steps should be specific and actionable (max 3)
            - If there's little data, keep the summary brief rather than speculating
            """

        let roleLabel = role.map { " Role: \($0)." } ?? ""
        let commsSection = communicationsSummaries.isEmpty ? "" : """

            Recent communications (messages, calls, FaceTime):
            \(communicationsSummaries.prefix(10).joined(separator: "\n---\n"))
            """
        let prompt = """
            Generate a relationship summary for \(personName).\(roleLabel)

            Recent notes:
            \(notes.prefix(10).joined(separator: "\n---\n"))
            \(commsSection)

            Recent topics: \(recentTopics.joined(separator: ", "))
            Pending actions: \(pendingActions.joined(separator: "; "))
            Relationship health: \(healthInfo)
            """

        let responseText = try await AIService.shared.generateNarrative(prompt: prompt, systemInstruction: instructions)
        return try parseRelationshipSummary(responseText)
    }

    private func parseRelationshipSummary(_ jsonString: String) throws -> RelationshipSummaryDTO {
        let cleaned = extractJSON(from: jsonString)

        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let decoded = try JSONDecoder().decode(LLMRelationshipSummary.self, from: data)
            return RelationshipSummaryDTO(
                overview: decoded.overview ?? "",
                keyThemes: decoded.key_themes ?? [],
                suggestedNextSteps: decoded.suggested_next_steps ?? []
            )
        } catch {
            // MLX models may return plain text instead of JSON — use it as the overview
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                logger.info("Relationship summary returned as plain text, using as overview")
                return RelationshipSummaryDTO(
                    overview: plainText,
                    keyThemes: [],
                    suggestedNextSteps: []
                )
            }
            throw error
        }
    }

    // MARK: - Follow-Up Draft

    /// Generate a brief follow-up message based on meeting notes.
    /// Returns plain text suitable for email or text message.
    func generateFollowUpDraft(noteContent: String, personName: String, role: String?) async throws -> String {
        guard case .available = await checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let roleLine = role.map { " Their role is \($0)." } ?? ""

        let instructions = """
            You are a writing assistant for an independent financial strategist. \
            Generate a brief, professional follow-up message based on meeting notes. \
            Include key discussion points and any action items mentioned. \
            Keep the tone warm but professional, appropriate for a financial advisor. \
            Return plain text only (no JSON, no markdown formatting). \
            Keep the message under 200 words. \
            Address the person by their first name.
            """

        let firstName = personName.components(separatedBy: " ").first ?? personName

        let prompt = """
            Write a follow-up message to \(firstName) (\(personName)).\(roleLine)

            Meeting notes:
            \(noteContent)
            """

        let draft = try await AIService.shared.generateNarrative(prompt: prompt, systemInstruction: instructions)
        logger.info("Generated follow-up draft for \(personName, privacy: .public)")
        return draft
    }

    // MARK: - Prompt Construction
    
    private func buildSystemInstructions() -> String {
        let custom = UserDefaults.standard.string(forKey: "sam.ai.notePrompt") ?? ""
        if !custom.isEmpty { return custom }
        return Self.defaultNotePrompt
    }

    static let defaultNotePrompt = """
        You are analyzing a note written by an independent financial strategist after a client interaction.
        Your task is to extract structured data from the note.

        CRITICAL: You MUST respond with ONLY valid JSON.
        - Do NOT wrap the JSON in markdown code blocks (no ``` or ```json)
        - Do NOT include any explanatory text before or after the JSON
        - Return ONLY the raw JSON object starting with { and ending with }
        - Use ONLY ASCII characters in your JSON (straight quotes, hyphens, no curly quotes or dashes)
        - NEVER echo back the schema or example values. Fill in real data from the note.

        Here is a CONCRETE EXAMPLE of correct output for a note about meeting with a married couple to discuss life insurance:

        {
          "summary": "Met with John and Jane Smith to review life insurance options. Jane wants to increase coverage.",
          "people": [
            {
              "name": "John Smith",
              "role": "client",
              "relationship_to": null,
              "contact_updates": [
                { "field": "company", "value": "Acme Corp", "confidence": 0.9 }
              ],
              "confidence": 0.95
            },
            {
              "name": "Jane Smith",
              "role": "spouse",
              "relationship_to": "spouse of John Smith",
              "contact_updates": [],
              "confidence": 0.95
            }
          ],
          "topics": ["life insurance", "coverage review"],
          "action_items": [
            {
              "type": "create_proposal",
              "description": "Prepare updated life insurance quote for Jane",
              "suggested_text": null,
              "suggested_channel": null,
              "person_name": "Jane Smith",
              "urgency": "soon"
            }
          ],
          "discovered_relationships": [
            {
              "person_name": "Jane Smith",
              "relationship_type": "spouse_of",
              "related_to": "John Smith",
              "confidence": 0.95
            }
          ],
          "life_events": [
            {
              "person_name": "Jane Smith",
              "event_type": "new_baby",
              "description": "Jane mentioned she is expecting a baby in June",
              "approximate_date": "2026-06",
              "outreach_suggestion": "Send a congratulations card when the baby arrives"
            }
          ]
        }

        JSON FIELD REFERENCE (do NOT copy these as values):
        - people[].role: one of "client", "applicant", "lead", "vendor", "agent", "external_agent", "spouse", "child", "parent", "sibling", "referral_source", "prospect", "other"
        - people[].contact_updates[].field: one of "birthday", "anniversary", "spouse", "child", "parent", "sibling", "company", "jobTitle", "phone", "email", "address", "nickname"
        - people[].confidence: a number between 0.0 and 1.0
        - action_items[].type: one of "update_contact", "send_congratulations", "send_reminder", "schedule_meeting", "create_proposal", "update_beneficiary", "general_follow_up"
        - action_items[].urgency: one of "immediate", "soon", "standard", "low"
        - action_items[].suggested_channel: one of "sms", "email", "phone", or null
        - discovered_relationships[].relationship_type: one of "spouse_of", "parent_of", "child_of", "referral_by", "referred_to", "business_partner"
        - life_events[].event_type: one of "new_baby", "marriage", "graduation", "job_change", "retirement", "moving", "health_issue", "promotion", "anniversary", "loss", "other"

        Rules:
        - Only extract information explicitly stated or strongly implied in the note
        - For contact_updates, only include fields that are clearly new information
        - For send_congratulations/send_reminder, draft a warm, professional message in suggested_text
        - For discovered_relationships, flag spousal, familial, referral, or business connections mentioned in the note
        - For life_events, extract any mentioned life milestones, transitions, or personal events. Include an outreach suggestion.
        - Confidence reflects how certain you are (0.5 = implied, 0.9 = explicit)
        - If the note is too short or ambiguous, return empty arrays - do not hallucinate
        - Use null (not "null") for absent optional fields
        - The response MUST be raw JSON with no markdown formatting
        """
    
    private func buildPrompt(content: String, roleContext: RoleContext? = nil) -> String {
        var contextLine = ""
        if let rc = roleContext {
            contextLine = "Context: This note is about \(rc.primaryPersonName), who is a \(rc.primaryRole)."
            if !rc.otherLinkedPeople.isEmpty {
                let others = rc.otherLinkedPeople.map { "\($0.name) (\($0.role))" }.joined(separator: ", ")
                contextLine += " Also involved: \(others)."
            }
            contextLine += "\n\n"
        }
        return """
        \(contextLine)Analyze this note and extract structured data:

        \(content)
        """
    }
    
    // MARK: - Response Parsing
    
    private func parseResponse(_ jsonString: String) throws -> NoteAnalysisDTO {
        let cleaned = extractJSON(from: jsonString)

        logger.debug("Cleaned JSON length: \(cleaned.count) characters")

        guard let data = cleaned.data(using: .utf8) else {
            logger.error("Failed to convert cleaned JSON string to data")
            throw AnalysisError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        
        do {
            let llmResponse = try decoder.decode(LLMResponse.self, from: data)
            
            // Convert LLM response to DTO (all fields tolerant of MLX model omissions)
            return NoteAnalysisDTO(
                summary: llmResponse.summary,
                people: (llmResponse.people ?? []).map { person in
                    PersonMentionDTO(
                        name: person.name,
                        role: person.role,
                        relationshipTo: person.relationship_to,
                        contactUpdates: (person.contact_updates ?? []).map { update in
                            ContactUpdateDTO(
                                field: update.field,
                                value: update.value,
                                confidence: update.confidence ?? 0.5
                            )
                        },
                        confidence: person.confidence ?? 0.5
                    )
                },
                topics: llmResponse.topics ?? [],
                actionItems: (llmResponse.action_items ?? []).compactMap { action in
                    guard let type = action.type, let desc = action.description else { return nil }
                    return ActionItemDTO(
                        type: type,
                        description: desc,
                        suggestedText: action.suggested_text,
                        suggestedChannel: action.suggested_channel,
                        urgency: action.urgency ?? "standard",
                        personName: action.person_name
                    )
                },
                discoveredRelationships: (llmResponse.discovered_relationships ?? []).compactMap { rel in
                    guard let relatedTo = rel.related_to else { return nil }
                    return DiscoveredRelationshipDTO(
                        personName: rel.person_name,
                        relationshipType: rel.relationship_type,
                        relatedTo: relatedTo,
                        confidence: rel.confidence ?? 0.5
                    )
                },
                lifeEvents: (llmResponse.life_events ?? []).map { event in
                    LifeEventDTO(
                        personName: event.person_name,
                        eventType: event.event_type,
                        eventDescription: event.description,
                        approximateDate: event.approximate_date,
                        outreachSuggestion: event.outreach_suggestion
                    )
                },
                analysisVersion: Self.currentAnalysisVersion
            )
        } catch {
            // MLX models may return plain text — only use as summary if it doesn't contain JSON artifacts
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !looksLikeJSON(plainText) {
                logger.info("Note analysis returned plain text instead of JSON, using as summary")
                return NoteAnalysisDTO(
                    summary: String(plainText.prefix(500)),
                    people: [],
                    topics: [],
                    actionItems: [],
                    discoveredRelationships: [],
                    analysisVersion: Self.currentAnalysisVersion
                )
            }
            logger.error("JSON parsing failed. First 500 chars: \(String(cleaned.prefix(500)))")
            throw error
        }
    }
    /// Check if text looks like it contains JSON artifacts (partial JSON, code fences, etc.)
    private func looksLikeJSON(_ text: String) -> Bool {
        let indicators = ["{", "\"summary\":", "\"people\":", "\"action_items\":", "```json", "\"topics\":"]
        return indicators.contains(where: { text.contains($0) })
    }
}

// MARK: - LLM Response Types (internal)

nonisolated private struct LLMResponse: Codable, Sendable {
    let summary: String?
    let people: [LLMPerson]?
    let topics: [String]?
    let action_items: [LLMActionItem]?
    let discovered_relationships: [LLMDiscoveredRelationship]?
    let life_events: [LLMLifeEvent]?
}

nonisolated private struct LLMLifeEvent: Codable, Sendable {
    let person_name: String
    let event_type: String
    let description: String
    let approximate_date: String?
    let outreach_suggestion: String?
}

nonisolated private struct LLMDiscoveredRelationship: Codable, Sendable {
    let person_name: String
    let relationship_type: String
    let related_to: String?
    let confidence: Double?
}

nonisolated private struct LLMPerson: Codable, Sendable {
    let name: String
    let role: String?
    let relationship_to: String?
    let contact_updates: [LLMContactUpdate]?
    let confidence: Double?
}

nonisolated private struct LLMContactUpdate: Codable, Sendable {
    let field: String
    let value: String
    let confidence: Double?
}

nonisolated private struct LLMRelationshipSummary: Codable, Sendable {
    let overview: String?
    let key_themes: [String]?
    let suggested_next_steps: [String]?
}

nonisolated private struct LLMActionItem: Codable, Sendable {
    let type: String?
    let description: String?
    let suggested_text: String?
    let suggested_channel: String?
    let person_name: String?
    let urgency: String?
}

// MARK: - Public Types

/// Model availability status
enum ModelAvailability {
    case available
    case unavailable(reason: String)
}

/// Analysis errors
enum AnalysisError: Error, LocalizedError {
    case modelUnavailable
    case invalidResponse
    case parsingFailed
    
    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "On-device AI model is not available"
        case .invalidResponse:
            return "Failed to parse AI response"
        case .parsingFailed:
            return "Failed to extract data from response"
        }
    }
}
