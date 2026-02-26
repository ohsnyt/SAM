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

            // 6. Coverage gap cross-sell (Phase S)
            newOutcomes.append(contentsOf: try scanCoverageGaps(people: allPeople))

            // 7. Content suggestions (Phase W)
            newOutcomes.append(contentsOf: await scanContentSuggestions())

            // 8. Content cadence nudges (Phase W)
            newOutcomes.append(contentsOf: try scanContentCadence())

            // Classify action lanes and suggest channels
            for outcome in newOutcomes {
                classifyActionLane(for: outcome)
                if outcome.actionLane == .communicate || outcome.actionLane == .call {
                    outcome.suggestedChannel = suggestChannel(for: outcome)
                }
            }

            // Generate multi-step sequence follow-ups for communicate/call outcomes
            var sequenceSteps: [SamOutcome] = []
            for outcome in newOutcomes {
                let steps = maybeCreateSequenceSteps(for: outcome)
                if !steps.isEmpty {
                    let seqID = UUID()
                    outcome.sequenceID = seqID
                    outcome.sequenceIndex = 0
                    for (i, step) in steps.enumerated() {
                        step.sequenceID = seqID
                        step.sequenceIndex = i + 1
                    }
                    sequenceSteps.append(contentsOf: steps)
                }
            }
            newOutcomes.append(contentsOf: sequenceSteps)

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
    /// Includes both static-threshold outcomes and velocity-aware predictive outcomes.
    private func scanRelationshipHealth(people: [SamPerson]) throws -> [SamOutcome] {
        var outcomes: [SamOutcome] = []

        for person in people {
            let health = meetingPrep.computeHealth(for: person)
            guard let days = health.daysSinceLastInteraction else { continue }

            let name = person.displayNameCache ?? person.displayName
            let role = person.roleBadges.first ?? "Contact"

            // 1. Static threshold: existing behavior
            let threshold = roleThreshold(for: person.roleBadges.first)
            if days >= threshold {
                outcomes.append(SamOutcome(
                    title: "Reconnect with \(name)",
                    rationale: "\(days) days since last interaction. \(role) relationship.",
                    outcomeKind: .outreach,
                    priorityScore: 0.7,
                    sourceInsightSummary: "No interaction in \(days) days (threshold: \(threshold) for \(role))",
                    linkedPerson: person
                ))
                continue // Skip predictive if already past static threshold
            }

            // 2. Predictive: decay risk >= moderate AND predicted overdue within role-aware lead time
            if health.decayRisk >= .moderate,
               let predicted = health.predictedOverdueDays,
               predicted <= health.predictiveLeadDays {
                outcomes.append(SamOutcome(
                    title: "Reach out to \(name) soon",
                    rationale: "Engagement declining — predicted overdue in \(predicted) day\(predicted == 1 ? "" : "s"). \(role) relationship.",
                    outcomeKind: .outreach,
                    priorityScore: 0.4,
                    sourceInsightSummary: "Engagement velocity declining (predicted overdue in \(predicted)d)",
                    linkedPerson: person
                ))
            }
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

    // MARK: - Coverage Gap Cross-Sell (Phase S)

    /// Scan clients with production records for coverage gaps.
    /// Compares their existing product types against a "complete coverage" baseline.
    private func scanCoverageGaps(people: [SamPerson]) throws -> [SamOutcome] {
        var outcomes: [SamOutcome] = []

        // Complete coverage baseline: at least one life product + retirement + education
        let lifeTypes: Set<WFGProductType> = [.iul, .termLife, .wholeLife]
        let retirementTypes: Set<WFGProductType> = [.retirementPlan, .annuity]
        let educationTypes: Set<WFGProductType> = [.educationPlan]

        let clients = people.filter { $0.roleBadges.contains("Client") }

        for client in clients {
            let records = (try? ProductionRepository.shared.fetchRecords(forPerson: client.id)) ?? []
            guard !records.isEmpty else { continue }

            let existingTypes = Set(records.map(\.productType))
            let name = client.displayNameCache ?? client.displayName

            var gaps: [String] = []

            if existingTypes.isDisjoint(with: lifeTypes) {
                gaps.append("life insurance")
            }
            if existingTypes.isDisjoint(with: retirementTypes) {
                gaps.append("retirement planning")
            }
            if existingTypes.isDisjoint(with: educationTypes) {
                gaps.append("education planning")
            }

            guard !gaps.isEmpty else { continue }

            // Dedup check
            let isDuplicate = try outcomeRepo.hasSimilarOutcome(
                kind: .growth,
                personID: client.id
            )
            guard !isDuplicate else { continue }

            let gapList = gaps.joined(separator: " and ")
            let existingList = existingTypes.map(\.displayName).joined(separator: ", ")

            outcomes.append(SamOutcome(
                title: "Consider \(gapList) for \(name)",
                rationale: "Has \(existingList) but no \(gapList). A complete financial strategy covers life, retirement, and education.",
                outcomeKind: .growth,
                sourceInsightSummary: "Coverage gap detected for \(name): missing \(gapList)",
                suggestedNextStep: "Schedule a review meeting to discuss \(gapList) options",
                linkedPerson: client
            ))
        }

        return outcomes
    }

    // MARK: - Content Scanners (Phase W)

    /// Suggest educational content topics from StrategicCoordinator's cached digest
    /// or fall back to ContentAdvisorService.
    private func scanContentSuggestions() async -> [SamOutcome] {
        // Guard: user has content suggestions enabled (default true)
        let enabled = UserDefaults.standard.object(forKey: "contentSuggestionsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "contentSuggestionsEnabled")
        guard enabled else { return [] }

        // Dedup: at most one batch of content outcomes per week
        let hasSimilar = (try? outcomeRepo.hasSimilarOutcome(
            kind: .contentCreation,
            personID: nil,
            withinHours: 168
        )) ?? false
        guard !hasSimilar else { return [] }

        // Try to get topics from cached strategic digest first
        var topics: [ContentTopic] = []
        if let digest = StrategicCoordinator.shared.latestDigest,
           !digest.contentSuggestions.isEmpty,
           let data = digest.contentSuggestions.data(using: .utf8) {
            if let analysis = try? JSONDecoder().decode(ContentAnalysis.self, from: data) {
                topics = analysis.topicSuggestions
            } else {
                // Try decoding as array of ContentTopic directly
                topics = (try? JSONDecoder().decode([ContentTopic].self, from: data)) ?? []
            }
        }

        // Fall back to direct ContentAdvisorService call
        if topics.isEmpty {
            let recentData = "Suggest 3 educational content topics for a financial strategist based on current market context."
            if let analysis = try? await ContentAdvisorService.shared.analyze(data: recentData) {
                topics = analysis.topicSuggestions
            }
        }

        // Map top 3 topics to outcomes
        return Array(topics.prefix(3)).compactMap { topic -> SamOutcome? in
            let keyPointsSummary = topic.keyPoints.joined(separator: ". ")
            let rationale = keyPointsSummary.isEmpty ? topic.topic : keyPointsSummary
            let complianceNote = topic.complianceNotes.map { " Compliance: \($0)" } ?? ""

            // Store full topic as JSON for round-trip in draft sheet
            let topicJSON = (try? String(data: JSONEncoder().encode(topic), encoding: .utf8)) ?? ""

            return SamOutcome(
                title: "Post about: \(topic.topic)",
                rationale: "\(rationale).\(complianceNote)",
                outcomeKind: .contentCreation,
                sourceInsightSummary: topicJSON,
                suggestedNextStep: "Open the draft sheet to generate a platform-specific post"
            )
        }
    }

    /// Nudge the user when posting cadence has lapsed on key platforms.
    private func scanContentCadence() throws -> [SamOutcome] {
        let enabled = UserDefaults.standard.object(forKey: "contentSuggestionsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "contentSuggestionsEnabled")
        guard enabled else { return [] }

        var outcomes: [SamOutcome] = []

        // LinkedIn: nudge after 10 days
        if let linkedInDays = try? ContentPostRepository.shared.daysSinceLastPost(platform: .linkedin),
           linkedInDays >= 10 {
            let hasSimilar = (try? outcomeRepo.hasSimilarOutcome(
                kind: .contentCreation,
                personID: nil,
                withinHours: 72
            )) ?? false
            if !hasSimilar {
                outcomes.append(SamOutcome(
                    title: "Post on LinkedIn — \(linkedInDays) days since last post",
                    rationale: "Consistent LinkedIn presence keeps you top-of-mind with professional connections. Aim for at least weekly.",
                    outcomeKind: .contentCreation,
                    sourceInsightSummary: "",
                    suggestedNextStep: "Share an educational insight or client success story"
                ))
            }
        }

        // Facebook: nudge after 14 days
        if let fbDays = try? ContentPostRepository.shared.daysSinceLastPost(platform: .facebook),
           fbDays >= 14 {
            let hasSimilar = outcomes.isEmpty ? ((try? outcomeRepo.hasSimilarOutcome(
                kind: .contentCreation,
                personID: nil,
                withinHours: 72
            )) ?? false) : true // Already have one cadence nudge, skip second
            if !hasSimilar {
                outcomes.append(SamOutcome(
                    title: "Post on Facebook — \(fbDays) days since last post",
                    rationale: "Regular Facebook content builds trust with your personal network. A quick educational post goes a long way.",
                    outcomeKind: .contentCreation,
                    sourceInsightSummary: "",
                    suggestedNextStep: "Share a relatable financial tip or seasonal reminder"
                ))
            }
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

        // Classify lanes and persist with deduplication
        for outcome in outcomes {
            classifyActionLane(for: outcome)
            if outcome.actionLane == .communicate || outcome.actionLane == .call {
                outcome.suggestedChannel = suggestChannel(for: outcome)
            }
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

    // MARK: - Multi-Step Sequence Generation

    /// Evaluate whether an outcome should have follow-up steps.
    /// Returns 0 or more follow-up SamOutcome instances (with isAwaitingTrigger = true).
    private func maybeCreateSequenceSteps(for outcome: SamOutcome) -> [SamOutcome] {
        // Only create sequences for communicate/call outcomes with a linked person
        guard outcome.actionLane == .communicate || outcome.actionLane == .call,
              let person = outcome.linkedPerson else { return [] }

        let title = outcome.title.lowercased()
        let personName = person.displayNameCache ?? person.displayName

        // Determine if a follow-up sequence is warranted and configure it
        let followUpDays: Int
        let followUpTitle: String
        let followUpChannel: CommunicationChannel
        let followUpRationale: String

        if title.contains("send proposal") || title.contains("send recommendation") {
            followUpDays = 5
            followUpChannel = outcome.suggestedChannel == .email ? .iMessage : .email
            followUpTitle = "Follow up with \(personName) on proposal (no response)"
            followUpRationale = "It's been \(followUpDays) days since the proposal was sent. A gentle follow-up keeps momentum."
        } else if title.contains("follow up") || title.contains("outreach")
                    || title.contains("check in") || title.contains("reach out")
                    || title.contains("reconnect") {
            followUpDays = 3
            followUpChannel = outcome.suggestedChannel == .iMessage ? .email : .iMessage
            followUpTitle = "Follow up with \(personName) via \(followUpChannel.displayName) (no response)"
            followUpRationale = "No response after \(followUpDays) days. Switching channel may help."
        } else if outcome.outcomeKind == .outreach && outcome.suggestedChannel == .iMessage {
            followUpDays = 3
            followUpChannel = .email
            followUpTitle = "Email follow-up with \(personName) (no response to text)"
            followUpRationale = "Text didn't get a response after \(followUpDays) days. Try email."
        } else {
            return []
        }

        let followUp = SamOutcome(
            title: followUpTitle,
            rationale: followUpRationale,
            outcomeKind: outcome.outcomeKind,
            sourceInsightSummary: "Sequence follow-up for: \(outcome.title)",
            suggestedNextStep: outcome.suggestedNextStep,
            linkedPerson: person,
            linkedContext: outcome.linkedContext
        )
        followUp.isAwaitingTrigger = true
        followUp.triggerAfterDays = followUpDays
        followUp.triggerCondition = .noResponse
        followUp.actionLane = .communicate
        followUp.suggestedChannel = followUpChannel

        return [followUp]
    }

    // MARK: - Action Lane Classification (Phase O)

    /// Classify an outcome into the correct action lane.
    /// Called after creation and before persisting.
    func classifyActionLane(for outcome: SamOutcome) {
        let title = outcome.title.lowercased()

        // 1. Source-based: if from a NoteActionItem, use action type heuristics
        let summary = outcome.sourceInsightSummary.lowercased()
        if summary.contains("pending action from note") {
            if title.contains("congratulat") || title.contains("send reminder") || title.contains("send welcome") {
                outcome.actionLane = .communicate
                return
            }
            if title.contains("schedule") || title.contains("book") {
                outcome.actionLane = .schedule
                return
            }
            if title.contains("proposal") || title.contains("create") || title.contains("draft") || title.contains("prepare") {
                outcome.actionLane = .deepWork
                return
            }
        }

        // 2. Keyword heuristics on title
        let communicateKeywords = ["send", "text", "email", "congratulat", "thank", "welcome", "message", "reach out", "reconnect"]
        if communicateKeywords.contains(where: { title.contains($0) }) {
            outcome.actionLane = .communicate
            return
        }

        let callKeywords = ["call", "check in with", "phone"]
        if callKeywords.contains(where: { title.contains($0) }) {
            outcome.actionLane = .call
            return
        }

        let scheduleKeywords = ["schedule", "book meeting", "set up meeting", "calendar invite"]
        if scheduleKeywords.contains(where: { title.contains($0) }) {
            outcome.actionLane = .schedule
            return
        }

        let deepWorkKeywords = ["draft", "proposal", "analysis", "prepare", "build", "create", "review leads", "development plan"]
        if deepWorkKeywords.contains(where: { title.contains($0) }) {
            outcome.actionLane = .deepWork
            return
        }

        // 3. Fallback by OutcomeKind
        switch outcome.outcomeKind {
        case .outreach, .growth:
            outcome.actionLane = .communicate
        case .proposal, .training, .contentCreation:
            outcome.actionLane = .deepWork
        case .followUp, .preparation, .compliance:
            outcome.actionLane = .record
        }
    }

    /// Suggest the best communication channel for an outcome targeting a person.
    func suggestChannel(for outcome: SamOutcome) -> CommunicationChannel {
        let title = outcome.title.lowercased()

        // Person's explicit or inferred preference
        let personPref = outcome.linkedPerson?.effectiveChannel

        // Complex outcomes → email
        if title.contains("proposal") || title.contains("analysis") || title.contains("document") {
            return .email
        }

        // Acknowledgment/congratulatory → person pref or iMessage
        if title.contains("congratulat") || title.contains("thank") || title.contains("welcome") {
            return personPref ?? .iMessage
        }

        // Default → person preference or iMessage
        return personPref ?? .iMessage
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
        case "client":           return 1.0
        case "applicant":        return 0.9
        case "lead":             return 0.7
        case "agent":            return 0.6
        case "referral partner": return 0.5
        case "external agent":   return 0.4
        case "vendor":           return 0.3
        default:                 return 0.5
        }
    }

    private func roleThreshold(for role: String?) -> Int {
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

    // MARK: - AI Enrichment

    /// Best-effort: enhance rationale, suggestedNextStep, and draft messages with AI for top outcomes.
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

            for outcome in topOutcomes {
                // Generate suggested next step if missing
                if outcome.suggestedNextStep == nil {
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
                    }
                }

                // Generate draft message for communicate/call lanes
                if outcome.draftMessageText == nil,
                   (outcome.actionLane == .communicate || outcome.actionLane == .call) {
                    await generateDraftMessage(for: outcome)
                }
            }
        } catch {
            logger.warning("AI enrichment skipped: \(error.localizedDescription)")
        }
    }

    /// Generate a draft message for a communicate or call outcome.
    private func generateDraftMessage(for outcome: SamOutcome) async {
        let person = outcome.linkedPerson
        let personName = person?.displayNameCache ?? person?.displayName ?? "the contact"
        let role = person?.roleBadges.first ?? "contact"
        let summary = person?.relationshipSummary ?? ""

        let channel = outcome.suggestedChannel ?? .iMessage
        let channelNote: String
        switch channel {
        case .iMessage: channelNote = "a brief, friendly text message"
        case .email:    channelNote = "a professional email (2-3 short paragraphs)"
        case .phone:    channelNote = "talking points for a phone call (3-4 bullet points)"
        case .faceTime: channelNote = "talking points for a video call (3-4 bullet points)"
        }

        let prompt = """
            Draft \(channelNote) from a financial strategist to \(personName).

            Purpose: \(outcome.title)
            Context: \(outcome.rationale)
            Person's role: \(role)
            \(summary.isEmpty ? "" : "Relationship context: \(summary)")

            The sender's name is not needed — the message will be sent from their account.
            Keep the tone warm but professional.
            """

        let systemInstruction: String
        switch channel {
        case .iMessage:
            systemInstruction = """
                Write ONLY the message text — no greeting line with "Hi [Name]," unless it fits naturally.
                Keep it under 3 sentences. Casual but professional. No emojis. No signature.
                """
        case .email:
            systemInstruction = """
                Write the email body only — no subject line.
                Start with a greeting. Keep it concise (2-3 short paragraphs). Professional tone.
                End with a simple closing like "Best" or "Looking forward to hearing from you."
                No signature block.
                """
        case .phone, .faceTime:
            systemInstruction = """
                Write 3-4 brief talking points as a simple list, one per line.
                Each point should be a conversation starter or key topic to cover.
                No bullet markers, just plain text lines.
                """
        }

        do {
            let draft = try await AIService.shared.generateNarrative(
                prompt: prompt,
                systemInstruction: systemInstruction
            )
            if !draft.isEmpty {
                outcome.draftMessageText = draft
                logger.debug("Generated draft message for '\(outcome.title)'")
            }
        } catch {
            logger.warning("Draft generation failed for '\(outcome.title)': \(error.localizedDescription)")
        }
    }
}
