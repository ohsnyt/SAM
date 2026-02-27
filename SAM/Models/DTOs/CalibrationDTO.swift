//
//  CalibrationDTO.swift
//  SAM
//
//  Created on February 27, 2026.
//  Phase AB: Coaching Calibration — Feedback Ledger
//
//  Lightweight ledger of user interaction signals stored as JSON in UserDefaults.
//  Inherently bounded: one entry per OutcomeKind (8), 24 hour slots, 7 day slots, ~5 categories.
//

import Foundation

/// Accumulated calibration signals from the user's interaction patterns.
/// Persisted as JSON in UserDefaults via `CalibrationService`.
nonisolated public struct CalibrationLedger: Codable, Sendable, Equatable {

    // MARK: - Per-Kind Stats

    /// Per-OutcomeKind acted/dismissed/rating counters. Keys are OutcomeKind raw values.
    public var kindStats: [String: KindStat]

    // MARK: - Timing Patterns

    /// Hour-of-day completion counts (0–23 → count).
    public var hourOfDayActs: [Int: Int]

    /// Day-of-week completion counts (1=Sunday … 7=Saturday → count).
    public var dayOfWeekActs: [Int: Int]

    // MARK: - Strategic Weights

    /// Per-category coaching weights derived from session feedback (0.5–2.0).
    /// Keys: "pipeline", "time", "pattern", etc.
    public var strategicCategoryWeights: [String: Double]

    // MARK: - Muted Kinds

    /// OutcomeKind raw values the user has explicitly muted.
    public var mutedKinds: [String]

    // MARK: - Session Feedback

    /// Per-category helpful/unhelpful counters from coaching sessions.
    public var sessionFeedback: [String: SessionStat]

    // MARK: - Metadata

    public var updatedAt: Date

    // MARK: - Init

    public init(
        kindStats: [String: KindStat] = [:],
        hourOfDayActs: [Int: Int] = [:],
        dayOfWeekActs: [Int: Int] = [:],
        strategicCategoryWeights: [String: Double] = [:],
        mutedKinds: [String] = [],
        sessionFeedback: [String: SessionStat] = [:],
        updatedAt: Date = .now
    ) {
        self.kindStats = kindStats
        self.hourOfDayActs = hourOfDayActs
        self.dayOfWeekActs = dayOfWeekActs
        self.strategicCategoryWeights = strategicCategoryWeights
        self.mutedKinds = mutedKinds
        self.sessionFeedback = sessionFeedback
        self.updatedAt = updatedAt
    }

    // MARK: - Computed Helpers

    /// Total interactions across all kinds (acted + dismissed).
    public var totalInteractions: Int {
        kindStats.values.reduce(0) { $0 + $1.actedOn + $1.dismissed }
    }

    /// Peak productivity hours (top 3 hours by completion count).
    public var peakHours: [Int] {
        hourOfDayActs
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
            .sorted()
    }

    /// Peak productivity days (top 2 days by completion count).
    public var peakDays: [Int] {
        dayOfWeekActs
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map(\.key)
            .sorted()
    }

    // MARK: - Nested Types

    /// Per-kind interaction statistics.
    public struct KindStat: Codable, Sendable, Equatable {
        public var actedOn: Int
        public var dismissed: Int
        public var totalRatings: Int
        public var ratingSum: Int
        public var avgResponseMinutes: Double

        public init(
            actedOn: Int = 0,
            dismissed: Int = 0,
            totalRatings: Int = 0,
            ratingSum: Int = 0,
            avgResponseMinutes: Double = 0
        ) {
            self.actedOn = actedOn
            self.dismissed = dismissed
            self.totalRatings = totalRatings
            self.ratingSum = ratingSum
            self.avgResponseMinutes = avgResponseMinutes
        }

        /// Average user rating (0 if no ratings).
        public var avgRating: Double {
            totalRatings > 0 ? Double(ratingSum) / Double(totalRatings) : 0
        }

        /// Ratio of acted-on to total interactions (0 if none).
        public var actRate: Double {
            let total = actedOn + dismissed
            return total > 0 ? Double(actedOn) / Double(total) : 0
        }
    }

    /// Per-category coaching session feedback counters.
    public struct SessionStat: Codable, Sendable, Equatable {
        public var helpful: Int
        public var unhelpful: Int

        public init(helpful: Int = 0, unhelpful: Int = 0) {
            self.helpful = helpful
            self.unhelpful = unhelpful
        }
    }
}
