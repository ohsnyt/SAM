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

// MARK: - Knowledge Gap

/// Represents a gap in SAM's knowledge that can be filled by user input.
struct KnowledgeGap: Identifiable, Sendable {
    let id: String           // e.g., "referralSources"
    let question: String
    let placeholder: String
    let icon: String         // SF Symbol
    let storageKey: String   // UserDefaults key prefix "sam.gap."
}

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

    /// Active knowledge gaps detected during outcome generation.
    var activeGaps: [KnowledgeGap] = []

    // MARK: - Dependencies

    private let outcomeRepo = OutcomeRepository.shared
    private let evidenceRepo = EvidenceRepository.shared
    private let peopleRepo = PeopleRepository.shared
    private let notesRepo = NotesRepository.shared
    private let meetingPrep = MeetingPrepCoordinator.shared
    private let touchRepo = IntentionalTouchRepository.shared

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

            // 9. Goal pacing coaching (Phase X)
            newOutcomes.append(contentsOf: scanGoalPacing())

            // 10. Deduced relationships review
            newOutcomes.append(contentsOf: scanDeducedRelationships())

            // 11. LinkedIn notification setup guidance (Phase 6)
            newOutcomes.append(contentsOf: try scanNotificationSetupGuidance())

            // 12. Role suggestions review
            newOutcomes.append(contentsOf: scanRoleSuggestions())

            // 13. Stale contacts → archive suggestions
            newOutcomes.append(contentsOf: try scanStaleContacts(people: allPeople))

            // 14. Progressive feature adoption coaching
            newOutcomes.append(contentsOf: scanFeatureAdoption())

            // 15. Substack auto-detection
            newOutcomes.append(contentsOf: try scanSubstackAutoDetection())

            // 16. WhatsApp auto-detection
            newOutcomes.append(contentsOf: scanWhatsAppAutoDetection())

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

            // Generate companion "heads-up" outcomes for detailed communications
            var companions: [SamOutcome] = []
            for outcome in newOutcomes where outcome.messageCategory == .detailed {
                if let companion = maybeCreateCompanionOutcome(for: outcome) {
                    companions.append(companion)
                }
            }
            newOutcomes.append(contentsOf: companions)

            // Score all new outcomes using calibrated weights
            let weights = CoachingAdvisor.shared.adjustedWeights()
            // Pre-compute health for all linked people to avoid redundant calls in the scoring loop
            let linkedPeople = Set(newOutcomes.compactMap { $0.linkedPerson })
            let healthCache = Dictionary(linkedPeople.map { ($0.id, meetingPrep.computeHealth(for: $0)) }, uniquingKeysWith: { first, _ in first })
            for outcome in newOutcomes {
                outcome.priorityScore = computePriority(outcome: outcome, weights: weights, healthCache: healthCache)
            }

            // Filter muted kinds
            let mutedKinds = Set(CalibrationService.cachedLedger.mutedKinds)
            if !mutedKinds.isEmpty {
                newOutcomes.removeAll { mutedKinds.contains($0.outcomeKindRawValue) }
            }

            // Soft suppress: kinds with <15% act rate after 20+ interactions get 0.3x priority
            let calibrationLedger = CalibrationService.cachedLedger
            for outcome in newOutcomes {
                if let kindStat = calibrationLedger.kindStats[outcome.outcomeKindRawValue],
                   kindStat.actedOn + kindStat.dismissed >= 20,
                   kindStat.actRate < 0.15 {
                    outcome.priorityScore *= 0.3
                }
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

            // Detect knowledge gaps
            activeGaps = detectKnowledgeGaps()

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
        let weights = CoachingAdvisor.shared.adjustedWeights()
        let active = try outcomeRepo.fetchActive()
        let linkedPeople = Set(active.compactMap { $0.linkedPerson })
        let healthCache = Dictionary(uniqueKeysWithValues: linkedPeople.map { ($0.id, meetingPrep.computeHealth(for: $0)) })
        for outcome in active {
            outcome.priorityScore = computePriority(outcome: outcome, weights: weights, healthCache: healthCache)
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

            let attendees = event.linkedPeople.filter { !$0.isMe }
            let primary = attendees.first ?? event.linkedPeople.first
            let eventEnd = event.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: event.occurredAt)!
            let minutesSince = Int(now.timeIntervalSince(eventEnd) / 60)

            // Build attendee names and meeting time for specificity
            let attendeeNames = attendees.map { $0.displayNameCache ?? $0.displayName }
            let nameStr = attendeeNames.isEmpty ? "" : " with \(attendeeNames.joined(separator: ", "))"
            let timeStr = eventEnd.formatted(date: .omitted, time: .shortened)
            let dayLabel: String
            if Calendar.current.isDateInYesterday(eventEnd) {
                dayLabel = "yesterday's"
            } else if Calendar.current.isDateInToday(eventEnd) {
                dayLabel = "today's"
            } else {
                dayLabel = eventEnd.formatted(date: .abbreviated, time: .omitted)
            }

            let timeAgoStr: String
            if minutesSince < 1 {
                timeAgoStr = "Just ended"
            } else if minutesSince < 60 {
                timeAgoStr = "\(minutesSince) minute\(minutesSince == 1 ? "" : "s") since it ended"
            } else {
                let hours = minutesSince / 60
                timeAgoStr = "\(hours) hour\(hours == 1 ? "" : "s") since it ended"
            }

            return SamOutcome(
                title: "Capture notes from \(dayLabel) \(event.title)\(nameStr) (\(timeStr))",
                rationale: "\(timeAgoStr). Record key points while they're fresh.",
                outcomeKind: .followUp,
                deadlineDate: Calendar.current.date(byAdding: .hour, value: 72, to: eventEnd),
                sourceInsightSummary: "Past meeting without notes: \(event.title)",
                suggestedNextStep: "Open the meeting capture sheet to record discussion, action items, and follow-ups",
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

            // Build last interaction context
            let lastInteraction = person.linkedEvidence
                .filter { $0.source.isInteraction }
                .sorted { $0.occurredAt > $1.occurredAt }
                .first
            let lastInteractionContext: String
            if let ev = lastInteraction {
                let dateStr = ev.occurredAt.formatted(date: .abbreviated, time: .omitted)
                let snippetPreview = String(ev.snippet.prefix(80))
                lastInteractionContext = " (\(ev.source.displayName.lowercased()) about \(snippetPreview) on \(dateStr))"
            } else {
                lastInteractionContext = ""
            }

            // 1. Static threshold: existing behavior — now direction-aware
            let threshold = roleThreshold(for: person.roleBadges.first)
            if days >= threshold {
                // Check if the user has recently reached out without response
                let recentOutbound = health.outboundCount30 > 0
                let noRecentInbound = health.inboundCount30 == 0

                let title: String
                let rationale: String
                let insight: String

                if recentOutbound && noRecentInbound {
                    // User is reaching out but contact isn't responding
                    let outDays = health.daysSinceLastOutbound ?? days
                    title = "Try a different channel with \(name)"
                    rationale = "You reached out \(outDays) day\(outDays == 1 ? "" : "s") ago but haven't heard back in \(days) days\(lastInteractionContext). Consider calling or meeting in person."
                    insight = "Outbound with no response in \(days) days"
                } else {
                    // Add role-specific insight
                    let roleInsight: String
                    switch role.lowercased() {
                    case "client":
                        roleInsight = " — a policy review may be overdue."
                    case "applicant":
                        roleInsight = " — application may stall without follow-up."
                    case "lead":
                        roleInsight = " — lead may go cold without re-engagement."
                    default:
                        roleInsight = "."
                    }
                    title = "Reconnect with \(name)"
                    rationale = "\(days) days since last interaction\(lastInteractionContext). \(role) relationship\(roleInsight)"
                    insight = "No interaction in \(days) days (threshold: \(threshold) for \(role))"
                }

                outcomes.append(SamOutcome(
                    title: title,
                    rationale: rationale,
                    outcomeKind: .outreach,
                    priorityScore: 0.7,
                    sourceInsightSummary: insight,
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
                    rationale: "Engagement declining — predicted overdue in \(predicted) day\(predicted == 1 ? "" : "s")\(lastInteractionContext). \(role) relationship.",
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
    /// Creates one outcome per stale lead (capped at 3) instead of a generic "review pipeline".
    private func scanGrowthOpportunities(people: [SamPerson]) throws -> [SamOutcome] {
        var outcomes: [SamOutcome] = []

        // Pre-compute health for all people to avoid redundant calls in loops/filters below
        let healthMap = Dictionary(uniqueKeysWithValues: people.map { ($0.id, meetingPrep.computeHealth(for: $0)) })

        // Find leads not contacted recently, sorted by staleness
        let leads = people.filter { $0.roleBadges.contains("Lead") }
        let staleLeads = leads.compactMap { person -> (SamPerson, Int, SamEvidenceItem?)? in
            let days = healthMap[person.id]?.daysSinceLastInteraction ?? 999
            guard days > 14 else { return nil }
            let lastEvidence = person.linkedEvidence
                .filter { $0.source.isInteraction }
                .sorted { $0.occurredAt > $1.occurredAt }
                .first
            return (person, days, lastEvidence)
        }.sorted { $0.1 > $1.1 } // Most stale first

        // One outcome per stale lead, capped at 3
        for (person, days, lastEvidence) in staleLeads.prefix(3) {
            let name = person.displayNameCache ?? person.displayName

            let lastContactStr: String
            if let ev = lastEvidence {
                let dateStr = ev.occurredAt.formatted(date: .abbreviated, time: .omitted)
                let snippet = String(ev.snippet.prefix(60))
                lastContactStr = "Last interaction was \(ev.source.displayName.lowercased()) on \(dateStr): \(snippet)."
            } else {
                lastContactStr = "No prior interactions on record."
            }

            let leadSince = person.stageTransitions
                .filter { $0.toStage == "Lead" }
                .sorted { $0.transitionDate > $1.transitionDate }
                .first?.transitionDate

            let sinceStr: String
            if let date = leadSince {
                sinceStr = " Lead since \(date.formatted(date: .abbreviated, time: .omitted))."
            } else {
                sinceStr = ""
            }

            outcomes.append(SamOutcome(
                title: "Reach out to \(name) — last contact \(days) days ago",
                rationale: "\(lastContactStr)\(sinceStr) Lead relationship.",
                outcomeKind: .growth,
                sourceInsightSummary: "Stale lead: \(name), \(days) days since last contact",
                suggestedNextStep: "Send a quick check-in to re-engage",
                linkedPerson: person
            ))
        }

        // Suggest referral outreach if a client has been active
        let activeClients = people.filter { person in
            person.roleBadges.contains("Client")
            && (healthMap[person.id]?.daysSinceLastInteraction ?? 999) <= 14
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

            // Look for conversation opener from recent notes/evidence
            let recentTopics = client.linkedNotes
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(3)
                .flatMap { $0.extractedTopics }
            let openerContext: String
            if let relevantTopic = recentTopics.first(where: {
                $0.lowercased().contains("kid") || $0.lowercased().contains("education")
                || $0.lowercased().contains("retire") || $0.lowercased().contains("college")
                || $0.lowercased().contains("family") || $0.lowercased().contains("future")
            }) {
                openerContext = " In a recent conversation, \(name) mentioned \"\(relevantTopic)\" — a natural opener for discussing \(gapList)."
            } else if let lastNote = client.linkedNotes.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                let dateStr = lastNote.updatedAt.formatted(date: .abbreviated, time: .omitted)
                openerContext = " Your last note (\(dateStr)) could inform the conversation."
            } else {
                openerContext = ""
            }

            outcomes.append(SamOutcome(
                title: "Consider \(gapList) for \(name)",
                rationale: "\(name) has \(existingList) but no \(gapList).\(openerContext)",
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

        // Fall back to direct ContentAdvisorService call (skip if no digest —
        // avoid blocking outcome generation with a slow LLM call on first run)
        if topics.isEmpty {
            logger.debug("No cached content topics from StrategicCoordinator; skipping AI fallback to avoid stalling outcome generation")
            return []
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

        // Substack: nudge after 14 days (bi-weekly cadence for long-form)
        if let substackDays = try? ContentPostRepository.shared.daysSinceLastPost(platform: .substack),
           substackDays >= 14 {
            let hasSimilar = outcomes.isEmpty ? ((try? outcomeRepo.hasSimilarOutcome(
                kind: .contentCreation,
                personID: nil,
                withinHours: 72
            )) ?? false) : true // Already have a cadence nudge, skip
            if !hasSimilar {
                outcomes.append(SamOutcome(
                    title: "Write a Substack article — \(substackDays) days since last post",
                    rationale: "Consistent long-form content builds authority and engages your subscriber base. Your readers expect regular insights.",
                    outcomeKind: .contentCreation,
                    sourceInsightSummary: "",
                    suggestedNextStep: "Draft an article extending a recent client conversation or seasonal topic"
                ))
            }
        }

        return outcomes
    }

    // MARK: - Goal Pacing Scanner (Phase X)

    /// Generate coaching outcomes for goals that are behind or at risk.
    private func scanGoalPacing() -> [SamOutcome] {
        let allProgress = GoalProgressEngine.shared.computeAllProgress()
        var outcomes: [SamOutcome] = []

        for gp in allProgress {
            guard gp.pace == .behind || gp.pace == .atRisk else { continue }

            // Dedup: one goal-pacing outcome per goal type every 72 hours
            let hasSimilar = (try? outcomeRepo.hasSimilarOutcome(
                kind: goalOutcomeKind(for: gp.goalType),
                personID: nil,
                withinHours: 72
            )) ?? false
            guard !hasSimilar else { continue }

            let remaining = max(gp.targetValue - gp.currentValue, 0)
            let rateText = goalRateText(gp)
            let paceLabel = gp.pace.displayName

            let (title, rationale, step, kind) = goalOutcomeDetails(
                goalType: gp.goalType,
                paceLabel: paceLabel,
                remaining: remaining,
                rateText: rateText,
                daysRemaining: gp.daysRemaining
            )

            let outcome = SamOutcome(
                title: title,
                rationale: rationale,
                outcomeKind: kind,
                priorityScore: gp.pace == .atRisk ? 0.8 : 0.6,
                deadlineDate: Calendar.current.date(byAdding: .day, value: min(gp.daysRemaining, 7), to: .now),
                sourceInsightSummary: "Goal: \(gp.title) — \(Int(gp.currentValue))/\(Int(gp.targetValue))",
                suggestedNextStep: step
            )
            outcomes.append(outcome)
        }

        return outcomes
    }

    // MARK: - Deduced Relationships Scanner

    private func scanDeducedRelationships() -> [SamOutcome] {
        guard let unconfirmed = try? DeducedRelationRepository.shared.fetchUnconfirmed(),
              !unconfirmed.isEmpty else { return [] }

        // One batched outcome for all unconfirmed deductions
        let hasSimilar = (try? outcomeRepo.hasSimilarOutcome(
            kind: .outreach,
            personID: nil,
            withinHours: 24
        )) ?? false

        // Check title-based dedup since we use .outreach kind
        if hasSimilar {
            let active = (try? outcomeRepo.fetchActive()) ?? []
            let alreadyExists = active.contains { $0.title.contains("deduced relationship") }
            if alreadyExists { return [] }
        }

        let count = unconfirmed.count
        let outcome = SamOutcome(
            title: "Review \(count) deduced relationship\(count == 1 ? "" : "s")",
            rationale: "SAM found family connections in your contact records that may link to people you know.",
            outcomeKind: .outreach,
            priorityScore: 0.5,
            deadlineDate: Calendar.current.date(byAdding: .day, value: 7, to: .now),
            sourceInsightSummary: "Deduced from Apple Contacts related names",
            suggestedNextStep: "Open the Relationship Map to review and confirm these connections."
        )
        outcome.actionLaneRawValue = ActionLane.reviewGraph.rawValue
        return [outcome]
    }

    // MARK: - Role Suggestions Review

    private func scanRoleSuggestions() -> [SamOutcome] {
        let suggestions = RoleDeductionEngine.shared.pendingSuggestions
        guard !suggestions.isEmpty else { return [] }

        // Title-based dedup
        let active = (try? outcomeRepo.fetchActive()) ?? []
        if active.contains(where: { $0.title.contains("suggested role") }) { return [] }

        // Build rationale summarizing role groups
        var roleCounts: [String: Int] = [:]
        for s in suggestions {
            roleCounts[s.suggestedRole, default: 0] += 1
        }
        let summary = roleCounts.sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)\($0.value == 1 ? "" : "s")" }
            .joined(separator: ", ")

        let outcome = SamOutcome(
            title: "Review \(suggestions.count) suggested role\(suggestions.count == 1 ? "" : "s")",
            rationale: "SAM analyzed your calendar, communications, and contacts to suggest roles: \(summary).",
            outcomeKind: .outreach,
            priorityScore: 0.55,
            deadlineDate: Calendar.current.date(byAdding: .day, value: 7, to: .now),
            sourceInsightSummary: "Deduced from calendar titles, communication patterns, and contact metadata",
            suggestedNextStep: "Open the Relationship Map to review and confirm role assignments."
        )
        outcome.actionLaneRawValue = ActionLane.reviewGraph.rawValue
        return [outcome]
    }

    // MARK: - LinkedIn Notification Setup Guidance (Phase 6)

    /// Scan for missing LinkedIn notification types and surface setup guidance outcomes.
    private func scanNotificationSetupGuidance() throws -> [SamOutcome] {
        guard MailImportCoordinator.shared.mailEnabled else { return [] }
        guard let startDate = Self.linkedInMonitoringStartDate else { return [] }

        let daysSinceStart = Calendar.current.dateComponents([.day], from: startDate, to: .now).day ?? 0
        var outcomes: [SamOutcome] = []

        let hasAny = (try? touchRepo.hasAnyEmailNotificationTouches()) ?? false

        // Global check: if no LinkedIn emails at all have been received
        if !hasAny && daysSinceStart >= LinkedInNotificationSetupGuide.noEmailsGuidance.suggestionThresholdDays {
            if let outcome = makeSetupOutcome(
                guide: LinkedInNotificationSetupGuide.noEmailsGuidance,
                userDefaultsKey: LinkedInNotificationSetupGuide.noEmailsUserDefaultsKey
            ) {
                outcomes.append(outcome)
            }
            return outcomes   // Don't check per-type until we've seen at least one email
        }

        guard hasAny else { return [] }

        // Per-type check: look for notification types missing from the rolling 30-day window
        let rollingWindowStart = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let seenTypes = (try? touchRepo.emailNotificationTypesSeenSince(rollingWindowStart)) ?? []

        // Suppress post-dependent types if user has never posted on LinkedIn
        let hasPostedContent = (try? ContentPostRepository.shared.daysSinceLastPost(platform: .linkedin)) != nil

        for monitored in LinkedInNotificationSetupGuide.monitoredTypes {
            if monitored.requiresUserPosts && !hasPostedContent { continue }
            if seenTypes.contains(monitored.touchType.rawValue) { continue }
            if daysSinceStart < monitored.suggestionThresholdDays { continue }

            if let outcome = makeSetupOutcome(guide: monitored, userDefaultsKey: monitored.userDefaultsKey) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// Build a SamOutcome for a single setup guidance type, applying dismiss/acknowledge logic.
    /// Returns nil if the outcome should be suppressed (too soon after dismiss/ack, already active, or verified).
    private func makeSetupOutcome(
        guide: LinkedInNotificationSetupGuide.MonitoredType,
        userDefaultsKey key: String
    ) -> SamOutcome? {
        let defaults = UserDefaults.standard

        // Acknowledgement check: user said "Already Done"
        if defaults.bool(forKey: "\(key).acknowledged") {
            let ackTime = defaults.double(forKey: "\(key).acknowledgedAt")
            if ackTime > 0 {
                let ackDate = Date(timeIntervalSince1970: ackTime)
                // If we've seen this notification type since acknowledgement, verified — suppress permanently
                let seenSinceAck = (try? touchRepo.emailNotificationTypesSeenSince(ackDate)) ?? []
                if seenSinceAck.contains(guide.touchType.rawValue) { return nil }
                // Give the setup 14 days to take effect before resurface
                let daysSinceAck = Calendar.current.dateComponents([.day], from: ackDate, to: .now).day ?? 0
                if daysSinceAck < 14 { return nil }
                // 14+ days with no verification — reset acknowledgement and resurface
                defaults.set(false, forKey: "\(key).acknowledged")
            }
        }

        // Dismiss timing check: resurface after 7 days (or 30 days after 3+ dismissals)
        let dismissCount = defaults.integer(forKey: "\(key).dismissCount")
        let lastDismissedTime = defaults.double(forKey: "\(key).lastDismissedAt")
        if lastDismissedTime > 0 {
            let lastDismissed = Date(timeIntervalSince1970: lastDismissedTime)
            let daysSinceDismiss = Calendar.current.dateComponents([.day], from: lastDismissed, to: .now).day ?? 0
            let resurfaceDays = dismissCount >= 3 ? 30 : 7
            if daysSinceDismiss < resurfaceDays { return nil }
        }

        // Title-based dedup: don't create a second active outcome with the same title
        let active = (try? outcomeRepo.fetchActive()) ?? []
        if active.contains(where: { $0.outcomeKind == .setup && $0.title == guide.title }) { return nil }

        // Build the JSON payload stored in sourceInsightSummary
        let payload = SetupGuidePayload(
            touchTypeRawValue: guide.touchType.rawValue,
            userDefaultsKey: key,
            instructions: guide.instructions,
            whyItMatters: guide.whyItMatters,
            settingsURL: LinkedInNotificationSetupGuide.settingsURL.absoluteString
        )
        let payloadJSON = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? ""

        let outcome = SamOutcome(
            title: guide.title,
            rationale: guide.whyItMatters,
            outcomeKind: .setup,
            priorityScore: guide.priority,
            sourceInsightSummary: payloadJSON,
            suggestedNextStep: "Open LinkedIn notification settings and follow the steps"
        )
        outcome.actionLane = .openURL
        outcome.draftMessageText = LinkedInNotificationSetupGuide.settingsURL.absoluteString
        return outcome
    }

    /// The date SAM began monitoring LinkedIn email notifications.
    /// Uses the UserDefaults timestamp written by MailImportCoordinator; falls back to the mail watermark.
    private static var linkedInMonitoringStartDate: Date? {
        let ts = UserDefaults.standard.double(forKey: "sam.linkedin.monitoringSince")
        if ts > 0 { return Date(timeIntervalSince1970: ts) }
        if let watermark = MailImportCoordinator.shared.lastMailWatermark {
            return watermark
        }
        return nil
    }

    // MARK: - Stale Contact Scanner (#13)

    /// Find active contacts with no evidence in 12+ months and no pipeline
    /// relevance, then suggest archiving. One per scan cycle, lowest priority.
    private func scanStaleContacts(people: [SamPerson]) throws -> [SamOutcome] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -12, to: .now) ?? .now
        let pipelineRoles: Set<String> = ["Lead", "Applicant", "Agent"]

        // Skip if we already have an active "Consider archiving" outcome
        let active = (try? outcomeRepo.fetchActive()) ?? []
        if active.contains(where: { $0.title.contains("Consider archiving") }) { return [] }

        for person in people {
            // Skip people with pipeline-relevant roles
            if !Set(person.roleBadges).isDisjoint(with: pipelineRoles) { continue }

            // Check for any evidence in the last 12 months
            let hasRecent = person.linkedEvidence.contains { $0.occurredAt > cutoff }
            if hasRecent { continue }

            let personName = person.displayNameCache ?? person.displayName
            let outcome = SamOutcome(
                title: "Consider archiving \(personName)",
                rationale: "No interactions in the last 12 months and no active pipeline role.",
                outcomeKind: .outreach,
                priorityScore: 0.15,
                sourceInsightSummary: "Stale contact with no recent evidence",
                suggestedNextStep: "Open their profile and archive if no longer relevant.",
                linkedPerson: person
            )
            return [outcome]
        }
        return []
    }

    /// Progressive feature adoption coaching — suggests one feature at a time
    /// based on days since onboarding and whether the user has tried each feature.
    private func scanFeatureAdoption() -> [SamOutcome] {
        let suggestions = FeatureAdoptionTracker.shared.suggestionsForUnusedFeatures()
        return suggestions.compactMap { suggestion in
            let isDuplicate = (try? outcomeRepo.hasSimilarOutcome(title: suggestion.title)) ?? false
            guard !isDuplicate else { return nil }
            FeatureAdoptionTracker.shared.markCoached(suggestion.feature)
            return SamOutcome(
                title: suggestion.title,
                rationale: suggestion.rationale,
                outcomeKind: .setup,
                priorityScore: 0.4,
                sourceInsightSummary: "Feature adoption coaching: \(suggestion.feature.rawValue)",
                suggestedNextStep: suggestion.suggestedNextStep
            )
        }
    }

    /// Suggests enabling Substack integration when Me contact has a substack.com URL.
    private func scanSubstackAutoDetection() throws -> [SamOutcome] {
        // Skip if already configured
        guard UserDefaults.standard.string(forKey: "sam.substack.feedURL") == nil else { return [] }

        // Check if Me contact has a Substack URL via cached contact data
        guard let me = try? peopleRepo.fetchMe() else { return [] }

        // Check email aliases and linked evidence for substack.com references
        let hasSubstackURL = me.emailAliases.contains { $0.lowercased().contains("substack.com") }
            || me.linkedEvidence.contains { $0.snippet.lowercased().contains("substack.com") }

        guard hasSubstackURL else { return [] }

        // Dedup — don't suggest again within 7 days
        let isDuplicate = (try? outcomeRepo.hasSimilarOutcome(kind: .setup, personID: nil, withinHours: 168)) ?? false
        guard !isDuplicate else { return [] }

        let outcome = SamOutcome(
            title: "Enable Substack Integration",
            rationale: "SAM found a Substack URL on your contact card. Connect your feed to track posting cadence and get content coaching.",
            outcomeKind: .setup,
            priorityScore: 0.5,
            sourceInsightSummary: "Substack auto-detection: URL found on Me contact",
            suggestedNextStep: "Open Settings → Data Sources → Substack"
        )
        outcome.actionLane = .openURL
        return [outcome]
    }

    /// Suggests enabling WhatsApp integration when the database exists on disk.
    private func scanWhatsAppAutoDetection() -> [SamOutcome] {
        // Skip if already configured
        guard !BookmarkManager.shared.hasWhatsAppAccess else { return [] }

        // Check if WhatsApp database exists
        let whatsAppPath = NSHomeDirectory()
            .appending("/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
        guard FileManager.default.fileExists(atPath: whatsAppPath) else { return [] }

        // Dedup
        let isDuplicate = (try? outcomeRepo.hasSimilarOutcome(kind: .setup, personID: nil, withinHours: 168)) ?? false
        guard !isDuplicate else { return [] }

        let outcome = SamOutcome(
            title: "Enable WhatsApp Integration",
            rationale: "SAM detected WhatsApp on this Mac. Connect it to import message history and track communication patterns.",
            outcomeKind: .setup,
            priorityScore: 0.5,
            sourceInsightSummary: "WhatsApp auto-detection: database found on disk",
            suggestedNextStep: "Open Settings → Data Sources → Communications"
        )
        outcome.actionLane = .openURL
        return [outcome]
    }

    /// Map GoalType to the most appropriate OutcomeKind.
    private func goalOutcomeKind(for goalType: GoalType) -> OutcomeKind {
        switch goalType {
        case .newClients:        return .growth
        case .policiesSubmitted: return .proposal
        case .productionVolume:  return .growth
        case .recruiting:        return .outreach
        case .meetingsHeld:      return .preparation
        case .contentPosts:      return .contentCreation
        case .deepWorkHours:     return .growth
        case .eventsHosted:      return .growth
        }
    }

    /// Generate title, rationale, next step, and kind for a behind/at-risk goal.
    /// Includes people-specific context where applicable (e.g., pending applicants for submissions goal).
    private func goalOutcomeDetails(
        goalType: GoalType,
        paceLabel: String,
        remaining: Double,
        rateText: String,
        daysRemaining: Int
    ) -> (title: String, rationale: String, step: String, kind: OutcomeKind) {
        let kind = goalOutcomeKind(for: goalType)

        switch goalType {
        case .newClients:
            // Find warmest leads
            let allLeads = (try? peopleRepo.fetchAll()
                .filter { $0.roleBadges.contains("Lead") && !$0.isArchived }) ?? []
            let leadHealthMap = Dictionary(uniqueKeysWithValues: allLeads.map { ($0.id, meetingPrep.computeHealth(for: $0)) })
            let leadNames = allLeads
                .sorted {
                    (leadHealthMap[$0.id]?.daysSinceLastInteraction ?? 999)
                    < (leadHealthMap[$1.id]?.daysSinceLastInteraction ?? 999)
                }
                .prefix(3)
                .compactMap { $0.displayNameCache ?? $0.displayName }
            let leadStr = leadNames.isEmpty ? "" : " Warmest leads: \(leadNames.joined(separator: ", "))."
            return (
                "Review pipeline for client conversions",
                "\(paceLabel) on new clients — \(Int(remaining)) remaining over \(daysRemaining) days (\(rateText)).\(leadStr)",
                leadNames.isEmpty ? "Identify leads ready for next-step meetings" : "Schedule a next-step meeting with \(leadNames.first ?? "a lead")",
                kind
            )
        case .policiesSubmitted:
            // Find applicants with pending paperwork
            let applicantNames = (try? peopleRepo.fetchAll()
                .filter { $0.roleBadges.contains("Applicant") && !$0.isArchived }
                .prefix(3)
                .compactMap { $0.displayNameCache ?? $0.displayName }) ?? []
            let appStr = applicantNames.isEmpty ? "" : " You have \(applicantNames.count) applicant\(applicantNames.count == 1 ? "" : "s") with pending paperwork: \(applicantNames.joined(separator: ", "))."
            return (
                "Push pending applications forward",
                "\(paceLabel) on submissions — \(Int(remaining)) remaining over \(daysRemaining) days (\(rateText)).\(appStr)",
                applicantNames.isEmpty ? "Review in-progress applications" : "Follow up with \(applicantNames.first ?? "an applicant") on missing documents",
                kind
            )
        case .productionVolume:
            let volStr = remaining >= 1_000 ? String(format: "$%.0fK", remaining / 1_000) : String(format: "$%.0f", remaining)
            return (
                "Focus on premium volume opportunities",
                "\(paceLabel) on production — \(volStr) remaining over \(daysRemaining) days (\(rateText)).",
                "Review clients who may benefit from higher-coverage or additional products",
                kind
            )
        case .recruiting:
            return (
                "Schedule recruiting conversations",
                "\(paceLabel) on recruiting — \(Int(remaining)) remaining over \(daysRemaining) days (\(rateText)).",
                "Reach out to warm prospects or ask top agents for referrals",
                kind
            )
        case .meetingsHeld:
            return (
                "Book more meetings this period",
                "\(paceLabel) on meetings — \(Int(remaining)) remaining over \(daysRemaining) days (\(rateText)).",
                "Check your contact list for overdue check-ins to schedule",
                kind
            )
        case .contentPosts:
            return (
                "Create and publish content",
                "\(paceLabel) on content — \(Int(remaining)) posts remaining over \(daysRemaining) days (\(rateText)).",
                "Draft a quick educational post or client success story",
                kind
            )
        case .deepWorkHours:
            let hoursStr = String(format: "%.1f", remaining)
            return (
                "Block focused work time",
                "\(paceLabel) on deep work — \(hoursStr) hours remaining over \(daysRemaining) days (\(rateText)).",
                "Schedule a 2-hour focus block on your calendar for tomorrow",
                kind
            )
        case .eventsHosted:
            return (
                "Plan your next event",
                "\(paceLabel) on events — \(Int(remaining)) remaining over \(daysRemaining) days (\(rateText)).",
                "Create a new event in SAM and start building your invitation list",
                kind
            )
        }
    }

    /// Rate text for goal pacing with guardrails against absurd daily rates.
    /// When dailyNeeded exceeds a reasonable max for the goal type, reframes as weekly or monthly.
    private func goalRateText(_ gp: GoalProgress) -> String {
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

        // If daily rate is unreasonable, skip to weekly
        if perDay > reasonableDailyMax {
            // If weekly rate is also unreasonable, show monthly with a note
            if perWeek > reasonableWeeklyMax {
                return "Need ~\(format(perMonth))/month — significant catch-up needed"
            }
            return "Need ~\(format(perWeek)) per week"
        }

        if perDay >= 1 {
            return "Need \(format(perDay)) per day"
        } else if perWeek >= 1 {
            return "Need \(format(perWeek)) per week"
        } else {
            return "Need \(format(perMonth)) per month"
        }
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
            logger.debug("Generated role transition outcomes for \(name): added=\(addedRoles), removed=\(removedRoles)")
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
        // Preserve pre-set lanes (e.g., reviewGraph, openURL for setup outcomes)
        if outcome.actionLane == .reviewGraph || outcome.actionLane == .openURL { return }

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
        case .setup:
            outcome.actionLane = .openURL
        }
    }

    /// Suggest the best communication channel for an outcome targeting a person,
    /// using message-category-aware routing.
    func suggestChannel(for outcome: SamOutcome) -> CommunicationChannel {
        let title = outcome.title.lowercased()

        // Resolve category: title keyword overrides, then OutcomeKind default
        let category: MessageCategory
        if title.contains("proposal") || title.contains("analysis") || title.contains("document") {
            category = .detailed
        } else if title.contains("linkedin") || title.contains("connect on") {
            category = .social
        } else if title.contains("congratulat") || title.contains("thank") || title.contains("check in") || title.contains("heads up") || title.contains("reminder") {
            category = .quick
        } else {
            category = outcome.outcomeKind.messageCategory
        }

        // Store the resolved category on the outcome
        outcome.messageCategory = category

        // Use person's category-specific channel preference
        if let person = outcome.linkedPerson,
           let ch = person.effectiveChannel(for: category) {
            return ch
        }

        // Category defaults
        switch category {
        case .quick:    return .iMessage
        case .detailed: return .email
        case .social:   return .linkedIn
        }
    }

    /// Create a companion "heads-up" outcome for detailed communications
    /// when the person's quick channel differs from the detailed channel.
    func maybeCreateCompanionOutcome(for primary: SamOutcome) -> SamOutcome? {
        guard primary.messageCategory == .detailed,
              !primary.isCompanionOutcome,
              let person = primary.linkedPerson else { return nil }

        let quickChannel = person.effectiveChannel(for: .quick) ?? .iMessage
        let detailedChannel = primary.suggestedChannel ?? .email

        // Only create companion when channels differ
        guard quickChannel != detailedChannel else { return nil }

        let personName = person.displayNameCache ?? person.displayName
        let channelName = detailedChannel.displayName.lowercased()

        let companion = SamOutcome(
            title: "Heads-up: text \(personName) about your \(channelName)",
            rationale: "Let \(personName) know to watch for your \(channelName) — increases response rate.",
            outcomeKind: .followUp,
            priorityScore: primary.priorityScore * 0.8,
            deadlineDate: primary.deadlineDate,
            sourceInsightSummary: "Companion heads-up for: \(primary.title)",
            suggestedNextStep: "Send a quick text so they know to check their \(channelName)",
            linkedPerson: person,
            linkedContext: primary.linkedContext
        )
        companion.actionLane = .communicate
        companion.suggestedChannel = quickChannel
        companion.messageCategory = .quick
        companion.companionOfID = primary.id
        companion.isCompanionOutcome = true
        companion.draftMessageText = "Hi \(personName), I just sent you something by \(channelName) — check your inbox!"
        return companion
    }

    // MARK: - Priority Computation

    private func computePriority(
        outcome: SamOutcome,
        weights: OutcomeWeights,
        healthCache: [UUID: RelationshipHealth]? = nil
    ) -> Double {
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
            let health = healthCache?[person.id] ?? meetingPrep.computeHealth(for: person)
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

        // User engagement — per-kind act rate from calibration (after 5+ interactions for the kind)
        let ledger = CalibrationService.cachedLedger
        if let kindStat = ledger.kindStats[outcome.outcomeKindRawValue],
           kindStat.actedOn + kindStat.dismissed >= 5 {
            score += weights.userEngagement * kindStat.actRate
        } else {
            score += weights.userEngagement * 0.5  // Neutral until enough data
        }

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

    // MARK: - Rich Context Builder

    /// Assemble a focused context block for an outcome's linked person, suitable for AI enrichment.
    /// Caps output at ~800 tokens to stay within on-device LLM limits.
    private func buildEnrichmentContext(for outcome: SamOutcome) -> String {
        guard let person = outcome.linkedPerson else {
            return gapAnswersContext()
        }

        var parts: [String] = []
        let name = person.displayNameCache ?? person.displayName
        let role = person.roleBadges.first ?? "Contact"

        // Person & role
        parts.append("Person: \(name) (\(role))")

        // Relationship summary
        if let summary = person.relationshipSummary, !summary.isEmpty {
            parts.append("Relationship summary: \(summary)")
        }

        // Key themes
        if !person.relationshipKeyThemes.isEmpty {
            parts.append("Key themes: \(person.relationshipKeyThemes.joined(separator: ", "))")
        }

        // Recent evidence (last 3 interactions)
        let recentEvidence = person.linkedEvidence
            .filter { $0.source.isInteraction }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(3)
        if !recentEvidence.isEmpty {
            let items = recentEvidence.map { ev in
                let dateStr = ev.occurredAt.formatted(date: .abbreviated, time: .omitted)
                let snippet = ev.snippet.prefix(120)
                let dirLabel: String
                switch ev.direction {
                case .outbound: dirLabel = " (sent)"
                case .inbound:  dirLabel = " (received)"
                default:        dirLabel = ""
                }
                return "- \(ev.source.displayName)\(dirLabel) on \(dateStr): \(snippet)"
            }.joined(separator: "\n")
            parts.append("Recent interactions:\n\(items)")
        }

        // Last note date + topics
        let recentNote = person.linkedNotes
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
        if let note = recentNote {
            let dateStr = note.updatedAt.formatted(date: .abbreviated, time: .omitted)
            let topics = note.extractedTopics.prefix(3).joined(separator: ", ")
            let topicStr = topics.isEmpty ? "" : " — topics: \(topics)"
            parts.append("Last note: \(dateStr)\(topicStr)")
        }

        // Pending action items from notes
        let pendingActions = person.linkedNotes
            .flatMap { $0.extractedActionItems }
            .filter { $0.status == .pending }
            .prefix(3)
        if !pendingActions.isEmpty {
            let items = pendingActions.map { "- \($0.description)" }.joined(separator: "\n")
            parts.append("Pending action items:\n\(items)")
        }

        // Pipeline stage
        if let stage = person.recruitingStages.sorted(by: { $0.enteredDate > $1.enteredDate }).first {
            parts.append("Pipeline: \(stage.stageRawValue)")
        }

        // Production holdings
        let records = (try? ProductionRepository.shared.fetchRecords(forPerson: person.id)) ?? []
        if !records.isEmpty {
            let holdings = records.map { "\($0.productType.displayName) (\($0.status.displayName))" }.joined(separator: ", ")
            parts.append("Current products: \(holdings)")
        }

        // Communication channel preference
        if let channel = person.effectiveChannel {
            parts.append("Preferred channel: \(channel.displayName)")
        }

        // Gap answers
        let gapCtx = gapAnswersContext()
        if !gapCtx.isEmpty {
            parts.append(gapCtx)
        }

        // Cap at ~800 tokens (~3200 chars)
        var result = parts.joined(separator: "\n")
        if result.count > 3200 {
            result = String(result.prefix(3200)) + "..."
        }
        return result
    }

    // MARK: - Knowledge Gap Detection

    /// Detect gaps in SAM's knowledge that the user could fill via inline prompts.
    func detectKnowledgeGaps() -> [KnowledgeGap] {
        var gaps: [KnowledgeGap] = []
        let defaults = UserDefaults.standard

        // No leads and no known referral sources
        let hasLeads = (try? peopleRepo.fetchAll().contains { $0.roleBadges.contains("Lead") }) ?? false
        if !hasLeads && defaults.string(forKey: "sam.gap.referralSources") == nil {
            gaps.append(KnowledgeGap(
                id: "referralSources",
                question: "Who are your best referral sources? (Name people or groups)",
                placeholder: "e.g., John Smith, Elev8tors group, BNI chapter...",
                icon: "person.2.badge.plus",
                storageKey: "sam.gap.referralSources"
            ))
        }

        // No content posts and content suggestions enabled
        let contentEnabled = defaults.object(forKey: "contentSuggestionsEnabled") == nil
            ? true
            : defaults.bool(forKey: "contentSuggestionsEnabled")
        let hasContentPosts = (try? ContentPostRepository.shared.daysSinceLastPost(platform: .linkedin)) != nil
        if contentEnabled && !hasContentPosts && defaults.string(forKey: "sam.gap.contentTopics") == nil {
            gaps.append(KnowledgeGap(
                id: "contentTopics",
                question: "What topics does your audience care about?",
                placeholder: "e.g., retirement planning, life insurance basics, tax strategies...",
                icon: "text.bubble",
                storageKey: "sam.gap.contentTopics"
            ))
        }

        // Stale leads but no associations/groups recorded
        let allLeadsForGaps = (try? peopleRepo.fetchAll().filter { $0.roleBadges.contains("Lead") }) ?? []
        let gapHealthMap = Dictionary(uniqueKeysWithValues: allLeadsForGaps.map { ($0.id, meetingPrep.computeHealth(for: $0)) })
        let staleLeads = allLeadsForGaps.filter {
            (gapHealthMap[$0.id]?.daysSinceLastInteraction ?? 999) > 14
        }
        if !staleLeads.isEmpty && defaults.string(forKey: "sam.gap.associations") == nil {
            gaps.append(KnowledgeGap(
                id: "associations",
                question: "What professional groups or associations are you part of?",
                placeholder: "e.g., BNI, local chamber of commerce, Elev8tors...",
                icon: "building.2",
                storageKey: "sam.gap.associations"
            ))
        }

        // Goal with no progress data and <30 days old
        let allProgress = GoalProgressEngine.shared.computeAllProgress()
        for gp in allProgress {
            if gp.currentValue == 0 && gp.daysRemaining > (gp.daysRemaining + 30) - 30 {
                let key = "sam.gap.goalProgress.\(gp.goalType.rawValue)"
                if defaults.string(forKey: key) == nil {
                    gaps.append(KnowledgeGap(
                        id: "goalProgress.\(gp.goalType.rawValue)",
                        question: "Have you made progress on \"\(gp.title)\" that SAM hasn't tracked?",
                        placeholder: "e.g., 3 meetings held, 2 applications submitted...",
                        icon: "chart.bar",
                        storageKey: key
                    ))
                    break // Only one goal gap at a time
                }
            }
        }

        return gaps
    }

    /// Format all answered knowledge gaps as context for AI prompts.
    func gapAnswersContext() -> String {
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

        return parts.isEmpty ? "" : "User-provided context:\n" + parts.joined(separator: "\n")
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
                logger.debug("AI not available — skipping enrichment")
                return
            }

            for outcome in topOutcomes {
                // Generate suggested next step if missing
                if outcome.suggestedNextStep == nil {
                    let context = buildEnrichmentContext(for: outcome)
                    let persona = await BusinessProfileService.shared.personaFragment()
                    let prompt = """
                        You are a coaching assistant for \(persona).
                        Given this outcome and relationship context, suggest a concrete next step.

                        Outcome: \(outcome.title)
                        Context: \(outcome.rationale)

                        \(context)

                        The next step must be specific: name the person, reference recent interactions, \
                        and describe exactly what to do (not "follow up" but "send a text asking about \
                        the project update from your last conversation").

                        IMPORTANT: Your suggestion MUST be grounded in the actual evidence and topics \
                        shown above. Only reference subjects that appear in the recent interactions or \
                        notes. Never assume or invent topics not supported by the context.
                        """

                    let systemInstruction = """
                        Respond with ONLY the next step — one short, actionable sentence.
                        Do not include any preamble, formatting, or explanation.
                        Base your suggestion strictly on the topics present in the context provided.
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
        let channel = outcome.suggestedChannel ?? .iMessage
        let category = outcome.messageCategory ?? outcome.outcomeKind.messageCategory
        let channelNote: String
        switch (category, channel) {
        case (.quick, .iMessage):  channelNote = "a very brief text message, 2-3 sentences max"
        case (.quick, _):          channelNote = "a very brief, friendly message (2-3 sentences)"
        case (.detailed, .email):  channelNote = "a professional, thorough email (2-4 paragraphs)"
        case (.detailed, _):       channelNote = "a detailed, professional message (2-3 paragraphs)"
        case (.social, .linkedIn): channelNote = "a professional LinkedIn networking message (2-3 sentences)"
        case (.social, _):         channelNote = "a professional networking message (2-3 sentences)"
        }

        let richContext = buildEnrichmentContext(for: outcome)

        let prompt = """
            Draft \(channelNote) from \(await BusinessProfileService.shared.personaFragment()) to \(personName).

            Purpose: \(outcome.title)
            Context: \(outcome.rationale)

            \(richContext)

            Reference specific recent interactions or topics you discussed.
            The message should feel personal, not templated.
            The sender's name is not needed — the message will be sent from their account.
            Keep the tone warm but professional.

            IMPORTANT: Only reference subjects that appear in the context above. \
            Never assume or invent topics not supported by the actual evidence.
            """

        let systemInstruction: String
        switch (category, channel) {
        case (.quick, .iMessage):
            systemInstruction = """
                Write ONLY the message text — no greeting line with "Hi [Name]," unless it fits naturally.
                Keep it under 2-3 sentences. Very brief and casual but professional. No emojis. No signature.
                """
        case (.detailed, .email):
            systemInstruction = """
                Write the email body only — no subject line.
                Start with a greeting. Be thorough and professional (2-4 paragraphs).
                Cover the topic in detail. End with a clear call to action or next step.
                End with a simple closing. No signature block.
                """
        case (.social, .linkedIn):
            systemInstruction = """
                Write ONLY the message text — keep it under 3 sentences.
                Professional networking tone. Reference shared interests or mutual connections.
                No emojis. No signature. No connection request phrasing.
                """
        case (_, .iMessage):
            systemInstruction = """
                Write ONLY the message text — no greeting line with "Hi [Name]," unless it fits naturally.
                Keep it under 3 sentences. Casual but professional. No emojis. No signature.
                """
        case (_, .email):
            systemInstruction = """
                Write the email body only — no subject line.
                Start with a greeting. Keep it concise (2-3 short paragraphs). Professional tone.
                End with a simple closing like "Best" or "Looking forward to hearing from you."
                No signature block.
                """
        case (_, .phone), (_, .faceTime):
            systemInstruction = """
                Write 3-4 brief talking points as a simple list, one per line.
                Each point should be a conversation starter or key topic to cover.
                No bullet markers, just plain text lines.
                """
        case (_, .linkedIn):
            systemInstruction = """
                Write ONLY the message text — keep it under 3 sentences.
                Professional but warm. No emojis. No signature. No connection requests phrasing.
                """
        case (_, .whatsApp):
            systemInstruction = """
                Write ONLY the message text — no greeting line unless it fits naturally.
                Keep it under 3 sentences. Casual but professional, like a text message.
                No emojis. No signature.
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

                // Phase Z: Compliance audit logging
                let flags = ComplianceScanner.scanWithSettings(draft)
                try ComplianceAuditRepository.shared.logDraft(
                    channel: channel.rawValue,
                    recipientName: personName,
                    originalDraft: draft,
                    complianceFlags: flags,
                    outcomeID: outcome.id
                )
            }
        } catch {
            logger.warning("Draft generation failed for '\(outcome.title)': \(error.localizedDescription)")
        }
    }
}
