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

/// Velocity trend of engagement gaps (are gaps growing or shrinking?).
enum VelocityTrend: String, Sendable {
    case accelerating   // Gaps shrinking — engagement increasing
    case steady         // Gaps consistent
    case decelerating   // Gaps growing — decay signal
    case noData
}

/// Per-role velocity thresholds for decay risk assessment.
struct RoleVelocityConfig: Sendable {
    let ratioModerate: Double   // Overdue ratio → moderate risk
    let ratioHigh: Double       // Overdue ratio → high risk
    let predictiveLeadDays: Int // Alert this many days before predicted overdue

    static func forRole(_ role: String?) -> RoleVelocityConfig {
        switch role?.lowercased() {
        case "client":           return .init(ratioModerate: 1.3, ratioHigh: 2.0, predictiveLeadDays: 14)
        case "applicant":        return .init(ratioModerate: 1.2, ratioHigh: 1.8, predictiveLeadDays: 14)
        case "lead":             return .init(ratioModerate: 1.3, ratioHigh: 2.0, predictiveLeadDays: 10)
        case "agent":            return .init(ratioModerate: 1.5, ratioHigh: 2.5, predictiveLeadDays: 10)
        case "referral partner": return .init(ratioModerate: 1.5, ratioHigh: 2.5, predictiveLeadDays: 14)
        case "external agent":   return .init(ratioModerate: 2.0, ratioHigh: 3.5, predictiveLeadDays: 21)
        case "vendor":           return .init(ratioModerate: 2.5, ratioHigh: 4.0, predictiveLeadDays: 30)
        default:                 return .init(ratioModerate: 1.5, ratioHigh: 2.5, predictiveLeadDays: 14)
        }
    }
}

/// Overall decay risk assessment combining overdue ratio + velocity trend.
enum DecayRisk: String, Sendable, Comparable {
    case none       // Healthy, within cadence
    case low        // Slightly overdue (<1.5×)
    case moderate   // Overdue (1.5-2.5×) or decelerating
    case high       // Severely overdue (>2.5×) or rapid deceleration
    case critical   // Past static threshold AND decelerating

    static func < (lhs: DecayRisk, rhs: DecayRisk) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
    private var sortOrder: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .moderate: return 2
        case .high: return 3
        case .critical: return 4
        }
    }
}

/// Health metrics for a person's relationship.
struct RelationshipHealth: Sendable {
    let daysSinceLastInteraction: Int?
    let interactionCount30: Int
    let interactionCount90: Int
    let trend: ContactTrend
    let role: String?

    // Velocity fields (Phase U)
    let cadenceDays: Int?              // Computed median gap in days (nil if <3 interactions)
    let effectiveCadenceDays: Int?     // User override or computed (used for health logic)
    let overdueRatio: Double?          // currentGap / effectiveCadence (nil if no cadence)
    let velocityTrend: VelocityTrend   // Gap acceleration direction
    let qualityScore30: Double         // Quality-weighted interaction score (last 30d)
    let predictedOverdueDays: Int?     // Days until predicted overdue (nil = not predictable)
    let decayRisk: DecayRisk           // Overall risk assessment
    let predictiveLeadDays: Int        // Role-aware lead time for predictive alerts

    /// Color incorporating decay risk when velocity data is available;
    /// falls back to static role-based thresholds otherwise.
    var statusColor: Color {
        // If we have velocity data, use decay risk for color
        if effectiveCadenceDays != nil {
            switch decayRisk {
            case .none:     return .green
            case .low:      return .green
            case .moderate: return .yellow
            case .high:     return .orange
            case .critical: return .red
            }
        }
        // Fallback: static threshold logic
        guard let days = daysSinceLastInteraction else { return .gray }
        let thresholds = Self.colorThresholds(for: role)
        switch days {
        case 0...thresholds.green:  return .green
        case 0...thresholds.yellow: return .yellow
        case 0...thresholds.orange: return .orange
        default:                    return .red
        }
    }

    var statusLabel: String {
        guard let days = daysSinceLastInteraction else { return "No recorded interactions" }
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        return "\(days) days ago"
    }

    /// Per-role color breakpoints (upper bound of each range, inclusive).
    private struct ColorThresholds {
        let green: Int
        let yellow: Int
        let orange: Int
    }

    private static func colorThresholds(for role: String?) -> ColorThresholds {
        switch role?.lowercased() {
        case "client", "applicant":
            return ColorThresholds(green: 7, yellow: 21, orange: 45)
        case "agent":
            return ColorThresholds(green: 7, yellow: 14, orange: 30)
        case "referral partner":
            return ColorThresholds(green: 14, yellow: 30, orange: 45)
        case "vendor":
            return ColorThresholds(green: 30, yellow: 60, orange: 90)
        default:
            return ColorThresholds(green: 14, yellow: 30, orange: 60)
        }
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
    let lastInteractions: [InteractionRecord]
    let pendingActionItems: [String]
    let recentLifeEvents: [String]
    let pipelineStage: String?
    let productHoldings: [String]
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
    let talkingPoints: [String]
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
            briefings = try await buildBriefings()
            followUpPrompts = try buildFollowUpPrompts()
            logger.info("Refresh complete: \(self.briefings.count) briefings, \(self.followUpPrompts.count) follow-ups")
        } catch {
            logger.error("Failed to refresh meeting prep: \(error.localizedDescription)")
        }
    }

    /// Compute health for a single person (reused by PersonDetailView, EngagementVelocitySection, etc.).
    func computeHealth(for person: SamPerson) -> RelationshipHealth {
        let now = Date()
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let sixtyDaysAgo = Calendar.current.date(byAdding: .day, value: -60, to: now)!
        let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: now)!

        // Use person.linkedEvidence (direct relationship) filtered to real interactions
        let evidence = person.linkedEvidence
            .filter { $0.source.isInteraction }
            .sorted { $0.occurredAt < $1.occurredAt }

        // --- Days since last interaction ---
        let lastDate = evidence.last?.occurredAt
        let daysSince: Int? = lastDate.map { Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0 }

        // --- Counts ---
        let count30 = evidence.filter { $0.occurredAt >= thirtyDaysAgo }.count
        let count90 = evidence.filter { $0.occurredAt >= ninetyDaysAgo }.count
        let countPrior30 = evidence.filter { $0.occurredAt >= sixtyDaysAgo && $0.occurredAt < thirtyDaysAgo }.count

        // --- Trend ---
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

        // --- Cadence via median gap ---
        let cadenceDays: Int?
        let gaps: [TimeInterval]
        if evidence.count >= 3 {
            gaps = zip(evidence.dropFirst(), evidence).map { $0.occurredAt.timeIntervalSince($1.occurredAt) }
            let sorted = gaps.sorted()
            let mid = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2)
                ? (sorted[mid - 1] + sorted[mid]) / 2.0
                : sorted[mid]
            cadenceDays = max(1, Int(round(median / 86400.0)))
        } else {
            gaps = []
            cadenceDays = nil
        }

        // --- Effective cadence (user override or computed) ---
        let effectiveCadenceDays: Int?
        if let override = person.preferredCadenceDays, override > 0 {
            effectiveCadenceDays = override
        } else {
            effectiveCadenceDays = cadenceDays
        }

        // --- Overdue ratio (against effective cadence) ---
        let currentGapDays = evidence.last.map { now.timeIntervalSince($0.occurredAt) / 86400.0 }
        let overdueRatio = effectiveCadenceDays.flatMap { cd in currentGapDays.map { $0 / Double(cd) } }

        // --- Velocity trend ---
        let velocityTrend = computeVelocityTrend(gaps: gaps)

        // --- Quality-weighted 30-day score ---
        let qualityScore30 = evidence
            .filter { $0.occurredAt >= thirtyDaysAgo }
            .reduce(0.0) { $0 + $1.source.qualityWeight }

        // --- Predicted overdue ---
        let predictedOverdueDays = computePredictedOverdue(
            cadenceDays: effectiveCadenceDays, currentGapDays: currentGapDays, velocityTrend: velocityTrend
        )

        // --- Role velocity config ---
        let roleConfig = RoleVelocityConfig.forRole(person.roleBadges.first)

        // --- Decay risk ---
        let decayRisk = assessDecayRisk(
            overdueRatio: overdueRatio, velocityTrend: velocityTrend,
            daysSince: daysSince, role: person.roleBadges.first
        )

        return RelationshipHealth(
            daysSinceLastInteraction: daysSince,
            interactionCount30: count30,
            interactionCount90: count90,
            trend: trend,
            role: person.roleBadges.first,
            cadenceDays: cadenceDays,
            effectiveCadenceDays: effectiveCadenceDays,
            overdueRatio: overdueRatio,
            velocityTrend: velocityTrend,
            qualityScore30: qualityScore30,
            predictedOverdueDays: predictedOverdueDays,
            decayRisk: decayRisk,
            predictiveLeadDays: roleConfig.predictiveLeadDays
        )
    }

    // MARK: - Velocity Helpers (Phase U)

    /// Compare first-half vs second-half gap medians to determine trend.
    private func computeVelocityTrend(gaps: [TimeInterval]) -> VelocityTrend {
        guard gaps.count >= 4 else { return .noData }

        let midpoint = gaps.count / 2
        let firstHalf = Array(gaps.prefix(midpoint)).sorted()
        let secondHalf = Array(gaps.suffix(gaps.count - midpoint)).sorted()

        func median(_ arr: [TimeInterval]) -> TimeInterval {
            let m = arr.count / 2
            return arr.count.isMultiple(of: 2) ? (arr[m - 1] + arr[m]) / 2.0 : arr[m]
        }

        let firstMedian = median(firstHalf)
        let secondMedian = median(secondHalf)

        guard firstMedian > 0 else { return .steady }

        let ratio = secondMedian / firstMedian
        if ratio > 1.3 {
            return .decelerating  // Gaps growing
        } else if ratio < 0.7 {
            return .accelerating  // Gaps shrinking
        }
        return .steady
    }

    /// Predict days until overdue (ratio hits 2.0) based on current trajectory.
    /// Returns nil when not at risk or insufficient data.
    private func computePredictedOverdue(
        cadenceDays: Int?,
        currentGapDays: Double?,
        velocityTrend: VelocityTrend
    ) -> Int? {
        guard let cd = cadenceDays, let gap = currentGapDays else { return nil }
        let ratio = gap / Double(cd)

        switch velocityTrend {
        case .decelerating:
            // If already past 0.8× cadence and decelerating, estimate days to 2.0×
            guard ratio >= 0.8 else { return nil }
            let targetGapDays = Double(cd) * 2.0
            let remainingDays = targetGapDays - gap
            guard remainingDays > 0 else { return 0 }
            // Gap grows by 1 day per day; result is simply the remaining days
            return max(1, Int(ceil(remainingDays)))
        case .steady:
            // If already overdue, predict how many more days until 2.0×
            guard ratio >= 1.0 else { return nil }
            let targetGapDays = Double(cd) * 2.0
            let remainingDays = targetGapDays - gap
            return remainingDays > 0 ? max(1, Int(ceil(remainingDays))) : 0
        case .accelerating, .noData:
            return nil
        }
    }

    /// Combine overdue ratio, velocity trend, and static thresholds into a DecayRisk level.
    private func assessDecayRisk(
        overdueRatio: Double?,
        velocityTrend: VelocityTrend,
        daysSince: Int?,
        role: String?
    ) -> DecayRisk {
        let ratio = overdueRatio ?? 0

        // Static threshold check for critical
        if let days = daysSince {
            let staticThreshold = staticRoleThreshold(for: role)
            if days >= staticThreshold && velocityTrend == .decelerating {
                return .critical
            }
            if days >= staticThreshold {
                return .high
            }
        }

        // Velocity-aware assessment (role-scaled thresholds)
        let config = RoleVelocityConfig.forRole(role)
        switch velocityTrend {
        case .decelerating:
            if ratio >= config.ratioHigh { return .high }
            if ratio >= config.ratioModerate { return .moderate }
            if ratio >= 1.0 { return .moderate }
            return .low
        case .steady:
            if ratio >= config.ratioHigh { return .high }
            if ratio >= config.ratioModerate { return .moderate }
            if ratio >= 1.0 { return .low }
            return .none
        case .accelerating, .noData:
            if ratio >= config.ratioHigh { return .moderate }
            if ratio >= config.ratioModerate { return .low }
            return .none
        }
    }

    /// Static per-role thresholds (matching OutcomeEngine/InsightGenerator).
    private func staticRoleThreshold(for role: String?) -> Int {
        switch role?.lowercased() {
        case "client":           return 45
        case "applicant":        return 14
        case "lead":             return 30
        case "agent":            return 21
        case "referral partner": return 45
        case "external agent":   return 60
        case "vendor":           return 90
        default:                 return 60
        }
    }

    // MARK: - Channel Preference Inference (Phase O)

    /// Infer the preferred communication channel for a person based on evidence history.
    /// Weights recent 90-day evidence 2x compared to older evidence.
    func inferChannelPreference(for person: SamPerson) {
        let allEvidence: [SamEvidenceItem]
        do {
            allEvidence = try evidenceRepository.fetchAll()
        } catch {
            return
        }

        let personID = person.id
        let linked = allEvidence.filter { item in
            item.linkedPeople.contains(where: { $0.id == personID })
        }

        guard !linked.isEmpty else { return }

        let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: Date())!

        var channelScores: [CommunicationChannel: Double] = [:]
        for item in linked {
            let weight: Double = item.occurredAt >= ninetyDaysAgo ? 2.0 : 1.0
            switch item.source {
            case .iMessage:
                channelScores[.iMessage, default: 0] += weight
            case .mail:
                channelScores[.email, default: 0] += weight
            case .phoneCall:
                channelScores[.phone, default: 0] += weight
            case .faceTime:
                channelScores[.faceTime, default: 0] += weight
            case .calendar, .contacts, .note, .manual:
                break
            }
        }

        if let best = channelScores.max(by: { $0.value < $1.value }) {
            person.inferredChannelRawValue = best.key.rawValue
        }
    }

    // MARK: - Private: Briefings

    private func buildBriefings() async throws -> [MeetingBriefing] {
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

        var results: [MeetingBriefing] = []

        for event in upcomingEvents {
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

            // Generate AI talking points
            let talkingPoints = await generateTalkingPoints(
                eventTitle: event.title,
                attendees: attendees,
                recentHistory: recentHistory,
                openActions: openActions,
                topics: topics
            )

            results.append(MeetingBriefing(
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
                sharedContexts: sharedContexts,
                talkingPoints: talkingPoints
            ))
        }

        return results.sorted { $0.startsAt < $1.startsAt }
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

        // Last 3 interactions
        let lastInteractions = fetchRecentHistory(for: [person], allEvidence: allEvidence, limit: 3)

        // Pending action items from notes
        let pendingActions: [String]
        if let notes = try? notesRepository.fetchNotes(forPerson: person) {
            pendingActions = notes.flatMap { $0.extractedActionItems }
                .filter { $0.status == .pending }
                .prefix(5)
                .map(\.description)
        } else {
            pendingActions = []
        }

        // Recent life events from notes (last 30 days)
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let lifeEvents: [String]
        if let notes = try? notesRepository.fetchNotes(forPerson: person) {
            lifeEvents = notes
                .filter { $0.updatedAt >= thirtyDaysAgo }
                .flatMap(\.lifeEvents)
                .map { "\($0.personName): \($0.eventDescription)" }
        } else {
            lifeEvents = []
        }

        // Pipeline stage from role badges
        let pipelineRoles: Set<String> = ["Client", "Applicant", "Lead", "Agent"]
        let pipelineStage = person.roleBadges.first(where: { pipelineRoles.contains($0) })

        // Product holdings
        let productHoldings: [String]
        if let records = try? ProductionRepository.shared.fetchRecords(forPerson: person.id) {
            productHoldings = records.map { $0.productType.displayName }
        } else {
            productHoldings = []
        }

        return AttendeeProfile(
            personID: person.id,
            displayName: person.displayNameCache ?? person.displayName,
            photoThumbnail: person.photoThumbnailCache,
            roleBadges: person.roleBadges,
            contexts: contexts,
            health: computeHealth(for: person),
            lastInteractions: lastInteractions,
            pendingActionItems: pendingActions,
            recentLifeEvents: lifeEvents,
            pipelineStage: pipelineStage,
            productHoldings: productHoldings
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

    // MARK: - AI Talking Points

    /// Generate AI-powered talking points for an upcoming meeting.
    /// Fails gracefully — returns empty array if AI is unavailable.
    private func generateTalkingPoints(
        eventTitle: String,
        attendees: [AttendeeProfile],
        recentHistory: [InteractionRecord],
        openActions: [NoteActionItem],
        topics: [String]
    ) async -> [String] {
        let attendeeSummaries = attendees.map { a in
            var parts = [a.displayName]
            if let stage = a.pipelineStage { parts.append("(\(stage))") }
            if !a.productHoldings.isEmpty { parts.append("Products: \(a.productHoldings.joined(separator: ", "))") }
            if !a.pendingActionItems.isEmpty { parts.append("Pending: \(a.pendingActionItems.joined(separator: "; "))") }
            if !a.recentLifeEvents.isEmpty { parts.append("Life events: \(a.recentLifeEvents.joined(separator: "; "))") }
            return parts.joined(separator: " — ")
        }

        let historySummary = recentHistory.prefix(3).map { "\($0.title) (\($0.date.formatted(date: .abbreviated, time: .omitted)))" }

        let actionSummary = openActions.prefix(3).map(\.description)

        let prompt = """
            You are a relationship advisor for a financial strategist. Generate 3-5 concise talking points for an upcoming meeting.

            Meeting: \(eventTitle)
            Attendees: \(attendeeSummaries.joined(separator: "\n"))
            Recent interactions: \(historySummary.joined(separator: "; "))
            Open action items: \(actionSummary.joined(separator: "; "))
            Recent topics: \(topics.joined(separator: ", "))

            Return ONLY a JSON array of strings, each being one talking point. Example:
            ["Ask about their retirement timeline", "Follow up on the IUL proposal from last week"]
            """

        do {
            let response = try await AIService.shared.generate(prompt: prompt)
            return parseTalkingPoints(response)
        } catch {
            logger.debug("Talking points generation skipped: \(error.localizedDescription)")
            return []
        }
    }

    /// Parse JSON array of strings from AI response, with fallback.
    private func parseTalkingPoints(_ response: String) -> [String] {
        // Try to extract JSON array from response
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String].self, from: data) else {
            // Fallback: try to find JSON array within the response
            if let start = trimmed.firstIndex(of: "["),
               let end = trimmed.lastIndex(of: "]") {
                let jsonSlice = String(trimmed[start...end])
                if let sliceData = jsonSlice.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode([String].self, from: sliceData) {
                    return Array(parsed.prefix(5))
                }
            }
            return []
        }
        return Array(parsed.prefix(5))
    }
}
