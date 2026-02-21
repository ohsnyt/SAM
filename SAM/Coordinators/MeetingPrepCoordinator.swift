//
//  MeetingPrepCoordinator.swift
//  SAM_crm
//
//  Created on February 20, 2026.
//  Phase K: Meeting Prep & Follow-Up
//
//  Core computation engine for meeting briefings, follow-up prompts,
//  and relationship health indicators.
//

import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MeetingPrepCoordinator")

// MARK: - Supporting Types

/// Trend direction for relationship interaction frequency.
enum ContactTrend: String, Sendable {
    case increasing
    case stable
    case decreasing
    case noData
}

/// Health metrics for a person's relationship.
struct RelationshipHealth: Sendable {
    let daysSinceLastInteraction: Int?
    let interactionCount30: Int
    let interactionCount90: Int
    let trend: ContactTrend

    /// Color based on days since last interaction.
    var statusColor: Color {
        guard let days = daysSinceLastInteraction else { return .gray }
        switch days {
        case 0...14: return .green
        case 15...30: return .yellow
        case 31...60: return .orange
        default: return .red
        }
    }

    var statusLabel: String {
        guard let days = daysSinceLastInteraction else { return "No recorded interactions" }
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        return "\(days) days ago"
    }
}

/// Profile summary for a meeting attendee.
struct AttendeeProfile: Identifiable, Sendable {
    var id: UUID { personID }
    let personID: UUID
    let displayName: String
    let photoThumbnail: Data?
    let roleBadges: [String]
    let contexts: [(name: String, kind: String)]
    let health: RelationshipHealth
}

/// Compact interaction record for display in briefings.
struct InteractionRecord: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let source: EvidenceSource
    let title: String
    let snippet: String?
}

/// A single upcoming meeting briefing.
struct MeetingBriefing: Identifiable, Sendable {
    let id: UUID  // Same as eventID
    let eventID: UUID
    let title: String
    let location: String?
    let startsAt: Date
    let endsAt: Date?
    let attendees: [AttendeeProfile]
    let recentHistory: [InteractionRecord]
    let openActionItems: [NoteActionItem]
    let topics: [String]
    let signals: [EvidenceSignal]
    let sharedContexts: [SamContext]
}

/// A follow-up prompt for a past meeting with no linked note.
struct FollowUpPrompt: Identifiable, Sendable {
    let id: UUID  // Same as eventID
    let eventID: UUID
    let title: String
    let endedAt: Date
    let hoursSinceEnd: Int
    let attendees: [(personID: UUID, displayName: String)]
    let hasLinkedNote: Bool
    let pendingActionItems: [NoteActionItem]
}

// MARK: - Coordinator

@MainActor
@Observable
final class MeetingPrepCoordinator {

    // MARK: - Singleton

    static let shared = MeetingPrepCoordinator()

    // MARK: - Published State

    var briefings: [MeetingBriefing] = []
    var followUpPrompts: [FollowUpPrompt] = []

    // MARK: - Dependencies

    private let evidenceRepository = EvidenceRepository.shared
    private let notesRepository = NotesRepository.shared
    private let peopleRepository = PeopleRepository.shared

    private init() {}

    // MARK: - Public API

    /// Main refresh — called from AwarenessView .task and on calendar sync.
    func refresh() async {
        do {
            briefings = try buildBriefings()
            followUpPrompts = try buildFollowUpPrompts()
            logger.info("Refresh complete: \(self.briefings.count) briefings, \(self.followUpPrompts.count) follow-ups")
        } catch {
            logger.error("Failed to refresh meeting prep: \(error.localizedDescription)")
        }
    }

    /// Compute health for a single person (reused by PersonDetailView).
    func computeHealth(for person: SamPerson) -> RelationshipHealth {
        let now = Date()
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let sixtyDaysAgo = Calendar.current.date(byAdding: .day, value: -60, to: now)!
        let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: now)!

        let allEvidence: [SamEvidenceItem]
        do {
            allEvidence = try evidenceRepository.fetchAll()
        } catch {
            return RelationshipHealth(daysSinceLastInteraction: nil, interactionCount30: 0, interactionCount90: 0, trend: .noData)
        }

        let personID = person.id
        let linked = allEvidence.filter { item in
            item.linkedPeople.contains(where: { $0.id == personID })
        }

        // Days since last interaction
        let lastDate = linked.first?.occurredAt // fetchAll returns sorted by occurredAt desc
        let daysSince: Int? = lastDate.map { Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0 }

        // Counts
        let count30 = linked.filter { $0.occurredAt >= thirtyDaysAgo }.count
        let count90 = linked.filter { $0.occurredAt >= ninetyDaysAgo }.count
        let countPrior30 = linked.filter { $0.occurredAt >= sixtyDaysAgo && $0.occurredAt < thirtyDaysAgo }.count

        // Trend
        let trend: ContactTrend
        if count30 == 0 && countPrior30 == 0 {
            trend = .noData
        } else if count30 > countPrior30 {
            trend = .increasing
        } else if count30 < countPrior30 {
            trend = .decreasing
        } else {
            trend = .stable
        }

        return RelationshipHealth(
            daysSinceLastInteraction: daysSince,
            interactionCount30: count30,
            interactionCount90: count90,
            trend: trend
        )
    }

    // MARK: - Private: Briefings

    private func buildBriefings() throws -> [MeetingBriefing] {
        let now = Date()
        let fortyEightHoursFromNow = Calendar.current.date(byAdding: .hour, value: 48, to: now)!

        let allEvidence = try evidenceRepository.fetchAll()

        // Upcoming calendar events with linked people
        let upcomingEvents = allEvidence.filter { item in
            item.source == .calendar
            && item.occurredAt > now
            && item.occurredAt <= fortyEightHoursFromNow
            && !item.linkedPeople.isEmpty
        }

        guard !upcomingEvents.isEmpty else { return [] }

        // Pre-fetch notes with pending actions
        let notesWithActions = try notesRepository.fetchNotesWithPendingActions()

        return upcomingEvents.map { event in
            let otherPeople = event.linkedPeople.filter { !$0.isMe }
            let attendees = otherPeople.map { person in
                buildAttendeeProfile(person: person, allEvidence: allEvidence)
            }

            let attendeeIDs = Set(event.linkedPeople.map(\.id))

            let recentHistory = fetchRecentHistory(for: event.linkedPeople, allEvidence: allEvidence, limit: 5)

            let openActions = notesWithActions.flatMap { note in
                note.extractedActionItems.filter { action in
                    action.status == .pending
                    && action.linkedPersonID.map({ attendeeIDs.contains($0) }) ?? false
                }
            }

            let topics = aggregateTopics(for: event.linkedPeople, allEvidence: allEvidence)

            let signals = aggregateSignals(for: event.linkedPeople, allEvidence: allEvidence)

            let sharedContexts = findSharedContexts(among: event.linkedPeople)

            return MeetingBriefing(
                id: event.id,
                eventID: event.id,
                title: event.title,
                location: nil,  // Location not separately stored; shown in snippet
                startsAt: event.occurredAt,
                endsAt: event.endedAt,
                attendees: attendees,
                recentHistory: recentHistory,
                openActionItems: openActions,
                topics: topics,
                signals: signals,
                sharedContexts: sharedContexts
            )
        }
        .sorted { $0.startsAt < $1.startsAt }
    }

    // MARK: - Private: Follow-Up Prompts

    private func buildFollowUpPrompts() throws -> [FollowUpPrompt] {
        let now = Date()
        let fortyEightHoursAgo = Calendar.current.date(byAdding: .hour, value: -48, to: now)!

        let allEvidence = try evidenceRepository.fetchAll()

        // Past calendar events in the 48h window
        let pastEvents = allEvidence.filter { item in
            item.source == .calendar
            && !item.linkedPeople.isEmpty
            && (item.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: item.occurredAt)!) <= now
            && (item.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: item.occurredAt)!) >= fortyEightHoursAgo
        }

        guard !pastEvents.isEmpty else { return [] }

        // Pre-fetch all notes
        let allNotes: [SamNote]
        do {
            allNotes = try notesRepository.fetchAll()
        } catch {
            allNotes = []
        }

        let notesWithActions = allNotes.filter { note in
            note.extractedActionItems.contains(where: { $0.status == .pending })
        }

        return pastEvents.compactMap { event in
            let eventEnd = event.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: event.occurredAt)!
            let attendeeIDs = Set(event.linkedPeople.map(\.id))

            // Check if a note was created after the event that references any attendee
            let hasLinkedNote = allNotes.contains { note in
                note.createdAt >= event.occurredAt
                && note.linkedPeople.contains(where: { attendeeIDs.contains($0.id) })
            }

            // Only prompt if no note exists
            guard !hasLinkedNote else { return nil }

            let hoursSinceEnd = max(0, Int(now.timeIntervalSince(eventEnd) / 3600))

            let pendingActions = notesWithActions.flatMap { note in
                note.extractedActionItems.filter { action in
                    action.status == .pending
                    && action.linkedPersonID.map({ attendeeIDs.contains($0) }) ?? false
                }
            }

            return FollowUpPrompt(
                id: event.id,
                eventID: event.id,
                title: event.title,
                endedAt: eventEnd,
                hoursSinceEnd: hoursSinceEnd,
                attendees: event.linkedPeople.filter { !$0.isMe }.map { ($0.id, $0.displayNameCache ?? $0.displayName) },
                hasLinkedNote: false,
                pendingActionItems: pendingActions
            )
        }
        .sorted { $0.endedAt > $1.endedAt }  // Most recent first
    }

    // MARK: - Private: Helpers

    private func buildAttendeeProfile(person: SamPerson, allEvidence: [SamEvidenceItem]) -> AttendeeProfile {
        let contexts = person.participations.compactMap { participation -> (name: String, kind: String)? in
            guard let context = participation.context else { return nil }
            return (name: context.name, kind: context.kind.rawValue)
        }

        return AttendeeProfile(
            personID: person.id,
            displayName: person.displayNameCache ?? person.displayName,
            photoThumbnail: person.photoThumbnailCache,
            roleBadges: person.roleBadges,
            contexts: contexts,
            health: computeHealth(for: person)
        )
    }

    private func fetchRecentHistory(for people: [SamPerson], allEvidence: [SamEvidenceItem], limit: Int) -> [InteractionRecord] {
        let personIDs = Set(people.map(\.id))
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

        return allEvidence
            .filter { item in
                item.occurredAt >= thirtyDaysAgo
                && item.linkedPeople.contains(where: { personIDs.contains($0.id) })
            }
            .prefix(limit)
            .map { item in
                InteractionRecord(
                    id: item.id,
                    date: item.occurredAt,
                    source: item.source,
                    title: item.title,
                    snippet: item.snippet.isEmpty ? nil : String(item.snippet.prefix(80))
                )
            }
    }

    private func aggregateTopics(for people: [SamPerson], allEvidence: [SamEvidenceItem]) -> [String] {
        let personIDs = Set(people.map(\.id))
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

        // Gather topics from notes linked to these people
        var topics = Set<String>()

        if let allNotes = try? notesRepository.fetchAll() {
            for note in allNotes where note.updatedAt >= thirtyDaysAgo {
                if note.linkedPeople.contains(where: { personIDs.contains($0.id) }) {
                    topics.formUnion(note.extractedTopics)
                }
            }
        }

        // Also extract signal messages as topic hints from evidence
        for item in allEvidence where item.occurredAt >= thirtyDaysAgo {
            if item.linkedPeople.contains(where: { personIDs.contains($0.id) }) {
                for signal in item.signals where signal.confidence >= 0.7 {
                    topics.insert(signal.type.rawValue)
                }
            }
        }

        return Array(topics).sorted()
    }

    private func aggregateSignals(for people: [SamPerson], allEvidence: [SamEvidenceItem]) -> [EvidenceSignal] {
        let personIDs = Set(people.map(\.id))
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

        return allEvidence
            .filter { item in
                item.occurredAt >= thirtyDaysAgo
                && item.linkedPeople.contains(where: { personIDs.contains($0.id) })
            }
            .flatMap(\.signals)
            .filter { $0.confidence >= 0.7 }
    }

    private func findSharedContexts(among people: [SamPerson]) -> [SamContext] {
        guard people.count >= 2 else { return [] }

        // Find contexts that contain at least 2 of the given people
        var contextCounts: [UUID: (context: SamContext, count: Int)] = [:]

        for person in people {
            for participation in person.participations {
                guard let context = participation.context else { continue }
                if let existing = contextCounts[context.id] {
                    contextCounts[context.id] = (context, existing.count + 1)
                } else {
                    contextCounts[context.id] = (context, 1)
                }
            }
        }

        return contextCounts.values
            .filter { $0.count >= 2 }
            .map(\.context)
    }
}
