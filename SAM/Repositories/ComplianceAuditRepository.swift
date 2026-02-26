//
//  ComplianceAuditRepository.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase Z: Compliance Awareness
//
//  Manages persistence of compliance audit entries for AI-generated drafts.
//

import Foundation
import SwiftData
import os.log

@MainActor @Observable
final class ComplianceAuditRepository {

    static let shared = ComplianceAuditRepository()

    private var container: ModelContainer?
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ComplianceAuditRepository")

    private init() {}

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.container = container
    }

    private var context: ModelContext {
        guard let container else {
            fatalError("ComplianceAuditRepository: configure(container:) not called")
        }
        return ModelContext(container)
    }

    // MARK: - Public API

    /// Log a new AI-generated draft for audit.
    @discardableResult
    func logDraft(
        channel: String,
        recipientName: String? = nil,
        recipientAddress: String? = nil,
        originalDraft: String,
        complianceFlags: [ComplianceFlag] = [],
        outcomeID: UUID? = nil
    ) throws -> ComplianceAuditEntry {
        let ctx = context

        var flagsJSON: String?
        if !complianceFlags.isEmpty {
            let data = try JSONEncoder().encode(complianceFlags)
            flagsJSON = String(data: data, encoding: .utf8)
        }

        let entry = ComplianceAuditEntry(
            channel: channel,
            recipientName: recipientName,
            recipientAddress: recipientAddress,
            originalDraft: originalDraft,
            complianceFlagsJSON: flagsJSON,
            outcomeID: outcomeID
        )
        ctx.insert(entry)
        try ctx.save()
        logger.debug("Logged audit entry \(entry.id) for channel \(channel)")
        return entry
    }

    /// Mark an audit entry as sent with the final draft text.
    func markSent(entryID: UUID, finalDraft: String) throws {
        let ctx = context
        var descriptor = FetchDescriptor<ComplianceAuditEntry>(
            predicate: #Predicate { $0.id == entryID }
        )
        descriptor.fetchLimit = 1
        guard let entry = try ctx.fetch(descriptor).first else { return }
        entry.finalDraft = finalDraft
        entry.wasModified = (finalDraft != entry.originalDraft)
        entry.sentAt = Date()
        try ctx.save()
    }

    /// Fetch recent audit entries, newest first.
    func fetchRecent(limit: Int = 50) throws -> [ComplianceAuditEntry] {
        let ctx = context
        var descriptor = FetchDescriptor<ComplianceAuditEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try ctx.fetch(descriptor)
    }

    /// Total number of audit entries.
    func count() throws -> Int {
        let ctx = context
        let descriptor = FetchDescriptor<ComplianceAuditEntry>()
        return try ctx.fetchCount(descriptor)
    }

    /// Delete entries older than the retention period.
    func pruneExpired(retentionDays: Int = 90) throws {
        let ctx = context
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<ComplianceAuditEntry>(
            predicate: #Predicate { $0.createdAt < cutoff }
        )
        let expired = try ctx.fetch(descriptor)
        guard !expired.isEmpty else { return }
        for entry in expired {
            ctx.delete(entry)
        }
        try ctx.save()
        logger.info("Pruned \(expired.count) expired audit entries (>\(retentionDays)d)")
    }

    /// Clear all audit entries.
    func clearAll() throws {
        let ctx = context
        let descriptor = FetchDescriptor<ComplianceAuditEntry>()
        let all = try ctx.fetch(descriptor)
        for entry in all {
            ctx.delete(entry)
        }
        try ctx.save()
        logger.info("Cleared all \(all.count) audit entries")
    }
}
