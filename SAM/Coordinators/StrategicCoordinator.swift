//
//  StrategicCoordinator.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  RLM-inspired orchestrator: gathers pre-aggregated data from existing
//  repositories, dispatches 4 specialist LLM analysts in parallel,
//  synthesizes results deterministically, and persists StrategicDigest.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "StrategicCoordinator")

@MainActor
@Observable
final class StrategicCoordinator {

    // MARK: - Singleton

    static let shared = StrategicCoordinator()

    // MARK: - Observable State

    enum GenerationStatus: String, Sendable {
        case idle
        case generating
        case success
        case failed
    }

    var latestDigest: StrategicDigest?
    var generationStatus: GenerationStatus = .idle
    var lastGeneratedAt: Date?
    var strategicRecommendations: [StrategicRec] = []
    var suggestedEventTopics: [SuggestedEventTopic] = []

    // MARK: - Private State

    private var context: ModelContext?

    // Cache TTLs
    private var lastPipelineAnalyzed: Date?
    private var lastTimeAnalyzed: Date?
    private var lastPatternAnalyzed: Date?
    private var lastContentAnalyzed: Date?
    private var lastEventTopicsAnalyzed: Date?

    // Cached specialist outputs
    private var cachedPipelineAnalysis: PipelineAnalysis?
    private var cachedTimeAnalysis: TimeAnalysis?
    private var cachedPatternAnalysis: PatternAnalysis?
    private var cachedContentAnalysis: ContentAnalysis?
    private var cachedEventTopicAnalysis: EventTopicAnalysis?

    // TTL durations
    private let pipelineTTL: TimeInterval = 4 * 60 * 60    // 4 hours
    private let timeTTL: TimeInterval = 12 * 60 * 60       // 12 hours
    private let patternTTL: TimeInterval = 24 * 60 * 60    // 24 hours
    private let contentTTL: TimeInterval = 24 * 60 * 60    // 24 hours
    private let eventTopicTTL: TimeInterval = 24 * 60 * 60 // 24 hours

    // Dependencies
    private let tracker = PipelineTracker.shared
    private let timeRepo = TimeTrackingRepository.shared
    private let peopleRepo = PeopleRepository.shared
    private let evidenceRepo = EvidenceRepository.shared

    private init() {}

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.context = ModelContext(container)
        loadLatestDigest()
    }

    // MARK: - Digest Generation

    func generateDigest(type: DigestType = .onDemand, onProgress: ((String) -> Void)? = nil) async {
        let enabled = UserDefaults.standard.object(forKey: "strategicDigestEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "strategicDigestEnabled")
        guard enabled else {
            logger.debug("Strategic digest disabled — skipping")
            return
        }
        guard generationStatus != .generating else { return }

        generationStatus = .generating
        let modelLabel = "hybrid/Qwen3-8B"
        logger.debug("⏱ Strategic digest starting — backend: \(modelLabel)")
        let digestClock = ContinuousClock()
        let digestStart = digestClock.now

        // Trigger stale role recruiting refresh only on scheduled digests —
        // user-triggered (onDemand) runs should not compete for AI resources
        if type != .onDemand {
            Task(priority: .utility) {
                await RoleRecruitingCoordinator.shared.refreshIfStale()
            }
        }

        // Gather data (all deterministic Swift)
        let pipelineData = gatherPipelineData()
        let timeData = gatherTimeData()
        let patternData = gatherPatternData()
        let contentData = gatherContentData()
        let eventHistoryData = gatherEventHistory()
        // Log context sizes — chars ÷ 4 ≈ tokens; helps identify which specialist has the largest input
        logger.debug("📏 Context sizes — pipeline: \(pipelineData.count)ch (~\(pipelineData.count/4)t), time: \(timeData.count)ch (~\(timeData.count/4)t), pattern: \(patternData.count)ch (~\(patternData.count/4)t), content: \(contentData.count)ch (~\(contentData.count/4)t)")

        onProgress?("Running AI specialists...")

        // Dispatch 4 specialists in parallel at background priority
        let now = Date.now
        let needsPipeline = !isCacheValid(lastPipelineAnalyzed, ttl: pipelineTTL)
        let needsTime = !isCacheValid(lastTimeAnalyzed, ttl: timeTTL)
        let needsPattern = !isCacheValid(lastPatternAnalyzed, ttl: patternTTL)
        let needsContent = !isCacheValid(lastContentAnalyzed, ttl: contentTTL)
        let needsEventTopics = !isCacheValid(lastEventTopicsAnalyzed, ttl: eventTopicTTL)
        logger.debug("🔍 Cache status — needsContent: \(needsContent), lastContentAnalyzed: \(String(describing: self.lastContentAnalyzed)), cachedContentAnalysis topics: \(self.cachedContentAnalysis?.topicSuggestions.count ?? -1)")

        // Run specialists concurrently
        async let pipelineResult = needsPipeline
            ? runPipelineAnalyst(data: pipelineData)
            : cachedPipelineAnalysis ?? PipelineAnalysis()
        async let timeResult = needsTime
            ? runTimeAnalyst(data: timeData)
            : cachedTimeAnalysis ?? TimeAnalysis()
        async let patternResult = needsPattern
            ? runPatternDetector(data: patternData)
            : cachedPatternAnalysis ?? PatternAnalysis()
        async let contentResult = needsContent
            ? runContentAdvisor(data: contentData)
            : cachedContentAnalysis ?? ContentAnalysis()
        async let eventTopicResult = needsEventTopics
            ? runEventTopicAdvisor(data: contentData, eventHistory: eventHistoryData)
            : cachedEventTopicAnalysis ?? EventTopicAnalysis()

        let pipeline = await pipelineResult
        onProgress?("Analyzing time allocation...")
        let time = await timeResult
        onProgress?("Detecting patterns...")
        let pattern = await patternResult
        onProgress?("Reviewing content strategy...")
        let content = await contentResult
        onProgress?("Evaluating event topics...")
        let eventTopics = await eventTopicResult
        onProgress?("Synthesizing recommendations...")

        // Update caches — but don't cache empty results (so they retry next time)
        if needsPipeline { cachedPipelineAnalysis = pipeline; lastPipelineAnalyzed = now }
        if needsTime { cachedTimeAnalysis = time; lastTimeAnalyzed = now }
        if needsPattern { cachedPatternAnalysis = pattern; lastPatternAnalyzed = now }
        if needsContent {
            logger.debug("🔍 Content result — \(content.topicSuggestions.count) topics, isEmpty: \(content.topicSuggestions.isEmpty)")
            cachedContentAnalysis = content
            lastContentAnalyzed = content.topicSuggestions.isEmpty ? nil : now
            logger.debug("🔍 Content cache updated — lastContentAnalyzed set to: \(String(describing: self.lastContentAnalyzed))")
        }
        if needsEventTopics { cachedEventTopicAnalysis = eventTopics; lastEventTopicsAnalyzed = now }

        // Update observable event topics
        suggestedEventTopics = eventTopics.suggestions

        // Synthesize (deterministic)
        let topRecs = synthesize(pipeline: pipeline, time: time, pattern: pattern, content: content)

        // Persist
        let digest = persistDigest(
            type: type,
            pipeline: pipeline,
            time: time,
            pattern: pattern,
            content: content,
            topRecs: topRecs
        )

        latestDigest = digest
        strategicRecommendations = topRecs
        lastGeneratedAt = now
        generationStatus = .success
        logger.debug("🔍 Digest assigned — latestDigest.contentSuggestions isEmpty: \(digest.contentSuggestions.isEmpty), length: \(digest.contentSuggestions.count)")

        let totalElapsed = digestClock.now - digestStart
        logger.info("⏱ Strategic digest complete — \(topRecs.count) recommendations — total: \(totalElapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))) — backend: \(modelLabel)")
    }

    /// Check if a fresh digest exists (< maxAge old).
    func hasFreshDigest(maxAge: TimeInterval = 4 * 60 * 60) -> Bool {
        guard let last = lastGeneratedAt else { return false }
        return Date.now.timeIntervalSince(last) < maxAge
    }

    /// Invalidate content cache so the next digest generation re-runs the content advisor.
    func invalidateContentCache() {
        logger.debug("🔍 invalidateContentCache called — clearing content cache")
        lastContentAnalyzed = nil
        cachedContentAnalysis = nil
    }

    // MARK: - Feedback

    func recordFeedback(recommendationID: UUID, feedback: RecommendationFeedback) {
        guard let digest = latestDigest else { return }

        // Update in-memory recommendations
        if let index = strategicRecommendations.firstIndex(where: { $0.id == recommendationID }) {
            strategicRecommendations[index].feedback = feedback
        }

        // Persist feedback to digest
        var feedbackMap: [String: String] = [:]
        if let existing = digest.feedbackJSON,
           let data = existing.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            feedbackMap = decoded
        }
        feedbackMap[recommendationID.uuidString] = feedback.rawValue

        if let encoded = try? JSONEncoder().encode(feedbackMap),
           let json = String(data: encoded, encoding: .utf8) {
            digest.feedbackJSON = json
        }

        // Also update strategicActions JSON with feedback
        if let actionsData = digest.strategicActions.data(using: .utf8),
           var recs = try? JSONDecoder().decode([StrategicRec].self, from: actionsData) {
            if let idx = recs.firstIndex(where: { $0.id == recommendationID }) {
                recs[idx].feedback = feedback
            }
            if let encoded = try? JSONEncoder().encode(recs),
               let json = String(data: encoded, encoding: .utf8) {
                digest.strategicActions = json
            }
        }

        try? context?.save()
        logger.debug("Feedback recorded: \(feedback.rawValue) for \(recommendationID)")
    }

    // MARK: - Data Gathering (Deterministic Swift)

    private func gatherPipelineData() -> String {
        tracker.refresh()

        let funnel = tracker.clientFunnel
        let rates = tracker.clientConversionRates
        let timeInStage = tracker.clientTimeInStage
        let velocity = tracker.clientVelocity
        let stuck = tracker.clientStuckPeople
        let production = tracker.productionByStatus
        let pendingAging = tracker.productionPendingAging

        var lines: [String] = []
        lines.append("PIPELINE SNAPSHOT:")
        lines.append("Funnel: \(funnel.leadCount) Leads, \(funnel.applicantCount) Applicants, \(funnel.clientCount) Clients")
        lines.append("Conversion: Lead->Applicant \(String(format: "%.0f", rates.leadToApplicant * 100))%, Applicant->Client \(String(format: "%.0f", rates.applicantToClient * 100))%")
        lines.append("Avg time-in-stage: Lead \(String(format: "%.0f", timeInStage.avgDaysAsLead))d, Applicant \(String(format: "%.0f", timeInStage.avgDaysAsApplicant))d")
        lines.append("Velocity: \(String(format: "%.1f", velocity)) transitions/week")

        if !stuck.isEmpty {
            lines.append("STUCK PEOPLE:")
            for person in stuck.prefix(10) {
                lines.append("  \(person.personName) — \(person.stage) for \(person.daysStuck) days")
            }
        }

        if !production.isEmpty {
            lines.append("PRODUCTION (\(tracker.productionWindowDays)d window):")
            for item in production where item.count > 0 {
                lines.append("  \(item.status.rawValue): \(item.count) cases, $\(String(format: "%.0f", item.totalPremium)) premium")
            }
        }

        if !pendingAging.isEmpty {
            lines.append("PENDING AGING:")
            for item in pendingAging.prefix(5) {
                lines.append("  \(item.personName) — \(item.productType.rawValue), \(item.daysPending)d pending, $\(String(format: "%.0f", item.premium))")
            }
        }

        // Recruiting
        let recruitFunnel = tracker.recruitFunnel
        let activeRecruits = recruitFunnel.filter { $0.count > 0 }
        if !activeRecruits.isEmpty {
            lines.append("RECRUITING:")
            for stage in activeRecruits {
                lines.append("  \(stage.stage.rawValue): \(stage.count)")
            }
            lines.append("Licensing rate: \(String(format: "%.0f", tracker.recruitLicensingRate * 100))%")
        }

        if !tracker.recruitMentoringAlerts.isEmpty {
            lines.append("MENTORING ALERTS:")
            for alert in tracker.recruitMentoringAlerts.prefix(5) {
                lines.append("  \(alert.personName) — \(alert.stage.rawValue), \(alert.daysSinceContact)d since contact")
            }
        }

        // Role Recruiting
        do {
            let roles = try RoleRecruitingRepository.shared.fetchActiveRoles()
            if !roles.isEmpty {
                lines.append("ROLE RECRUITING:")
                for role in roles {
                    let candidates = (try? RoleRecruitingRepository.shared.fetchCandidates(for: role.id, includeTerminal: true)) ?? []
                    let byCounts = Dictionary(grouping: candidates, by: { $0.stage })
                    let suggested = byCounts[.suggested]?.count ?? 0
                    let considering = byCounts[.considering]?.count ?? 0
                    let approached = byCounts[.approached]?.count ?? 0
                    let committed = byCounts[.committed]?.count ?? 0
                    lines.append("  \(role.name): \(suggested) suggested, \(considering) considering, \(approached) approached, \(committed) committed (target: \(role.targetCount))")
                }
            }
        } catch {
            logger.error("Failed to gather role recruiting pipeline data: \(error)")
        }

        // Journal barriers and strategies for pipeline-related goals
        do {
            let journalEntries = try GoalJournalRepository.shared.fetchRecent(limit: 5)
            let pipelineRelevant = journalEntries.filter { entry in
                let type = entry.goalType
                return type == .newClients || type == .policiesSubmitted || type == .recruiting || type == .roleFilling
            }
            if !pipelineRelevant.isEmpty {
                lines.append("PIPELINE GOAL LEARNINGS:")
                for entry in pipelineRelevant {
                    let goalType = entry.goalType.displayName
                    if !entry.barriers.isEmpty {
                        lines.append("  \(goalType) barriers: \(entry.barriers.joined(separator: ", "))")
                    }
                    if let strategy = entry.adjustedStrategy, !strategy.isEmpty {
                        lines.append("  \(goalType) adjusted strategy: \(strategy)")
                    }
                }
            }
        } catch {
            logger.error("Failed to gather journal pipeline data: \(error)")
        }

        return lines.joined(separator: "\n")
    }

    private func gatherTimeData() -> String {
        let now = Date.now
        let cal = Calendar.current
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: now) ?? now

        let weekBreakdown = (try? timeRepo.categoryBreakdown(from: sevenDaysAgo, to: now)) ?? [:]
        let monthBreakdown = (try? timeRepo.categoryBreakdown(from: thirtyDaysAgo, to: now)) ?? [:]

        var lines: [String] = []
        lines.append("TIME ALLOCATION (last 7 days):")
        let totalWeek = weekBreakdown.values.reduce(0, +)
        for category in TimeCategory.allCases {
            let mins = weekBreakdown[category] ?? 0
            if mins > 0 {
                let pct = totalWeek > 0 ? Double(mins) / Double(totalWeek) * 100 : 0
                lines.append("  \(category.rawValue): \(mins) min (\(String(format: "%.0f", pct))%)")
            }
        }
        lines.append("  Total: \(totalWeek) min (\(String(format: "%.1f", Double(totalWeek) / 60))h)")

        lines.append("")
        lines.append("TIME ALLOCATION (last 30 days):")
        let totalMonth = monthBreakdown.values.reduce(0, +)
        for category in TimeCategory.allCases {
            let mins = monthBreakdown[category] ?? 0
            if mins > 0 {
                let pct = totalMonth > 0 ? Double(mins) / Double(totalMonth) * 100 : 0
                lines.append("  \(category.rawValue): \(mins) min (\(String(format: "%.0f", pct))%)")
            }
        }
        lines.append("  Total: \(totalMonth) min (\(String(format: "%.1f", Double(totalMonth) / 60))h)")

        // Role distribution
        do {
            let allPeople = try peopleRepo.fetchAll()
            let active = allPeople.filter { !$0.isArchived && !$0.isMe }
            var roleCounts: [String: Int] = [:]
            for person in active {
                for badge in person.roleBadges {
                    roleCounts[badge, default: 0] += 1
                }
            }
            if !roleCounts.isEmpty {
                lines.append("")
                lines.append("CONTACT DISTRIBUTION:")
                for (role, count) in roleCounts.sorted(by: { $0.value > $1.value }) {
                    lines.append("  \(role): \(count)")
                }
            }
        } catch {
            logger.error("Failed to gather role distribution: \(error)")
        }

        return lines.joined(separator: "\n")
    }

    private func gatherPatternData() -> String {
        var lines: [String] = []

        do {
            let allPeople = try peopleRepo.fetchAll()
            let active = allPeople.filter { !$0.isArchived && !$0.isMe }

            // Communication frequency by role
            var commsByRole: [String: (count: Int, people: Int)] = [:]
            for person in active {
                let evidenceCount = person.linkedEvidence.count
                let primaryRole = person.roleBadges.first ?? "Untagged"
                var entry = commsByRole[primaryRole] ?? (count: 0, people: 0)
                entry.count += evidenceCount
                entry.people += 1
                commsByRole[primaryRole] = entry
            }

            lines.append("INTERACTION PATTERNS BY ROLE:")
            for (role, data) in commsByRole.sorted(by: { $0.value.count > $1.value.count }) {
                let avg = data.people > 0 ? Double(data.count) / Double(data.people) : 0
                lines.append("  \(role): \(data.count) total interactions across \(data.people) people (avg \(String(format: "%.1f", avg))/person)")
            }

            // Meeting outcomes — notes with action items vs without
            let allNotes = try NotesRepository.shared.fetchAll()
            let notesWithActions = allNotes.filter { note in
                guard let artifact = note.analysisArtifact else { return false }
                return !artifact.actions.isEmpty
            }
            let totalNotes = allNotes.count
            let actionRate = totalNotes > 0 ? Double(notesWithActions.count) / Double(totalNotes) * 100 : 0
            lines.append("")
            lines.append("MEETING NOTE QUALITY:")
            lines.append("  Total notes: \(totalNotes)")
            lines.append("  Notes with action items: \(notesWithActions.count) (\(String(format: "%.0f", actionRate))%)")

            // People with no recent interaction (30 days)
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
            let coldPeople = active.filter { person in
                let lastInteraction = person.linkedEvidence.map(\.occurredAt).max()
                return lastInteraction == nil || lastInteraction! < thirtyDaysAgo
            }
            lines.append("")
            lines.append("ENGAGEMENT GAPS:")
            lines.append("  People with no interaction in 30 days: \(coldPeople.count) of \(active.count)")

            // Referral tracking — people with "Referral Partner" badge and their linked evidence
            let referralPartners = active.filter { $0.roleBadges.contains("Referral Partner") }
            if !referralPartners.isEmpty {
                lines.append("")
                lines.append("REFERRAL NETWORK:")
                lines.append("  Active referral partners: \(referralPartners.count)")
                let avgReferralEvidence = referralPartners.isEmpty ? 0 :
                    Double(referralPartners.map(\.linkedEvidence.count).reduce(0, +)) / Double(referralPartners.count)
                lines.append("  Avg interactions per partner: \(String(format: "%.1f", avgReferralEvidence))")
            }

        } catch {
            logger.error("Failed to gather pattern data: \(error)")
        }

        return lines.joined(separator: "\n")
    }

    private func gatherContentData() -> String {
        var lines: [String] = []

        // Active business goals — so content ideas align with what the user is working toward
        do {
            let activeGoals = try GoalRepository.shared.fetchActive()
            if !activeGoals.isEmpty {
                lines.append("ACTIVE BUSINESS GOALS (content should support these):")
                let engine = GoalProgressEngine.shared
                for goal in activeGoals {
                    let progress = engine.computeProgress(for: goal)
                    var desc = "  - \(goal.title) (\(goal.goalType.displayName): \(Int(progress.currentValue))/\(Int(goal.targetValue)) \(goal.goalType.unit), \(progress.pace.displayName))"
                    if let notes = goal.notes, !notes.isEmpty {
                        desc += " — \(notes)"
                    }
                    lines.append(desc)
                }
                lines.append("")
            }
        } catch {
            logger.error("Failed to gather goal data for content advisor: \(error)")
        }

        // Recent meeting topics from evidence titles
        do {
            let allEvidence = try evidenceRepo.fetchAll()
            let meetingEvidence = allEvidence
                .filter { $0.source == .calendar }
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(50)
            let recentTopics = meetingEvidence.compactMap(\.title).prefix(15)
            if !recentTopics.isEmpty {
                lines.append("RECENT MEETING TOPICS:")
                for topic in recentTopics {
                    lines.append("  - \(topic)")
                }
            }

            // Note topics from analysis
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
            let recentNotes = try NotesRepository.shared.fetchAll()
                .filter { $0.updatedAt > thirtyDaysAgo }
                .prefix(20)
            var topics: Set<String> = []
            for note in recentNotes {
                if let artifact = note.analysisArtifact,
                   let topicsJSON = artifact.topicsJSON,
                   let data = topicsJSON.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String].self, from: data) {
                    topics.formUnion(decoded)
                }
            }
            if !topics.isEmpty {
                lines.append("")
                lines.append("DISCUSSION TOPICS (from notes):")
                for topic in topics.sorted().prefix(15) {
                    lines.append("  - \(topic)")
                }
            }
        } catch {
            logger.error("Failed to gather content data: \(error)")
        }

        // Role recruiting goals — so content attracts the right candidates
        do {
            let roles = try RoleRecruitingRepository.shared.fetchActiveRoles()
            let unfilled = roles.filter { $0.filledCount < $0.targetCount }
            if !unfilled.isEmpty {
                lines.append("")
                lines.append("ROLE RECRUITING GOALS (suggest content that attracts candidates matching these profiles):")
                for role in unfilled {
                    let remaining = role.targetCount - role.filledCount
                    var desc = "  \(role.name) (need \(remaining) more)"
                    if !role.idealCandidateProfile.isEmpty {
                        desc += ": \(role.idealCandidateProfile)"
                    }
                    if !role.refinementNotes.isEmpty {
                        desc += " Previously rejected because: \(role.refinementNotes.joined(separator: ", "))"
                    }
                    lines.append(desc)
                }
            }
        } catch {
            logger.error("Failed to gather role recruiting data for content: \(error)")
        }

        // Content-enabled roles — seeded topics from user-flagged roles
        do {
            let allRoles = try RoleRecruitingRepository.shared.fetchActiveRoles()
            let contentRoles = allRoles.filter { $0.contentGenerationEnabled }
            if !contentRoles.isEmpty {
                lines.append("")
                lines.append("CONTENT-ENABLED ROLES (suggest at least one topic per role below):")
                for role in contentRoles {
                    var desc = "  \(role.name)"
                    if !role.contentBrief.isEmpty {
                        desc += ": \(role.contentBrief)"
                    }
                    lines.append(desc)

                    // Include recent interactions with people in this role
                    let candidates = role.candidates.filter { !$0.stage.isTerminal }
                    let recentCandidates = candidates
                        .sorted { ($0.lastContactedAt ?? $0.identifiedAt) > ($1.lastContactedAt ?? $1.identifiedAt) }
                        .prefix(5)
                    for candidate in recentCandidates {
                        if let person = candidate.person {
                            let name = person.displayName
                            let lastContact = candidate.lastContactedAt?.formatted(date: .abbreviated, time: .omitted) ?? "not yet contacted"
                            lines.append("    - \(name) (last contact: \(lastContact))")
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to gather content-enabled roles: \(error)")
        }

        // Goal check-in learnings for content alignment
        do {
            let recentJournalEntries = try GoalJournalRepository.shared.fetchRecent(limit: 5)
            let relevant = recentJournalEntries.filter { !$0.whatsWorking.isEmpty || !$0.whatsNotWorking.isEmpty || $0.keyInsight != nil }
            if !relevant.isEmpty {
                lines.append("")
                lines.append("GOAL CHECK-IN LEARNINGS:")
                for entry in relevant {
                    let goalType = entry.goalType.displayName
                    let pace = entry.paceAtCheckIn.displayName.lowercased()
                    var desc = "  \(goalType) (\(pace))"
                    if !entry.whatsWorking.isEmpty {
                        desc += ": Working: \(entry.whatsWorking.joined(separator: ", "))."
                    }
                    if !entry.whatsNotWorking.isEmpty {
                        desc += " Not working: \(entry.whatsNotWorking.joined(separator: ", "))."
                    }
                    if let insight = entry.keyInsight {
                        desc += " Insight: \(insight)."
                    }
                    lines.append(desc)
                }
            }
        } catch {
            logger.error("Failed to gather journal data for content: \(error)")
        }

        // Seasonal context
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM yyyy"
        let monthYear = dateFormatter.string(from: .now)
        let quarter = (Calendar.current.component(.month, from: .now) - 1) / 3 + 1
        lines.append("")
        lines.append("SEASONAL CONTEXT: \(monthYear), Q\(quarter)")

        return lines.joined(separator: "\n")
    }

    private func gatherEventHistory() -> String {
        var lines: [String] = []

        do {
            let pastEvents = try EventRepository.shared.fetchPast()
            let upcomingEvents = try EventRepository.shared.fetchUpcoming()

            if !pastEvents.isEmpty {
                lines.append("PAST EVENTS (most recent first):")
                for event in pastEvents.prefix(10) {
                    let attendees = EventRepository.shared.fetchParticipations(for: event).filter { $0.rsvpStatus == .accepted }.count
                    lines.append("  - \"\(event.title)\" (\(event.startDate.formatted(date: .abbreviated, time: .omitted)), \(event.format.displayName), \(attendees) attendees)")
                }
            }

            if !upcomingEvents.isEmpty {
                lines.append("")
                lines.append("UPCOMING EVENTS:")
                for event in upcomingEvents {
                    lines.append("  - \"\(event.title)\" (\(event.startDate.formatted(date: .abbreviated, time: .omitted)), \(event.format.displayName))")
                }
            }

            if pastEvents.isEmpty && upcomingEvents.isEmpty {
                lines.append("EVENT HISTORY: No events created yet.")
            }
        } catch {
            logger.error("Failed to gather event history: \(error)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Specialist Dispatch

    private func runPipelineAnalyst(data: String) async -> PipelineAnalysis {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await PipelineAnalystService.shared.analyze(data: data)
            logger.debug("⏱ Pipeline Health: \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))")
            return result
        } catch {
            logger.error("Pipeline analyst failed: \(error.localizedDescription)")
            return PipelineAnalysis()
        }
    }

    private func runTimeAnalyst(data: String) async -> TimeAnalysis {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await TimeAnalystService.shared.analyze(data: data)
            logger.debug("⏱ Time Balance: \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))")
            return result
        } catch {
            logger.error("Time analyst failed: \(error.localizedDescription)")
            return TimeAnalysis()
        }
    }

    private func runPatternDetector(data: String) async -> PatternAnalysis {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await PatternDetectorService.shared.analyze(data: data)
            logger.debug("⏱ Patterns: \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))")
            return result
        } catch {
            logger.error("Pattern detector failed: \(error.localizedDescription)")
            return PatternAnalysis()
        }
    }

    private func runContentAdvisor(data: String) async -> ContentAnalysis {
        let clock = ContinuousClock()
        let start = clock.now
        logger.debug("🔍 Content advisor starting — input data \(data.count) chars")
        do {
            let result = try await ContentAdvisorService.shared.analyze(data: data)
            logger.debug("⏱ Content Ideas: \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))) — \(result.topicSuggestions.count) topics returned")
            return result
        } catch {
            logger.error("❌ Content advisor failed: \(error)")
            return ContentAnalysis()
        }
    }

    private func runEventTopicAdvisor(data: String, eventHistory: String) async -> EventTopicAnalysis {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let result = try await EventTopicAdvisorService.shared.analyze(data: data, eventHistory: eventHistory)
            logger.debug("⏱ Event Topics: \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))")
            return result
        } catch {
            logger.error("Event topic advisor failed: \(error.localizedDescription)")
            return EventTopicAnalysis()
        }
    }

    // MARK: - Synthesis (Deterministic Swift)

    private func synthesize(
        pipeline: PipelineAnalysis,
        time: TimeAnalysis,
        pattern: PatternAnalysis,
        content: ContentAnalysis
    ) -> [StrategicRec] {
        var allRecs: [StrategicRec] = []
        allRecs.append(contentsOf: pipeline.recommendations)
        allRecs.append(contentsOf: time.recommendations)
        allRecs.append(contentsOf: pattern.recommendations)

        // Apply feedback-based category weights
        let weights = computeCategoryWeights()

        // Adjust priorities by category weight
        allRecs = allRecs.map { rec in
            let weight = weights[rec.category] ?? 1.0
            return StrategicRec(
                id: rec.id,
                title: rec.title,
                rationale: rec.rationale,
                priority: min(1.0, rec.priority * weight),
                category: rec.category,
                feedback: rec.feedback,
                approaches: rec.approaches
            )
        }

        // Deduplicate similar recommendations
        allRecs = deduplicateRecommendations(allRecs)

        // Sort by priority descending, cap at 7
        allRecs.sort { $0.priority > $1.priority }
        return Array(allRecs.prefix(7))
    }

    private func deduplicateRecommendations(_ recs: [StrategicRec]) -> [StrategicRec] {
        var result: [StrategicRec] = []
        for rec in recs {
            let isDuplicate = result.contains { existing in
                titleSimilarity(existing.title, rec.title) > 0.6
            }
            if !isDuplicate {
                result.append(rec)
            }
        }
        return result
    }

    private func titleSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(separator: " ").map(String.init))
        let wordsB = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    /// Compute per-category weight adjustments based on calibration ledger + historical feedback.
    /// Uses CalibrationLedger (0.5–2.0 range) when available; falls back to digest-based (0.9–1.1).
    private func computeCategoryWeights() -> [String: Double] {
        // Prefer CalibrationLedger strategic weights if available
        let ledger = CalibrationService.cachedLedger
        let ledgerWeights = ledger.strategicCategoryWeights
        if !ledgerWeights.isEmpty {
            // Ensure all categories are present, defaulting to 1.0
            var weights: [String: Double] = [:]
            let categories = ["pipeline", "time", "pattern"]
            for cat in categories {
                weights[cat] = ledgerWeights[cat] ?? 1.0
            }
            return weights
        }

        // Fall back to digest-based computation (original ±10% logic)
        var acted: [String: Int] = [:]
        var dismissed: [String: Int] = [:]

        guard let context else { return [:] }
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now

        do {
            let descriptor = FetchDescriptor<StrategicDigest>(
                sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
            )
            let digests = try context.fetch(descriptor)
                .filter { $0.generatedAt >= thirtyDaysAgo }

            for digest in digests {
                guard let feedbackData = digest.feedbackJSON?.data(using: .utf8),
                      let feedbackMap = try? JSONDecoder().decode([String: String].self, from: feedbackData),
                      let actionsData = digest.strategicActions.data(using: .utf8),
                      let recs = try? JSONDecoder().decode([StrategicRec].self, from: actionsData) else {
                    continue
                }

                for (recID, feedbackStr) in feedbackMap {
                    guard let rec = recs.first(where: { $0.id.uuidString == recID }) else { continue }
                    if feedbackStr == "actedOn" {
                        acted[rec.category, default: 0] += 1
                    } else if feedbackStr == "dismissed" {
                        dismissed[rec.category, default: 0] += 1
                    }
                }
            }
        } catch {
            logger.error("Failed to compute category weights: \(error)")
        }

        var weights: [String: Double] = [:]
        let categories = ["pipeline", "time", "pattern"]
        for cat in categories {
            let a = Double(acted[cat] ?? 0)
            let d = Double(dismissed[cat] ?? 0)
            let total = a + d
            if total > 0 {
                let ratio = (a - d) / total  // -1 to +1
                weights[cat] = 1.0 + ratio * 0.1  // 0.9 to 1.1
            } else {
                weights[cat] = 1.0
            }
        }
        return weights
    }

    // MARK: - Persistence

    @discardableResult
    private func persistDigest(
        type: DigestType,
        pipeline: PipelineAnalysis,
        time: TimeAnalysis,
        pattern: PatternAnalysis,
        content: ContentAnalysis,
        topRecs: [StrategicRec]
    ) -> StrategicDigest {
        let digest = StrategicDigest(digestType: type)
        digest.pipelineSummary = pipeline.healthSummary
        digest.timeSummary = time.balanceSummary
        digest.patternInsights = pattern.patterns.map(\.description).joined(separator: "; ")
        // Persist full structured ContentTopic data as JSON for interactive rendering
        logger.debug("🔍 persistDigest — content.topicSuggestions.count: \(content.topicSuggestions.count)")
        if let contentData = try? JSONEncoder().encode(content.topicSuggestions),
           let contentJSON = String(data: contentData, encoding: .utf8) {
            digest.contentSuggestions = contentJSON
            logger.debug("🔍 persistDigest — stored JSON (\(contentJSON.count) chars): \(String(contentJSON.prefix(200)))")
        } else {
            // Fallback: semicolon-separated titles
            let fallback = content.topicSuggestions.map(\.topic).joined(separator: "; ")
            digest.contentSuggestions = fallback
            logger.debug("🔍 persistDigest — JSON encode failed, used fallback: \(fallback)")
        }

        // Persist event topic suggestions as JSON
        if let eventTopicData = try? JSONEncoder().encode(suggestedEventTopics),
           let eventTopicJSON = String(data: eventTopicData, encoding: .utf8) {
            digest.eventTopicSuggestions = eventTopicJSON
        }

        // Encode recommendations
        if let data = try? JSONEncoder().encode(topRecs),
           let json = String(data: data, encoding: .utf8) {
            digest.strategicActions = json
        }

        // Encode full raw output
        let rawOutput: [String: Any] = [
            "pipeline": pipeline.healthSummary,
            "pipelineRisks": pipeline.riskAlerts,
            "time": time.balanceSummary,
            "timeImbalances": time.imbalances,
            "patterns": pattern.patterns.map(\.description),
            "content": content.topicSuggestions.map(\.topic)
        ]
        if let rawData = try? JSONSerialization.data(withJSONObject: rawOutput),
           let rawJSON = String(data: rawData, encoding: .utf8) {
            digest.rawJSON = rawJSON
        }

        context?.insert(digest)
        try? context?.save()
        return digest
    }

    // MARK: - Loading

    private func loadLatestDigest() {
        guard let context else { return }
        do {
            var descriptor = FetchDescriptor<StrategicDigest>(
                sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            if let digest = try context.fetch(descriptor).first {
                latestDigest = digest
                lastGeneratedAt = digest.generatedAt

                // Parse recommendations
                if let data = digest.strategicActions.data(using: .utf8),
                   let recs = try? JSONDecoder().decode([StrategicRec].self, from: data) {
                    strategicRecommendations = recs
                }

                // Restore event topic suggestions
                if let topicJSON = digest.eventTopicSuggestions,
                   let topicData = topicJSON.data(using: .utf8),
                   let topics = try? JSONDecoder().decode([SuggestedEventTopic].self, from: topicData) {
                    suggestedEventTopics = topics
                }
            }
        } catch {
            logger.error("Failed to load latest digest: \(error)")
        }
    }

    // MARK: - Business Snapshot

    /// Condensed business snapshot for coaching session context (~200 tokens).
    func condensedBusinessSnapshot() -> String {
        tracker.refresh()
        let funnel = tracker.clientFunnel
        let recruitFunnel = tracker.recruitFunnel
        let activeRecruits = recruitFunnel.filter { $0.count > 0 }

        var lines: [String] = []
        lines.append("Pipeline: \(funnel.leadCount) Leads, \(funnel.applicantCount) Applicants, \(funnel.clientCount) Clients")

        if !activeRecruits.isEmpty {
            let recruitTotal = activeRecruits.map(\.count).reduce(0, +)
            lines.append("Recruiting: \(recruitTotal) active across \(activeRecruits.count) stages")
        }

        let stuck = tracker.clientStuckPeople
        if !stuck.isEmpty {
            lines.append("Stuck: \(stuck.count) people need attention")
        }

        let production = tracker.productionByStatus
        let activeProduction = production.filter { $0.count > 0 }
        if !activeProduction.isEmpty {
            let totalCases = activeProduction.map(\.count).reduce(0, +)
            lines.append("Production: \(totalCases) active cases")
        }

        return lines.joined(separator: ". ")
    }

    // MARK: - Helpers

    private func isCacheValid(_ lastAnalyzed: Date?, ttl: TimeInterval) -> Bool {
        guard let last = lastAnalyzed else { return false }
        return Date.now.timeIntervalSince(last) < ttl
    }
}
