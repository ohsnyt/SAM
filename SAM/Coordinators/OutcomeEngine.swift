//
//  OutcomeEngine.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  Generates prioritized, outcome-focused coaching suggestions by scanning
//  all evidence sources: calendar, notes, relationship health, action items.
//  Deterministic scoring enriched with optional AI-generated rationale.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "OutcomeEngine")

@MainActor
@Observable
final class OutcomeEngine {

    // MARK: - Singleton

    static let shared = OutcomeEngine()

    // MARK: - Observable State

    enum GenerationStatus: String, Sendable {
        case idle
        case generating
        case success
        case failed
    }

    var generationStatus: GenerationStatus = .idle
    var lastGeneratedAt: Date?
    var lastError: String?

    // MARK: - Dependencies

    private let outcomeRepo = OutcomeRepository.shared
    private let evidenceRepo = EvidenceRepository.shared
    private let peopleRepo = PeopleRepository.shared
    private let notesRepo = NotesRepository.shared
    private let meetingPrep = MeetingPrepCoordinator.shared

    private init() {}

    // MARK: - Priority Weights

    struct OutcomeWeights: Sendable {
        var timeUrgency: Double = 0.30
        var relationshipHealth: Double = 0.20
        var roleImportance: Double = 0.20
        var evidenceRecency: Double = 0.15
        var userEngagement: Double = 0.15
    }

    // MARK: - Main Generation

    /// Fire-and-forget generation — does not block the caller.
    func startGeneration() {
        guard generationStatus != .generating else { return }
        Task { await generateOutcomes() }
    }

    /// Synthesize outcomes from all evidence sources.
    func generateOutcomes() async {
        guard generationStatus != .generating else { return }
        generationStatus = .generating
        lastError = nil

        do {
            // Prune expired outcomes first
            try outcomeRepo.pruneExpired()

            let allEvidence = try evidenceRepo.fetchAll()
            let allPeople = try peopleRepo.fetchAll().filter { !$0.isMe && !$0.isArchived }
            let allNotes = try notesRepo.fetchAll()

            var newOutcomes: [SamOutcome] = []

            // 1. Upcoming meetings → preparation outcomes
            newOutcomes.append(contentsOf: try scanUpcomingMeetings(allEvidence: allEvidence))

            // 2. Past meetings without notes → followUp outcomes
            newOutcomes.append(contentsOf: try scanPastMeetingsWithoutNotes(allEvidence: allEvidence, allNotes: allNotes))

            // 3. Pending action items → proposal / followUp outcomes
            newOutcomes.append(contentsOf: try scanPendingActionItems(allNotes: allNotes))

            // 4. Relationship health → outreach outcomes
            newOutcomes.append(contentsOf: try scanRelationshipHealth(people: allPeople))

            // 5. Growth opportunities (when few active outcomes)
            let activeCount = (try? outcomeRepo.fetchActive().count) ?? 0
            if activeCount + newOutcomes.count < 3 {
                newOutcomes.append(contentsOf: try scanGrowthOpportunities(people: allPeople))
            }

            // Score all new outcomes
            let weights = OutcomeWeights()
            for outcome in newOutcomes {
                outcome.priorityScore = computePriority(outcome: outcome, weights: weights)
            }

            // Persist (deduplication inside upsert check)
            var persisted = 0
            for outcome in newOutcomes {
                let isDuplicate = try outcomeRepo.hasSimilarOutcome(
                    kind: outcome.outcomeKind,
                    personID: outcome.linkedPerson?.id
                )
                if !isDuplicate {
                    try outcomeRepo.upsert(outcome: outcome)
                    persisted += 1
                }
            }

            // AI enrichment (best-effort, non-blocking)
            await enrichWithAI()

            // Reprioritize all active outcomes
            try reprioritize()

            generationStatus = .success
            lastGeneratedAt = .now
            logger.info("Generated \(persisted) new outcomes (\(newOutcomes.count) candidates, \(newOutcomes.count - persisted) duplicates)")

        } catch {
            generationStatus = .failed
            lastError = error.localizedDescription
            logger.error("Outcome generation failed: \(error.localizedDescription)")
        }
    }

    /// Re-score and sort all active outcomes.
    func reprioritize() throws {
        let weights = OutcomeWeights()
        let active = try outcomeRepo.fetchActive()
        for outcome in active {
            outcome.priorityScore = computePriority(outcome: outcome, weights: weights)
        }
    }

    // MARK: - Scanners

    /// Scan upcoming meetings (next 48h) → preparation outcomes.
    private func scanUpcomingMeetings(allEvidence: [SamEvidenceItem]) throws -> [SamOutcome] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .hour, value: 48, to: now)!

        let upcoming = allEvidence.filter {
            $0.source == .calendar
            && $0.occurredAt > now
            && $0.occurredAt <= cutoff
            && !$0.linkedPeople.isEmpty
        }

        return upcoming.compactMap { event -> SamOutcome? in
            let attendees = event.linkedPeople.filter { !$0.isMe }
            guard let primary = attendees.first else { return nil }

            let hoursUntil = max(1, Int(event.occurredAt.timeIntervalSince(now) / 3600))
            let names = attendees.map { $0.displayNameCache ?? $0.displayName }.joined(separator: ", ")

            return SamOutcome(
                title: "Prepare for meeting with \(names)",
                rationale: "\(event.title). \(hoursUntil) hour\(hoursUntil == 1 ? "" : "s") away.",
                outcomeKind: .preparation,
                deadlineDate: event.occurredAt,
                sourceInsightSummary: "Upcoming calendar event: \(event.title) at \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))",
                linkedPerson: primary
            )
        }
    }

    /// Scan past meetings (last 48h) without linked notes → followUp outcomes.
    private func scanPastMeetingsWithoutNotes(allEvidence: [SamEvidenceItem], allNotes: [SamNote]) throws -> [SamOutcome] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .hour, value: -48, to: now)!

        let pastEvents = allEvidence.filter { item in
            item.source == .calendar
            && !item.linkedPeople.isEmpty
            && (item.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: item.occurredAt)!) <= now
            && (item.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: item.occurredAt)!) >= cutoff
        }

        return pastEvents.compactMap { event -> SamOutcome? in
            let attendeeIDs = Set(event.linkedPeople.map(\.id))

            // Check if a note was created after the event referencing any attendee
            let hasNote = allNotes.contains { note in
                note.createdAt >= event.occurredAt
                && note.linkedPeople.contains(where: { attendeeIDs.contains($0.id) })
            }
            guard !hasNote else { return nil }

            let primary = event.linkedPeople.first { !$0.isMe } ?? event.linkedPeople.first
            let eventEnd = event.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: event.occurredAt)!
            let hoursSince = max(1, Int(now.timeIntervalSince(eventEnd) / 3600))

            return SamOutcome(
                title: "Document takeaways from \(event.title)",
                rationale: "\(hoursSince) hour\(hoursSince == 1 ? "" : "s") since it ended. Capture key points while fresh.",
                outcomeKind: .followUp,
                deadlineDate: Calendar.current.date(byAdding: .hour, value: 72, to: eventEnd),
                sourceInsightSummary: "Past meeting without notes: \(event.title)",
                suggestedNextStep: "Open a note and record what was discussed",
                linkedPerson: primary
            )
        }
    }

    /// Scan pending action items from notes → proposal / followUp outcomes.
    private func scanPendingActionItems(allNotes: [SamNote]) throws -> [SamOutcome] {
        var outcomes: [SamOutcome] = []

        for note in allNotes {
            let pending = note.extractedActionItems.filter { $0.status == .pending }
            for action in pending {
                let kind: OutcomeKind = action.type == .createProposal ? .proposal : .followUp
                let personName = action.linkedPersonName ?? "someone"

                // Resolve linked person if possible
                var linkedPerson: SamPerson? = nil
                if let personID = action.linkedPersonID {
                    linkedPerson = note.linkedPeople.first { $0.id == personID }
                }

                let daysSinceNote = Calendar.current.dateComponents([.day], from: note.updatedAt, to: .now).day ?? 0

                outcomes.append(SamOutcome(
                    title: action.description,
                    rationale: "From note \(daysSinceNote) day\(daysSinceNote == 1 ? "" : "s") ago about \(personName).",
                    outcomeKind: kind,
                    sourceInsightSummary: "Pending action from note: \(action.description)",
                    suggestedNextStep: action.suggestedText,
                    linkedPerson: linkedPerson
                ))
            }
        }

        return outcomes
    }

    /// Scan relationship health for people going cold → outreach outcomes.
    private func scanRelationshipHealth(people: [SamPerson]) throws -> [SamOutcome] {
        var outcomes: [SamOutcome] = []

        for person in people {
            let health = meetingPrep.computeHealth(for: person)
            guard let days = health.daysSinceLastInteraction else { continue }

            let threshold = roleThreshold(for: person.roleBadges.first)
            guard days >= threshold else { continue }

            let name = person.displayNameCache ?? person.displayName
            let role = person.roleBadges.first ?? "Contact"

            outcomes.append(SamOutcome(
                title: "Reconnect with \(name)",
                rationale: "\(days) days since last interaction. \(role) relationship.",
                outcomeKind: .outreach,
                sourceInsightSummary: "No interaction in \(days) days (threshold: \(threshold) for \(role))",
                linkedPerson: person
            ))
        }

        return outcomes
    }

    /// Suggest growth activities when the active outcome queue is thin.
    private func scanGrowthOpportunities(people: [SamPerson]) throws -> [SamOutcome] {
        var outcomes: [SamOutcome] = []

        // Find leads not contacted recently
        let leads = people.filter { $0.roleBadges.contains("Lead") }
        let staleLeads = leads.filter { person in
            let health = meetingPrep.computeHealth(for: person)
            return (health.daysSinceLastInteraction ?? 999) > 14
        }

        if !staleLeads.isEmpty {
            outcomes.append(SamOutcome(
                title: "Review leads pipeline",
                rationale: "\(staleLeads.count) lead\(staleLeads.count == 1 ? "" : "s") haven't been contacted recently.",
                outcomeKind: .growth,
                sourceInsightSummary: "\(staleLeads.count) stale leads detected",
                suggestedNextStep: "Pick one lead to reach out to today"
            ))
        }

        // Suggest referral outreach if a client has been active
        let activeClients = people.filter { person in
            person.roleBadges.contains("Client")
            && (meetingPrep.computeHealth(for: person).daysSinceLastInteraction ?? 999) <= 14
        }
        if let client = activeClients.first {
            let name = client.displayNameCache ?? client.displayName
            outcomes.append(SamOutcome(
                title: "Consider referral outreach via \(name)",
                rationale: "Active client relationship — good time to ask about referrals.",
                outcomeKind: .growth,
                sourceInsightSummary: "Active client \(name) — referral opportunity",
                linkedPerson: client
            ))
        }

        return outcomes
    }

    // MARK: - Role Transition Outcomes

    /// Generate outcomes when a person's role badges change.
    /// Called from PersonDetailView after badge edits.
    func generateRoleTransitionOutcomes(for person: SamPerson, addedRoles: Set<String>, removedRoles: Set<String>) {
        let enabled = UserDefaults.standard.object(forKey: "autoRoleTransitionOutcomes") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "autoRoleTransitionOutcomes")
        guard enabled else { return }

        let name = person.displayNameCache ?? person.displayName
        var outcomes: [SamOutcome] = []

        if addedRoles.contains("Applicant") {
            outcomes.append(contentsOf: [
                SamOutcome(
                    title: "Schedule needs analysis with \(name)",
                    rationale: "\(name) is now an Applicant. Start the assessment process.",
                    outcomeKind: .preparation,
                    sourceInsightSummary: "Role change: +Applicant for \(name)",
                    suggestedNextStep: "Book a 30-minute discovery call",
                    linkedPerson: person
                ),
                SamOutcome(
                    title: "Collect underwriting requirements for \(name)",
                    rationale: "Gather necessary documentation to move the application forward.",
                    outcomeKind: .preparation,
                    sourceInsightSummary: "Role change: +Applicant for \(name)",
                    suggestedNextStep: "Send the requirements checklist",
                    linkedPerson: person
                ),
                SamOutcome(
                    title: "Send initial proposals to \(name)",
                    rationale: "Prepare and present product options based on the needs analysis.",
                    outcomeKind: .proposal,
                    sourceInsightSummary: "Role change: +Applicant for \(name)",
                    suggestedNextStep: "Draft proposals after needs analysis is complete",
                    linkedPerson: person
                ),
            ])
        }

        if addedRoles.contains("Client") {
            outcomes.append(contentsOf: [
                SamOutcome(
                    title: "Send welcome package to \(name)",
                    rationale: "\(name) is now a Client. Start the onboarding experience.",
                    outcomeKind: .followUp,
                    sourceInsightSummary: "Role change: +Client for \(name)",
                    suggestedNextStep: "Prepare and send the welcome materials",
                    linkedPerson: person
                ),
                SamOutcome(
                    title: "Schedule onboarding meeting with \(name)",
                    rationale: "Walk through policy details, answer questions, set expectations.",
                    outcomeKind: .preparation,
                    sourceInsightSummary: "Role change: +Client for \(name)",
                    suggestedNextStep: "Send a calendar invite for this week",
                    linkedPerson: person
                ),
                SamOutcome(
                    title: "Set up policy review cadence for \(name)",
                    rationale: "Establish regular check-ins to maintain the relationship.",
                    outcomeKind: .outreach,
                    sourceInsightSummary: "Role change: +Client for \(name)",
                    suggestedNextStep: "Add a recurring 6-month review reminder",
                    linkedPerson: person
                ),
            ])
        }

        if addedRoles.contains("Agent") {
            outcomes.append(contentsOf: [
                SamOutcome(
                    title: "Schedule initial training for \(name)",
                    rationale: "\(name) joined as an Agent. Begin onboarding and training.",
                    outcomeKind: .training,
                    sourceInsightSummary: "Role change: +Agent for \(name)",
                    suggestedNextStep: "Set up first training session this week",
                    linkedPerson: person
                ),
                SamOutcome(
                    title: "Set up commission tracking for \(name)",
                    rationale: "Ensure \(name)'s production is tracked from day one.",
                    outcomeKind: .compliance,
                    sourceInsightSummary: "Role change: +Agent for \(name)",
                    suggestedNextStep: "Add to the team tracking system",
                    linkedPerson: person
                ),
                SamOutcome(
                    title: "Create development plan for \(name)",
                    rationale: "Outline goals, milestones, and support for the first 90 days.",
                    outcomeKind: .growth,
                    sourceInsightSummary: "Role change: +Agent for \(name)",
                    suggestedNextStep: "Draft a 30-60-90 day plan",
                    linkedPerson: person
                ),
            ])
        }

        // Persist with deduplication
        for outcome in outcomes {
            do {
                let isDuplicate = try outcomeRepo.hasSimilarOutcome(
                    kind: outcome.outcomeKind,
                    personID: person.id
                )
                if !isDuplicate {
                    try outcomeRepo.upsert(outcome: outcome)
                }
            } catch {
                logger.error("Failed to create role transition outcome: \(error.localizedDescription)")
            }
        }

        if !outcomes.isEmpty {
            logger.info("Generated role transition outcomes for \(name): added=\(addedRoles), removed=\(removedRoles)")
        }
    }

    // MARK: - Priority Computation

    private func computePriority(outcome: SamOutcome, weights: OutcomeWeights) -> Double {
        var score = 0.0

        // Time urgency (deadline proximity)
        if let deadline = outcome.deadlineDate {
            let hoursUntil = deadline.timeIntervalSince(.now) / 3600
            if hoursUntil <= 0 {
                score += weights.timeUrgency * 1.0  // Overdue
            } else if hoursUntil <= 6 {
                score += weights.timeUrgency * 0.9
            } else if hoursUntil <= 24 {
                score += weights.timeUrgency * 0.7
            } else if hoursUntil <= 48 {
                score += weights.timeUrgency * 0.5
            } else {
                score += weights.timeUrgency * 0.3
            }
        } else {
            score += weights.timeUrgency * 0.3  // No deadline = moderate baseline
        }

        // Relationship health
        if let person = outcome.linkedPerson {
            let health = meetingPrep.computeHealth(for: person)
            if let days = health.daysSinceLastInteraction {
                let healthScore = min(1.0, Double(days) / 60.0)
                score += weights.relationshipHealth * healthScore
            }
        }

        // Role importance
        let roleScore = roleImportanceScore(for: outcome.linkedPerson?.roleBadges.first)
        score += weights.roleImportance * roleScore

        // Evidence recency (newer creation = more urgent)
        let ageHours = Date.now.timeIntervalSince(outcome.createdAt) / 3600
        let recencyScore = max(0, 1.0 - (ageHours / 168))  // Decay over 7 days
        score += weights.evidenceRecency * recencyScore

        // User engagement — placeholder (filled in by CoachingAdvisor later)
        score += weights.userEngagement * 0.5  // Neutral until we have feedback data

        return min(1.0, max(0.0, score))
    }

    private func roleImportanceScore(for role: String?) -> Double {
        switch role?.lowercased() {
        case "client":          return 1.0
        case "applicant":       return 0.9
        case "lead":            return 0.7
        case "agent":           return 0.6
        case "external agent":  return 0.4
        case "vendor":          return 0.3
        default:                return 0.5
        }
    }

    private func roleThreshold(for role: String?) -> Int {
        switch role?.lowercased() {
        case "client":          return 45
        case "applicant":       return 14
        case "lead":            return 30
        case "agent":           return 21
        case "external agent":  return 60
        case "vendor":          return 90
        default:                return 60
        }
    }

    // MARK: - AI Enrichment

    /// Best-effort: enhance rationale and suggestedNextStep with AI for top outcomes.
    private func enrichWithAI() async {
        do {
            let active = try outcomeRepo.fetchActive()
            // Only enrich top 5 to avoid excessive LLM calls
            let topOutcomes = Array(active.prefix(5))
            guard !topOutcomes.isEmpty else { return }

            let availability = await AIService.shared.checkAvailability()
            guard case .available = availability else {
                logger.info("AI not available — skipping enrichment")
                return
            }

            for outcome in topOutcomes where outcome.suggestedNextStep == nil {
                let prompt = """
                    You are a coaching assistant for a financial strategist.
                    Given this outcome, suggest a concrete next step (1 sentence).

                    Outcome: \(outcome.title)
                    Context: \(outcome.rationale)
                    Person role: \(outcome.linkedPerson?.roleBadges.first ?? "unknown")
                    """

                let systemInstruction = """
                    Respond with ONLY the next step — one short, actionable sentence.
                    Do not include any preamble, formatting, or explanation.
                    """

                do {
                    let nextStep = try await AIService.shared.generateNarrative(
                        prompt: prompt,
                        systemInstruction: systemInstruction
                    )
                    if !nextStep.isEmpty {
                        outcome.suggestedNextStep = nextStep
                    }
                } catch {
                    logger.warning("AI enrichment failed for '\(outcome.title)': \(error.localizedDescription)")
                    // Continue with other outcomes — non-fatal
                }
            }
        } catch {
            logger.warning("AI enrichment skipped: \(error.localizedDescription)")
        }
    }
}
