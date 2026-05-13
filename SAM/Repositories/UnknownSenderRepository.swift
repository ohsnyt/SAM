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

    /// Uses `container.mainContext` rather than a private `ModelContext` so
    /// status mutations (`markAdded`, `purgeNeverInclude`) don't fault SamPerson
    /// references that PersonDetailView reads via `@Query` on the mainContext.
    /// Cross-context writes were crashing roleBadges fault-resolution when
    /// adding an UnknownSender as a person — see SphereRepository for the
    /// matching fix on that model.
    func configure(container: ModelContainer) {
        self.container = container
        self.modelContext = container.mainContext
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

    /// Delete any `.neverInclude` records whose identifier now belongs to a
    /// known SamPerson. The `UnknownSender.email` column stores both email
    /// addresses *and* canonicalized phone numbers (10-digit, digits-only),
    /// so a single Set covers both axes — pass in the union of
    /// `emailCache + emailAliases + phoneAliases` for every relevant person.
    /// Resolves the contradiction where a user previously excluded an
    /// address/number and later added that person (e.g. Jean was junked,
    /// then added as a Church Sphere contact with two emails + one phone).
    /// Without this cleanup the record is inert — the known-identifier check
    /// short-circuits past it — but if the SamPerson is ever unlinked,
    /// `.neverInclude` silently reactivates.
    @discardableResult
    func purgeNeverInclude(forKnownIdentifiers knownIdentifiers: Set<String>) throws -> Int {
        guard let modelContext else { throw RepositoryError.notConfigured }
        guard !knownIdentifiers.isEmpty else { return 0 }

        let descriptor = FetchDescriptor<UnknownSender>()
        let stale = try modelContext.fetch(descriptor)
            .filter { $0.status == .neverInclude && knownIdentifiers.contains($0.email) }
        guard !stale.isEmpty else { return 0 }

        for record in stale {
            modelContext.delete(record)
        }
        try modelContext.save()
        logger.info("Purged \(stale.count) stale neverInclude records superseded by SamPerson links")
        return stale.count
    }

    /// Returns every identifier (email or canonicalized phone) SAM has already
    /// triaged in any status. Use this to short-circuit bulk re-scans (WhatsApp
    /// JID sweep, sent-recipient discovery) so previously-seen senders aren't
    /// re-recorded on every import cycle. Pending senders are included because
    /// re-recording them inflates emailCount + latestEmailDate without adding
    /// signal — they're already in the triage queue.
    func triagedIdentifiers() throws -> Set<String> {
        guard let modelContext else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<UnknownSender>()
        let all = try modelContext.fetch(descriptor)
        return Set(all.map(\.email))
    }

    /// Fetch a single unknown sender by ID.
    func fetchByID(_ id: UUID) throws -> UnknownSender? {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<UnknownSender>()
        let all = try modelContext.fetch(descriptor)
        return all.first { $0.id == id }
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
        let existingByEmail = Dictionary(
            existing.map { ($0.email, $0) },
            uniquingKeysWith: { first, _ in first }
        )

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
                // Only count this sender as "updated" if the inbound date is
                // strictly newer than what we already have. Bulk re-scans
                // (e.g. WhatsApp full-DB sweeps every comms-import cycle) used
                // to bump emailCount + overwrite latestEmailDate every pass,
                // which produced inflated counters and stamped every record
                // with `Date()` regardless of whether new mail had arrived.
                guard sender.date > (record.latestEmailDate ?? .distantPast) else {
                    // Backfill display name if we now have one and didn't before.
                    if let name = sender.displayName, record.displayName == nil {
                        record.displayName = name
                    }
                    if sender.isLikelyMarketing {
                        record.isLikelyMarketing = true
                    }
                    continue
                }
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
            logger.debug("Unknown senders: \(created) new, \(updated) updated")
        }
    }

    // MARK: - Sent Recipient Discovery

    /// Upsert unknown recipients from sent mail.
    /// Increments sentEmailCount; tracks earliestSentDate for watermark reset on approval.
    /// Upgrades existing inbound records (.mail) to .sentMail if the user also sent to that address.
    func bulkRecordSentRecipients(
        _ recipients: [(email: String, displayName: String?, subject: String, date: Date)]
    ) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<UnknownSender>()
        let existing = try modelContext.fetch(descriptor)
        let existingByEmail = Dictionary(
            existing.map { ($0.email, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Deduplicate input by email (keep latest date, accumulate count)
        var grouped: [String: (email: String, displayName: String?, subject: String, date: Date, count: Int)] = [:]
        for r in recipients {
            let key = r.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let prev = grouped[key] {
                grouped[key] = (key, r.displayName ?? prev.displayName,
                                r.date > prev.date ? r.subject : prev.subject,
                                max(r.date, prev.date), prev.count + 1)
            } else {
                grouped[key] = (key, r.displayName, r.subject, r.date, 1)
            }
        }

        var created = 0
        var updated = 0

        for (canonicalEmail, r) in grouped {
            if let record = existingByEmail[canonicalEmail] {
                // Update existing record
                record.sentEmailCount += r.count
                record.latestSubject = r.subject
                record.latestEmailDate = r.date
                if let name = r.displayName, record.displayName == nil {
                    record.displayName = name
                }
                if record.earliestSentDate == nil || r.date < (record.earliestSentDate ?? .distantFuture) {
                    record.earliestSentDate = r.date
                }
                // Upgrade inbound-only record to sentMail (higher signal)
                if record.source == .mail {
                    record.source = .sentMail
                }
                // Re-surface dismissed on 2+ sends
                if record.status == .dismissed && record.sentEmailCount >= 2 {
                    record.status = .pending
                }
                updated += 1
            } else {
                // Create new sent-recipient record
                let record = UnknownSender(
                    email: canonicalEmail,
                    displayName: r.displayName,
                    status: .pending,
                    firstSeenAt: r.date,
                    emailCount: 0,
                    latestSubject: r.subject,
                    latestEmailDate: r.date,
                    source: .sentMail,
                    isLikelyMarketing: false
                )
                record.sentEmailCount = r.count
                record.earliestSentDate = r.date
                modelContext.insert(record)
                created += 1
            }
        }

        try modelContext.save()
        if created > 0 || updated > 0 {
            logger.debug("Sent recipients: \(created) new, \(updated) updated")
        }
    }

    // MARK: - Status Updates

    func markNeverInclude(_ sender: UnknownSender) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        sender.status = .neverInclude
        sender.lastTriagedAt = Date()
        try modelContext.save()
    }

    /// Mark a sender as never-include by identifier (email or phone handle).
    /// Creates the UnknownSender record if it doesn't exist yet.
    func markNeverInclude(identifier: String, source: EvidenceSource) throws {
        guard let modelContext else { throw RepositoryError.notConfigured }
        let canonical = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let descriptor = FetchDescriptor<UnknownSender>()
        let all = try modelContext.fetch(descriptor)

        if let existing = all.first(where: { $0.email == canonical }) {
            guard existing.status != .added else { return } // Don't override if already added as contact
            existing.status = .neverInclude
            existing.lastTriagedAt = Date()
        } else {
            let sender = UnknownSender(
                email: canonical,
                status: .neverInclude,
                latestSubject: "Auto-tagged: junk/spam",
                source: source,
                isLikelyMarketing: true
            )
            sender.lastTriagedAt = Date()
            modelContext.insert(sender)
        }

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
