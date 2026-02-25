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
        tomorrowPreview: [BriefingCalendarItem]
    ) async -> (visual: String, tts: String) {
        let availability = await AIService.shared.checkAvailability()
        guard case .available = availability else {
            logger.info("AI unavailable — skipping morning narrative")
            return ("", "")
        }

        let dataBlock = buildMorningDataBlock(
            calendarItems: calendarItems,
            priorityActions: priorityActions,
            followUps: followUps,
            lifeEvents: lifeEvents,
            tomorrowPreview: tomorrowPreview
        )

        // Visual narrative
        let visualPrompt = """
            You are a warm, professional executive assistant for a financial strategist.
            Write a concise morning briefing summary (3-5 sentences) based on the data below.
            Include exact times, full names, and specific details. Be data-dense but readable.
            Use a confident, forward-looking tone. No greetings or sign-offs.

            \(dataBlock)
            """

        let visualSystem = "Respond with ONLY the narrative paragraph. No headers, bullets, or formatting."

        // TTS narrative
        let ttsPrompt = """
            You are a warm, professional executive assistant briefing your boss verbally.
            Write a short spoken briefing (2-3 sentences) based on the data below.
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
        let availability = await AIService.shared.checkAvailability()
        guard case .available = availability else {
            logger.info("AI unavailable — skipping evening narrative")
            return ("", "")
        }

        let dataBlock = buildEveningDataBlock(
            accomplishments: accomplishments,
            streakUpdates: streakUpdates,
            metrics: metrics,
            tomorrowHighlights: tomorrowHighlights
        )

        let visualPrompt = """
            You are a warm, professional executive assistant summarizing the day.
            Write a concise end-of-day summary (3-5 sentences) based on the data below.
            Celebrate accomplishments, note key metrics, and preview tomorrow.
            Be encouraging but honest. No greetings or sign-offs.

            \(dataBlock)
            """

        let visualSystem = "Respond with ONLY the narrative paragraph. No headers, bullets, or formatting."

        let ttsPrompt = """
            You are a warm, professional executive assistant giving a spoken evening summary.
            Write a short recap (2-3 sentences) highlighting accomplishments and tomorrow's plan.
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
        tomorrowPreview: [BriefingCalendarItem]
    ) -> String {
        var parts: [String] = []

        if !calendarItems.isEmpty {
            let items = calendarItems.map { item in
                let time = item.startsAt.formatted(date: .omitted, time: .shortened)
                let attendees = item.attendeeNames.isEmpty ? "" : " with \(item.attendeeNames.joined(separator: ", "))"
                return "- \(time): \(item.eventTitle)\(attendees)"
            }.joined(separator: "\n")
            parts.append("TODAY'S SCHEDULE (\(calendarItems.count) meetings):\n\(items)")
        }

        if !priorityActions.isEmpty {
            let items = priorityActions.prefix(5).map { "- \($0.title)" }.joined(separator: "\n")
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
}
