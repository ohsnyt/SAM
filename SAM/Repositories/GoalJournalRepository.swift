//
//  GoalJournalRepository.swift
//  SAM
//
//  Created on March 17, 2026.
//  Goal Journal: CRUD + export for GoalJournalEntry.
//

import SwiftData
import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GoalJournalRepository")

@MainActor
@Observable
final class GoalJournalRepository {
    static let shared = GoalJournalRepository()

    private var container: ModelContainer?
    private var context: ModelContext?

    /// Observable status for MinionsView.
    var isSummarizing: Bool = false

    private init() {}

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured
        case notFound

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "GoalJournalRepository not configured"
            case .notFound: return "Journal entry not found"
            }
        }
    }

    // MARK: - Create

    @discardableResult
    func create(from dto: GoalJournalEntryDTO) throws -> GoalJournalEntry {
        guard let context else { throw RepositoryError.notConfigured }

        let entry = GoalJournalEntry(
            id: dto.id,
            goalID: dto.goalID,
            goalType: dto.goalType,
            headline: dto.headline,
            whatsWorking: dto.whatsWorking,
            whatsNotWorking: dto.whatsNotWorking,
            barriers: dto.barriers,
            adjustedStrategy: dto.adjustedStrategy,
            keyInsight: dto.keyInsight,
            commitmentActions: dto.commitmentActions,
            paceAtCheckIn: dto.paceAtCheckIn,
            progressAtCheckIn: dto.progressAtCheckIn,
            conversationTurnCount: dto.conversationTurnCount
        )
        entry.createdAt = dto.createdAt

        context.insert(entry)
        try context.save()
        logger.debug("Created journal entry \(entry.id) for goal \(entry.goalID)")
        return entry
    }

    // MARK: - Fetch

    /// Fetch all entries for a specific goal, sorted by createdAt descending.
    func fetchEntries(for goalID: UUID) throws -> [GoalJournalEntry] {
        guard let context else { throw RepositoryError.notConfigured }

        var descriptor = FetchDescriptor<GoalJournalEntry>(
            predicate: #Predicate { $0.goalID == goalID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        return try context.fetch(descriptor)
    }

    /// Fetch most recent entries across all goals.
    func fetchRecent(limit: Int = 10) throws -> [GoalJournalEntry] {
        guard let context else { throw RepositoryError.notConfigured }

        var descriptor = FetchDescriptor<GoalJournalEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    /// Fetch all entries (for backup export).
    func fetchAll() throws -> [GoalJournalEntry] {
        guard let context else { throw RepositoryError.notConfigured }
        return try context.fetch(FetchDescriptor<GoalJournalEntry>())
    }

    /// Fetch the most recent entry for a specific goal.
    func fetchLatest(for goalID: UUID) throws -> GoalJournalEntry? {
        guard let context else { throw RepositoryError.notConfigured }

        var descriptor = FetchDescriptor<GoalJournalEntry>(
            predicate: #Predicate { $0.goalID == goalID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Delete

    func delete(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<GoalJournalEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = try context.fetch(descriptor).first else {
            throw RepositoryError.notFound
        }
        context.delete(entry)
        try context.save()
        logger.debug("Deleted journal entry \(id)")
    }

    // MARK: - Background Summarization

    /// Summarize a check-in session in the background, save the result, then clear status.
    func summarizeAndSave(
        messages: [CoachingMessage],
        context: GoalCheckInContext,
        onSaved: (() -> Void)? = nil
    ) {
        isSummarizing = true
        Task { @MainActor in
            do {
                #if canImport(AppKit)
                let dto = try await GoalCheckInService.shared.summarizeSession(
                    messages: messages,
                    context: context
                )
                try create(from: dto)
                logger.debug("Background journal summarization saved for goal \(context.goalID)")
                onSaved?()
                #else
                logger.debug("Journal summarization not available on iOS")
                #endif
            } catch {
                logger.error("Background journal summarization failed: \(error.localizedDescription)")
            }
            isSummarizing = false
        }
    }

    // MARK: - Export

    /// JSON-encoded [GoalJournalEntryDTO] for future team sharing.
    func exportEntries(for goalID: UUID) throws -> Data {
        let entries = try fetchEntries(for: goalID)
        let dtos = entries.map { GoalJournalEntryDTO(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(dtos)
    }
}
