//
//  MailImportCoordinator.swift
//  SAM_crm
//
//  Email Integration - Import Coordinator
//
//  Orchestrates email fetch → analyze → upsert pipeline via Mail.app.
//

import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailImportCoordinator")

@MainActor
@Observable
final class MailImportCoordinator {
    static let shared = MailImportCoordinator()

    // Dependencies
    private let mailService = MailService.shared
    private let analysisService = EmailAnalysisService.shared
    private let evidenceRepository = EvidenceRepository.shared
    private let peopleRepository = PeopleRepository.shared

    // Observable state
    var importStatus: ImportStatus = .idle
    var lastImportedAt: Date?
    var lastImportCount: Int = 0
    var lastError: String?
    var unknownSenderCount: Int = 0
    var knownSenderCount: Int = 0

    /// Available Mail.app accounts (loaded from service, not persisted)
    var availableAccounts: [MailAccountDTO] = []

    // Settings (observable vars synced to UserDefaults)
    private(set) var mailEnabled: Bool = false
    private(set) var selectedAccountIDs: [String] = []
    private(set) var importIntervalSeconds: TimeInterval = 600
    /// Lookback days for initial import. 0 means "All" (no limit).
    private(set) var lookbackDays: Int = 30
    private(set) var filterRules: [MailFilterRule] = []

    private(set) var lastMailWatermark: Date?

    private var lastImportTime: Date?
    private var importTask: Task<Void, Never>?

    private init() {
        mailEnabled = UserDefaults.standard.bool(forKey: "mailImportEnabled")
        selectedAccountIDs = UserDefaults.standard.stringArray(forKey: "mailSelectedAccountIDs") ?? []
        let interval = UserDefaults.standard.double(forKey: "mailImportInterval")
        importIntervalSeconds = interval > 0 ? interval : 600
        let days = UserDefaults.standard.integer(forKey: "mailLookbackDays")
        // 0 means "All" (no limit), negative means unset → default 30
        lookbackDays = days >= 0 && UserDefaults.standard.object(forKey: "mailLookbackDays") != nil ? days : 30
        if let data = UserDefaults.standard.data(forKey: "mailFilterRules"),
           let rules = try? JSONDecoder().decode([MailFilterRule].self, from: data) {
            filterRules = rules
        }
        if let ts = UserDefaults.standard.object(forKey: "mailLastWatermark") as? Double {
            lastMailWatermark = Date(timeIntervalSinceReferenceDate: ts)
        }
    }

    // MARK: - Settings Setters

    func setMailEnabled(_ value: Bool) {
        mailEnabled = value
        UserDefaults.standard.set(value, forKey: "mailImportEnabled")
    }

    func setSelectedAccountIDs(_ value: [String]) {
        selectedAccountIDs = value
        UserDefaults.standard.set(value, forKey: "mailSelectedAccountIDs")
    }

    func setImportInterval(_ value: TimeInterval) {
        importIntervalSeconds = value
        UserDefaults.standard.set(value, forKey: "mailImportInterval")
    }

    func setLookbackDays(_ value: Int) {
        let changed = value != lookbackDays
        lookbackDays = value
        UserDefaults.standard.set(value, forKey: "mailLookbackDays")
        if changed { resetMailWatermark() }
    }

    func resetMailWatermark() {
        lastMailWatermark = nil
        UserDefaults.standard.removeObject(forKey: "mailLastWatermark")
        logger.info("Mail watermark reset — next import will scan full lookback window")
    }

    func setFilterRules(_ value: [MailFilterRule]) {
        filterRules = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "mailFilterRules")
        }
    }

    // MARK: - Cancellation

    /// Cancel all background tasks. Called by AppDelegate on app termination.
    func cancelAll() {
        importTask?.cancel()
        importTask = nil
        if importStatus == .importing {
            importStatus = .idle
        }
        logger.info("All tasks cancelled")
    }

    // MARK: - Public API

    var isConfigured: Bool {
        !selectedAccountIDs.isEmpty
    }

    /// Load available accounts from Mail.app.
    func loadAccounts() async {
        availableAccounts = await mailService.fetchAccounts()
    }

    func startAutoImport() {
        guard mailEnabled, isConfigured else { return }
        Task { await importNow() }
    }

    /// Fire-and-forget import — does not block the caller.
    func startImport() {
        guard importStatus != .importing, isConfigured else { return }
        importTask?.cancel()
        importTask = Task { await performImport(force: true) }
    }

    func importNow() async {
        guard importStatus != .importing else {
            logger.debug("Import already in progress, skipping")
            return
        }
        importTask?.cancel()
        importTask = Task { await performImport(force: true) }
        await importTask?.value
    }

    /// Check if Mail.app is accessible. Returns nil on success.
    func checkMailAccess() async -> String? {
        await mailService.checkAccess()
    }

    // MARK: - Private

    private func performImport(force: Bool = false) async {
        guard isConfigured else {
            lastError = "No Mail accounts selected"
            return
        }

        if !force, let last = lastImportTime, Date().timeIntervalSince(last) < importIntervalSeconds {
            logger.debug("Skipping import — last import was \(Date().timeIntervalSince(last), format: .fixed(precision: 0))s ago (interval: \(self.importIntervalSeconds)s)")
            return
        }

        importStatus = .importing
        lastError = nil

        do {
            let lookbackDate: Date = lookbackDays == 0
                ? .distantPast
                : (Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date())
            let since = lastMailWatermark ?? lookbackDate

            // 1. Fast metadata sweep (all messages)
            let (allMetas, fetchWarnings) = try await mailService.fetchMetadata(
                accountIDs: selectedAccountIDs, since: since
            )

            if allMetas.isEmpty, let warning = fetchWarnings {
                lastError = warning
            }

            // 2. Build known emails set from PeopleRepository
            let knownEmails = try peopleRepository.allKnownEmails()

            // 3. Also exclude neverInclude senders
            let neverInclude = try UnknownSenderRepository.shared.neverIncludeEmails()

            // 4. Partition metas → known vs unknown
            let (knownMetas, unknownMetas) = partitionBySenderKnown(
                metas: allMetas,
                knownEmails: knownEmails,
                neverIncludeEmails: neverInclude
            )

            knownSenderCount = knownMetas.count
            unknownSenderCount = unknownMetas.count

            logger.info("\(knownMetas.count) emails from known senders, \(unknownMetas.count) unknown skipped")

            // 5. Record unknown senders for triage (excluding neverInclude)
            let unknownToRecord = unknownMetas.filter { !neverInclude.contains($0.senderEmail) }
            if !unknownToRecord.isEmpty {
                let senderData = unknownToRecord.map { meta in
                    (email: meta.senderEmail,
                     displayName: MailService.extractName(from: meta.sender),
                     subject: meta.subject,
                     date: meta.date,
                     source: EvidenceSource.mail,
                     isLikelyMarketing: meta.isLikelyMarketing)
                }
                try UnknownSenderRepository.shared.bulkRecordUnknownSenders(senderData)
            }

            // 6. Fetch bodies only for known senders (the expensive part)
            let emails = await mailService.fetchBodies(for: knownMetas, filterRules: filterRules)

            // 7. Analyze each email with on-device LLM
            var analyzedEmails: [(EmailDTO, EmailAnalysisDTO?)] = []
            for email in emails {
                guard !Task.isCancelled else {
                    logger.info("Mail import cancelled during analysis")
                    break
                }
                do {
                    let analysis = try await analysisService.analyzeEmail(
                        subject: email.subject,
                        body: email.bodyPlainText,
                        senderName: email.senderName
                    )
                    analyzedEmails.append((email, analysis))
                } catch {
                    logger.warning("Analysis failed for email \(email.messageID): \(error)")
                    analyzedEmails.append((email, nil))
                }
            }

            // 8. Upsert into EvidenceRepository
            try evidenceRepository.bulkUpsertEmails(analyzedEmails)

            // Update watermark to newest email date (from all metas, not just bodies)
            let allDates = knownMetas.map(\.date) + unknownMetas.map(\.date)
            if let newest = allDates.max() {
                lastMailWatermark = newest
                UserDefaults.standard.set(newest.timeIntervalSinceReferenceDate, forKey: "mailLastWatermark")
            }

            // 9. Trigger insights
            InsightGenerator.shared.startAutoGeneration()

            // 10. Prune orphaned mail evidence — only for known senders
            // We must NOT prune evidence for emails we intentionally skipped
            if !emails.isEmpty {
                let validUIDs = Set(emails.map { $0.sourceUID })
                try evidenceRepository.pruneMailOrphans(
                    validSourceUIDs: validUIDs,
                    scopedToSenderEmails: knownEmails
                )
            }

            lastImportedAt = Date()
            lastImportTime = Date()
            lastImportCount = emails.count
            importStatus = .success

            logger.info("Mail import complete: \(emails.count) emails from known senders")

        } catch {
            lastError = error.localizedDescription
            importStatus = .failed
            logger.error("Mail import failed: \(error)")
        }
    }

    // MARK: - Reprocess

    /// Reprocess emails for a specific sender (after user adds them as a contact).
    func reprocessForSender(email senderEmail: String) async {
        guard isConfigured else { return }

        do {
            let since: Date = lookbackDays == 0
                ? .distantPast
                : (Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date())

            // 1. Full metadata sweep
            let (allMetas, _) = try await mailService.fetchMetadata(
                accountIDs: selectedAccountIDs, since: since
            )

            // 2. Filter to just this sender's emails
            let senderMetas = allMetas.filter { $0.senderEmail == senderEmail.lowercased() }
            guard !senderMetas.isEmpty else {
                logger.info("No emails found for sender \(senderEmail, privacy: .public) to reprocess")
                return
            }

            // 3. Fetch bodies for those metas
            let emails = await mailService.fetchBodies(for: senderMetas, filterRules: filterRules)

            // 4. Analyze with LLM
            var analyzedEmails: [(EmailDTO, EmailAnalysisDTO?)] = []
            for email in emails {
                do {
                    let analysis = try await analysisService.analyzeEmail(
                        subject: email.subject,
                        body: email.bodyPlainText,
                        senderName: email.senderName
                    )
                    analyzedEmails.append((email, analysis))
                } catch {
                    logger.warning("Analysis failed for reprocess email \(email.messageID): \(error)")
                    analyzedEmails.append((email, nil))
                }
            }

            // 5. Upsert (deduplicates by sourceUID)
            try evidenceRepository.bulkUpsertEmails(analyzedEmails)

            // 6. Trigger insights
            InsightGenerator.shared.startAutoGeneration()

            logger.info("Reprocessed \(emails.count) emails for sender \(senderEmail, privacy: .public)")

        } catch {
            logger.error("Reprocess failed for \(senderEmail, privacy: .public): \(error)")
        }
    }

    // MARK: - Helpers

    /// Partition message metas into known-sender and unknown-sender groups.
    private func partitionBySenderKnown(
        metas: [MessageMeta],
        knownEmails: Set<String>,
        neverIncludeEmails: Set<String>
    ) -> (known: [MessageMeta], unknown: [MessageMeta]) {
        var known: [MessageMeta] = []
        var unknown: [MessageMeta] = []

        for meta in metas {
            if knownEmails.contains(meta.senderEmail) {
                known.append(meta)
            } else if neverIncludeEmails.contains(meta.senderEmail) {
                // Silently skip neverInclude — still "unknown" for counting
                unknown.append(meta)
            } else {
                unknown.append(meta)
            }
        }

        return (known, unknown)
    }

    enum ImportStatus: Equatable {
        case idle, importing, success, failed
    }
}
