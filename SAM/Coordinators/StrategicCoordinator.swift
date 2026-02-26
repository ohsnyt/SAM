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

    // MARK: - Private State

    private var context: ModelContext?

    // Cache TTLs
    private var lastPipelineAnalyzed: Date?
    private var lastTimeAnalyzed: Date?
    private var lastPatternAnalyzed: Date?
    private var lastContentAnalyzed: Date?

    // Cached specialist outputs
    private var cachedPipelineAnalysis: PipelineAnalysis?
    private var cachedTimeAnalysis: TimeAnalysis?
    private var cachedPatternAnalysis: PatternAnalysis?
    private var cachedContentAnalysis: ContentAnalysis?

    // TTL durations
    private let pipelineTTL: TimeInterval = 4 * 60 * 60    // 4 hours
    private let timeTTL: TimeInterval = 12 * 60 * 60       // 12 hours
    private let patternTTL: TimeInterval = 24 * 60 * 60    // 24 hours
    private let contentTTL: TimeInterval = 24 * 60 * 60    // 24 hours

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

    func generateDigest(type: DigestType = .onDemand) async {
        let enabled = UserDefaults.standard.object(forKey: "strategicDigestEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "strategicDigestEnabled")
        guard enabled else {
            logger.info("Strategic digest disabled — skipping")
            return
        }
        guard generationStatus != .generating else { return }

        generationStatus = .generating
        logger.info("Generating strategic digest (type: \(type.rawValue))")

        do {
            // Gather data (all deterministic Swift)
            let pipelineData = gatherPipelineData()
            let timeData = gatherTimeData()
            let patternData = gatherPatternData()
            let contentData = gatherContentData()

            // Dispatch 4 specialists in parallel at background priority
            let now = Date.now
            let needsPipeline = !isCacheValid(lastPipelineAnalyzed, ttl: pipelineTTL)
            let needsTime = !isCacheValid(lastTimeAnalyzed, ttl: timeTTL)
            let needsPattern = !isCacheValid(lastPatternAnalyzed, ttl: patternTTL)
            let needsContent = !isCacheValid(lastContentAnalyzed, ttl: contentTTL)

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

            let pipeline = await pipelineResult
            let time = await timeResult
            let pattern = await patternResult
            let content = await contentResult

            // Update caches
            if needsPipeline { cachedPipelineAnalysis = pipeline; lastPipelineAnalyzed = now }
            if needsTime { cachedTimeAnalysis = time; lastTimeAnalyzed = now }
            if needsPattern { cachedPatternAnalysis = pattern; lastPatternAnalyzed = now }
            if needsContent { cachedContentAnalysis = content; lastContentAnalyzed = now }

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

            logger.info("Strategic digest generated: \(topRecs.count) recommendations")

        } catch {
            generationStatus = .failed
            logger.error("Strategic digest generation failed: \(error.localizedDescription)")
        }
    }

    /// Check if a fresh digest exists (< maxAge old).
    func hasFreshDigest(maxAge: TimeInterval = 4 * 60 * 60) -> Bool {
        guard let last = lastGeneratedAt else { return false }
        return Date.now.timeIntervalSince(last) < maxAge
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
        logger.info("Feedback recorded: \(feedback.rawValue) for \(recommendationID)")
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

        // Seasonal context
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM yyyy"
        let monthYear = dateFormatter.string(from: .now)
        let quarter = (Calendar.current.component(.month, from: .now) - 1) / 3 + 1
        lines.append("")
        lines.append("SEASONAL CONTEXT: \(monthYear), Q\(quarter)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Specialist Dispatch

    private nonisolated func runPipelineAnalyst(data: String) async -> PipelineAnalysis {
        do {
            return try await PipelineAnalystService.shared.analyze(data: data)
        } catch {
            logger.error("Pipeline analyst failed: \(error.localizedDescription)")
            return PipelineAnalysis()
        }
    }

    private nonisolated func runTimeAnalyst(data: String) async -> TimeAnalysis {
        do {
            return try await TimeAnalystService.shared.analyze(data: data)
        } catch {
            logger.error("Time analyst failed: \(error.localizedDescription)")
            return TimeAnalysis()
        }
    }

    private nonisolated func runPatternDetector(data: String) async -> PatternAnalysis {
        do {
            return try await PatternDetectorService.shared.analyze(data: data)
        } catch {
            logger.error("Pattern detector failed: \(error.localizedDescription)")
            return PatternAnalysis()
        }
    }

    private nonisolated func runContentAdvisor(data: String) async -> ContentAnalysis {
        do {
            return try await ContentAdvisorService.shared.analyze(data: data)
        } catch {
            logger.error("Content advisor failed: \(error.localizedDescription)")
            return ContentAnalysis()
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
                feedback: rec.feedback
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

    /// Compute per-category weight adjustments based on historical feedback.
    /// Categories with more "actedOn" feedback get boosted; those with more "dismissed" get reduced.
    private func computeCategoryWeights() -> [String: Double] {
        var acted: [String: Int] = [:]
        var dismissed: [String: Int] = [:]

        // Look at recent digests (last 30 days)
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

        // Build weights: ±10% per acted/dismissed ratio
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
        digest.contentSuggestions = content.topicSuggestions.map(\.topic).joined(separator: "; ")

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
            }
        } catch {
            logger.error("Failed to load latest digest: \(error)")
        }
    }

    // MARK: - Helpers

    private func isCacheValid(_ lastAnalyzed: Date?, ttl: TimeInterval) -> Bool {
        guard let last = lastAnalyzed else { return false }
        return Date.now.timeIntervalSince(last) < ttl
    }
}
