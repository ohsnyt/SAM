//
//  LifeEventCoachingService.swift
//  SAM
//
//  Created on February 27, 2026.
//  Life Event Coaching — Phase H
//
//  Actor service that manages AI interactions for life event coaching sessions.
//  Produces event-type-calibrated prompts (empathy for loss, celebration for
//  milestones, transition support for job changes) and extracts actionable items.
//

import Foundation
import os.log

actor LifeEventCoachingService {

    // MARK: - Singleton

    static let shared = LifeEventCoachingService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LifeEventCoachingService")

    private init() {}

    // MARK: - Initial Coaching

    /// Generate the initial coaching message for a life event.
    func generateInitialCoaching(context: LifeEventCoachingContext) async throws -> CoachingMessage {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let systemInstruction = buildSystemInstruction(context: context)

        let prompt = """
            The user has a life event to respond to:

            Person: \(context.personName)
            Event: \(eventLabel(for: context.event.eventType))
            Details: \(context.event.eventDescription)
            \(context.event.approximateDate.map { "Approximate date: \($0)" } ?? "")

            Provide 2-3 specific, actionable ideas for how the user should respond to this \
            life event. For each idea, include:
            1. A concrete first step (e.g., "Send this message: ...")
            2. A suggested message draft the user can send as-is or customize
            3. A follow-up action if appropriate

            Be warm, specific, and practical. The user should be able to act immediately \
            on at least one suggestion.
            """

        let responseText = try await AIService.shared.generateNarrative(
            prompt: prompt,
            systemInstruction: systemInstruction
        )

        let actions = extractActions(from: responseText, context: context)

        return CoachingMessage(
            role: .assistant,
            content: responseText,
            actions: actions
        )
    }

    // MARK: - Follow-up Response

    /// Generate a response to a user message within the life event coaching conversation.
    func generateResponse(
        userMessage: String,
        recentHistory: [CoachingMessage],
        context: LifeEventCoachingContext
    ) async throws -> CoachingMessage {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let systemInstruction = buildSystemInstruction(context: context)

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

            Continue helping the user think through their response to this life event. \
            Provide specific message drafts, talking points, or action steps they can use. \
            Be warm and practical. If they ask for a message draft, write one they can \
            send immediately.
            """

        let responseText = try await AIService.shared.generateNarrative(
            prompt: prompt,
            systemInstruction: systemInstruction
        )

        let actions = extractActions(from: responseText, context: context)

        return CoachingMessage(
            role: .assistant,
            content: responseText,
            actions: actions
        )
    }

    // MARK: - System Instruction

    /// Build the system instruction with event-type-calibrated tone.
    private func buildSystemInstruction(context: LifeEventCoachingContext) -> String {
        let toneGuidance = toneForEventType(context.event.eventType)
        let roleContext = context.personRoles.isEmpty
            ? "a contact"
            : context.personRoles.joined(separator: ", ")

        var instruction = """
            You are SAM, a relationship coaching assistant for an independent financial \
            strategist at World Financial Group. You are helping the user respond to a \
            life event involving \(context.personName), who is \(roleContext).

            LIFE EVENT: \(eventLabel(for: context.event.eventType))
            DETAILS: \(context.event.eventDescription)
            \(context.event.approximateDate.map { "APPROXIMATE DATE: \($0)" } ?? "")

            TONE AND APPROACH:
            \(toneGuidance)

            ACTIONS YOU MAY SUGGEST:
            • Send a personal message (iMessage, email, or handwritten card)
            • Schedule a meeting or call to check in
            • Create a note to capture ideas or talking points
            • Draft a social media congratulations (if appropriate and public)
            • Suggest a thoughtful gesture (gift, flowers, meal delivery)
            • Offer to review their financial coverage when the timing is right
            • Recommend connecting them with a relevant resource or referral

            DO NOT SUGGEST:
            • Immediately pivoting to a sales pitch for sensitive events (loss, health)
            • Researching, purchasing, or integrating new software
            • Generic platitudes without specific actions
            • Anything that feels tone-deaf to the situation

            Be warm, specific, and relationship-aware. When suggesting a message, provide \
            a complete draft the user can send as-is or customize. Name specific actions: \
            "Send this message via iMessage", "Schedule a 15-minute call", "Write a note \
            with these talking points".
            """

        if !context.relationshipSummary.isEmpty {
            instruction += "\n\nRELATIONSHIP CONTEXT:\n\(context.relationshipSummary)"
        }

        if let suggestion = context.event.outreachSuggestion, !suggestion.isEmpty {
            instruction += "\n\nEXISTING OUTREACH SUGGESTION (from earlier analysis):\n\(suggestion)"
        }

        return instruction
    }

    // MARK: - Tone Calibration

    /// Returns tone guidance appropriate for the event type.
    private func toneForEventType(_ eventType: String) -> String {
        switch eventType {
        case "loss", "health_issue":
            return """
                This is a sensitive situation. Lead with empathy and genuine care. \
                Do NOT suggest business conversations, coverage reviews, or financial planning \
                in the initial outreach. Focus entirely on emotional support, checking in, \
                and being present. Only after the user has established comfort and the person \
                is ready should you suggest a gentle transition to "making sure everything \
                is in order" — and only if the user explicitly asks about that.
                """
        case "new_baby", "marriage", "graduation", "promotion":
            return """
                This is a celebration! Lead with genuine congratulations and warmth. \
                After the celebratory outreach, it is appropriate to gently suggest that \
                this life change might be a good time for a financial review (new baby = \
                life insurance review, marriage = beneficiary updates, graduation = first \
                job financial planning, promotion = retirement contribution review). Frame \
                this as caring, not selling. Suggest the financial review as a separate, \
                later conversation — not in the congratulatory message itself.
                """
        case "job_change", "retirement", "moving":
            return """
                This is a major life transition. Lead with congratulations and support. \
                These events naturally create financial planning needs: job change = 401k \
                rollover, benefits review; retirement = income planning, Medicare; \
                moving = insurance updates, local referrals. It is appropriate to offer a \
                financial review as a helpful service, framed as "let me help make sure \
                this transition goes smoothly." This can be part of the initial outreach \
                if done warmly.
                """
        case "anniversary":
            return """
                This is a relationship milestone. Lead with warm acknowledgment. If this \
                is a client relationship anniversary, celebrate the partnership. If personal \
                (wedding anniversary), send congratulations. Consider suggesting a thoughtful \
                gesture (card, small gift). A policy review can be gently suggested as a \
                separate conversation.
                """
        default:
            return """
                Respond with warmth and genuine interest. Consider the person's relationship \
                to the user and suggest an appropriate outreach approach that strengthens \
                the relationship.
                """
        }
    }

    // MARK: - Event Type Label

    /// Returns a display-friendly label for the event type, avoiding cross-actor access
    /// to LifeEvent.knownTypes.
    private func eventLabel(for eventType: String) -> String {
        let known: [String: String] = [
            "new_baby": "New Baby",
            "marriage": "Marriage",
            "graduation": "Graduation",
            "job_change": "Job Change",
            "retirement": "Retirement",
            "moving": "Moving",
            "health_issue": "Health Issue",
            "promotion": "Promotion",
            "anniversary": "Anniversary",
            "loss": "Loss",
            "other": "Other"
        ]
        return known[eventType] ?? eventType.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Action Extraction

    /// Extract actionable items from AI response text, pre-populating person metadata.
    private func extractActions(from text: String, context: LifeEventCoachingContext) -> [CoachingAction] {
        var actions: [CoachingAction] = []
        let lowered = text.lowercased()

        // Message/outreach detection
        if lowered.contains("send a message") || lowered.contains("send this message")
            || lowered.contains("reach out") || lowered.contains("text them")
            || lowered.contains("email them") || lowered.contains("write to")
            || lowered.contains("draft a message") || lowered.contains("imessage")
        {
            actions.append(CoachingAction(
                label: "Send Message to \(context.personName)",
                actionType: .composeMessage,
                metadata: [
                    "personName": context.personName,
                    "personID": context.personID?.uuidString ?? ""
                ]
            ))
        }

        // Schedule meeting/call
        if lowered.contains("schedule") || lowered.contains("set up a call")
            || lowered.contains("book time") || lowered.contains("coffee")
            || lowered.contains("check-in call") || lowered.contains("check in call")
        {
            actions.append(CoachingAction(
                label: "Schedule Meeting",
                actionType: .scheduleEvent,
                metadata: [
                    "title": "\(eventLabel(for: context.event.eventType)) check-in with \(context.personName)",
                    "personName": context.personName
                ]
            ))
        }

        // Note creation
        if lowered.contains("note") || lowered.contains("write down")
            || lowered.contains("talking points") || lowered.contains("jot down")
        {
            actions.append(CoachingAction(
                label: "Create Note",
                actionType: .createNote,
                metadata: [
                    "content": "Life event: \(eventLabel(for: context.event.eventType)) — \(context.personName)\n\(context.event.eventDescription)",
                    "personName": context.personName
                ]
            ))
        }

        // Navigate to person profile
        if lowered.contains("review their profile") || lowered.contains("check their history")
            || lowered.contains("look at their")
        {
            if let personID = context.personID {
                actions.append(CoachingAction(
                    label: "View \(context.personName)",
                    actionType: .navigateToPerson,
                    metadata: ["personID": personID.uuidString]
                ))
            }
        }

        // Social media / content draft
        if lowered.contains("social media") || lowered.contains("linkedin")
            || lowered.contains("facebook") || lowered.contains("public congratulations")
        {
            actions.append(CoachingAction(
                label: "Draft Post",
                actionType: .draftContent
            ))
        }

        return actions
    }
}
