//
//  ScenarioProjectionEngine.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase Y: Scenario Projections
//
//  Computes deterministic linear projections from trailing 90-day velocity
//  across 5 business categories. No AI calls — pure math.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ScenarioProjectionEngine")

// MARK: - Value Types

struct ProjectionPoint: Sendable, Identifiable {
    var id: Int { months }
    let months: Int          // 3, 6, or 12
    let low: Double
    let mid: Double
    let high: Double
}

enum ProjectionTrend: String, Sendable {
    case accelerating
    case steady
    case decelerating
    case insufficientData
}

enum ProjectionCategory: String, Sendable, CaseIterable {
    case clientPipeline = "clientPipeline"
    case recruiting     = "recruiting"
    case revenue        = "revenue"
    case meetings       = "meetings"
    case content        = "content"

    var displayName: String {
        switch self {
        case .clientPipeline: return "New Clients"
        case .recruiting:     return "Producing Agents"
        case .revenue:        return "Revenue"
        case .meetings:       return "Meetings"
        case .content:        return "Content Posts"
        }
    }

    var icon: String {
        switch self {
        case .clientPipeline: return "person.badge.plus"
        case .recruiting:     return "person.3.fill"
        case .revenue:        return "dollarsign.circle.fill"
        case .meetings:       return "calendar"
        case .content:        return "text.bubble.fill"
        }
    }

    var color: String {
        switch self {
        case .clientPipeline: return "green"
        case .recruiting:     return "teal"
        case .revenue:        return "purple"
        case .meetings:       return "orange"
        case .content:        return "pink"
        }
    }

    var unit: String {
        switch self {
        case .clientPipeline: return "clients"
        case .recruiting:     return "agents"
        case .revenue:        return "$"
        case .meetings:       return "meetings"
        case .content:        return "posts"
        }
    }

    var isCurrency: Bool {
        self == .revenue
    }
}

struct ScenarioProjection: Sendable, Identifiable {
    var id: String { category.rawValue }
    let category: ProjectionCategory
    let trailingMonthlyRate: Double
    let points: [ProjectionPoint]  // always 3 entries: 3mo, 6mo, 12mo
    let trend: ProjectionTrend
    let hasEnoughData: Bool
}

// MARK: - Engine

@MainActor
@Observable
final class ScenarioProjectionEngine {

    static let shared = ScenarioProjectionEngine()

    var projections: [ScenarioProjection] = []
    var lastComputedAt: Date?

    private init() {}

    // MARK: - Public API

    func refresh() {
        let now = Date.now
        let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: now)!

        var results: [ScenarioProjection] = []

        // 1. Client Pipeline — transitions to "Client" stage
        results.append(computeClientPipeline(since: ninetyDaysAgo, now: now))

        // 2. Recruiting — transitions to advanced stages (Licensed, First Sale, Producing)
        results.append(computeRecruiting(since: ninetyDaysAgo, now: now))

        // 3. Revenue — sum of annualPremium by submittedDate
        results.append(computeRevenue(since: ninetyDaysAgo, now: now))

        // 4. Meetings — calendar evidence count
        results.append(computeMeetings(since: ninetyDaysAgo, now: now))

        // 5. Content Posts
        results.append(computeContent(since: ninetyDaysAgo, now: now))

        projections = results
        lastComputedAt = now
        logger.info("Refreshed scenario projections: \(results.count) categories")
    }

    // MARK: - Category Computations

    private func computeClientPipeline(since: Date, now: Date) -> ScenarioProjection {
        var buckets = bucketize(since: since, now: now) { _ in 0.0 }

        if let transitions = try? PipelineRepository.shared.fetchTransitions(pipelineType: .client, since: since) {
            let clientTransitions = transitions.filter { $0.toStage == "Client" }
            for transition in clientTransitions {
                let bucketIndex = bucketIndex(for: transition.transitionDate, since: since, now: now)
                buckets[bucketIndex] += 1.0
            }
        }

        return buildProjection(category: .clientPipeline, monthlyBuckets: buckets)
    }

    private func computeRecruiting(since: Date, now: Date) -> ScenarioProjection {
        let advancedStages: Set<String> = [
            RecruitingStageKind.licensed.rawValue,
            RecruitingStageKind.firstSale.rawValue,
            RecruitingStageKind.producing.rawValue
        ]

        var buckets = bucketize(since: since, now: now) { _ in 0.0 }

        if let transitions = try? PipelineRepository.shared.fetchTransitions(pipelineType: .recruiting, since: since) {
            let advanced = transitions.filter { advancedStages.contains($0.toStage) }
            for transition in advanced {
                let bucketIndex = bucketIndex(for: transition.transitionDate, since: since, now: now)
                buckets[bucketIndex] += 1.0
            }
        }

        return buildProjection(category: .recruiting, monthlyBuckets: buckets)
    }

    private func computeRevenue(since: Date, now: Date) -> ScenarioProjection {
        var buckets = bucketize(since: since, now: now) { _ in 0.0 }

        if let records = try? ProductionRepository.shared.fetchRecords(since: since) {
            for record in records {
                let bucketIndex = bucketIndex(for: record.submittedDate, since: since, now: now)
                buckets[bucketIndex] += record.annualPremium
            }
        }

        return buildProjection(category: .revenue, monthlyBuckets: buckets)
    }

    private func computeMeetings(since: Date, now: Date) -> ScenarioProjection {
        var buckets = bucketize(since: since, now: now) { _ in 0.0 }

        if let allEvidence = try? EvidenceRepository.shared.fetchAll() {
            let calendarEvents = allEvidence.filter {
                $0.source == .calendar && $0.occurredAt >= since && $0.occurredAt <= now
            }
            for event in calendarEvents {
                let bucketIndex = bucketIndex(for: event.occurredAt, since: since, now: now)
                buckets[bucketIndex] += 1.0
            }
        }

        return buildProjection(category: .meetings, monthlyBuckets: buckets)
    }

    private func computeContent(since: Date, now: Date) -> ScenarioProjection {
        var buckets = bucketize(since: since, now: now) { _ in 0.0 }

        if let posts = try? ContentPostRepository.shared.fetchRecent(days: 90) {
            for post in posts {
                let bucketIndex = bucketIndex(for: post.postedAt, since: since, now: now)
                buckets[bucketIndex] += 1.0
            }
        }

        return buildProjection(category: .content, monthlyBuckets: buckets)
    }

    // MARK: - Shared Computation

    /// Bucket trailing 90 days into 3 monthly periods.
    /// Index 0 = oldest (60–90 days ago), index 2 = most recent (0–30 days ago).
    private func bucketize(since: Date, now: Date, initialValue: (Int) -> Double) -> [Double] {
        [initialValue(0), initialValue(1), initialValue(2)]
    }

    /// Determine which bucket (0, 1, 2) a date falls into.
    /// 0 = 60–90 days ago, 1 = 30–60 days ago, 2 = 0–30 days ago.
    private func bucketIndex(for date: Date, since: Date, now: Date) -> Int {
        let daysAgo = now.timeIntervalSince(date) / (24 * 60 * 60)
        if daysAgo >= 60 { return 0 }
        if daysAgo >= 30 { return 1 }
        return 2
    }

    private func buildProjection(category: ProjectionCategory, monthlyBuckets: [Double]) -> ScenarioProjection {
        let nonzeroCount = monthlyBuckets.filter { $0 > 0 }.count
        let hasEnoughData = nonzeroCount >= 2

        // Monthly rate = mean of 3 buckets
        let rate = monthlyBuckets.reduce(0, +) / Double(monthlyBuckets.count)

        // Standard deviation
        let variance = monthlyBuckets.reduce(0.0) { sum, val in
            let diff = val - rate
            return sum + diff * diff
        } / Double(monthlyBuckets.count)
        let stdev = sqrt(variance)

        // Trend: compare most recent 30d (bucket 2) vs prior 60d average (buckets 0, 1)
        let trend: ProjectionTrend
        if !hasEnoughData {
            trend = .insufficientData
        } else {
            let priorAvg = (monthlyBuckets[0] + monthlyBuckets[1]) / 2.0
            if priorAvg == 0 {
                trend = monthlyBuckets[2] > 0 ? .accelerating : .steady
            } else {
                let ratio = monthlyBuckets[2] / priorAvg
                if ratio > 1.15 {
                    trend = .accelerating
                } else if ratio < 0.85 {
                    trend = .decelerating
                } else {
                    trend = .steady
                }
            }
        }

        // Project at 3, 6, 12 month horizons
        let horizons = [3, 6, 12]
        let points: [ProjectionPoint] = horizons.map { months in
            let monthsDouble = Double(months)
            let mid = rate * monthsDouble
            let band = max(stdev * sqrt(monthsDouble), mid * 0.2)
            let low = max(mid - band, 0)
            let high = mid + band
            return ProjectionPoint(months: months, low: low, mid: mid, high: high)
        }

        return ScenarioProjection(
            category: category,
            trailingMonthlyRate: rate,
            points: points,
            trend: trend,
            hasEnoughData: hasEnoughData
        )
    }
}
