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

    /// Fetch all pending unknown senders, sorted by last name then first name.
    func fetchPending() throws -> [UnknownSender] {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<UnknownSender>()
        let all = try modelContext.fetch(descriptor)
        return all
            .filter { $0.status == .pending }
            .sorted { lhs, rhs in
                let lhsLast = lhs.displayName.flatMap { $0.split(separator: " ").last.map(String.init) } ?? lhs.email
                let rhsLast = rhs.displayName.flatMap { $0.split(separator: " ").last.map(String.init) } ?? rhs.email
                return lhsLast.localizedCaseInsensitiveCompare(rhsLast) == .orderedAscending
            }
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
    /// Sets isLikelyMarketing to true if any message from the sender has marketing headers — never cleared once set.
    func bulkRecordUnknownSenders(
        _ senders: [(email: String, displayName: String?, subject: String, date: Date, source: EvidenceSource, isLikelyMarketing: Bool)]
    ) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }

        // Fetch all existing unknown senders for lookup
        let descriptor = FetchDescriptor<UnknownSender>()
        let existing = try modelContext.fetch(descriptor)
        let existingByEmail = Dictionary(uniqueKeysWithValues: existing.map { ($0.email, $0) })

        var created = 0
        var updated = 0

        // Deduplicate input by email (keep latest date)
        var grouped: [String: (email: String, displayName: String?, subject: String, date: Date, source: EvidenceSource, isLikelyMarketing: Bool)] = [:]
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
                // Upgrade to marketing if newly detected (never cleared once set)
                if sender.isLikelyMarketing {
                    record.isLikelyMarketing = true
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
                    source: sender.source,
                    isLikelyMarketing: sender.isLikelyMarketing
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

    // MARK: - LinkedIn Metadata

    /// Update or create an UnknownSender record for a LinkedIn "Later" contact,
    /// stamping it with touch score, company, position, and connection date.
    /// Uses the same synthetic key format as LinkedInImportCoordinator.
    func upsertLinkedInLater(
        uniqueKey: String,
        displayName: String?,
        touchScore: Int,
        company: String?,
        position: String?,
        connectedOn: Date?
    ) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<UnknownSender>()
        let all = try modelContext.fetch(descriptor)
        let existing = all.first { $0.email == uniqueKey }

        if let record = existing {
            record.intentionalTouchScore = touchScore
            record.linkedInCompany = company
            record.linkedInPosition = position
            record.linkedInConnectedOn = connectedOn
            if let name = displayName, record.displayName == nil {
                record.displayName = name
            }
            // Re-surface if previously dismissed
            if record.status == .dismissed {
                record.status = .pending
            }
        } else {
            let record = UnknownSender(
                email: uniqueKey,
                displayName: displayName,
                status: .pending,
                firstSeenAt: connectedOn ?? Date(),
                emailCount: 1,
                latestSubject: uniqueKey,
                latestEmailDate: connectedOn ?? Date(),
                source: .linkedIn,
                isLikelyMarketing: false,
                intentionalTouchScore: touchScore,
                linkedInCompany: company,
                linkedInPosition: position,
                linkedInConnectedOn: connectedOn
            )
            modelContext.insert(record)
        }

        try modelContext.save()
    }

    // MARK: - Facebook Metadata

    /// Update or create an UnknownSender record for a Facebook "Later" contact,
    /// stamping it with touch score, friendship date, and message metadata.
    /// Uses synthetic key format: "facebook:{normalized-name}-{timestamp}".
    func upsertFacebookLater(
        uniqueKey: String,
        displayName: String?,
        touchScore: Int,
        friendedOn: Date?,
        messageCount: Int,
        lastMessageDate: Date?
    ) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<UnknownSender>()
        let all = try modelContext.fetch(descriptor)
        let existing = all.first { $0.email == uniqueKey }

        if let record = existing {
            record.intentionalTouchScore = touchScore
            record.facebookFriendedOn = friendedOn
            record.facebookMessageCount = messageCount
            record.facebookLastMessageDate = lastMessageDate
            if let name = displayName, record.displayName == nil {
                record.displayName = name
            }
            // Re-surface if previously dismissed
            if record.status == .dismissed {
                record.status = .pending
            }
        } else {
            let record = UnknownSender(
                email: uniqueKey,
                displayName: displayName,
                status: .pending,
                firstSeenAt: friendedOn ?? Date(),
                emailCount: 1,
                latestSubject: uniqueKey,
                latestEmailDate: friendedOn ?? Date(),
                source: .facebook,
                isLikelyMarketing: false,
                intentionalTouchScore: touchScore,
                facebookFriendedOn: friendedOn,
                facebookMessageCount: messageCount,
                facebookLastMessageDate: lastMessageDate
            )
            modelContext.insert(record)
        }

        try modelContext.save()
    }

    // MARK: - Substack Metadata

    /// Update or create an UnknownSender record for a Substack subscriber,
    /// stamping it with subscription date, plan type, and active status.
    func upsertSubstackLater(
        email: String,
        subscribedAt: Date?,
        planType: String?,
        isActive: Bool
    ) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let canonicalEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let descriptor = FetchDescriptor<UnknownSender>()
        let all = try modelContext.fetch(descriptor)
        let existing = all.first { $0.email == canonicalEmail }

        if let record = existing {
            record.substackSubscribedAt = subscribedAt
            record.substackPlanType = planType
            record.substackIsActive = isActive
            // Re-surface if previously dismissed
            if record.status == .dismissed {
                record.status = .pending
            }
        } else {
            let record = UnknownSender(
                email: canonicalEmail,
                displayName: nil,
                status: .pending,
                firstSeenAt: subscribedAt ?? Date(),
                emailCount: 1,
                latestSubject: "Substack subscriber",
                latestEmailDate: subscribedAt ?? Date(),
                source: .substack,
                isLikelyMarketing: false,
                substackSubscribedAt: subscribedAt,
                substackPlanType: planType,
                substackIsActive: isActive
            )
            modelContext.insert(record)
        }

        try modelContext.save()
    }
}
