//
//  CoachingPlannerService.swift
//  SAM
//
//  Created on February 27, 2026.
//  Strategic Action Coaching Flow — Phase C
//
//  Actor service that manages AI interactions for the coaching chat session.
//  Uses bounded context windows for reliable on-device inference.
//

import Foundation
import os.log

actor CoachingPlannerService {

    // MARK: - Singleton

    static let shared = CoachingPlannerService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CoachingPlannerService")

    private init() {}

    // MARK: - Initial Plan Generation

    /// Generate the initial detailed plan based on the selected approach.
    func generateInitialPlan(context: CoachingSessionContext) async throws -> CoachingMessage {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        // Load relevant best practices for this recommendation category
        await BestPracticesService.shared.loadIfNeeded()
        let practices = await BestPracticesService.shared.practices(
            for: context.recommendation.category,
            limit: 3
        )
        let businessCtx = await BusinessProfileService.shared.fullContextBlock()

        let systemInstruction = buildSystemInstruction(context: context, practices: practices, businessContext: businessCtx)

        let prompt: String
        if let approach = context.approach {
            prompt = """
                The user wants to implement the following strategic recommendation using this approach:

                Recommendation: \(context.recommendation.title)
                Rationale: \(context.recommendation.rationale)

                Chosen Approach: \(approach.title)
                \(approach.summary)
                High-level steps: \(approach.steps.joined(separator: ", "))

                Create a detailed, actionable plan using ONLY the actions listed in your constraints. \
                For each step, name the specific action (send a message, schedule a meeting, \
                draft a post, review data in SAM, create a note, etc.) and who it involves. \
                If relevant, reference the best practices provided. \
                Do not suggest researching new tools, hiring help, or purchasing services.
                """
        } else {
            prompt = """
                The user wants help implementing this strategic recommendation:

                Recommendation: \(context.recommendation.title)
                Rationale: \(context.recommendation.rationale)

                Suggest 2-3 concrete approaches the user could take, with specific steps for each. \
                Every step must be an action the user can take right now using SAM, their phone, \
                their existing contacts, or their upline. Name specific actions and people. \
                If relevant, reference the best practices provided. \
                Do not suggest researching new tools, hiring help, or purchasing services.
                """
        }

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

    // MARK: - Follow-up Response

    /// Generate a response to a user message within the coaching conversation.
    func generateResponse(
        userMessage: String,
        recentHistory: [CoachingMessage],
        context: CoachingSessionContext
    ) async throws -> CoachingMessage {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        // Load relevant best practices
        await BestPracticesService.shared.loadIfNeeded()
        let practices = await BestPracticesService.shared.practices(
            for: context.recommendation.category,
            limit: 3
        )
        let businessCtx = await BusinessProfileService.shared.fullContextBlock()

        let systemInstruction = buildSystemInstruction(context: context, practices: practices, businessContext: businessCtx)

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

            Continue the planning conversation. Provide helpful, concrete advice \
            using ONLY the actions listed in your constraints (messaging, scheduling, \
            content drafting, note-taking, reviewing SAM data, consulting upline). \
            Name the person and action clearly. \
            Do not suggest researching new tools, hiring help, or purchasing services.
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

    // MARK: - Private Helpers

    /// Build the system instruction with bounded context and constraints.
    private func buildSystemInstruction(context: CoachingSessionContext, practices: [BestPractice] = [], businessContext: String = "") -> String {
        var instruction = """
            You are SAM, a strategic coaching assistant for an independent financial strategist. \
            You help plan and implement business strategies using \
            ONLY the tools and capabilities available to the user right now.

            \(businessContext)

            ACTIONS YOU MAY SUGGEST:
            • Compose messages to specific people (leads, clients, agents, upline) via iMessage, email, or phone
            • Draft educational social media content for Facebook or LinkedIn
            • Schedule meetings, deep work blocks, or follow-up calls
            • Review existing data in SAM (pipeline status, relationship notes, interaction history)
            • Reach out to upline supervisor, trainer, or field coach for guidance
            • Visit specific places to meet prospects (community events, networking groups, local businesses, online forums)
            • Suggest opening lines, conversation topics, and talking points for meetings or outreach
            • Review recent posts or messaging patterns for improvement opportunities
            • Create notes to capture plans, ideas, or meeting prep

            DO NOT SUGGEST:
            • Researching, purchasing, or integrating new software or tools
            • Hiring consultants, assistants, or IT professionals
            • Building websites, apps, or technical systems
            • Purchasing advertising or marketing services
            • Any action requiring tools the user does not already have

            Be practical, specific, and action-oriented. Name real actions: \
            "Send a message to [person]", "Schedule a 30-minute block to...", \
            "Draft a LinkedIn post about...". Keep responses focused and concise.

            Current recommendation: \(context.recommendation.title)
            Category: \(context.recommendation.category)
            Rationale: \(context.recommendation.rationale)
            """

        if let approach = context.approach {
            instruction += "\n\nSelected approach: \(approach.title)\n\(approach.summary)"
        }

        if !context.businessSnapshot.isEmpty {
            instruction += "\n\nBusiness context:\n\(context.businessSnapshot)"
        }

        // Inject relevant best practices
        if !practices.isEmpty {
            instruction += "\n\nRELEVANT BEST PRACTICES (reference these in your advice):"
            for practice in practices {
                instruction += "\n• \(practice.title): \(practice.description)"
            }
        }

        return instruction
    }

    /// Extract actionable items from AI response text using keyword matching.
    private func extractActions(from text: String) -> [CoachingAction] {
        var actions: [CoachingAction] = []
        let lowered = text.lowercased()

        // Look for message/email/outreach patterns
        if lowered.contains("send a message") || lowered.contains("reach out") || lowered.contains("email") || lowered.contains("follow up with") {
            actions.append(CoachingAction(
                label: "Compose Message",
                actionType: .composeMessage
            ))
        }

        // Look for content/post patterns
        if lowered.contains("draft a post") || lowered.contains("create content") || lowered.contains("social media") || lowered.contains("write a post") {
            actions.append(CoachingAction(
                label: "Draft Content",
                actionType: .draftContent
            ))
        }

        // Look for scheduling patterns
        if lowered.contains("schedule a meeting") || lowered.contains("book time") || lowered.contains("set up a call") || lowered.contains("block time") {
            actions.append(CoachingAction(
                label: "Schedule Event",
                actionType: .scheduleEvent
            ))
        }

        // Look for note/document patterns
        if lowered.contains("take notes") || lowered.contains("document") || lowered.contains("write down") || lowered.contains("capture") {
            actions.append(CoachingAction(
                label: "Create Note",
                actionType: .createNote
            ))
        }

        // Look for review/pipeline/data patterns
        if lowered.contains("review your pipeline") || lowered.contains("check your pipeline") || lowered.contains("look at your") || lowered.contains("review your data") || lowered.contains("review data in sam") {
            actions.append(CoachingAction(
                label: "Review Pipeline",
                actionType: .reviewPipeline
            ))
        }

        // Look for upline/mentor consultation patterns
        if lowered.contains("upline") || lowered.contains("field trainer") || lowered.contains("field coach") || lowered.contains("your trainer") || lowered.contains("your supervisor") {
            actions.append(CoachingAction(
                label: "Contact Upline",
                actionType: .composeMessage,
                metadata: ["personName": "Upline"]
            ))
        }

        return actions
    }
}
