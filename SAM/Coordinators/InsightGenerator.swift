//
//  InsightGenerator.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase I: Insights & Awareness
//
//  Coordinator that aggregates signals from all sources (notes, calendar, contacts)
//  and generates actionable insights for the Awareness dashboard.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "InsightGenerator")

@MainActor
@Observable
final class InsightGenerator {

    // MARK: - Singleton

    static let shared = InsightGenerator()

    private init() {}

    // MARK: - Container

    private var context: ModelContext?

    func configure(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    // MARK: - Dependencies

    private var evidenceRepository = EvidenceRepository.shared
    private var peopleRepository = PeopleRepository.shared
    private var notesRepository = NotesRepository.shared

    // MARK: - Observable State

    /// Current generation status
    var generationStatus: GenerationStatus = .idle

    /// Timestamp of last successful generation
    var lastGeneratedAt: Date?

    /// Count of insights generated in last operation
    var lastInsightCount: Int = 0

    /// Error message if generation failed
    var lastError: String?

    // MARK: - Settings (UserDefaults-backed)

    @ObservationIgnored
    var autoGenerateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "insightAutoGenerateEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "insightAutoGenerateEnabled") }
    }

    @ObservationIgnored
    var daysSinceContactThreshold: Int {
        get { UserDefaults.standard.integer(forKey: "insightDaysSinceContactThreshold") }
        set { UserDefaults.standard.set(newValue, forKey: "insightDaysSinceContactThreshold") }
    }

    // MARK: - Status Enum

    enum GenerationStatus: Equatable {
        case idle
        case generating
        case success
        case failed

        var displayText: String {
            switch self {
            case .idle: return "Ready"
            case .generating: return "Generating insights..."
            case .success: return "Complete"
            case .failed: return "Failed"
            }
        }
    }

    // MARK: - Public API

    /// Generate insights from all available data sources
    /// Returns array of generated insights
    func generateInsights() async -> [GeneratedInsight] {
        generationStatus = .generating
        lastError = nil

        do {
            var generatedInsights: [GeneratedInsight] = []

            // 1. Generate insights from note action items
            let noteInsights = try await generateInsightsFromNotes()
            generatedInsights.append(contentsOf: noteInsights)

            // 2. Generate insights from relationship patterns (no recent contact)
            let relationshipInsights = try await generateRelationshipInsights()
            generatedInsights.append(contentsOf: relationshipInsights)

            // 3. Generate insights from discovered relationships
            let discoveredInsights = try await generateDiscoveredRelationshipInsights()
            generatedInsights.append(contentsOf: discoveredInsights)

            // 4. Generate insights from upcoming events
            let calendarInsights = try await generateCalendarInsights()
            generatedInsights.append(contentsOf: calendarInsights)

            // 5. Generate insights from email signals
            let emailInsights = try await generateInsightsFromEmails()
            generatedInsights.append(contentsOf: emailInsights)

            // 6. Generate insights from life events in notes
            let lifeEventInsights = try await generateLifeEventInsights()
            generatedInsights.append(contentsOf: lifeEventInsights)

            // 7. Deduplicate and prioritize
            let deduplicatedInsights = deduplicateInsights(generatedInsights)

            // 8. Persist to SwiftData
            persistInsights(deduplicatedInsights)

            // 9. Update status
            lastInsightCount = deduplicatedInsights.count
            lastGeneratedAt = .now
            generationStatus = .success

            logger.info("Generated \(deduplicatedInsights.count) insights (notes: \(noteInsights.count), relationships: \(relationshipInsights.count), discovered: \(discoveredInsights.count), calendar: \(calendarInsights.count), email: \(emailInsights.count), lifeEvents: \(lifeEventInsights.count))")

            return deduplicatedInsights

        } catch {
            lastError = error.localizedDescription
            generationStatus = .failed
            logger.error("Failed to generate insights: \(error)")
            return []
        }
    }

    /// Start auto-generation (triggered after imports or on schedule)
    func startAutoGeneration() {
        guard autoGenerateEnabled else { return }

        Task {
            await generateInsights()
        }
    }

    // MARK: - Role Thresholds

    /// Per-role configuration for no-contact insight generation.
    private struct RoleThresholds {
        let noContactDays: Int
        let urgencyBoost: Bool  // medium → high

        static func forRole(_ role: String?) -> RoleThresholds {
            switch role?.lowercased() {
            case "client":           return RoleThresholds(noContactDays: 45, urgencyBoost: true)
            case "applicant":        return RoleThresholds(noContactDays: 14, urgencyBoost: true)
            case "lead":             return RoleThresholds(noContactDays: 30, urgencyBoost: false)
            case "agent":            return RoleThresholds(noContactDays: 21, urgencyBoost: true)
            case "referral partner": return RoleThresholds(noContactDays: 45, urgencyBoost: false)
            case "external agent":   return RoleThresholds(noContactDays: 60, urgencyBoost: false)
            case "vendor":           return RoleThresholds(noContactDays: 90, urgencyBoost: false)
            default:                 return RoleThresholds(noContactDays: 60, urgencyBoost: false)
            }
        }
    }

    // MARK: - Insight Generation Logic

    /// Generate insights from note action items
    private func generateInsightsFromNotes() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []

        // Fetch notes with pending action items
        let notesWithActions = try notesRepository.fetchNotesWithPendingActions()

        for note in notesWithActions {
            for actionItem in note.extractedActionItems where actionItem.status == .pending {
                let insight = GeneratedInsight(
                    kind: mapActionTypeToInsightKind(actionItem.type),
                    title: actionItem.description,
                    body: generateBodyForActionItem(actionItem, note: note),
                    personID: actionItem.linkedPersonID,
                    sourceType: .note,
                    sourceID: note.id,
                    urgency: mapActionUrgencyToInsightPriority(actionItem.urgency),
                    confidence: 0.9, // High confidence from LLM extraction
                    createdAt: .now
                )
                insights.append(insight)
            }
        }

        return insights
    }

    /// Generate insights from relationship patterns (no recent contact).
    /// Uses per-role thresholds (e.g. 14 days for Applicants, 90 for Vendors)
    /// plus velocity-aware predictive decay insights.
    private func generateRelationshipInsights() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []
        var staticInsightPersonIDs: Set<UUID> = []

        // Fetch all people and evidence
        let allPeople = try peopleRepository.fetchAll()
        let allEvidence = try evidenceRepository.fetchAll()
        let meetingPrep = MeetingPrepCoordinator.shared

        for person in allPeople {
            guard !person.isArchived, !person.isMe else { continue }

            let role = person.roleBadges.first
            let thresholds = RoleThresholds.forRole(role)

            // User override for global threshold (only applies when > 0 and no role-specific override)
            let effectiveDays: Int
            if role == nil, daysSinceContactThreshold > 0 {
                effectiveDays = daysSinceContactThreshold
            } else {
                effectiveDays = thresholds.noContactDays
            }

            let cutoffDate = Calendar.current.date(byAdding: .day, value: -effectiveDays, to: .now)!

            // Find most recent evidence for this person
            let personEvidence = allEvidence.filter { evidence in
                evidence.linkedPeople.contains(where: { $0.id == person.id })
            }
            let mostRecent = personEvidence.max(by: { $0.occurredAt < $1.occurredAt })

            // 1. Static threshold: existing behavior
            if let lastContact = mostRecent?.occurredAt, lastContact < cutoffDate {
                let daysSince = Calendar.current.dateComponents([.day], from: lastContact, to: .now).day ?? 0

                let roleLabel = role ?? "Contact"
                var urgency: InsightPriority = daysSince > (effectiveDays * 2) ? .high : .medium
                if thresholds.urgencyBoost && urgency == .medium {
                    urgency = .high
                }

                let insight = GeneratedInsight(
                    kind: .relationshipAtRisk,
                    title: "No recent contact with \(person.displayNameCache ?? person.displayName)",
                    body: "Last interaction was \(daysSince) days ago (\(roleLabel) threshold: \(effectiveDays) days). Consider reaching out to maintain the relationship.",
                    personID: person.id,
                    sourceType: .pattern,
                    sourceID: nil,
                    urgency: urgency,
                    confidence: 0.8,
                    createdAt: .now
                )
                insights.append(insight)
                staticInsightPersonIDs.insert(person.id)
            }
        }

        // 2. Predictive decay insights (skip if static insight already exists for same person)
        for person in allPeople {
            guard !person.isArchived, !person.isMe else { continue }
            guard !staticInsightPersonIDs.contains(person.id) else { continue }

            let health = meetingPrep.computeHealth(for: person)

            guard health.velocityTrend == .decelerating,
                  let ratio = health.overdueRatio, ratio >= 1.0,
                  health.decayRisk >= .moderate else { continue }

            let name = person.displayNameCache ?? person.displayName
            let cadenceLabel = health.cadenceDays.map { "Usual cadence: ~\($0) days." } ?? ""
            let predictedLabel = health.predictedOverdueDays.map { "Predicted overdue in ~\($0) days." } ?? ""
            let currentGap = health.daysSinceLastInteraction.map { "\($0) days since last interaction." } ?? ""

            let insight = GeneratedInsight(
                kind: .relationshipAtRisk,
                title: "Engagement declining with \(name)",
                body: "\(currentGap) \(cadenceLabel) \(predictedLabel) Contact gaps are growing — consider reaching out before the relationship goes cold.",
                personID: person.id,
                sourceType: .pattern,
                sourceID: nil,
                urgency: .medium,
                confidence: 0.7,
                createdAt: .now
            )
            insights.append(insight)
        }

        return insights
    }

    /// Generate insights from discovered relationships in notes (high confidence, pending review).
    private func generateDiscoveredRelationshipInsights() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []

        let allNotes = try notesRepository.fetchAll()

        for note in allNotes {
            for rel in note.discoveredRelationships where rel.status == .pending && rel.confidence >= 0.7 {
                let insight = GeneratedInsight(
                    kind: .informational,
                    title: "Possible relationship: \(rel.personName) may be \(rel.relationshipType.rawValue.replacingOccurrences(of: "_", with: " ")) \(rel.relatedTo)",
                    body: "Discovered in a note. Review and confirm if this relationship should be tracked.",
                    personID: nil,
                    sourceType: .note,
                    sourceID: note.id,
                    urgency: .low,
                    confidence: rel.confidence,
                    createdAt: .now
                )
                insights.append(insight)
            }
        }

        return insights
    }

    /// Generate insights from upcoming calendar events
    private func generateCalendarInsights() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []

        // Fetch upcoming events (next 7 days)
        let startDate = Date.now
        let endDate = Calendar.current.date(byAdding: .day, value: 7, to: startDate)!

        let allEvidence = try evidenceRepository.fetchAll()
        let upcomingEvents = allEvidence.filter {
            $0.source == .calendar &&
            $0.occurredAt >= startDate &&
            $0.occurredAt <= endDate
        }

        // Generate preparation reminders for meetings
        for event in upcomingEvents {
            // Only generate insights for events with linked people
            guard !event.linkedPeople.isEmpty else { continue }

            let daysUntil = Calendar.current.dateComponents([.day], from: .now, to: event.occurredAt).day ?? 0

            if daysUntil <= 2 {
                let personNames = event.linkedPeople.map { $0.displayNameCache ?? $0.displayName }.joined(separator: ", ")

                let insight = GeneratedInsight(
                    kind: .followUpNeeded,
                    title: "Upcoming meeting: \(event.title)",
                    body: "Meeting with \(personNames) in \(daysUntil) day\(daysUntil == 1 ? "" : "s"). Review recent notes and prepare talking points.",
                    personID: event.linkedPeople.first?.id,
                    sourceType: .calendar,
                    sourceID: event.id,
                    urgency: daysUntil == 0 ? .high : .medium,
                    confidence: 1.0, // Calendar events are factual
                    createdAt: .now
                )
                insights.append(insight)
            }
        }

        return insights
    }

    /// Generate insights from email evidence signals
    private func generateInsightsFromEmails() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -14, to: .now)!

        let allEvidence = try evidenceRepository.fetchAll()
        let mailEvidence = allEvidence.filter {
            $0.source == .mail && $0.occurredAt >= cutoffDate
        }

        for evidence in mailEvidence {
            let personID = evidence.linkedPeople.first?.id

            for signal in evidence.signals {
                let kind: InsightKind
                let urgency: InsightPriority

                switch signal.type {
                case .lifeEvent:
                    kind = .followUpNeeded
                    urgency = .medium
                case .financialEvent:
                    kind = .opportunity
                    urgency = .high
                case .opportunity:
                    kind = .opportunity
                    urgency = .medium
                case .complianceRisk:
                    kind = .complianceWarning
                    urgency = .high
                default:
                    continue
                }

                let insight = GeneratedInsight(
                    kind: kind,
                    title: signal.message,
                    body: "From email: \(evidence.title)",
                    personID: personID,
                    sourceType: .email,
                    sourceID: evidence.id,
                    urgency: urgency,
                    confidence: signal.confidence,
                    createdAt: .now
                )
                insights.append(insight)
            }
        }

        return insights
    }

    /// Generate insights from life events detected in notes (pending events only).
    private func generateLifeEventInsights() async throws -> [GeneratedInsight] {
        var insights: [GeneratedInsight] = []

        let allNotes = try notesRepository.fetchAll()

        for note in allNotes {
            for event in note.lifeEvents where event.status == .pending {
                let title = "Life event: \(event.personName) — \(event.eventDescription)"
                var body = "Event type: \(event.eventTypeLabel)"
                if let approxDate = event.approximateDate, !approxDate.isEmpty {
                    body += "\nApproximate date: \(approxDate)"
                }
                if let suggestion = event.outreachSuggestion, !suggestion.isEmpty {
                    body += "\nSuggested outreach: \(suggestion)"
                }

                let insight = GeneratedInsight(
                    kind: .opportunity,
                    title: title,
                    body: body,
                    personID: note.linkedPeople.first?.id,
                    sourceType: .note,
                    sourceID: note.id,
                    urgency: .medium,
                    confidence: 0.85,
                    createdAt: .now
                )
                insights.append(insight)
            }
        }

        return insights
    }

    // MARK: - Persistence

    /// Persist generated insights to SwiftData, deduplicating against recent entries.
    private func persistInsights(_ insights: [GeneratedInsight]) {
        guard let context = context else {
            logger.debug("InsightGenerator not configured with container — skipping persistence")
            return
        }

        do {
            let descriptor = FetchDescriptor<SamInsight>()
            let existing = try context.fetch(descriptor)
            let oneDayAgo = Date.now.addingTimeInterval(-86400)

            var created = 0

            for insight in insights {
                // Dedup: skip if same kind + personID + sourceID exists within 24h
                let isDuplicate = existing.contains { sam in
                    sam.kind == insight.kind &&
                    sam.samPerson?.id == insight.personID &&
                    sam.sourceID == insight.sourceID &&
                    sam.createdAt > oneDayAgo &&
                    sam.dismissedAt == nil
                }
                guard !isDuplicate else { continue }

                // Resolve person from THIS context (not PeopleRepository's context)
                var person: SamPerson?
                if let personID = insight.personID {
                    let personDescriptor = FetchDescriptor<SamPerson>(
                        predicate: #Predicate { $0.id == personID }
                    )
                    person = try? context.fetch(personDescriptor).first
                }

                let samInsight = SamInsight(
                    kind: insight.kind,
                    title: insight.title,
                    message: insight.body,
                    confidence: insight.confidence,
                    urgency: insight.urgency,
                    sourceType: insight.sourceType,
                    sourceID: insight.sourceID
                )
                samInsight.samPerson = person
                context.insert(samInsight)
                created += 1
            }

            // Prune dismissed insights older than 30 days
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            for sam in existing {
                if let dismissed = sam.dismissedAt, dismissed < thirtyDaysAgo {
                    context.delete(sam)
                }
            }

            try context.save()
            if created > 0 {
                logger.info("Persisted \(created) new insights to SwiftData")
            }
        } catch {
            logger.error("Failed to persist insights: \(error)")
        }
    }

    // MARK: - Deduplication

    /// Remove duplicate insights based on similarity
    private func deduplicateInsights(_ insights: [GeneratedInsight]) -> [GeneratedInsight] {
        var unique: [GeneratedInsight] = []

        for insight in insights {
            // Check if we already have a similar insight
            let isDuplicate = unique.contains { existing in
                // Same person and same kind within 24 hours = duplicate
                existing.personID == insight.personID &&
                existing.kind == insight.kind &&
                abs(existing.createdAt.timeIntervalSince(insight.createdAt)) < 86400 // 24 hours
            }

            if !isDuplicate {
                unique.append(insight)
            }
        }

        // Sort by urgency (high first) and then by creation date (newest first)
        return unique.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency {
                return lhs.urgency.rawValue > rhs.urgency.rawValue
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    // MARK: - Helper Mapping Functions

    /// Map action item type to insight kind
    private func mapActionTypeToInsightKind(_ type: NoteActionItem.ActionType) -> InsightKind {
        switch type {
        case .updateContact:
            return .informational
        case .sendCongratulations:
            return .opportunity
        case .sendReminder:
            return .followUpNeeded
        case .scheduleMeeting:
            return .followUpNeeded
        case .createProposal:
            return .opportunity
        case .updateBeneficiary:
            return .complianceWarning
        case .generalFollowUp:
            return .followUpNeeded
        }
    }

    /// Map action urgency to insight priority
    private func mapActionUrgencyToInsightPriority(_ urgency: NoteActionItem.Urgency) -> InsightPriority {
        switch urgency {
        case .immediate:
            return .high
        case .soon:
            return .high
        case .standard:
            return .medium
        case .low:
            return .low
        }
    }

    /// Generate body text for action item insight
    private func generateBodyForActionItem(_ actionItem: NoteActionItem, note: SamNote) -> String {
        var body = actionItem.description

        if let suggestedText = actionItem.suggestedText, !suggestedText.isEmpty {
            body += "\n\nSuggested message: \"\(suggestedText)\""
        }

        if let summary = note.summary {
            body += "\n\nFrom note: \(summary)"
        }

        return body
    }
}

// MARK: - Supporting Types

/// Generated insight (not yet persisted to SamInsight)
struct GeneratedInsight: Identifiable, Equatable {
    let id = UUID()
    let kind: InsightKind
    let title: String
    let body: String
    let personID: UUID?
    let sourceType: InsightSourceType
    let sourceID: UUID? // Note ID, Evidence ID, etc.
    let urgency: InsightPriority
    let confidence: Double
    let createdAt: Date
}

/// Source type for insights
public enum InsightSourceType: String, Codable {
    case note = "Note"
    case calendar = "Calendar"
    case contacts = "Contacts"
    case email = "Email"
    case pattern = "Pattern" // Derived from analysis (e.g., no recent contact)
}

/// Priority level for insights
public enum InsightPriority: Int, Codable, Comparable {
    case low = 1
    case medium = 2
    case high = 3

    public static func < (lhs: InsightPriority, rhs: InsightPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayText: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var color: String {
        switch self {
        case .low: return "gray"
        case .medium: return "orange"
        case .high: return "red"
        }
    }
}
