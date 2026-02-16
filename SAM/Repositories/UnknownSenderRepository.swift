//
//  UnknownSenderRepository.swift
//  SAM
//
//  SwiftData CRUD for UnknownSender triage records.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "UnknownSenderRepository")

@MainActor
@Observable
final class UnknownSenderRepository {

    // MARK: - Singleton

    static let shared = UnknownSenderRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var modelContext: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.modelContext = ModelContext(container)
    }

    // MARK: - Fetch

    /// Fetch all pending unknown senders, sorted by email count descending.
    func fetchPending() throws -> [UnknownSender] {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<UnknownSender>(
            sortBy: [SortDescriptor(\.emailCount, order: .reverse)]
        )
        let all = try modelContext.fetch(descriptor)
        return all.filter { $0.status == .pending }
    }

    /// Returns the set of emails marked as neverInclude for fast import-time lookup.
    func neverIncludeEmails() throws -> Set<String> {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<UnknownSender>()
        let all = try modelContext.fetch(descriptor)
        return Set(all.filter { $0.status == .neverInclude }.map(\.email))
    }

    // MARK: - Bulk Record

    /// Upsert unknown senders from import results.
    /// Increments emailCount for existing records. Re-surfaces dismissed senders on new email.
    func bulkRecordUnknownSenders(
        _ senders: [(email: String, displayName: String?, subject: String, date: Date, source: EvidenceSource)]
    ) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }

        // Fetch all existing unknown senders for lookup
        let descriptor = FetchDescriptor<UnknownSender>()
        let existing = try modelContext.fetch(descriptor)
        let existingByEmail = Dictionary(uniqueKeysWithValues: existing.map { ($0.email, $0) })

        var created = 0
        var updated = 0

        // Deduplicate input by email (keep latest date)
        var grouped: [String: (email: String, displayName: String?, subject: String, date: Date, source: EvidenceSource)] = [:]
        for sender in senders {
            let key = sender.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let prev = grouped[key] {
                // Keep the entry with the latest date
                if sender.date > prev.date {
                    grouped[key] = sender
                }
            } else {
                grouped[key] = sender
            }
        }

        for (canonicalEmail, sender) in grouped {
            if let record = existingByEmail[canonicalEmail] {
                // Update existing
                record.emailCount += 1
                record.latestSubject = sender.subject
                record.latestEmailDate = sender.date
                if let name = sender.displayName, record.displayName == nil {
                    record.displayName = name
                }
                // Re-surface dismissed senders on new email
                if record.status == .dismissed {
                    record.status = .pending
                }
                updated += 1
            } else {
                // Create new
                let record = UnknownSender(
                    email: canonicalEmail,
                    displayName: sender.displayName,
                    status: .pending,
                    firstSeenAt: sender.date,
                    emailCount: 1,
                    latestSubject: sender.subject,
                    latestEmailDate: sender.date,
                    source: sender.source
                )
                modelContext.insert(record)
                created += 1
            }
        }

        try modelContext.save()
        if created > 0 || updated > 0 {
            logger.info("Unknown senders: \(created) new, \(updated) updated")
        }
    }

    // MARK: - Status Updates

    func markNeverInclude(_ sender: UnknownSender) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        sender.status = .neverInclude
        sender.lastTriagedAt = Date()
        try modelContext.save()
    }

    func markDismissed(_ sender: UnknownSender) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        sender.status = .dismissed
        sender.lastTriagedAt = Date()
        try modelContext.save()
    }

    func markAdded(_ sender: UnknownSender) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        sender.status = .added
        sender.lastTriagedAt = Date()
        try modelContext.save()
    }
}
