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
import FoundationModels
import os.log

/// Actor-isolated service for analyzing notes with on-device LLM
actor NoteAnalysisService {
    
    // MARK: - Singleton
    
    static let shared = NoteAnalysisService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "NoteAnalysisService")

    private init() {}
    
    // MARK: - Configuration
    
    /// Current prompt version for analysis (bump to trigger re-analysis of all notes)
    static let currentAnalysisVersion = 1
    
    private let model = SystemLanguageModel.default
    
    // MARK: - Model Availability
    
    /// Check if the on-device LLM is available
    func checkAvailability() -> ModelAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "Device not eligible for Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Apple Intelligence not enabled. Enable in Settings → Apple Intelligence & Siri")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "Model is downloading or not ready")
        case .unavailable(let other):
            return .unavailable(reason: "Model unavailable: \(other)")
        }
    }
    
    // MARK: - Analysis
    
    /// Analyze a note and extract structured data
    /// Returns NoteAnalysisDTO with people, topics, action items, and summary
    func analyzeNote(content: String) async throws -> NoteAnalysisDTO {
        // Check availability first
        guard case .available = checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }
        
        // Build system instructions
        let instructions = buildSystemInstructions()
        
        // Create session with instructions
        let session = LanguageModelSession(instructions: instructions)
        
        // Build prompt with note content
        let prompt = buildPrompt(content: content)
        
        // Generate response (structured JSON)
        let response = try await session.respond(to: prompt)
        
        // Parse JSON response
        let analysis = try parseResponse(response.content)
        
        logger.info("Analyzed note: \(analysis.people.count) people, \(analysis.actionItems.count) actions")

        return analysis
    }
    
    // MARK: - Prompt Construction
    
    private func buildSystemInstructions() -> String {
        """
        You are analyzing a note written by an independent financial strategist after a client interaction.
        Your task is to extract structured data from the note.
        
        CRITICAL: You MUST respond with ONLY valid JSON. 
        - Do NOT wrap the JSON in markdown code blocks (no ``` or ```json)
        - Do NOT include any explanatory text before or after the JSON
        - Return ONLY the raw JSON object starting with { and ending with }
        
        The JSON structure must be:
        {
          "summary": "1–2 sentence summary suitable for display next to a person's name in a CRM",
          
          "people": [
            {
              "name": "Full Name",
              "role": "client | spouse | child | parent | sibling | referral_source | colleague | prospect | other",
              "relationship_to": "spouse of John Smith (or null)",
              "contact_updates": [
                { "field": "birthday | anniversary | spouse | child | parent | sibling | company | jobTitle | phone | email | address | nickname", "value": "...", "confidence": 0.0–1.0 }
              ],
              "confidence": 0.0–1.0
            }
          ],
          
          "topics": ["life insurance", "retirement planning", ...],
          
          "action_items": [
            {
              "type": "update_contact | send_congratulations | send_reminder | schedule_meeting | create_proposal | update_beneficiary | general_follow_up",
              "description": "What needs to happen",
              "suggested_text": "Draft message text if type is send_* (or null)",
              "suggested_channel": "sms | email | phone (or null)",
              "person_name": "Who it relates to (or null)",
              "urgency": "immediate | soon | standard | low"
            }
          ]
        }
        
        Rules:
        - Only extract information explicitly stated or strongly implied
        - For contact_updates, only include fields that are clearly new information
        - For send_congratulations/send_reminder, draft a warm, professional message
        - Confidence reflects how certain you are (0.5 = implied, 0.9 = explicit)
        - If the note is too short or ambiguous, return empty arrays — do not hallucinate
        - The response MUST be raw JSON with no markdown formatting
        """
    }
    
    private func buildPrompt(content: String) -> String {
        """
        Analyze this note and extract structured data:
        
        \(content)
        """
    }
    
    // MARK: - Response Parsing
    
    private func parseResponse(_ jsonString: String) throws -> NoteAnalysisDTO {
        // Clean up any potential markdown code blocks and extra text
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code block markers (```json ... ``` or ``` ... ```)
        if cleaned.hasPrefix("```") {
            // Find the first newline after ```
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // Remove trailing ```
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
        }
        
        // Remove any remaining leading/trailing whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        logger.debug("Cleaned JSON length: \(cleaned.count) characters")

        guard let data = cleaned.data(using: .utf8) else {
            logger.error("Failed to convert cleaned JSON string to data")
            throw AnalysisError.invalidResponse
        }
        
        let decoder = JSONDecoder()
        
        do {
            let llmResponse = try decoder.decode(LLMResponse.self, from: data)
            
            // Convert LLM response to DTO
            return NoteAnalysisDTO(
                summary: llmResponse.summary,
                people: llmResponse.people.map { person in
                    PersonMentionDTO(
                        name: person.name,
                        role: person.role,
                        relationshipTo: person.relationship_to,
                        contactUpdates: person.contact_updates.map { update in
                            ContactUpdateDTO(
                                field: update.field,
                                value: update.value,
                                confidence: update.confidence
                            )
                        },
                        confidence: person.confidence
                    )
                },
                topics: llmResponse.topics,
                actionItems: llmResponse.action_items.map { action in
                    ActionItemDTO(
                        type: action.type,
                        description: action.description,
                        suggestedText: action.suggested_text,
                        suggestedChannel: action.suggested_channel,
                        urgency: action.urgency,
                        personName: action.person_name
                    )
                },
                analysisVersion: Self.currentAnalysisVersion
            )
        } catch {
            logger.error("JSON parsing failed. First 500 chars: \(String(cleaned.prefix(500)))")
            throw error
        }
    }
}

// MARK: - LLM Response Types (internal)

private struct LLMResponse: Codable {
    let summary: String?
    let people: [LLMPerson]
    let topics: [String]
    let action_items: [LLMActionItem]
}

private struct LLMPerson: Codable {
    let name: String
    let role: String?
    let relationship_to: String?
    let contact_updates: [LLMContactUpdate]
    let confidence: Double
}

private struct LLMContactUpdate: Codable {
    let field: String
    let value: String
    let confidence: Double
}

private struct LLMActionItem: Codable {
    let type: String
    let description: String
    let suggested_text: String?
    let suggested_channel: String?
    let person_name: String?
    let urgency: String
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
