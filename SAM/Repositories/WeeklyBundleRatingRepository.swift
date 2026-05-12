//
//  WeeklyBundleRatingRepository.swift
//  SAM
//
//  CRUD for WeeklyBundleRating. Captures one user rating per (week, bundle)
//  so weekly review surfaces a finite list, not a re-rated firehose.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "WeeklyBundleRatingRepository")

@MainActor
@Observable
final class WeeklyBundleRatingRepository {

    static let shared = WeeklyBundleRatingRepository()

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    /// Monday-anchored start of the ISO week containing `date`.
    static func weekStart(for date: Date) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2  // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    /// Fetch the rating for a specific (bundle, week) pair, if it exists.
    func fetch(bundleID: UUID, weekStart: Date) throws -> WeeklyBundleRating? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<WeeklyBundleRating>(
            predicate: #Predicate { $0.bundle?.id == bundleID && $0.weekStartDate == weekStart }
        )
        return try context.fetch(descriptor).first
    }

    /// All ratings for the given week, newest first.
    func fetchAll(forWeek weekStart: Date) throws -> [WeeklyBundleRating] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<WeeklyBundleRating>(
            predicate: #Predicate { $0.weekStartDate == weekStart },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Upsert a rating. Replaces stars/comment if a row already exists for
    /// the same (bundle, week).
    @discardableResult
    func upsert(
        bundleID: UUID,
        weekStart: Date,
        stars: Int,
        comment: String?,
        kindsSeen: [OutcomeSubItemKind]
    ) throws -> WeeklyBundleRating {
        guard let context else { throw RepositoryError.notConfigured }

        if let existing = try fetch(bundleID: bundleID, weekStart: weekStart) {
            existing.stars = max(0, min(5, stars))
            existing.comment = comment
            existing.kindsSeenRaw = kindsSeen.map(\.rawValue).joined(separator: "\n")
            try context.save()
            return existing
        }

        guard let bundle = try OutcomeBundleRepository.shared.fetch(id: bundleID) else {
            throw WeeklyBundleRatingError.bundleNotFound
        }

        let rating = WeeklyBundleRating(
            bundle: bundle,
            personID: bundle.personID,
            weekStartDate: weekStart,
            stars: stars,
            comment: comment,
            kindsSeenRaw: kindsSeen.map(\.rawValue).joined(separator: "\n")
        )
        context.insert(rating)
        try context.save()
        return rating
    }

    /// Feed a rating into CalibrationService — one signal per sub-item kind
    /// that appeared in this week's bundle. CalibrationService maintains the
    /// running rating average per kind, which feeds strategic weights.
    func feedCalibration(rating: WeeklyBundleRating) async {
        guard rating.stars > 0, !rating.kindsSeen.isEmpty else { return }
        for kind in rating.kindsSeen {
            await CalibrationService.shared.recordRating(kind: kind.rawValue, rating: rating.stars)
        }
    }

    /// Average stars per OutcomeSubItemKind across the entire ledger. Used by
    /// the calibration loop to nudge strategic weights.
    func averageStarsPerKind() throws -> [OutcomeSubItemKind: Double] {
        guard let context else { throw RepositoryError.notConfigured }
        let all = try context.fetch(FetchDescriptor<WeeklyBundleRating>())
        var sums: [OutcomeSubItemKind: (sum: Int, count: Int)] = [:]
        for rating in all where rating.stars > 0 {
            for kind in rating.kindsSeen {
                let prev = sums[kind] ?? (0, 0)
                sums[kind] = (prev.sum + rating.stars, prev.count + 1)
            }
        }
        return sums.mapValues { Double($0.sum) / Double($0.count) }
    }
}

enum WeeklyBundleRatingError: Error {
    case bundleNotFound
}
