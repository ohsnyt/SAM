//
//  GoalCheckInService.swift
//  SAM
//
//  Created on March 17, 2026.
//  Goal Journal: AI service for goal-scoped coaching check-ins.
//
//  Two responsibilities:
//  1. Goal-scoped coaching responses during check-in conversations.
//  2. Post-session summarization into structured GoalJournalEntryDTO.
//

import Foundation
import os.log

actor GoalCheckInService {

    // MARK: - Singleton

    static let shared = GoalCheckInService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GoalCheckInService")

    private init() {}

    // MARK: - Context Block Cache

    private var cachedContextBlock: String?
    private var contextBlockTimestamp: Date?

    /// Returns a cached business context block, refreshing every 5 minutes.
    private func contextBlock() async -> String {
        if let cached = cachedContextBlock,
           let ts = contextBlockTimestamp,
           Date.now.timeIntervalSince(ts) < 300 {
            return cached
        }
        let block = await BusinessProfileService.shared.fullContextBlock()
        cachedContextBlock = block
        contextBlockTimestamp = .now
        return block
    }

    // MARK: - Goal-Scoped Coaching Response

    /// Generate a coaching response within a goal check-in conversation.
    func generateResponse(
        userMessage: String,
        recentHistory: [CoachingMessage],
        context: GoalCheckInContext
    ) async throws -> CoachingMessage {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw CheckInError.modelUnavailable
        }

        let businessCtx = await contextBlock()
        let persona = await BusinessProfileService.shared.personaFragment()
        let calibration = await CalibrationService.shared.calibrationFragment()

        let systemInstruction = buildSystemInstruction(
            context: context,
            businessContext: businessCtx,
            persona: persona,
            calibration: calibration
        )

        // Build conversation context from recent history (last 4 messages)
        let historyWindow = recentHistory.suffix(4)
        var conversationLines: [String] = []
        for msg in historyWindow {
            let role = msg.role == .assistant ? "SAM" : "User"
            conversationLines.append("\(role): \(msg.content)")
        }

        let prompt = """
            Conversation so far:
            \(conversationLines.joined(separator: "\n\n"))

            User: \(userMessage)

            Continue the check-in conversation. Respond directly to what the user said — \
            acknowledge their situation, then ask ONE follow-up question or offer ONE \
            concrete suggestion. Keep it to 2-4 sentences. Do not list multiple questions.

            IMPORTANT: If the user signals the conversation is wrapping up (e.g., "yes thanks", \
            "sounds good", "will do", "that's it", agreement without new topics), close warmly \
            and briefly. Do NOT ask another question or reopen the discussion. A simple encouraging \
            sign-off is perfect.
            """

        let responseText = try await AIService.shared.generateNarrative(
            prompt: prompt,
            systemInstruction: systemInstruction
        )

        let actions = extractActions(from: responseText)

        return CoachingMessage(
            role: .assistant,
            content: responseText,
            actions: actions
        )
    }

    // MARK: - Opening Message

    /// Generate the initial greeting for a goal check-in.
    func generateOpeningMessage(context: GoalCheckInContext) -> CoachingMessage {
        let paceStr = context.progress.pace.displayName.lowercased()
        let currentVal = Int(context.progress.currentValue)
        let targetVal = Int(context.progress.targetValue)
        let daysLeft = context.progress.daysRemaining

        var greeting = "Let's check in on **\(context.goalTitle)**. You're \(paceStr) at \(currentVal)/\(targetVal) with \(daysLeft) days left."

        // Reference last journal entry if available
        if let last = context.previousEntries.first {
            if let strategy = last.adjustedStrategy, !strategy.isEmpty {
                greeting += "\n\nLast time you decided to try: \"\(strategy)\" — how's that going?"
            } else if !last.commitmentActions.isEmpty {
                let actions = last.commitmentActions.prefix(2).joined(separator: " and ")
                greeting += "\n\nLast check-in you committed to: \(actions). How did that work out?"
            } else {
                greeting += "\n\nWhat's been working for you? What hasn't?"
            }
        } else {
            greeting += "\n\nThis is your first check-in for this goal. What's been working so far? What obstacles are you running into?"
        }

        return CoachingMessage(role: .assistant, content: greeting)
    }

    // MARK: - Post-Session Summarization

    /// Summarize a check-in conversation into a structured journal entry.
    func summarizeSession(
        messages: [CoachingMessage],
        context: GoalCheckInContext
    ) async throws -> GoalJournalEntryDTO {
        let userTurnCount = messages.filter { $0.role == .user }.count

        // Build conversation transcript for summarization
        let transcript = messages.map { msg in
            let role = msg.role == .assistant ? "SAM" : "User"
            return "\(role): \(msg.content)"
        }.joined(separator: "\n\n")

        let systemInstruction = """
            Extract structured learnings from this goal check-in conversation. \
            Respond ONLY with valid JSON (no markdown fencing). Use this exact format:
            {
              "headline": "One-line summary of this check-in",
              "whats_working": ["strategy 1", "strategy 2"],
              "whats_not_working": ["strategy 1"],
              "barriers": ["obstacle 1"],
              "adjusted_strategy": "New approach decided, or null if none",
              "key_insight": "Single most important takeaway, or null",
              "commitment_actions": ["specific next action 1", "specific next action 2"]
            }

            Rules:
            - Extract only what was actually discussed, never fabricate
            - Keep each item concise (one sentence max)
            - If a field has no content from the conversation, use an empty array or null
            - The headline should capture the essence of what was decided
            """

        let prompt = """
            Goal: \(context.goalTitle) (\(context.goalType.displayName))
            Progress: \(Int(context.progress.currentValue))/\(Int(context.progress.targetValue)), \
            \(context.progress.pace.displayName), \(context.progress.daysRemaining) days left

            Conversation:
            \(transcript)
            """

        // Try AI extraction
        if case .available = await AIService.shared.checkAvailability() {
            do {
                let responseText = try await AIService.shared.generateNarrative(
                    prompt: prompt,
                    systemInstruction: systemInstruction,
                    maxTokens: 512
                )

                if let dto = parseJournalJSON(
                    responseText,
                    context: context,
                    turnCount: userTurnCount
                ) {
                    return dto
                }
                logger.warning("JSON parsing failed for journal summarization, using fallback")
            } catch {
                logger.warning("AI summarization failed: \(error.localizedDescription), using fallback")
            }
        }

        // Fallback: populate headline from first user message
        let firstUserMsg = messages.first(where: { $0.role == .user })?.content ?? "Check-in"
        let truncatedHeadline = String(firstUserMsg.prefix(100))

        return GoalJournalEntryDTO(
            goalID: context.goalID,
            goalTypeRawValue: context.goalType.rawValue,
            headline: truncatedHeadline,
            paceAtCheckInRawValue: context.progress.pace.rawValue,
            progressAtCheckIn: context.progress.percentComplete,
            conversationTurnCount: userTurnCount
        )
    }

    // MARK: - Private Helpers

    private func buildSystemInstruction(
        context: GoalCheckInContext,
        businessContext: String,
        persona: String,
        calibration: String
    ) -> String {
        var parts: [String] = []

        parts.append("""
            You are SAM, a goal coaching assistant for \(persona). \
            You're having a casual check-in conversation about a specific business goal.

            CONVERSATION RULES:
            - Respond to what the user actually said. Acknowledge their situation first, then go deeper on ONE thread.
            - Ask at most ONE follow-up question per response. Never ask multiple questions.
            - Keep responses to 2-4 sentences. This is a conversation, not an interview.
            - Stay focused on the goal topic. Don't ask about unrelated business metrics or scheduling.
            - Offer a concrete suggestion or reframe when appropriate, not just questions.
            - Be warm and direct, like a trusted colleague checking in over coffee.
            """)

        parts.append("""
            GOAL CONTEXT:
            Title: \(context.goalTitle)
            Type: \(context.goalType.displayName)
            Progress: \(Int(context.progress.currentValue))/\(Int(context.progress.targetValue)) \
            (\(String(format: "%.0f", context.progress.percentComplete * 100))%)
            Pace: \(context.progress.pace.displayName)
            Days remaining: \(context.progress.daysRemaining)
            """)

        // Previous journal entries
        if !context.previousEntries.isEmpty {
            var journalLines: [String] = ["PREVIOUS CHECK-IN LEARNINGS:"]
            for entry in context.previousEntries.prefix(3) {
                let dateStr = entry.createdAt.formatted(date: .abbreviated, time: .omitted)
                journalLines.append("  \(dateStr) (\(entry.paceAtCheckIn.displayName)):")
                journalLines.append("    Headline: \(entry.headline)")
                if !entry.whatsWorking.isEmpty {
                    journalLines.append("    Working: \(entry.whatsWorking.joined(separator: ", "))")
                }
                if !entry.whatsNotWorking.isEmpty {
                    journalLines.append("    Not working: \(entry.whatsNotWorking.joined(separator: ", "))")
                }
                if !entry.barriers.isEmpty {
                    journalLines.append("    Barriers: \(entry.barriers.joined(separator: ", "))")
                }
                if let strategy = entry.adjustedStrategy {
                    journalLines.append("    Adjusted strategy: \(strategy)")
                }
                if !entry.commitmentActions.isEmpty {
                    journalLines.append("    Committed to: \(entry.commitmentActions.joined(separator: ", "))")
                }
            }
            parts.append(journalLines.joined(separator: "\n"))
        }

        // Goal-type-specific coaching prompts
        parts.append(goalTypeCoachingPrompt(context.goalType))

        if !businessContext.isEmpty {
            parts.append(businessContext)
        }

        if !calibration.isEmpty {
            parts.append(calibration)
        }

        parts.append("""
            CONVERSATION ARC (spread across multiple turns, not all at once):
            Early turns: understand what's happening and what's blocking progress.
            Middle turns: explore one obstacle or opportunity in depth.
            Later turns: help the user land on a specific adjustment or commitment.
            """)

        return parts.joined(separator: "\n\n")
    }

    private func goalTypeCoachingPrompt(_ type: GoalType) -> String {
        switch type {
        case .recruiting:
            return "COACHING FOCUS: Ask about mentoring cadence with current recruits, licensing progress, what's attracting candidates, warm vs cold outreach results."
        case .newClients:
            return "COACHING FOCUS: Ask about pipeline quality, lead sources that are converting, follow-up cadence, what's getting prospects to commit."
        case .contentPosts:
            return "COACHING FOCUS: Ask about engagement rates, which topics resonate, posting consistency, what's blocking content creation."
        case .roleFilling:
            return "COACHING FOCUS: Ask about candidate quality, what profiles are succeeding, sourcing channels, interview conversion rates."
        case .policiesSubmitted:
            return "COACHING FOCUS: Ask about application completion bottlenecks, carrier turnaround, client decision timing."
        case .productionVolume:
            return "COACHING FOCUS: Ask about average case size, product mix, which client segments are most productive."
        case .meetingsHeld:
            return "COACHING FOCUS: Ask about meeting quality vs quantity, no-show rates, scheduling efficiency, which meeting types drive results."
        case .deepWorkHours:
            return "COACHING FOCUS: Ask about time blocking discipline, interruption patterns, what deep work activities have the highest ROI."
        case .eventsHosted:
            return "COACHING FOCUS: Ask about attendance rates, event formats that work, promotion strategies, post-event follow-up."
        }
    }

    private func extractActions(from text: String) -> [CoachingAction] {
        var actions: [CoachingAction] = []
        let lowered = text.lowercased()

        if lowered.contains("send a message") || lowered.contains("reach out") || lowered.contains("email") || lowered.contains("follow up with") {
            actions.append(CoachingAction(label: "Compose Message", actionType: .composeMessage))
        }
        if lowered.contains("draft a post") || lowered.contains("create content") || lowered.contains("social media") || lowered.contains("write a post") {
            actions.append(CoachingAction(label: "Draft Content", actionType: .draftContent))
        }
        if lowered.contains("schedule a meeting") || lowered.contains("book time") || lowered.contains("set up a call") || lowered.contains("block time") {
            actions.append(CoachingAction(label: "Schedule Event", actionType: .scheduleEvent))
        }
        if lowered.contains("take notes") || lowered.contains("document") || lowered.contains("write down") || lowered.contains("capture") {
            actions.append(CoachingAction(label: "Create Note", actionType: .createNote))
        }

        return actions
    }

    private func parseJournalJSON(
        _ text: String,
        context: GoalCheckInContext,
        turnCount: Int
    ) -> GoalJournalEntryDTO? {
        // Strip markdown fencing if present
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = cleaned.data(using: .utf8) else { return nil }

        struct JournalExtraction: Decodable {
            let headline: String?
            let whats_working: [String]?
            let whats_not_working: [String]?
            let barriers: [String]?
            let adjusted_strategy: String?
            let key_insight: String?
            let commitment_actions: [String]?
        }

        guard let parsed = try? JSONDecoder().decode(JournalExtraction.self, from: data) else {
            return nil
        }

        return GoalJournalEntryDTO(
            goalID: context.goalID,
            goalTypeRawValue: context.goalType.rawValue,
            headline: parsed.headline ?? "Check-in",
            whatsWorking: parsed.whats_working ?? [],
            whatsNotWorking: parsed.whats_not_working ?? [],
            barriers: parsed.barriers ?? [],
            adjustedStrategy: parsed.adjusted_strategy,
            keyInsight: parsed.key_insight,
            commitmentActions: parsed.commitment_actions ?? [],
            paceAtCheckInRawValue: context.progress.pace.rawValue,
            progressAtCheckIn: context.progress.percentComplete,
            conversationTurnCount: turnCount
        )
    }

    // MARK: - Errors

    enum CheckInError: Error, LocalizedError {
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .modelUnavailable: return "AI model is not available"
            }
        }
    }
}
