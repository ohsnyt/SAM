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
import SwiftData

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
        if BackupCoordinator.isRestoring { return }
        guard generationStatus != .generating else { return }
        Task { await generateOutcomes() }
    }

    /// Synthesize outcomes from all evidence sources.
    func generateOutcomes() async {
        if BackupCoordinator.isRestoring { return }
        guard generationStatus != .generating else { return }
        generationStatus = .generating
        lastError = nil

        await PerformanceMonitor.shared.measure("OutcomeEngine.generateOutcomes") {
            await self._generateOutcomesBody()
        }
    }

    private func _generateOutcomesBody() async {
        if BackupCoordinator.isRestoring {
            generationStatus = .idle
            return
        }
        do {
            let perf = PerformanceMonitor.shared

            try perf.measureSync("OutcomeEngine.pruneExpired") { try outcomeRepo.pruneExpired() }

            let woken = try perf.measureSync("OutcomeEngine.wakeExpiredSnoozes") { try outcomeRepo.wakeExpiredSnoozes() }
            try perf.measureSync("OutcomeEngine.autoResolveWoken") {
                for outcome in woken {
                    if shouldAutoResolve(outcome) {
                        try outcomeRepo.markCompleted(id: outcome.id)
                        logger.info("Auto-resolved woken outcome: \(outcome.title)")
                    }
                }
            }

            // Yield between heavy fetches so the @MainActor releases for UI work.
            // Evidence is no longer loaded wholesale — each scanner that needs it
            // does its own date-bounded fetch (see scanUpcomingMeetings et al.).
            let allPeople = try perf.measureSync("OutcomeEngine.fetchAllPeople") {
                try peopleRepo.fetchAll().filter { !$0.isMe && !$0.isArchived && $0.hasMeaningfulSignal }
            }
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }
            let allNotes = try perf.measureSync("OutcomeEngine.fetchAllNotes") { try notesRepo.fetchAll() }
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            var newOutcomes: [SamOutcome] = []

            // 1. Upcoming meetings → preparation outcomes
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.upcomingMeetings") { try scanUpcomingMeetings() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 2. Past meetings without notes → followUp outcomes
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.pastMeetingsWithoutNotes") { try scanPastMeetingsWithoutNotes(allNotes: allNotes) })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 3. Pending action items → proposal / followUp outcomes
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.pendingActionItems") { try scanPendingActionItems(allNotes: allNotes) })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 4. Relationship health → outreach outcomes
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.relationshipHealth") { try scanRelationshipHealth(people: allPeople) })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 5. Growth opportunities (when few active outcomes)
            let activeCount = (try? outcomeRepo.fetchActive().count) ?? 0
            if activeCount + newOutcomes.count < 3 {
                newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.growthOpportunities") { try scanGrowthOpportunities(people: allPeople) })
            }
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 6. Coverage gap cross-sell (Phase S)
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.coverageGaps") { try scanCoverageGaps(people: allPeople) })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 7. Content suggestions (Phase W)
            newOutcomes.append(contentsOf: await perf.measure("OutcomeEngine.contentSuggestions") { await scanContentSuggestions() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 8. Content cadence nudges (Phase W)
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.contentCadence") { try scanContentCadence() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 9. Goal pacing coaching (Phase X)
            newOutcomes.append(contentsOf: perf.measureSync("OutcomeEngine.goalPacing") { scanGoalPacing() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 10. Deduced relationships review
            newOutcomes.append(contentsOf: perf.measureSync("OutcomeEngine.deducedRelationships") { scanDeducedRelationships() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 11. LinkedIn notification setup guidance (Phase 6)
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.notificationSetupGuidance") { try scanNotificationSetupGuidance() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 12. Role suggestions review
            newOutcomes.append(contentsOf: perf.measureSync("OutcomeEngine.roleSuggestions") { scanRoleSuggestions() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 13. Stale contacts → archive suggestions
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.staleContacts") { try scanStaleContacts(people: allPeople) })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 14. Progressive feature adoption coaching
            newOutcomes.append(contentsOf: perf.measureSync("OutcomeEngine.featureAdoption") { scanFeatureAdoption() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 15. Substack auto-detection
            newOutcomes.append(contentsOf: try perf.measureSync("OutcomeEngine.substackAutoDetection") { try scanSubstackAutoDetection() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 16. WhatsApp auto-detection
            newOutcomes.append(contentsOf: perf.measureSync("OutcomeEngine.whatsAppAutoDetection") { scanWhatsAppAutoDetection() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 17. Role recruiting discovery & cultivation
            newOutcomes.append(contentsOf: perf.measureSync("OutcomeEngine.roleRecruiting") { scanRoleRecruiting() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // 18. Sarah's open commitments due soon (Block 3)
            newOutcomes.append(contentsOf: perf.measureSync("OutcomeEngine.openCommitments") { scanOpenCommitments() })
            await Task.yield()
            if BackupCoordinator.isRestoring { generationStatus = .idle; return }

            // Classify action lanes and suggest channels
            perf.measureSync("OutcomeEngine.classifyActionLanes") {
                for outcome in newOutcomes {
                    classifyActionLane(for: outcome)
                    if outcome.actionLane == .communicate || outcome.actionLane == .call {
                        outcome.suggestedChannel = suggestChannel(for: outcome)
                    }
                }
            }

            // Generate multi-step sequence follow-ups for communicate/call outcomes
            let sequenceSteps = perf.measureSync("OutcomeEngine.buildSequenceSteps") { () -> [SamOutcome] in
                var steps: [SamOutcome] = []
                for outcome in newOutcomes {
                    let outcomeSteps = maybeCreateSequenceSteps(for: outcome)
                    if !outcomeSteps.isEmpty {
                        let seqID = UUID()
                        outcome.sequenceID = seqID
                        outcome.sequenceIndex = 0
                        for (i, step) in outcomeSteps.enumerated() {
                            step.sequenceID = seqID
                            step.sequenceIndex = i + 1
                        }
                        steps.append(contentsOf: outcomeSteps)
                    }
                }
                return steps
            }
            newOutcomes.append(contentsOf: sequenceSteps)

            // Generate companion "heads-up" outcomes for detailed communications
            let companions = perf.measureSync("OutcomeEngine.buildCompanions") { () -> [SamOutcome] in
                var result: [SamOutcome] = []
                for outcome in newOutcomes where outcome.messageCategory == .detailed {
                    if let companion = maybeCreateCompanionOutcome(for: outcome) {
                        result.append(companion)
                    }
                }
                return result
            }
            newOutcomes.append(contentsOf: companions)

            // Score all new outcomes using calibrated weights.
            // Iter 2: reuses currentRunHealthCache populated by
            // scanRelationshipHealth — eliminates a second round of
            // computeHealth calls (was 2.3 s on its own).
            await perf.measure("OutcomeEngine.scorePriorities") {
                let weights = CoachingAdvisor.shared.adjustedWeights()
                let healthCache = currentRunHealthCache
                for outcome in newOutcomes {
                    outcome.priorityScore = computePriority(outcome: outcome, weights: weights, healthCache: healthCache)
                }
            }

            // Filter muted kinds
            perf.measureSync("OutcomeEngine.filterMutedKinds") {
                let mutedKinds = Set(CalibrationService.cachedLedger.mutedKinds)
                if !mutedKinds.isEmpty {
                    newOutcomes.removeAll { mutedKinds.contains($0.outcomeKindRawValue) }
                }
            }

            // Soft suppress: kinds with <15% act rate after 20+ interactions get 0.3x priority
            perf.measureSync("OutcomeEngine.softSuppress") {
                let calibrationLedger = CalibrationService.cachedLedger
                for outcome in newOutcomes {
                    if let kindStat = calibrationLedger.kindStats[outcome.outcomeKindRawValue],
                       kindStat.actedOn + kindStat.dismissed >= 20,
                       kindStat.actRate < 0.15 {
                        outcome.priorityScore *= 0.3
                    }
                }
            }

            // Persist (deduplication: skip if an active duplicate exists OR
            // if the user recently dismissed/completed the same suggestion).
            // Iter 2: pre-build a single dedup index and insert without per-item
            // save. Was 10.0 s for ~80 outcomes (160 full-table fetches + 80
            // saves); now one full-table fetch + one save at the end.
            let persisted = try await perf.measure("OutcomeEngine.persistOutcomes") { () -> Int in
                let dedup = try outcomeRepo.buildDedupIndex()
                var count = 0
                var batch = 0
                for outcome in newOutcomes {
                    let kindRaw = outcome.outcomeKindRawValue
                    let pid = outcome.linkedPerson?.id
                    if dedup.isDuplicate(kindRaw: kindRaw, personID: pid) { continue }
                    if dedup.wasActedOn(kindRaw: kindRaw, personID: pid) { continue }
                    try outcomeRepo.insertWithoutSave(outcome: outcome)
                    count += 1
                    batch += 1
                    if batch % 25 == 0 { await Task.yield() }
                }
                if count > 0 { try outcomeRepo.save() }
                return count
            }

            // Detect knowledge gaps
            activeGaps = perf.measureSync("OutcomeEngine.detectKnowledgeGaps") { detectKnowledgeGaps() }

            // AI enrichment (best-effort, non-blocking)
            await perf.measure("OutcomeEngine.enrichWithAI") { await enrichWithAI() }

            // Reprioritize all active outcomes
            try await perf.measure("OutcomeEngine.reprioritize") { try await reprioritize() }

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
    func reprioritize() async throws {
        // Flush any unsaved mutations (e.g. from enrichWithAI) so the context
        // is consistent before we re-fetch and mutate again.
        try? outcomeRepo.save()

        let weights = CoachingAdvisor.shared.adjustedWeights()
        let active = try outcomeRepo.fetchActive()

        // Iter 2: reuse the run-wide healthCache built in scanRelationshipHealth
        // (covers all people from fetchAllPeople). Falls back to a per-person
        // computeHealth only if the active outcome links a person we didn't see
        // on this pass (rare). Was rebuilding the whole cache here = 2.3–4.5 s.
        var healthCache = currentRunHealthCache
        var personBatch = 0
        for outcome in active {
            guard !outcome.isDeleted,
                  let person = outcome.linkedPerson,
                  !person.isDeleted,
                  healthCache[person.id] == nil else { continue }
            healthCache[person.id] = meetingPrep.computeHealth(for: person)
            personBatch += 1
            if personBatch % 25 == 0 { await Task.yield() }
        }

        // Iter 2: iterate the already-fetched array directly — the prior code
        // did a full-table fetch per outcome (N²) which dominated the 2.7 s cost.
        var outcomeBatch = 0
        for outcome in active where !outcome.isDeleted {
            outcome.priorityScore = computePriority(outcome: outcome, weights: weights, healthCache: healthCache)
            outcomeBatch += 1
            if outcomeBatch % 25 == 0 { await Task.yield() }
        }
        try? outcomeRepo.save()
    }

    // MARK: - Snooze Auto-Resolve

    /// Check whether a woken snoozed outcome can be auto-resolved.
    /// Returns true if outbound evidence to the linked person appeared since the snooze,
    /// or if the linked event already has the person as a participant.
    private func shouldAutoResolve(_ outcome: SamOutcome) -> Bool {
        guard let snoozedAt = outcome.snoozedAt else { return false }

        // Check for outbound evidence to the linked person since snooze
        if let person = outcome.linkedPerson {
            let outboundSources: Set<EvidenceSource> = [.mail, .iMessage, .whatsApp]
            let recentEvidence = (try? evidenceRepo.fetchOccurringBetween(snoozedAt, nil)) ?? []
            let hasOutbound = recentEvidence.contains { ev in
                ev.isFromMe
                && outboundSources.contains(ev.source)
                && ev.linkedPeople.contains(where: { $0.id == person.id })
            }
            if hasOutbound && (outcome.outcomeKind == .followUp || outcome.outcomeKind == .outreach) {
                return true
            }
        }

        // For event-linked outcomes: check if the person was already added as participant
        if let event = outcome.linkedEvent, let person = outcome.linkedPerson {
            let participations = EventRepository.shared.fetchParticipations(for: event)
            if participations.contains(where: { $0.person?.id == person.id }) {
                return true
            }
        }

        return false
    }

    // MARK: - Scanners

    /// Scan upcoming meetings (next 48h) → preparation outcomes.
    private func scanUpcomingMeetings() throws -> [SamOutcome] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .hour, value: 48, to: now)!

        let candidates = try evidenceRepo.fetchOccurringBetween(now, cutoff)
        let upcoming = candidates.filter {
            $0.source == .calendar
            && $0.linkedPeople.contains(where: { !$0.isDeleted })
        }

        return upcoming.compactMap { event -> SamOutcome? in
            let attendees = event.linkedPeople.filter { !$0.isDeleted && !$0.isMe }
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
    private func scanPastMeetingsWithoutNotes(allNotes: [SamNote]) throws -> [SamOutcome] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .hour, value: -48, to: now)!
        // Pull from a slightly wider window so events whose `endedAt` falls inside
        // the cutoff but whose `occurredAt` started a bit earlier still surface.
        let lookbackStart = Calendar.current.date(byAdding: .hour, value: -56, to: now)!

        let candidates = try evidenceRepo.fetchOccurringBetween(lookbackStart, now)
        let pastEvents = candidates.filter { item in
            item.source == .calendar
            && item.linkedPeople.contains(where: { !$0.isDeleted })
            && (item.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: item.occurredAt)!) <= now
            && (item.endedAt ?? Calendar.current.date(byAdding: .hour, value: 1, to: item.occurredAt)!) >= cutoff
        }

        return pastEvents.compactMap { event -> SamOutcome? in
            let attendeeIDs = Set(event.linkedPeople.filter { !$0.isDeleted }.map(\.id))

            // Check if a note was created after the event referencing any attendee
            let hasNote = allNotes.contains { note in
                note.createdAt >= event.occurredAt
                && note.linkedPeople.contains(where: { attendeeIDs.contains($0.id) })
            }
            guard !hasNote else { return nil }

            let attendees = event.linkedPeople.filter { !$0.isDeleted && !$0.isMe }
            let primary = attendees.first ?? event.linkedPeople.first(where: { !$0.isDeleted })
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

    /// Per-run cache of relationship health, populated by `scanRelationshipHealth`
    /// and reused by `scorePriorities` / `reprioritize` to avoid re-faulting evidence
    /// for every linked person on every scoring pass.
    /// Iter 2 fix: prevented reprioritize from doing 50× redundant computeHealth
    /// calls (was 4.5 s on the +5 min run).
    private var currentRunHealthCache: [UUID: RelationshipHealth] = [:]

    /// Read-only snapshot of the most recent health cache. Used by
    /// `DailyBriefingCoordinator.gatherFollowUps` to avoid recomputing
    /// health for ~200 people that `scanRelationshipHealth` just walked.
    /// Empty if outcome generation has not yet run this session.
    var healthCacheSnapshot: [UUID: RelationshipHealth] {
        currentRunHealthCache
    }

    /// Scan relationship health for people going cold → outreach outcomes.
    /// Includes both static-threshold outcomes and velocity-aware predictive outcomes.
    /// Side effect: populates `currentRunHealthCache` so later phases can reuse the work.
    private func scanRelationshipHealth(people: [SamPerson]) throws -> [SamOutcome] {
        var outcomes: [SamOutcome] = []
        currentRunHealthCache.removeAll(keepingCapacity: true)
        currentRunHealthCache.reserveCapacity(people.count)

        // Phase 1c instrumentation — relationshipHealth is the slowest scanner.
        // We log aggregate timing once per call so the cost can be split between
        // computeHealth (per-person evidence walk) and the rest of the iteration.
        let scanStart = Date()
        var healthCumulative: TimeInterval = 0
        var healthCalls = 0

        for person in people {
            let healthStart = Date()
            let health = meetingPrep.computeHealth(for: person)
            currentRunHealthCache[person.id] = health
            healthCumulative += Date().timeIntervalSince(healthStart)
            healthCalls += 1
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

        let totalElapsed = Date().timeIntervalSince(scanStart)
        logger.info("scanRelationshipHealth: \(healthCalls) people in \(totalElapsed, format: .fixed(precision: 3))s (computeHealth \(healthCumulative, format: .fixed(precision: 3))s = \(healthCumulative / max(totalElapsed, 0.001) * 100, format: .fixed(precision: 0))%)")

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

            // Use journal learnings to inform the suggested next step
            let journalEntry = try? GoalJournalRepository.shared.fetchLatest(for: gp.goalID)

            let (title, rationale, defaultStep, kind) = goalOutcomeDetails(
                goalType: gp.goalType,
                paceLabel: paceLabel,
                remaining: remaining,
                rateText: rateText,
                daysRemaining: gp.daysRemaining
            )

            // Prefer journal-informed step over generic advice
            let step: String
            if let entry = journalEntry {
                if let strategy = entry.adjustedStrategy, !strategy.isEmpty {
                    step = "You recently decided to try: \"\(strategy)\" — have you acted on this?"
                } else if let firstAction = entry.commitmentActions.first {
                    step = "You committed to: \"\(firstAction)\" — have you done this yet?"
                } else {
                    step = defaultStep
                }
            } else {
                step = defaultStep
            }

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

        // Check-in nudge: if behind/atRisk and no recent journal entry (>14 days)
        for gp in allProgress where gp.pace == .behind || gp.pace == .atRisk {
            let latestEntry = try? GoalJournalRepository.shared.fetchLatest(for: gp.goalID)
            let daysSinceCheckIn: Int
            if let entry = latestEntry {
                daysSinceCheckIn = Calendar.current.dateComponents([.day], from: entry.createdAt, to: .now).day ?? 999
            } else {
                daysSinceCheckIn = 999  // Never checked in
            }

            guard daysSinceCheckIn >= 14 else { continue }

            // Title-based dedup
            let active = (try? outcomeRepo.fetchActive()) ?? []
            let alreadyNudged = active.contains { $0.title.contains("Check in on") && $0.title.contains(gp.title) }
            guard !alreadyNudged else { continue }

            let nudge = SamOutcome(
                title: "Check in on your \(gp.title) goal",
                rationale: "You're \(gp.pace.displayName.lowercased()) on \(gp.title) and haven't checked in \(daysSinceCheckIn == 999 ? "yet" : "in \(daysSinceCheckIn) days"). A quick conversation helps SAM give better guidance.",
                outcomeKind: goalOutcomeKind(for: gp.goalType),
                priorityScore: 0.5,
                deadlineDate: Calendar.current.date(byAdding: .day, value: 3, to: .now),
                sourceInsightSummary: "Goal: \(gp.title) — \(gp.pace.displayName)",
                suggestedNextStep: "Open the Goals tab and tap 'Check In' on this goal."
            )
            outcomes.append(nudge)
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

            // Check for any evidence in the last 12 months. Cancelled / no-show meetings
            // don't count — if they only "interacted" via events that never happened, they
            // really are stale.
            let hasRecent = person.linkedEvidence.contains {
                $0.occurredAt > cutoff && $0.reviewStatus.countsAsOccurred
            }
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
                outcomeKind: .training,
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
        case .roleFilling:       return .roleFilling
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
        case .roleFilling:
            return (
                "Fill open role positions",
                "\(paceLabel) on role filling — \(Int(remaining)) remaining over \(daysRemaining) days (\(rateText)).",
                "Scan your contacts for potential candidates or follow up with existing candidates",
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
        case .roleFilling:       reasonableDailyMax = 2;  reasonableWeeklyMax = 5
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
                let wasActedOn = try outcomeRepo.hasRecentlyActedOutcome(
                    kind: outcome.outcomeKind,
                    personID: person.id
                )
                if !isDuplicate && !wasActedOn {
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
        case .roleFilling:
            outcome.actionLane = .communicate
        case .userTask:
            outcome.actionLane = .record
        case .commitment:
            outcome.actionLane = .communicate
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
            let topOutcomeIDs = Array(active.prefix(5).map { $0.id })
            guard !topOutcomeIDs.isEmpty else { return }

            let availability = await AIService.shared.checkAvailability()
            guard case .available = availability else {
                logger.debug("AI not available — skipping enrichment")
                return
            }

            for outcomeID in topOutcomeIDs {
                // Re-fetch outcome after each await to avoid stale/deleted model crashes
                guard let outcome = try? outcomeRepo.fetch(id: outcomeID),
                      !outcome.isDeleted,
                      outcome.status == .pending || outcome.status == .inProgress else {
                    continue
                }

                // Generate suggested next step if missing
                if outcome.suggestedNextStep == nil {
                    let context = buildEnrichmentContext(for: outcome)
                    let persona = await BusinessProfileService.shared.personaFragment()

                    // Re-fetch again after await — model may have been invalidated
                    guard let freshOutcome = try? outcomeRepo.fetch(id: outcomeID),
                          !freshOutcome.isDeleted else {
                        continue
                    }

                    let prompt = """
                        You are a coaching assistant for \(persona).
                        Given this outcome and relationship context, suggest a concrete next step.

                        Outcome: \(freshOutcome.title)
                        Context: \(freshOutcome.rationale)

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
                        // Re-fetch after AI call before mutating
                        guard let liveOutcome = try? outcomeRepo.fetch(id: outcomeID),
                              !liveOutcome.isDeleted else {
                            continue
                        }
                        if !nextStep.isEmpty {
                            liveOutcome.suggestedNextStep = nextStep
                        }
                    } catch {
                        logger.warning("AI enrichment failed for outcome \(outcomeID): \(error.localizedDescription)")
                    }
                }

                // Generate draft message for communicate/call lanes
                // Re-fetch before checking draft eligibility
                if let draftOutcome = try? outcomeRepo.fetch(id: outcomeID),
                   !draftOutcome.isDeleted,
                   draftOutcome.draftMessageText == nil,
                   (draftOutcome.actionLane == .communicate || draftOutcome.actionLane == .call) {
                    await generateDraftMessage(for: outcomeID)
                }
            }
        } catch {
            logger.warning("AI enrichment skipped: \(error.localizedDescription)")
        }
    }

    /// Generate a draft message for a communicate or call outcome.
    /// Accepts an outcome ID and re-fetches before/after AI calls to avoid stale model crashes.
    private func generateDraftMessage(for outcomeID: UUID) async {
        guard let outcome = try? outcomeRepo.fetch(id: outcomeID),
              !outcome.isDeleted else { return }
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
            // Re-fetch after AI call to avoid mutating a stale/deleted model
            guard let liveOutcome = try? outcomeRepo.fetch(id: outcomeID),
                  !liveOutcome.isDeleted else { return }
            if !draft.isEmpty {
                liveOutcome.draftMessageText = draft
                logger.debug("Generated draft message for '\(liveOutcome.title)'")

                // Phase Z: Compliance audit logging
                let flags = ComplianceScanner.scanWithSettings(draft)
                try ComplianceAuditRepository.shared.logDraft(
                    channel: channel.rawValue,
                    recipientName: personName,
                    originalDraft: draft,
                    complianceFlags: flags,
                    outcomeID: liveOutcome.id
                )
            }
        } catch {
            logger.warning("Draft generation failed for outcome \(outcomeID): \(error.localizedDescription)")
        }
    }

    // MARK: - Role Recruiting Scanner

    /// Generates .roleFilling outcomes for role recruiting discovery & cultivation.
    private func scanRoleRecruiting() -> [SamOutcome] {
        var outcomes: [SamOutcome] = []

        let repo = RoleRecruitingRepository.shared
        guard let roles = try? repo.fetchActiveRoles() else { return [] }

        for role in roles {
            let candidates = (try? repo.fetchCandidates(for: role.id, includeTerminal: true)) ?? []
            let activeCandidates = candidates.filter { !$0.stage.isTerminal }

            // 1. Criteria gap: active role with empty criteria and empty idealCandidateProfile
            if role.criteria.isEmpty && role.idealCandidateProfile.isEmpty {
                outcomes.append(SamOutcome(
                    title: "Define what makes a good \(role.name) candidate",
                    rationale: "SAM needs criteria to scan your contacts for \(role.name) candidates.",
                    outcomeKind: .roleFilling,
                    priorityScore: 0.7,
                    sourceInsightSummary: "Role \(role.name) has no criteria defined"
                ))
                continue  // Can't generate other outcomes without criteria
            }

            // 2. Scan nudge: active role with criteria but 0 candidates
            if activeCandidates.isEmpty && !role.criteria.isEmpty {
                let lastScored = RoleRecruitingCoordinator.shared.lastScoredAt[role.id]
                let stale = lastScored == nil || Date.now.timeIntervalSince(lastScored!) > 24 * 60 * 60
                if stale {
                    outcomes.append(SamOutcome(
                        title: "Scan contacts for \(role.name) candidates",
                        rationale: "You have criteria defined but haven't scanned yet. SAM can identify matches in your network.",
                        outcomeKind: .roleFilling,
                        priorityScore: 0.6,
                        sourceInsightSummary: "Role \(role.name): criteria exist but no candidates scored"
                    ))
                }
            }

            // 3. Follow-up nudge: candidate in .approached with no contact in 14+ days
            let approachedStale = activeCandidates.filter { candidate in
                candidate.stage == .approached
                && (candidate.lastContactedAt == nil
                    || Date.now.timeIntervalSince(candidate.lastContactedAt!) > 14 * 24 * 60 * 60)
            }
            for candidate in approachedStale.prefix(3) {
                guard let person = candidate.person else { continue }
                let name = person.displayNameCache ?? person.displayName
                let daysSince = candidate.lastContactedAt.map {
                    Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0
                } ?? 0
                outcomes.append(SamOutcome(
                    title: "Follow up with \(name) about the \(role.name) role",
                    rationale: "It's been \(daysSince) days since you last reached out.",
                    outcomeKind: .roleFilling,
                    priorityScore: 0.65,
                    sourceInsightSummary: "Role candidate follow-up: \(name) for \(role.name)",
                    linkedPerson: person
                ))
            }

            // 4. Initial contact nudge: approved candidate in .suggested for 7+ days
            let suggestedStale = activeCandidates.filter { candidate in
                candidate.stage == .suggested
                && candidate.isUserApproved
                && Date.now.timeIntervalSince(candidate.stageEnteredAt) > 7 * 24 * 60 * 60
            }
            for candidate in suggestedStale.prefix(3) {
                guard let person = candidate.person else { continue }
                let name = person.displayNameCache ?? person.displayName
                let topStrength = candidate.strengthSignals.first ?? "matching profile"
                outcomes.append(SamOutcome(
                    title: "Reach out to \(name) about the \(role.name) role",
                    rationale: "They scored \(Int(candidate.matchScore * 100))% because of \(topStrength).",
                    outcomeKind: .roleFilling,
                    priorityScore: 0.55,
                    sourceInsightSummary: "Role candidate outreach: \(name) for \(role.name)",
                    linkedPerson: person
                ))
            }

            // 5. Existing member referral: filledCount < targetCount AND people exist with matching role
            if role.filledCount < role.targetCount {
                let committed = candidates.filter { $0.stage == .committed }
                for member in committed.prefix(2) {
                    guard let person = member.person else { continue }
                    let name = person.displayNameCache ?? person.displayName

                    // Check 30-day window dedup
                    let isDuplicate = (try? outcomeRepo.hasSimilarOutcome(
                        kind: .roleFilling,
                        personID: person.id,
                        withinHours: 30 * 24
                    )) ?? false
                    guard !isDuplicate else { continue }

                    outcomes.append(SamOutcome(
                        title: "Ask \(name) for \(role.name) referrals",
                        rationale: "\(name) understands the \(role.name) role — they may know others who'd be a good fit.",
                        outcomeKind: .roleFilling,
                        priorityScore: 0.5,
                        sourceInsightSummary: "Existing \(role.name) referral ask: \(name)",
                        linkedPerson: person
                    ))
                }
            }
        }

        return outcomes
    }

    // MARK: - Commitment scans (Block 3)

    /// Surface Sarah's open commitments due within the coaching window (default
    /// 48h). Aggregates per-person so the kind+person dedup doesn't collapse
    /// multiple commitments to the same person. The outcome's title names the
    /// next-due item; the rationale enumerates the rest.
    private func scanOpenCommitments() -> [SamOutcome] {
        // Sweep overdue pending commitments first so what we surface is current.
        _ = try? CommitmentRepository.shared.sweepMissed()

        guard let open = try? CommitmentRepository.shared.fetchOpenFromSarah(dueWithin: 3),
              !open.isEmpty else {
            return []
        }

        // Group by counterparty. Commitments without a linked person still
        // surface but are grouped under a synthetic "unassigned" bucket.
        let grouped = Dictionary(grouping: open) { $0.linkedPerson?.id ?? UUID() }

        var outcomes: [SamOutcome] = []
        for (_, bucket) in grouped {
            let sorted = bucket.sorted {
                switch ($0.dueDate, $1.dueDate) {
                case let (a?, b?): return a < b
                case (_?, nil):    return true
                case (nil, _?):    return false
                default:           return $0.createdAt < $1.createdAt
                }
            }
            guard let lead = sorted.first else { continue }

            let person = lead.linkedPerson
            let name = person.map { $0.displayNameCache ?? $0.displayName } ?? "someone"

            let title: String
            let rationale: String
            if sorted.count == 1 {
                title = "You committed to \(name): \(lead.text)"
                let due = formatDue(lead)
                rationale = due.map { "Due \($0). Mark it done once you deliver." }
                    ?? "You haven't resolved this yet. Close it out or dismiss when it's handled."
            } else {
                title = "\(sorted.count) open commitments to \(name)"
                let bullets = sorted.prefix(3).map { "• \($0.text)\(formatDue($0).map { " — \($0)" } ?? "")" }.joined(separator: "\n")
                rationale = "You have \(sorted.count) open commitments to \(name):\n\(bullets)"
            }

            let priority: Double = {
                if let due = lead.dueDate {
                    let hours = due.timeIntervalSinceNow / 3600
                    if hours < 0 { return 0.95 }        // overdue
                    if hours < 24 { return 0.85 }       // due today
                    if hours < 72 { return 0.7 }        // due in 3 days
                    return 0.55
                }
                return 0.45
            }()

            outcomes.append(SamOutcome(
                title: title,
                rationale: rationale,
                outcomeKind: .commitment,
                priorityScore: priority,
                deadlineDate: lead.dueDate,
                sourceInsightSummary: "Open commitment from Sarah (\(lead.id.uuidString))",
                linkedPerson: person
            ))
        }

        return outcomes
    }

    private func formatDue(_ commitment: SamCommitment) -> String? {
        if let due = commitment.dueDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: due, relativeTo: .now)
        }
        return commitment.dueHint
    }
}
