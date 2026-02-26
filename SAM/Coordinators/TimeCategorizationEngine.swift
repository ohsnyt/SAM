//
//  TimeCategorizationEngine.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase Q: Time Tracking & Categorization
//
//  Heuristic auto-categorization of calendar events into TimeEntry records.
//  Called after each calendar import to populate the time tracking layer.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TimeCategorizationEngine")

@MainActor
@Observable
final class TimeCategorizationEngine {

    // MARK: - Singleton

    static let shared = TimeCategorizationEngine()

    // MARK: - Dependencies

    private let timeRepo = TimeTrackingRepository.shared
    private let evidenceRepo = EvidenceRepository.shared

    private init() {}

    // MARK: - Batch Categorization

    /// Scan all calendar evidence items and create/update TimeEntry records.
    /// Skips all-day events (duration >= 24h) and preserves manual overrides.
    func categorizeNewCalendarEvents() throws {
        let allEvents = try evidenceRepo.fetchAll()
        let calendarEvents = allEvents.filter { $0.source == .calendar }

        var created = 0
        var updated = 0

        for event in calendarEvents {
            // Skip all-day events (duration >= 24 hours)
            guard let endedAt = event.endedAt else { continue }
            let durationSeconds = endedAt.timeIntervalSince(event.occurredAt)
            guard durationSeconds < 24 * 60 * 60 && durationSeconds > 0 else { continue }

            // Check if entry already exists with manual override
            if let existing = try? timeRepo.fetchBySourceEvidence(id: event.id),
               existing.isManualOverride {
                continue
            }

            // Determine category
            let linkedPeople = event.linkedPeople
            let hasOtherAttendees = !linkedPeople.isEmpty
            let category = categorize(
                title: event.title,
                linkedPeople: linkedPeople,
                hasOtherAttendees: hasOtherAttendees
            )

            let linkedIDs = linkedPeople.map(\.id)

            let entry = try timeRepo.upsertFromCalendar(
                evidenceID: event.id,
                title: event.title,
                startedAt: event.occurredAt,
                endedAt: endedAt,
                category: category,
                linkedPeopleIDs: linkedIDs
            )

            if entry.createdAt.timeIntervalSinceNow > -1 {
                created += 1
            } else {
                updated += 1
            }
        }

        if created > 0 || updated > 0 {
            logger.info("Time categorization: \(created) created, \(updated) updated")
        }
    }

    // MARK: - Single Event Categorization

    /// Determine the TimeCategory for an event using heuristics.
    /// First match wins: title keywords → attendee roles → solo fallback → other.
    func categorize(
        title: String,
        linkedPeople: [SamPerson],
        hasOtherAttendees: Bool
    ) -> TimeCategory {
        let lowered = title.lowercased()

        // Step 1 — Title keywords (first match wins)
        if containsAny(lowered, ["training", "onboarding", "mentoring", "coaching session"]) {
            return .trainingMentoring
        }
        if containsAny(lowered, ["review", "policy review", "renewal", "annual review"]) {
            return .policyReview
        }
        if containsAny(lowered, ["recruit", "recruiting", "interview candidate"]) {
            return .recruiting
        }
        if containsAny(lowered, ["prospecting", "cold call", "outreach", "networking"]) {
            return .prospecting
        }
        if containsAny(lowered, ["travel", "flight", "drive to", "commute"]) {
            return .travel
        }
        if containsAny(lowered, ["admin", "paperwork", "filing", "compliance"]) {
            return .admin
        }
        if containsAny(lowered, ["deep work", "focus time", "focus block"]) {
            return .deepWork
        }
        if containsAny(lowered, ["webinar", "conference", "course", "certification", "study"]) {
            return .personalDev
        }

        // Step 2 — Attendee role badges (priority order)
        let allRoles = Set(linkedPeople.flatMap(\.roleBadges))

        if allRoles.contains("Client") || allRoles.contains("Applicant") {
            return .clientMeeting
        }
        if allRoles.contains("Lead") {
            return .prospecting
        }
        if allRoles.contains("Agent") {
            return .trainingMentoring
        }
        if allRoles.contains("External Agent") {
            return .recruiting
        }
        if allRoles.contains("Vendor") {
            return .admin
        }

        // Step 3 — Solo event (no other attendees)
        if !hasOtherAttendees {
            return .deepWork
        }

        // Step 4 — Fallback
        return .other
    }

    // MARK: - Helpers

    private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
