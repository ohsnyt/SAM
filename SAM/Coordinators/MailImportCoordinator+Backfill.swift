//
//  MailImportCoordinator+Backfill.swift
//  SAM
//
//  Per-person mail-history backfill (2026-05-13).
//
//  When a contact is added (or recovered from a prior neverInclude exclusion),
//  the standard import lookback misses every message from before the window.
//  This extension lets the user pull ALL historical mail to/from a specific
//  person's addresses in one user-initiated action, with a preview step before
//  any evidence is written.
//

import AppKit
import Foundation
import os.log

private let backfillLogger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailBackfill")

extension MailImportCoordinator {

    // MARK: - Preview model

    /// Result of `previewHistoricalMail(for:)`. Held in @State by the preview
    /// sheet so the user can confirm before any rows are written.
    struct MailHistoryPreview: Identifiable, Sendable {
        let id = UUID()
        let personID: UUID
        let personName: String
        /// Canonical email addresses we searched on (lowercased, +tag stripped).
        let searchedEmails: [String]
        /// Combined count across inbound + outbound (before dedup).
        let totalFound: Int
        /// Messages already present in Evidence (matched by `mail:<Message-ID>` sourceUID).
        let alreadyImportedCount: Int
        /// Messages eligible for import, newest first.
        let newCandidates: [Candidate]

        var willImportCount: Int { newCandidates.count }

        var dateRange: (oldest: Date, newest: Date)? {
            guard let oldest = newCandidates.map(\.dto.date).min(),
                  let newest = newCandidates.map(\.dto.date).max()
            else { return nil }
            return (oldest, newest)
        }

        struct Candidate: Identifiable, Sendable {
            let id: String          // sourceUID — `mail:<Message-ID>`
            let dto: EmailDTO
            let direction: CommunicationDirection
        }
    }

    enum MailBackfillError: LocalizedError {
        case noDirectAccess
        case noEnvelope
        case noEmailsForPerson

        var errorDescription: String? {
            switch self {
            case .noDirectAccess:
                return "Direct Mail access isn't granted. Open Mail Settings and authorize Mail folder access."
            case .noEnvelope:
                return "Mail Envelope Index database not found. Make sure Mail.app has run at least once."
            case .noEmailsForPerson:
                return "This person has no email addresses on file. Add an email first, then retry."
            }
        }
    }

    // MARK: - Preview

    /// Scan the Mail Envelope Index for every historical message to/from the
    /// person's known email addresses. Does NOT write any evidence — caller
    /// must call `commitHistoricalMail(_:)` with the result to persist.
    func previewHistoricalMail(for person: SamPerson) async throws -> MailHistoryPreview {
        guard hasDirectAccess else { throw MailBackfillError.noDirectAccess }

        let personEmails = canonicalEmailsForPerson(person)
        guard !personEmails.isEmpty else { throw MailBackfillError.noEmailsForPerson }

        guard let dirURL = BookmarkManager.shared.resolveMailDirURL() else {
            throw MailBackfillError.noEnvelope
        }
        _ = dirURL.startAccessingSecurityScopedResource()
        defer { BookmarkManager.shared.stopAccessing(dirURL) }

        let mailDBService = MailDatabaseService.shared
        guard let versionDirURL = await mailDBService.findMailDataDir(rootURL: dirURL),
              let envelopeURL = await mailDBService.findEnvelopeIndex(in: versionDirURL) else {
            throw MailBackfillError.noEnvelope
        }

        let inboundCandidates = try await fetchInbound(
            envelopeURL: envelopeURL,
            personEmails: personEmails
        )
        let outboundCandidates = try await fetchOutbound(
            envelopeURL: envelopeURL,
            personEmails: Set(personEmails)
        )

        let combined = (inboundCandidates + outboundCandidates)
            .sorted { $0.dto.date > $1.dto.date }

        let evidenceRepository = EvidenceRepository.shared
        var existingCount = 0
        var newCandidates: [MailHistoryPreview.Candidate] = []
        newCandidates.reserveCapacity(combined.count)
        for candidate in combined {
            if (try? evidenceRepository.fetch(sourceUID: candidate.id)) != nil {
                existingCount += 1
            } else {
                newCandidates.append(candidate)
            }
        }

        backfillLogger.info(
            "Mail backfill preview for \(person.id, privacy: .private): found \(combined.count) total, \(existingCount) already imported, \(newCandidates.count) new"
        )

        return MailHistoryPreview(
            personID: person.id,
            personName: person.displayNameCache ?? person.displayName,
            searchedEmails: personEmails,
            totalFound: combined.count,
            alreadyImportedCount: existingCount,
            newCandidates: newCandidates
        )
    }

    // MARK: - Commit

    /// Persist the new candidates as Evidence rows. Idempotent on
    /// `mail:<Message-ID>` — re-running with the same preview is safe.
    /// Returns the number of rows actually upserted.
    @discardableResult
    func commitHistoricalMail(_ preview: MailHistoryPreview) throws -> Int {
        let evidenceRepository = EvidenceRepository.shared

        let inboundPairs: [(EmailDTO, EmailAnalysisDTO?)] = preview.newCandidates
            .filter { $0.direction == .inbound }
            .map { ($0.dto, nil) }
        let outboundPairs: [(EmailDTO, EmailAnalysisDTO?)] = preview.newCandidates
            .filter { $0.direction == .outbound }
            .map { ($0.dto, nil) }

        if !inboundPairs.isEmpty {
            try evidenceRepository.bulkUpsertEmails(inboundPairs, direction: .inbound)
        }
        if !outboundPairs.isEmpty {
            try evidenceRepository.bulkUpsertEmails(outboundPairs, direction: .outbound)
        }

        let count = inboundPairs.count + outboundPairs.count
        backfillLogger.info("Mail backfill commit: \(count) evidence rows upserted for person \(preview.personID, privacy: .private)")
        return count
    }

    // MARK: - Inbound / Outbound

    /// Mail FROM the person TO any user account. Sender-address match on the
    /// inbox-side query gives us the exact set.
    private func fetchInbound(
        envelopeURL: URL,
        personEmails: [String]
    ) async throws -> [MailHistoryPreview.Candidate] {
        let mailDBService = MailDatabaseService.shared
        let metas = try await mailDBService.fetchMetadata(
            dbURL: envelopeURL,
            since: .distantPast,
            accountEmails: selectedAccountIDs,
            maxResults: 2000,
            mailbox: .inbox,
            senderAddresses: personEmails,
            orderAscending: false
        )
        return metas.map { meta in
            let dto = EmailDTO(
                id: String(meta.mailID),
                messageID: meta.messageID,
                subject: meta.subject,
                senderName: MailService.extractName(from: meta.sender),
                senderEmail: meta.senderEmail,
                recipientEmails: [],
                ccEmails: [],
                bccEmails: [],
                date: meta.date,
                bodyPlainText: "",
                bodySnippet: "Historical mail — body not fetched during backfill.",
                isRead: true,
                folderName: "INBOX"
            )
            return MailHistoryPreview.Candidate(
                id: dto.sourceUID,
                dto: dto,
                direction: .inbound
            )
        }
    }

    /// Mail FROM the user TO the person. The DB doesn't let us filter on
    /// recipient at the SQL level, so we pull the user's sent mail and filter
    /// client-side after fetchMetadataOnly attaches recipient lists.
    private func fetchOutbound(
        envelopeURL: URL,
        personEmails: Set<String>
    ) async throws -> [MailHistoryPreview.Candidate] {
        let userAddrs = Array(userSenderAddresses())
        guard !userAddrs.isEmpty else { return [] }

        let mailDBService = MailDatabaseService.shared
        let sentMetas = try await mailDBService.fetchMetadata(
            dbURL: envelopeURL,
            since: .distantPast,
            accountEmails: selectedAccountIDs,
            maxResults: 5000,
            mailbox: .sent,
            senderAddresses: userAddrs,
            orderAscending: false
        )
        guard !sentMetas.isEmpty else { return [] }

        let dtos = (try? await mailDBService.fetchMetadataOnly(
            dbURL: envelopeURL,
            metas: sentMetas,
            mailbox: .sent
        )) ?? []

        return dtos.compactMap { dto -> MailHistoryPreview.Candidate? in
            let recipients = (dto.recipientEmails + dto.ccEmails + dto.bccEmails)
                .map { $0.lowercased() }
            let asSet = Set(recipients)
            guard !personEmails.intersection(asSet).isEmpty else { return nil }
            return MailHistoryPreview.Candidate(
                id: dto.sourceUID,
                dto: dto,
                direction: .outbound
            )
        }
    }

    // MARK: - Helpers

    private func canonicalEmailsForPerson(_ person: SamPerson) -> [String] {
        var set: Set<String> = []
        if let e = canonicalizeSenderAddress(person.emailCache) { set.insert(e) }
        for alias in person.emailAliases {
            if let e = canonicalizeSenderAddress(alias) { set.insert(e) }
        }
        return Array(set).sorted()
    }
}
