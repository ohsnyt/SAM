//
//  ContentPostRepository.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase W: Content Assist & Social Media Coaching
//
//  SwiftData CRUD for ContentPost records.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContentPostRepository")

@MainActor
@Observable
final class ContentPostRepository {

    // MARK: - Singleton

    static let shared = ContentPostRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Create

    /// Log a new content post.
    @discardableResult
    func logPost(platform: ContentPlatform, topic: String, sourceOutcomeID: UUID? = nil) throws -> ContentPost {
        guard let context else { throw RepositoryError.notConfigured }

        let post = ContentPost(
            platform: platform,
            topic: topic,
            sourceOutcomeID: sourceOutcomeID
        )
        context.insert(post)
        try context.save()
        logger.info("Logged post on \(platform.rawValue): \(topic)")
        return post
    }

    // MARK: - Fetch

    /// Fetch recent posts within a given number of days, sorted by postedAt descending.
    func fetchRecent(days: Int = 30) throws -> [ContentPost] {
        guard let context else { throw RepositoryError.notConfigured }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let descriptor = FetchDescriptor<ContentPost>(
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.postedAt >= cutoff }
    }

    /// Get the most recent post for a specific platform.
    func lastPost(platform: ContentPlatform) throws -> ContentPost? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<ContentPost>(
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.first { $0.platform == platform }
    }

    /// Number of days since the last post on a given platform, or nil if no posts exist.
    func daysSinceLastPost(platform: ContentPlatform) throws -> Int? {
        guard let last = try lastPost(platform: platform) else { return nil }
        return Calendar.current.dateComponents([.day], from: last.postedAt, to: .now).day
    }

    /// Post count by platform over a given period.
    func postCountByPlatform(days: Int = 30) throws -> [ContentPlatform: Int] {
        let recent = try fetchRecent(days: days)
        var counts: [ContentPlatform: Int] = [:]
        for post in recent {
            counts[post.platform, default: 0] += 1
        }
        return counts
    }

    /// Consecutive weeks (going backwards from current week) with at least 1 post.
    func weeklyPostingStreak() throws -> Int {
        guard let context else { throw RepositoryError.notConfigured }

        let calendar = Calendar.current
        guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else {
            return 0
        }

        let descriptor = FetchDescriptor<ContentPost>(
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)

        // Build set of week-start dates that have posts
        var postWeeks = Set<Date>()
        for post in all {
            if let weekStart = calendar.dateInterval(of: .weekOfYear, for: post.postedAt)?.start {
                postWeeks.insert(weekStart)
            }
        }

        // Walk backwards from current week
        var streak = 0
        var checkDate = currentWeekStart
        while postWeeks.contains(checkDate) {
            streak += 1
            guard let previousWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: checkDate) else {
                break
            }
            checkDate = previousWeek
        }
        return streak
    }

    // MARK: - Delete

    func delete(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<ContentPost>()
        let all = try context.fetch(descriptor)
        guard let post = all.first(where: { $0.id == id }) else { return }
        context.delete(post)
        try context.save()
        logger.info("Deleted content post \(id)")
    }

    // MARK: - Errors

    enum RepositoryError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "ContentPostRepository not configured. Call configure(container:) first."
            }
        }
    }
}
