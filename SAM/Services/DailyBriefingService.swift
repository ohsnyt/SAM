//
//  DailyBriefingService.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Daily Briefing System
//
//  Actor-isolated service for generating morning/evening narrative prose
//  via AIService. Produces two variants per call: visual (data-dense)
//  and TTS (conversational, future use).
//

import Foundation
import os.log

actor DailyBriefingService {

    // MARK: - Singleton

    static let shared = DailyBriefingService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DailyBriefingService")

    private init() {}

    // MARK: - Morning Narrative

    /// Generate a morning briefing narrative from structured sections.
    /// Returns (visual, tts) — both empty if AI unavailable.
    func generateMorningNarrative(
        calendarItems: [BriefingCalendarItem],
        priorityActions: [BriefingAction],
        followUps: [BriefingFollowUp],
        lifeEvents: [BriefingLifeEvent],
        tomorrowPreview: [BriefingCalendarItem],
        goalProgress: [GoalProgress] = []
    ) async -> (visual: String, tts: String) {
        // Guard: require meaningful data to prevent hallucination.
        // A single sparse section (e.g. one stale action) is not enough context
        // for the model to produce a grounded narrative.
        let sectionCount = [
            !calendarItems.isEmpty,
            !priorityActions.isEmpty,
            !followUps.isEmpty,
            !lifeEvents.isEmpty,
            !goalProgress.isEmpty
        ].filter { $0 }.count
        let totalItems = calendarItems.count + priorityActions.count
            + followUps.count + lifeEvents.count + goalProgress.count
        guard sectionCount >= 2 || totalItems >= 3 else {
            logger.debug("Insufficient briefing data (\(sectionCount) sections, \(totalItems) items) — skipping narrative to prevent hallucination")
            return ("", "")
        }

        let availability = await AIService.shared.checkAvailability()
        guard case .available = availability else {
            logger.debug("AI unavailable — skipping morning narrative")
            return ("", "")
        }

        let dataBlock = buildMorningDataBlock(
            calendarItems: calendarItems,
            priorityActions: priorityActions,
            followUps: followUps,
            lifeEvents: lifeEvents,
            tomorrowPreview: tomorrowPreview,
            goalProgress: goalProgress
        )

        // Use Prompt Lab deployed variant if available, otherwise fall back to default
        let deployedSystemPrompt = UserDefaults.standard.string(forKey: "sam.promptLab.morningBriefing") ?? ""

        let visualPrompt: String
        let visualSystem: String

        if !deployedSystemPrompt.isEmpty {
            // Prompt Lab custom variant is deployed — use it as the system instruction
            visualPrompt = dataBlock
            visualSystem = deployedSystemPrompt
        } else {
            let persona = await BusinessProfileService.shared.personaFragment()
            visualPrompt = """
                You are a warm, professional executive assistant for \(persona).
                Write a concise morning briefing (150 words or less) based ONLY on the data below.

                CRITICAL: Only reference people, meetings, times, and goals that appear in the data.
                Never invent names, events, or details. If a section is missing, skip it.

                Structure:
                1. First 1-2 sentences: overview of the day based ONLY on data present. If TODAY'S CALENDAR is empty, say the calendar is open — NEVER invent meetings or times.
                2. Create a new paragraph and present (with a maximum of 80 words) a suggested plan for what to tackle based on information from the priority actions and follow-ups.
                3. If there are business goals, create a new sentence to mention the most relevant one.

                Include exact times, full names, and specific details from the data. Be data-dense but readable.
                NEVER fabricate meetings, times, or events that do not appear in the data.
                Use a confident, forward-looking tone. No greetings or sign-offs.

                \(dataBlock)
                """
            visualSystem = "Respond with ONLY the narrative paragraph. No headers, bullets, or formatting."
        }

        // TTS narrative
        let ttsPrompt = """
            You are a warm, professional executive assistant briefing your boss verbally.
            Write a short spoken briefing (2-3 sentences) based ONLY on the data below.
            Only reference people, meetings, and details that appear in the data. Never invent anything.
            Include what's coming up first and the most important action for the next few hours.
            Use conversational transitions ("First up...", "Also worth noting...").
            Round numbers ("about a dozen" instead of "12"), use relative times ("in a couple hours").
            Keep sentences short and clear for audio delivery.

            \(dataBlock)
            """

        let ttsSystem = "Respond with ONLY the spoken narrative. No formatting, headers, or brackets."

        do {
            async let visualResult = AIService.shared.generateNarrative(prompt: visualPrompt, systemInstruction: visualSystem)
            async let ttsResult = AIService.shared.generateNarrative(prompt: ttsPrompt, systemInstruction: ttsSystem)

            let visual = try await visualResult
            let tts = try await ttsResult

            return (visual, tts)
        } catch {
            logger.warning("Morning narrative generation failed: \(error.localizedDescription)")
            return ("", "")
        }
    }

    // MARK: - Evening Narrative

    /// Generate an evening recap narrative from accomplishments and metrics.
    /// Returns (visual, tts) — both empty if AI unavailable.
    func generateEveningNarrative(
        accomplishments: [BriefingAccomplishment],
        streakUpdates: [BriefingStreakUpdate],
        metrics: BriefingMetrics,
        tomorrowHighlights: [BriefingCalendarItem]
    ) async -> (visual: String, tts: String) {
        // Guard: require meaningful data to prevent hallucination
        let totalItems = accomplishments.count + streakUpdates.count + tomorrowHighlights.count
        guard totalItems >= 2 else {
            logger.debug("Insufficient evening data (\(totalItems) items) — skipping narrative to prevent hallucination")
            return ("", "")
        }

        let availability = await AIService.shared.checkAvailability()
        guard case .available = availability else {
            logger.debug("AI unavailable — skipping evening narrative")
            return ("", "")
        }

        let dataBlock = buildEveningDataBlock(
            accomplishments: accomplishments,
            streakUpdates: streakUpdates,
            metrics: metrics,
            tomorrowHighlights: tomorrowHighlights
        )

        // Use Prompt Lab deployed variant if available, otherwise fall back to default
        let deployedEveningPrompt = UserDefaults.standard.string(forKey: "sam.promptLab.eveningBriefing") ?? ""

        let visualPrompt: String
        let visualSystem: String

        if !deployedEveningPrompt.isEmpty {
            visualPrompt = dataBlock
            visualSystem = deployedEveningPrompt
        } else {
            let persona = await BusinessProfileService.shared.personaFragment()
            visualPrompt = """
                You are a warm, professional executive assistant summarizing the day for \(persona).
                Write a concise end-of-day summary (3-5 sentences) based ONLY on the data below.

                CRITICAL: Only reference accomplishments, metrics, and events that appear in the data.
                Never invent names or details. If a section is missing, skip it.

                Celebrate accomplishments. Note key metrics. Preview tomorrow. Be encouraging but honest.

                Respond with ONLY the narrative paragraph. No headers, bullets, or formatting.

                \(dataBlock)
                """
            visualSystem = "Respond with ONLY the narrative paragraph. No headers, bullets, or formatting."
        }

        let ttsPrompt = """
            You are a warm, professional executive assistant giving a spoken evening summary.
            Write a short recap (2-3 sentences) based ONLY on the data below. Never invent details.
            Highlight accomplishments and tomorrow's plan.
            Use conversational, encouraging tone with short sentences for audio delivery.

            \(dataBlock)
            """

        let ttsSystem = "Respond with ONLY the spoken narrative. No formatting, headers, or brackets."

        do {
            async let visualResult = AIService.shared.generateNarrative(prompt: visualPrompt, systemInstruction: visualSystem)
            async let ttsResult = AIService.shared.generateNarrative(prompt: ttsPrompt, systemInstruction: ttsSystem)

            let visual = try await visualResult
            let tts = try await ttsResult
            return (visual, tts)
        } catch {
            logger.warning("Evening narrative generation failed: \(error.localizedDescription)")
            return ("", "")
        }
    }

    // MARK: - Data Block Builders

    private func buildMorningDataBlock(
        calendarItems: [BriefingCalendarItem],
        priorityActions: [BriefingAction],
        followUps: [BriefingFollowUp],
        lifeEvents: [BriefingLifeEvent],
        tomorrowPreview: [BriefingCalendarItem],
        goalProgress: [GoalProgress] = []
    ) -> String {
        var parts: [String] = []

        let now = Date()
        let currentTime = now.formatted(date: .omitted, time: .shortened)
        parts.append("CURRENT TIME: \(currentTime)")

        // Filter out events that have already ended
        let upcomingItems = calendarItems.filter { item in
            if let endTime = item.endsAt {
                return endTime > now
            }
            // No end time — include if start is today or later
            return item.startsAt > now
        }

        if !upcomingItems.isEmpty {
            let items = upcomingItems.map { item in
                let start = item.startsAt.formatted(date: .omitted, time: .shortened)
                let end = item.endsAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
                let timeRange = end.isEmpty ? start : "\(start)–\(end)"
                let attendees = item.attendeeNames.isEmpty ? "" : " with \(item.attendeeNames.joined(separator: ", "))"
                return "- \(timeRange): \(item.eventTitle)\(attendees)"
            }.joined(separator: "\n")
            parts.append("TODAY'S SCHEDULE (\(upcomingItems.count) upcoming events):\n\(items)")
        }

        if !priorityActions.isEmpty {
            let items = priorityActions.prefix(5).map { action in
                let person = action.personName.map { " (\($0))" } ?? ""
                return "- [\(action.urgency)] \(action.title)\(person)"
            }.joined(separator: "\n")
            parts.append("PRIORITY ACTIONS:\n\(items)")
        }

        if !followUps.isEmpty {
            let items = followUps.prefix(3).map {
                "- \($0.personName): \($0.reason) (\($0.daysSinceInteraction) days)"
            }.joined(separator: "\n")
            parts.append("FOLLOW-UPS NEEDED:\n\(items)")
        }

        if !lifeEvents.isEmpty {
            let items = lifeEvents.map { "- \($0.personName): \($0.eventDescription)" }.joined(separator: "\n")
            parts.append("LIFE EVENTS:\n\(items)")
        }

        if !goalProgress.isEmpty {
            let items = goalProgress.map { gp in
                let pctStr = String(format: "%.0f", gp.percentComplete * 100)
                let rateStr = briefingGoalRateText(gp)
                return "- \(gp.goalType.displayName): \(Int(gp.currentValue))/\(Int(gp.targetValue)) (\(pctStr)%, \(gp.pace.displayName), \(gp.daysRemaining)d left, \(rateStr))"
            }.joined(separator: "\n")
            parts.append("BUSINESS GOALS:\n\(items)")
        }

        // Gap answers context (user-provided knowledge) — read directly from UserDefaults
        let gapContext = Self.readGapAnswers()
        if !gapContext.isEmpty {
            parts.append("USER CONTEXT:\n\(gapContext)")
        }

        if !tomorrowPreview.isEmpty {
            let items = tomorrowPreview.prefix(3).map { item in
                let time = item.startsAt.formatted(date: .omitted, time: .shortened)
                return "- \(time): \(item.eventTitle)"
            }.joined(separator: "\n")
            parts.append("TOMORROW PREVIEW:\n\(items)")
        }

        return parts.isEmpty ? "No significant items for today." : parts.joined(separator: "\n\n")
    }

    private func buildEveningDataBlock(
        accomplishments: [BriefingAccomplishment],
        streakUpdates: [BriefingStreakUpdate],
        metrics: BriefingMetrics,
        tomorrowHighlights: [BriefingCalendarItem]
    ) -> String {
        var parts: [String] = []

        parts.append("TODAY'S METRICS: \(metrics.meetingCount) meetings, \(metrics.notesTakenCount) notes, \(metrics.outcomesCompletedCount) outcomes completed, \(metrics.emailsProcessedCount) emails processed")

        if !accomplishments.isEmpty {
            let items = accomplishments.map { "- \($0.title)" }.joined(separator: "\n")
            parts.append("ACCOMPLISHMENTS:\n\(items)")
        }

        if !streakUpdates.isEmpty {
            let items = streakUpdates.map { update in
                let record = update.isNewRecord ? " (NEW RECORD!)" : ""
                return "- \(update.streakName): \(update.currentCount)\(record)"
            }.joined(separator: "\n")
            parts.append("STREAKS:\n\(items)")
        }

        if !tomorrowHighlights.isEmpty {
            let items = tomorrowHighlights.prefix(3).map { item in
                let time = item.startsAt.formatted(date: .omitted, time: .shortened)
                return "- \(time): \(item.eventTitle)"
            }.joined(separator: "\n")
            parts.append("TOMORROW:\n\(items)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Gap Answers

    /// Read user-provided knowledge gap answers from UserDefaults.
    /// Matches the same keys used by OutcomeEngine.gapAnswersContext().
    private static func readGapAnswers() -> String {
        let defaults = UserDefaults.standard
        let gapKeys = [
            ("sam.gap.referralSources", "Known referral sources"),
            ("sam.gap.contentTopics", "Audience topics of interest"),
            ("sam.gap.associations", "Professional groups/associations"),
        ]

        var parts: [String] = []
        for (key, label) in gapKeys {
            if let answer = defaults.string(forKey: key), !answer.isEmpty {
                parts.append("\(label): \(answer)")
            }
        }

        return parts.isEmpty ? "" : parts.joined(separator: "\n")
    }

    // MARK: - Goal Rate Guardrails

    /// Format goal rate for briefing with guardrails against absurd daily numbers.
    private func briefingGoalRateText(_ gp: GoalProgress) -> String {
        let remaining = max(gp.targetValue - gp.currentValue, 0)
        let days = Double(max(gp.daysRemaining, 1))
        let perDay = remaining / days
        let perWeek = remaining / (days / 7.0)
        let perMonth = remaining / (days / 30.0)

        let format: (Double) -> String = { val in
            val == val.rounded() ? String(format: "%.0f", val) : String(format: "%.1f", val)
        }

        // Per-type reasonable daily maximums
        let reasonableDailyMax: Double
        let reasonableWeeklyMax: Double
        switch gp.goalType {
        case .policiesSubmitted: reasonableDailyMax = 5;  reasonableWeeklyMax = 25
        case .newClients:        reasonableDailyMax = 3;  reasonableWeeklyMax = 15
        case .meetingsHeld:      reasonableDailyMax = 5;  reasonableWeeklyMax = 25
        case .productionVolume:  reasonableDailyMax = 50_000; reasonableWeeklyMax = 250_000
        case .recruiting:        reasonableDailyMax = 3;  reasonableWeeklyMax = 15
        case .contentPosts:      reasonableDailyMax = 3;  reasonableWeeklyMax = 15
        case .deepWorkHours:     reasonableDailyMax = 8;  reasonableWeeklyMax = 40
        case .eventsHosted:      reasonableDailyMax = 2;  reasonableWeeklyMax = 5
        }

        if perDay > reasonableDailyMax {
            if perWeek > reasonableWeeklyMax {
                return "need ~\(format(perMonth))/month — significant catch-up needed"
            }
            return "need ~\(format(perWeek))/week"
        }

        if perDay >= 1 {
            return "need \(format(perDay))/day"
        } else if perWeek >= 1 {
            return "need \(format(perWeek))/week"
        } else {
            return "need \(format(perMonth))/month"
        }
    }
}
