//
//  GoalRepository.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase X: Goal Setting & Decomposition
//
//  SwiftData CRUD for BusinessGoal records.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GoalRepository")

@MainActor
@Observable
final class GoalRepository {

    // MARK: - Singleton

    static let shared = GoalRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Create

    /// Create a new business goal.
    @discardableResult
    func create(
        goalType: GoalType,
        title: String,
        targetValue: Double,
        startDate: Date,
        endDate: Date,
        notes: String? = nil
    ) throws -> BusinessGoal {
        guard let context else { throw RepositoryError.notConfigured }

        let goal = BusinessGoal(
            goalType: goalType,
            title: title,
            targetValue: targetValue,
            startDate: startDate,
            endDate: endDate,
            notes: notes
        )
        context.insert(goal)
        try context.save()
        logger.info("Created goal: \(title) — \(goalType.displayName) target \(targetValue)")
        return goal
    }

    // MARK: - Fetch

    /// Fetch active goals, sorted by endDate ascending (nearest deadline first).
    func fetchActive() throws -> [BusinessGoal] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<BusinessGoal>(
            sortBy: [SortDescriptor(\.endDate, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.isActive }
    }

    /// Fetch all goals (active + archived), sorted by createdAt descending.
    func fetchAll() throws -> [BusinessGoal] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<BusinessGoal>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Update

    /// Update editable fields on an existing goal.
    func update(
        id: UUID,
        title: String? = nil,
        targetValue: Double? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        notes: String? = nil
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<BusinessGoal>()
        let all = try context.fetch(descriptor)
        guard let goal = all.first(where: { $0.id == id }) else {
            throw RepositoryError.notFound
        }

        if let title { goal.title = title }
        if let targetValue { goal.targetValue = targetValue }
        if let startDate { goal.startDate = startDate }
        if let endDate { goal.endDate = endDate }
        if let notes { goal.notes = notes }
        goal.updatedAt = .now

        try context.save()
        logger.info("Updated goal \(id): \(goal.title)")
    }

    // MARK: - Archive / Delete

    /// Soft-archive a goal (sets isActive = false).
    func archive(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<BusinessGoal>()
        let all = try context.fetch(descriptor)
        guard let goal = all.first(where: { $0.id == id }) else {
            throw RepositoryError.notFound
        }

        goal.isActive = false
        goal.updatedAt = .now
        try context.save()
        logger.info("Archived goal \(id): \(goal.title)")
    }

    /// Permanently delete a goal.
    func delete(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<BusinessGoal>()
        let all = try context.fetch(descriptor)
        guard let goal = all.first(where: { $0.id == id }) else { return }

        context.delete(goal)
        try context.save()
        logger.info("Deleted goal \(id)")
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured
        case notFound

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "GoalRepository not configured. Call configure(container:) first."
            case .notFound:
                return "Goal not found."
            }
        }
    }
}
