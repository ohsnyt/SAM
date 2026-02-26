//
//  TimeTrackingRepository.swift
//  SAM
//
//  Created on February 25, 2026.
//  Phase Q: Time Tracking & Categorization
//
//  SwiftData CRUD for TimeEntry records.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TimeTrackingRepository")

@MainActor
@Observable
final class TimeTrackingRepository {

    // MARK: - Singleton

    static let shared = TimeTrackingRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Fetch Operations

    /// Fetch all entries in a date range, sorted by startedAt descending.
    func fetchEntries(from start: Date, to end: Date) throws -> [TimeEntry] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<TimeEntry>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.startedAt >= start && $0.startedAt <= end }
    }

    /// Fetch entries for a single day.
    func fetchEntries(for date: Date) throws -> [TimeEntry] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return try fetchEntries(from: start, to: end)
    }

    /// Find an existing entry by its source calendar evidence ID.
    func fetchBySourceEvidence(id: UUID) throws -> TimeEntry? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<TimeEntry>()
        let all = try context.fetch(descriptor)
        return all.first { $0.sourceEvidenceID == id }
    }

    /// Aggregate minutes per category over a date range.
    func categoryBreakdown(from start: Date, to end: Date) throws -> [TimeCategory: Int] {
        let entries = try fetchEntries(from: start, to: end)
        var breakdown: [TimeCategory: Int] = [:]
        for entry in entries {
            breakdown[entry.category, default: 0] += entry.durationMinutes
        }
        return breakdown
    }

    // MARK: - Upsert from Calendar

    /// Create or update a TimeEntry from a calendar event. Idempotent — skips
    /// existing entries that have `isManualOverride == true`.
    @discardableResult
    func upsertFromCalendar(
        evidenceID: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date,
        category: TimeCategory,
        linkedPeopleIDs: [UUID]
    ) throws -> TimeEntry {
        guard let context else { throw RepositoryError.notConfigured }

        let durationMinutes = max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))

        if let existing = try fetchBySourceEvidence(id: evidenceID) {
            // Preserve manual overrides
            if existing.isManualOverride {
                // Still update non-category fields
                existing.title = title
                existing.startedAt = startedAt
                existing.endedAt = endedAt
                existing.durationMinutes = durationMinutes
                existing.linkedPeopleIDs = linkedPeopleIDs
                try context.save()
                return existing
            }

            existing.title = title
            existing.categoryRawValue = category.rawValue
            existing.startedAt = startedAt
            existing.endedAt = endedAt
            existing.durationMinutes = durationMinutes
            existing.linkedPeopleIDs = linkedPeopleIDs
            try context.save()
            return existing
        }

        let entry = TimeEntry(
            category: category,
            title: title,
            durationMinutes: durationMinutes,
            startedAt: startedAt,
            endedAt: endedAt,
            sourceEvidenceID: evidenceID,
            linkedPeopleIDs: linkedPeopleIDs
        )
        context.insert(entry)
        try context.save()
        return entry
    }

    // MARK: - Manual Entry

    /// Create a manual time entry (no linked calendar event).
    @discardableResult
    func createManual(
        category: TimeCategory,
        title: String,
        durationMinutes: Int,
        startedAt: Date,
        endedAt: Date
    ) throws -> TimeEntry {
        guard let context else { throw RepositoryError.notConfigured }

        let entry = TimeEntry(
            category: category,
            title: title,
            durationMinutes: durationMinutes,
            startedAt: startedAt,
            endedAt: endedAt,
            isManualEntry: true
        )
        context.insert(entry)
        try context.save()
        logger.info("Created manual time entry: \(title)")
        return entry
    }

    // MARK: - Category Update

    /// Update the category for an entry, marking it as a manual override.
    func updateCategory(id: UUID, newCategory: TimeCategory) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<TimeEntry>()
        let all = try context.fetch(descriptor)
        guard let entry = all.first(where: { $0.id == id }) else { return }

        entry.categoryRawValue = newCategory.rawValue
        entry.isManualOverride = true
        try context.save()
        logger.info("Category updated to \(newCategory.rawValue) for: \(entry.title)")
    }

    // MARK: - Delete

    func delete(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<TimeEntry>()
        let all = try context.fetch(descriptor)
        guard let entry = all.first(where: { $0.id == id }) else { return }

        context.delete(entry)
        try context.save()
        logger.info("Deleted time entry: \(entry.title)")
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "TimeTrackingRepository not configured — call configure(container:) first"
            }
        }
    }
}
