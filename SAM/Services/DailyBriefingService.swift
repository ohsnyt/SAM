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

        // Fetch journal data from MainActor before building the synchronous data block
        let journalBlock = await MainActor.run { () -> String in
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            guard let recentJournal = try? GoalJournalRepository.shared.fetchRecent(limit: 5) else { return "" }
            let recent = recentJournal.filter { $0.createdAt > sevenDaysAgo }
            guard !recent.isEmpty else { return "" }
            let items = recent.map { entry in
                var line = "- \(entry.goalType.displayName) (\(entry.paceAtCheckIn.displayName)): \(entry.headline)"
                if let insight = entry.keyInsight, !insight.isEmpty {
                    line += " — \(insight)"
                }
                return line
            }.joined(separator: "\n")
            return "RECENT GOAL CHECK-INS:\n\(items)"
        }

        let dataBlock = buildMorningDataBlock(
            calendarItems: calendarItems,
            priorityActions: priorityActions,
            followUps: followUps,
            lifeEvents: lifeEvents,
            tomorrowPreview: tomorrowPreview,
            goalProgress: goalProgress,
            recentJournalBlock: journalBlock
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
                Write a morning briefing of 110 to 160 words based ONLY on the data below.
                Shorter than 110 words means you skipped information the advisor needs.

                CRITICAL: Only reference people, meetings, times, dates, and goals that appear in the data.
                Never invent names, events, or details. Use dates exactly as given — if the data says a birthday is today, it is today; do not shift it to yesterday or tomorrow.

                PRONOUN DISCIPLINE — this is non-negotiable:
                - Address the advisor directly as "you" / "your" throughout. Their meetings are "your 10 AM", their goals are "your Q2 target", their calendar is "your day".
                - Do not refer to the advisor in the third person ("the advisor", "Sarah") or the first person ("I", "we", "my"). "we" is banned entirely — the advisor is not attending their own meetings with you.
                - "I" / "my" / "me" is reserved for moments when YOU, the assistant, are doing something for the advisor ("I've pulled up…", "my read is…").
                - For meetings with one other person, write "You meet with Jane Martinez" — never "Jane Martinez and I" and never repeat the other person's name to fill the "I" slot.
                - Tasks the advisor owes belong in passive or subject-first voice, not shared-voice: "Mike Chen is still owed the illustration" or "The illustration for Mike Chen is still owed", not "We need to send Mike Chen the illustration".

                Cover every section present in the data. Do not skip any of these if they appear:
                - TODAY'S SCHEDULE (exact times, full names)
                - PRIORITY ACTIONS (who, what, why it matters now)
                - FOLLOW-UPS NEEDED (person and the reason)
                - LIFE EVENTS (birthdays, new babies, moves — these are relationship moments)
                - BUSINESS GOALS (one sentence on the most relevant one, with current progress)
                - TOMORROW PREVIEW (one short phrase)

                Structure:
                1. Open with 1-2 sentences framing the day — what shape it has, what anchors your calendar.
                2. New paragraph: walk through what to do and why, weaving in priority actions, follow-ups, and life events. Life events are relationship signals worth a sentence — not a bullet.
                3. One sentence on the most relevant business goal and where it stands.
                4. One sentence on tomorrow if TOMORROW PREVIEW is present.

                Voice: confident, forward-looking, collegial. Write to a peer, not as a taskmaster.
                Avoid command-voice openers like "Please ensure" or "Prioritize sending". Good openers: "The day opens with…", "Worth a quick note to Jane…" (always followed by a person's name), "Looking ahead…".
                No greetings, no sign-offs, no bullets, no headers.

                \(dataBlock)
                """
            visualSystem = "Respond with ONLY the narrative paragraph. No headers, bullets, or formatting."
        }

        // TTS narrative is generated but no consumer plays it (no AVSpeechSynthesizer
        // wired up, NarrationService doesn't reference ttsNarrative). Skip it to
        // halve the briefing critical-path inference time. Re-enable when audio
        // playback is implemented by restoring the second generateNarrative call.

        let clock = ContinuousClock()
        logger.info("⏱️ Narrative prompt ready — visual prompt \(visualPrompt.count)ch")

        do {
            let visualStart = clock.now
            let visual = try await AIService.shared.generateNarrative(prompt: visualPrompt, systemInstruction: visualSystem, priority: .interactive)
            let visualElapsed = clock.now - visualStart
            logger.info("⏱️ Visual narrative complete (\(Self.formatElapsed(visualElapsed)), \(visual.count)ch)")

            return (visual, "")
        } catch {
            logger.warning("Morning narrative generation failed: \(error.localizedDescription)")
            return ("", "")
        }
    }

    private static func formatElapsed(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
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
                Write a concise end-of-day summary of 60 to 120 words based ONLY on the data below.

                CRITICAL: Only reference accomplishments, metrics, and events that appear in the data.
                Never invent names or details. Use dates exactly as given.

                PRONOUN DISCIPLINE — this is non-negotiable:
                - Address the advisor directly as "you" / "your". Their day, their accomplishments, their metrics — "your day", "what you closed today", "your progress on the Q2 target".
                - "I" / "my" is reserved for YOU, the assistant ("I've noted…", "my read is…"). Never use first-person for the advisor's work.
                - "we" is banned. The advisor closed those deals, not SAM.

                Celebrate accomplishments. Note key metrics with the numbers exactly as provided. Preview tomorrow in one short sentence if the data includes it. Be encouraging but honest.
                No greetings, no sign-offs, no bullets, no headers.

                \(dataBlock)
                """
            visualSystem = "Respond with ONLY the narrative paragraph. No headers, bullets, or formatting."
        }

        // TTS narrative skipped — see comment in generateMorningNarrative.
        do {
            let visual = try await AIService.shared.generateNarrative(prompt: visualPrompt, systemInstruction: visualSystem, priority: .interactive)
            return (visual, "")
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
        goalProgress: [GoalProgress] = [],
        recentJournalBlock: String = ""
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

        // Recent goal journal entries (past 7 days) — pre-fetched via @MainActor
        if !recentJournalBlock.isEmpty {
            parts.append(recentJournalBlock)
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
        case .roleFilling:       reasonableDailyMax = 2;  reasonableWeeklyMax = 5
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
